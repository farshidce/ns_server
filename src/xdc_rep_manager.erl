%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.
%%
%% The XDC Replication Manager (XRM) manages vbucket replication to remote data
%% centers. Each instance of XRM running on a node is responsible for only
%% replicating the node's active vbuckets. Individual vbucket replications are
%% are controlled by adding/deleting replication documents to the _replicator
%% db.
%%
%% A typical XDC replication document will look as follows:
%% {
%%   "_id" : "my_xdc_rep",
%%   "type" : "xdc",
%%   "source" : "bucket0",
%%   "target" : "/remoteClusters/clusterUUID/buckets/bucket0",
%%   "continuous" : true
%% }
%%

-module(xdc_rep_manager).
-behaviour(gen_server).

-export([stats/1]).
-export([start_link/0, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("xdc_replicator.hrl").


%% Record to store and track changes to the _replicator db
-record(rep_db_state, {
    changes_feed_loop = nil,
    rep_db_name = nil
    }).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% returns a list of replication stats for the bucket. the format for each
% item in the list is:
% {ReplicationDocId,           & the settings doc id for this replication
%    [{changes_left, Integer}, % amount of work remaining
%     {docs_checked, Integer}, % total number of docs checked on target, survives restarts
%     {docs_written, Integer}, % total number of docs written to target, survives restarts
%     {vbs_replicating,[Integer, ...]} % list of vbuckets actively replicating
%    ]
% }
stats(Bucket) ->
    gen_server:call(?MODULE, {stats, Bucket}).


init(_) ->
    <<"_replicator">> = ?l2b(couch_config:get("replicator", "db",
                                              "_replicator")),

    maybe_create_replication_info_ddoc(),

    %% monitor replication doc change
    {Loop, <<"_replicator">> = RepDbName} = changes_feed_loop(),

    {ok, #rep_db_state{
       changes_feed_loop = Loop,
       rep_db_name = RepDbName
      }}.

maybe_create_replication_info_ddoc() ->
    UserCtx = #user_ctx{roles = [<<"_admin">>, <<"_replicator">>]},
    DB = case couch_db:open_int(<<"_replicator">>,
                                [sys_db, {user_ctx, UserCtx}]) of
             {ok, XDb} ->
                 XDb;
             _Error ->
                 {ok, XDb} = couch_db:create(<<"_replicator">>,
                                             [sys_db, {user_ctx, UserCtx}]),
                 ?xdcr_info("replication info doc created: ~n~p", [XDb]),
                 XDb
         end,
    try couch_db:open_doc(DB, <<"_design/_replicator_info">>, []) of
        {ok, _Doc} ->
            ok;
        _ ->
            DDoc = couch_doc:from_json_obj(
                     {[
                        {<<"meta">>, {[{<<"id">>, <<"_design/_replicator_info">>}]}},
                        {<<"json">>, {[
                          {<<"language">>, <<"javascript">>},
                          {<<"views">>,
                            {[{<<"infos">>,
                               {[{<<"map">>, ?REPLICATION_INFOS_MAP},
                                 {<<"reduce">>, ?REPLICATION_INFOS_REDUCE}]}}]}}]}}]}),
            ok = couch_db:update_doc(DB, DDoc, [])
    after
        couch_db:close(DB)
    end.

handle_call({stats, Bucket0}, _, State) ->
    Bucket = list_to_binary(Bucket0),
    Reps = try xdc_replication_sup:get_replications(Bucket)
           catch T:E ->
                   ?xdcr_error("xdcr stats Error:~p", [{T,E,erlang:get_stacktrace()}]),
                   []
           end,
    Stats = lists:foldl(
        fun({Id, Pid}, Acc) ->
                case catch xdc_replication:stats(Pid) of
                    {ok, Stats} ->
                        [{Id, Stats} | Acc];
                    Error ->
                        ?xdcr_error("Error getting stats for bucket ~s with"
                                   " id ~s :~p", [Bucket, Id, Error])
                end
        end, [], Reps),
    {reply, Stats, State};

handle_call(Msg, From, State) ->
    ?xdcr_error("replication manager received unexpected call ~p from ~p",
                [Msg, From]),
    {stop, {error, {unexpected_call, Msg}}, State}.


handle_cast({rep_db_update, {ChangeProps} = Change}, State) ->
    try
        {noreply, process_update(Change, State)}
    catch
        _Tag:Error ->
            {json, DocJSON} = get_value(doc, ChangeProps),
            {DocProps} = ?JSON_DECODE(DocJSON),
            {Meta} = get_value(<<"meta">>, DocProps, {[]}),
            DocId = get_value(<<"id">>, Meta),
            ?xdcr_error("~s: xdc replication error: ~p~n~p",
                        [DocId, Error, erlang:get_stacktrace()]),
            {noreply, State}
    end;

handle_cast(Msg, State) ->
    ?xdcr_error("replication manager received unexpected cast ~p", [Msg]),
    {stop, {error, {unexpected_cast, Msg}}, State}.


handle_info(Msg, State) ->
    %% Ignore any other messages but log them
    ?xdcr_info("ignoring unexpected message: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, _State) ->
    xdc_replication_sup:shutdown().

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

process_update({Change}, State) ->
    DocDeleted = get_value(<<"deleted">>, Change, false),
    DocId = get_value(<<"id">>, Change),
    {json, DocJSON} = get_value(doc, Change),
    {DocProps} = ?JSON_DECODE(DocJSON),
    {Props} = get_value(<<"json">>, DocProps, {[]}),
    case DocDeleted of
        true ->
            ?xdcr_debug("replication doc deleted (docId: ~p), stop all replications",
                        [DocId]),
            xdc_replication_sup:stop_replication(DocId),
            State;
        false ->
            case get_value(<<"type">>, Props) of
                <<"xdc">> ->
                    ?xdcr_debug("replication doc (docId: ~p) modified, parse "
                                "new doc and adjsut replications for change ("
                                "source ~p, target: ~p)",
                                [DocId, get_value(<<"source">>, Props),
                                 get_value(<<"target">>, Props)]),

                    XRep = parse_xdc_rep_doc(DocId, {Props}),
                    xdc_replication_sup:stop_replication(DocId),
                    {ok, _Pid} = xdc_replication_sup:start_replication(XRep),
                    State;
                _ ->
                    State
            end
    end.


%% monitor replication doc change. msg rep_db_udpate will be sent to
%% XDCR manager if rep doc is changed.
changes_feed_loop() ->
    {ok, RepDb} = ensure_rep_db_exists(),
    RepDbName = couch_db:name(RepDb),
    couch_db:close(RepDb),
    Server = self(),
    Pid = spawn_link(
            fun() ->
                    {ok, Db} = couch_db:open_int(RepDbName, [sys_db]),
                    ChangesFeedFun = couch_changes:handle_changes(
                                       #changes_args{
                                          include_docs = true,
                                          feed = "continuous",
                                          timeout = infinity,
                                          db_open_options = [sys_db]
                                         },
                                       {json_req, null},
                                       Db
                                      ),
                    ChangesFeedFun(
                      fun({change, Change, _}, _) ->
                              case has_valid_rep_id(Change) of
                                  true ->
                                      ok = gen_server:cast(
                                             Server, {rep_db_update, Change});
                                  false ->
                                      ok
                              end;
                         (_, _) ->
                              ok
                      end
                     ),
                    couch_db:close(Db)
            end
           ),
    {Pid, RepDbName}.

%% make sure the replication db exists in couchdb
ensure_rep_db_exists() ->
    DbName = ?l2b(couch_config:get("replicator", "db", "_replicator")),
    UserCtx = #user_ctx{roles = [<<"_admin">>, <<"_replicator">>]},
    case couch_db:open_int(DbName, [sys_db, {user_ctx, UserCtx}]) of
        {ok, Db} ->
            Db;
        _Error ->
            {ok, Db} = couch_db:create(DbName, [sys_db, {user_ctx, UserCtx}])
    end,
    {ok, Db}.


has_valid_rep_id({Change}) ->
    has_valid_rep_id(get_value(<<"id">>, Change));
has_valid_rep_id(<<?DESIGN_DOC_PREFIX, _Rest/binary>>) ->
    false;
has_valid_rep_id(_Else) ->
    true.


%% validate and parse XDC rep doc
parse_xdc_rep_doc(RepDocId, RepDoc) ->
    try
        xdc_rep_utils:parse_rep_doc(RepDocId, RepDoc)
    catch
        throw:{error, Reason} ->
            throw({bad_rep_doc, Reason});
        Tag:Err ->
            throw({bad_rep_doc, to_binary({Tag, Err})})
    end.

