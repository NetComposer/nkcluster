%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Protocol behaviour
%%
%% This module implements the wire protocol for control and worker nodes
%%
-module(nkcluster_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).

-export([wait_auth/1, set_master/2, take_control/2]).
-export([send_rpc/2, send_reply/3, send_event/2, send_announce/0, send_announce/1]).
-export([get_all/0, encode/1, stop/1]).
-export([transports/1, default_port/1, naptr/2]).
-export([conn_init/1, conn_parse/3, conn_encode/2, conn_handle_call/4, 
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).

-export_type([conn_id/0, from/0, msg/0, rpc/0, trans_id/0]).

-include_lib("nklib/include/nklib.hrl").

-type conn_id() :: pid() | nkpacket:nkport().
-type trans_id() :: pos_integer().
-type from() :: {pid(), trans_id()}.

-type msg() ::
    announce |
    set_master |
    {auth, map()|{error, term()}} |
    {rpc, trans_id(), rpc()} |
    {rep, trans_id(), nkcluster:reply()} |
    {ev, nkcluster:job_class(), nkcluster:event()}.

-type rpc() ::
    {req, nkcluster:job_class(), nkcluster:request()} |
    {tsk, nkcluster:job_class(), nkcluster:task_id(), nkcluster:task()} |
    {cmd, nkcluster:job_class(), nkcluster:task_id(), nkcluster:command()}.




-define(VSNS, [0]).                 % Supported versions
-define(MAX_TIME_DIFF, 5000).

%% ===================================================================
%% Public
%% ===================================================================


%% @private Perfoms a synchronous request to authenticate to the worker
-spec wait_auth(conn_id()) ->
    {ok, nkcluster:node_id(), map()} | {error, term()}.

wait_auth(ConnId) ->
    do_call(ConnId, wait_auth).
    

%% @private Sets this connection as master for this cluster
-spec set_master(conn_id(), [nklib:uri()]) ->
    ok | {error, term()}.

set_master(ConnId, Uris) ->
    do_call(ConnId, {send, {set_master, Uris}}).


-spec take_control(ConnPid::pid(), Proxy::pid()) ->
    ok.

take_control(ConnPid, Proxy) ->
    gen_server:cast(ConnPid, {take_control, Proxy}).


%% @private
-spec send_rpc(conn_id(), rpc()) ->
    {ok, trans_id()} | {error, term()}.

send_rpc(ConnId, Rpc) ->
    do_call(ConnId, {rpc, Rpc}).


-spec send_reply(conn_id(), trans_id(), nkcluster:reply()) ->
    ok | {error, term()}.

send_reply(ConnId, TransId, Reply) ->
    do_call(ConnId, {send, encode({rep, TransId, Reply})}).


%% @private
-spec send_event(nkcluster:job_class(), nkcluster:event()) ->
    ok | {error, term()}.

send_event(Class, Msg) ->
    send_event(get_worker_master(), Class, Msg).


%% @doc Gets all worker 'main' connections
-spec get_worker_master() ->
    [pid()].

get_worker_master() ->
    [Pid || {undefined, Pid} <- nklib_proc:values(nkcluster_worker_master)].


%% @private
send_event([], _Class, _Msg) ->
    {error, no_connections};

send_event([Pid|Rest], Class, Msg) ->
    case do_call(Pid, {send, encode({ev, Class, Msg})}) of
        ok ->
            ok;
        {error, _} ->
            send_event(Rest, Class, Msg)
    end.


%% @private
-spec send_announce() ->
    ok | error.

send_announce() ->
    send_announce(get_all_worker()).


%% @private
send_announce([]) ->
    error;

send_announce([Pid|Rest]) ->
    case do_call(Pid, {send, announce}) of
        ok -> ok;
        _ -> send_announce(Rest)
    end.


%% @doc Gets all started connections
-spec get_all() ->
    [{control|worker, Node::nkcluster:node_id(), Remote::nkcluster:node_id(), pid()}].

get_all() ->
    [
        {Type, NodeId, Remote, Pid} || 
        {{Type, NodeId, Remote}, Pid} <- nklib_proc:values(nkcluster_conn)
    ].


%% @doc Gets all worker started connections to primary nodes
-spec get_all_worker() ->
    [pid()].

get_all_worker() ->
    [Pid || {worker, _NodeId, _Remote, Pid} <- get_all()].


%% @private
stop(Pid) ->
    nkpacket_connection:stop(Pid).


%% @private
-spec encode(term()) ->
    binary().

encode(Msg) ->
    erlang:term_to_binary(Msg, [compressed]).
    

%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(nkcluster) ->
    [tcp, tls, sctp, ws, wss].


-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(tcp) -> 1972;
default_port(tls) -> 1973;
default_port(sctp) -> 1972;
default_port(ws) -> 1974;
default_port(wss) -> 1975;
default_port(_) -> invalid.


-spec naptr(nklib:scheme(), string()) ->
    {ok, nkpacket:transport()} | invalid.

naptr(nkcluster, "nks+d2t") -> {ok, tls};
naptr(nkcluster, "nk+d2t") -> {ok, tcp};
naptr(nkcluster, "nks+d2w") -> {ok, wss};
naptr(nkcluster, "nk+d2w") -> {ok, ws};
naptr(nkcluster, "nk+d2s") -> {ok, sctp};
naptr(_, _) -> invalid.


%% ===================================================================
%% Connection callbacks
%% ===================================================================


-record(state, {
    nkport :: nkpacket:nkport(),
    type :: control | worker,
    node_id :: term(),
    auth = false :: boolean(),
    cluster :: term(),
    password :: term(),
    remote_node_id :: term(),
    remote_listen = [] :: [nklib:uri()],
    remote_meta = [] :: [nklib:token()],
    auth_froms = [] :: [{pid(), reference()}],
    vsn :: term(),
    pos_id :: trans_id(),
    control :: pid(),
    worker_master = false :: boolean()
}).


-spec conn_init(nkpacket:nkport()) ->
	{ok, #state{}}.

conn_init(NkPort) ->
    NodeId = nkcluster_agent:node_id(),
    {ok, _SrvId, #{type:=Type}=User} = nkpacket:get_user(NkPort),
    State = #state{
        nkport = NkPort,
        node_id = NodeId,
        pos_id = erlang:phash2({nklib_util:l_timestamp(), NodeId}) * 1000,
        password = maps:get(password, User, undefined)
    },
    lager:debug("NkCLUSTER node ~s (~p) starting connection", [NodeId, Type]),
    case User of
        #{type:=listen} ->
            % We don't know yet our type
            {ok, State};
        #{type:=control} ->
            % Later we will call take_control
            State1 = State#state{type=control},
            send_auth(NkPort, State1);
        #{type:={control, Pid}} when is_pid(Pid) ->
            State1 = State#state{type=control, control=Pid},
            send_auth(NkPort, State1);
        #{type:=worker} ->
            State1 = State#state{type=worker},
            send_auth(NkPort, State1)
    end.


%% @private
-spec conn_parse(term()|close, nkpacket:nkpacket(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
	{ok, State};

conn_parse({binary, WsBinary}, NkPort, State) ->
    conn_parse(WsBinary, NkPort, State);

conn_parse(Data, NkPort, #state{auth=false}=State) ->
    case catch binary_to_term(Data) of
        {auth, Msg} ->
            process_auth(Msg, NkPort, State);
        Other ->
            lager:warning("NkCLUSTER node received unexpected object, closing: ~p", 
                          [Other]),
            {stop, normal, State}
    end;

conn_parse(Data, NkPort, #state{auth=true, type=worker}=State) ->
    case catch binary_to_term(Data) of
        {set_master, Uris} ->
            ok = nkcluster_agent:update_cluster_addr(true, Uris),
            State1 = case State#state.worker_master of
                true -> 
                    State;
                false ->
                    nklib_proc:put(nkcluster_worker_master),
                    State#state{worker_master=true}
            end,
            {ok, State1};
        {rpc, TransId, {req, nkcluster, {ping, Time}}} ->
            nkcluster_agent:received_ping(),
            Reply = {reply, {Time, nklib_util:l_timestamp()}},
            ret_send({rep, TransId, Reply}, NkPort, State);
        {rpc, TransId, Rpc} ->
            case process_rpc(Rpc, {self(), TransId}) of
                defer -> {ok, State};
                Reply -> ret_send({rep, TransId, Reply}, NkPort, State)
            end;
        Other ->
            lager:warning("NkCLUSTER Worker received unexpected object, "
                          "closing: ~p", [Other]),
            {stop, normal, State}
    end;

conn_parse(Data, _NkPort, #state{auth=true, type=control}=State) ->
    case catch binary_to_term(Data) of
        announce ->
            #state{remote_node_id=RemNodeId} = State,
            nkcluster_nodes:node_announce(RemNodeId, self()),
            {ok, State};
        {rep, TransId, Reply} ->
            process_resp(TransId, Reply, State);
        {ev, Class, Event} ->
            process_event(Class, Event, State);
        Other ->
            lager:warning("NkCLUSTER Control received unexpected object, "
                          "closing: ~p", [Other]),
            {stop, normal, State}
    end.


-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Term, _NkPort) ->
    {ok, encode(Term)}.


%% @private
-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkpacket(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_call(wait_auth, From, NkPort, #state{auth=true}=State) ->
    gen_server:reply(From, get_remote(NkPort, State)),
    {ok, State};

conn_handle_call(wait_auth, From, _NkPort, State) ->
    #state{auth_froms=Froms} = State,
    {ok, State#state{auth_froms=[From|Froms]}};

conn_handle_call({rpc, Rpc}, From, NkPort, #state{pos_id=TransId}=State) ->
    do_send_rpc({rpc, TransId, Rpc}, From, NkPort, State);

conn_handle_call({send, Msg}, From, NkPort, #state{auth=true}=State)->
    ret_send2(Msg, From, NkPort, State);

conn_handle_call({send, _Msg}, From, _NkPort, State) ->
    gen_server:reply(From, {error, not_authenticated}),
    {ok, State};

conn_handle_call(Msg, _From, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


%% @private
-spec conn_handle_cast(term(), nkpacket:nkpacket(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_handle_cast({take_control, Proxy}, _NkPort, #state{type=control}=State) ->
    nkpacket_connection:update_monitor(self(), Proxy),
    {ok, State#state{control=Proxy}};

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @private
-spec conn_handle_info(term(), nkpacket:nkpacket(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

% nkcluster_jobs launchs processes with start_link
conn_handle_info({'EXIT', _, normal}, _NkPort, State) ->
    {ok, State};

conn_handle_info(Msg, _NkPort, State) ->
    lager:info("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkpacket(), #state{}) ->
    ok.

conn_stop(_Reason, NkPort, #state{type=Type}) ->
    lager:info("NkCLUSTER node (~p) disconnected from ~s", [Type, get_remote_id(NkPort)]).


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec do_call(pid()|nkpacket:nkport(), term()) ->
    term().

do_call(Id, Msg) ->
    Pid = nkpacket:pid(Id),
    case catch gen_server:call(Pid, Msg, 5*60*1000) of
        {'EXIT', Error} -> {error, {process_failed, Error}};
        Other -> Other
    end.


%% @private
send_auth(NkPort, #state{node_id=NodeId, type=Type}=State) ->
    AuthMsg = #{
        stage => 1, 
        vsns => ?VSNS, 
        id => NodeId,
        cluster => nkcluster_app:get(cluster_name),
        time => nklib_util:l_timestamp() div 1000,
        type => Type
    },
    case raw_send({auth, AuthMsg}, NkPort) of
        ok ->
            {ok, State};
        error ->
            {stop, connection_error}
    end.


%% @private
do_send_rpc(Msg, From, NkPort, #state{auth=true, pos_id=TransId}=State) ->
    case raw_send(Msg, NkPort) of
        ok ->
            gen_server:reply(From, {ok, TransId}),
            {ok, State#state{pos_id=TransId+1}};
        error ->
            gen_server:reply(From, {ok, connection_error}),
            {stop, normal, State}
    end;

do_send_rpc(_Msg, From, _NkPort, State) ->
    gen_server:reply(From, {error, not_authenticated}),
    {ok, State}.



%% @private
%% Processed at the listening side
process_auth(#{stage:=1, vsns:=Vsns, id:=RemNodeId, cluster:=Cluster, 
               type:=Type, time:=Time}, NkPort, State) ->
    case select_vsn(Vsns) of
        error ->
            not_authorized(unsupported_version, NkPort, State);
        Vsn ->
            Now = nklib_util:l_timestamp() div 1000,
            Drift = abs(Now-Time),
            case Drift > ?MAX_TIME_DIFF of
                true ->
                    lager:warning("NkCLUSTER node big time drift: ~p", [Drift]);
                    % not_authorized(time_drift, State);
                false ->
                    ok
            end,
            Hash = make_auth_hash(RemNodeId, NkPort, State),
            #state{node_id=NodeId} = State,
            Stage2 = #{
                stage => 2, 
                id => NodeId, 
                vsn => Vsn, 
                hash => Hash
            },
            OurType = case Type of
                control -> worker;
                worker -> control
            end,
            State1 = State#state{
                type = OurType, 
                cluster = Cluster,
                remote_node_id = RemNodeId, 
                vsn=Vsn
            },
            ret_send({auth, Stage2}, NkPort, State1)
    end;

%% Processed at the connecting side
process_auth(#{stage:=2, id:=ListenId, vsn:=Vsn, hash:=Hash}, NkPort, State) ->
    true = lists:member(Vsn, ?VSNS),
    #state{node_id=NodeId} = State,
    case make_auth_hash(NodeId, NkPort, State) of
        Hash ->
            % The remote (listening) side has a valid password
            % We send listen and meta, and try to authenticated ourselves
            State1 = State#state{remote_node_id=ListenId},
            Base3 = #{
                stage => 3, 
                hash => make_auth_hash(ListenId, NkPort, State),
                listen => nkcluster_app:get(listen),
                meta => nkcluster_app:get(meta)
            },
            Stage3 = case nkcluster_agent:is_primary() of
                true -> Base3#{primary_nodes=>riak_core_node_watcher:nodes(nkdist)};
                false -> Base3
            end,
            ret_send({auth, Stage3}, NkPort, State1); 
        _ ->
            not_authorized(invalid_password, NkPort, State)
    end;

%% Processed at the listening side again
process_auth(#{stage:=3, listen:=Listen, meta:=Meta, hash:=Hash}=Msg, NkPort, State) ->
    #state{node_id=ListenId, type=Type} = State,
    case make_auth_hash(ListenId, NkPort, State) of
        Hash ->
            % The remote (connecting) side has a valid password
            % We send listen and meta
            lager:info("NkCLUSTER node (~p) connected to ~s", 
                       [Type, get_remote_id(NkPort)]),
            State1 = State#state{
                remote_listen = Listen,
                remote_meta = Meta,
                auth = true
            },
            register(State1),
            join_nodes(Msg),
            Base4 = #{
                stage => 4,
                listen => nkcluster_app:get(listen),
                meta => nkcluster_app:get(meta)
            },
            Stage4 = case nkcluster_agent:is_primary() of
                true -> Base4#{primary_nodes=>riak_core_node_watcher:nodes(nkdist)};
                false -> Base4
            end,
            ret_send({auth, Stage4}, NkPort, State1);
        _ ->
            not_authorized(invalid_password, NkPort, State)
    end;
    
%% Processed at the connecting side again, both sides are autenticated
process_auth(#{stage:=4, listen:=Listen, meta:=Meta}=Msg, NkPort, State) ->
    State2 = State#state{
        remote_listen = Listen,
        remote_meta = Meta
    },
    #state{type=Type} = State,
    lager:info("NkCLUSTER node (~p) connected to ~s", [Type, get_remote_id(NkPort)]),
    join_nodes(Msg),
    register(State2),
    #state{auth_froms=AuthFroms} = State,
    lists:foreach(
        fun(From) -> gen_server:reply(From, get_remote(NkPort, State2)) end,
        AuthFroms),
    {ok, State2#state{auth=true, auth_froms=[]}};

process_auth({error, Error}, NkPort, #state{node_id=NodeId}=State) ->
    lager:notice("NkCLUSTER node ~s authentication error: ~p", [NodeId, Error]),
    not_authorized(Error, NkPort, State).


%% @private
process_rpc({req, Class, Req}, From) ->
    nkcluster_jobs:request(Class, Req, From);

process_rpc({tsk, Class, TaskId, Spec}, From) ->
    nkcluster_jobs:task(Class, TaskId, Spec, From);

process_rpc({cmd, Class, TaskId, Cmd}, From) ->
    nkcluster_jobs:command(Class, TaskId, Cmd, From).


%% @private
process_resp(TransId, Msg, #state{control=Pid}=State) ->
    nkcluster_node_proxy:received_resp(Pid, TransId, Msg),
    {ok, State}.

%% @private
process_event(Class, Event, #state{control=Pid}=State) ->
    nkcluster_node_proxy:received_event(Pid, Class, Event),
    {ok, State}.


%% @private
-spec ret_send2(msg()|binary(), {pid(), term()}, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

ret_send2(Msg, From, NkPort, State) ->
    case raw_send(Msg, NkPort) of
        ok ->
            gen_server:reply(From, ok),
            {ok, State};
        error ->
            gen_server:reply(From, {error, connection_error}),
            {stop, normal, State}
    end.


%% @private
-spec ret_send(msg()|binary(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

ret_send(Msg, NkPort, State) ->
    case raw_send(Msg, NkPort) of
        ok ->
            {ok, State};
        error ->
            {stop, normal, State}
    end.


%% @private
-spec raw_send(msg()|binary(), nkpacket:nkport()) ->
    ok | error.

raw_send(Msg, NkPort) when is_binary(Msg) ->
    case nkpacket_connection_lib:raw_send(NkPort, Msg) of
        ok ->
            ok;
        {error, closed} ->
            error;
        {error, Error} ->
            lager:notice("NkCLUSTER node error sending ~p: ~p", [Msg, Error]),
            error
    end;

raw_send(Msg, NkPort) ->
    raw_send(encode(Msg), NkPort).


%% @private
select_vsn(Vsns) -> 
    case sort_vsns(Vsns, []) of
        [Vsn|_] -> Vsn;
        [] -> error
    end.


%% @private
sort_vsns([], Acc) ->
    lists:reverse(lists:sort(Acc));

sort_vsns([Vsn|Rest], Acc) ->
    case lists:member(Vsn, ?VSNS) of
        true -> sort_vsns(Rest, [Vsn|Acc]);
        false -> sort_vsns(Rest, Acc)
    end.


%% @private
make_auth_hash(Salt, NkPort, #state{password=Pass}) ->
    Pass2 = case Pass of
        undefined -> nkcluster_app:get(password);
        _ -> Pass
    end,
    {ok, {_Proto, Transp, _, _}} = nkpacket:get_local(NkPort),
    case Transp==tls orelse Transp==wss of
        true ->
            Pass2;
        false ->
            pbkdf2(Pass2, Salt)
    end.


%% @private
register(#state{type=Type, node_id=NodeId, remote_node_id=RemNodeId}) ->
    nklib_proc:put(nkcluster_conn, {Type, NodeId, RemNodeId}).


%% @private
not_authorized(Error, NkPort, #state{auth_froms=AuthFroms}=State) ->
    lists:foreach(
        fun(From) -> gen_server:reply(From, {error, Error}) end,
        AuthFroms),
    case Error of
        invalid_password -> timer:sleep(500);
        _ -> ok
    end,
    raw_send({auth, {error, Error}}, NkPort),
    {stop, normal, State}.


%% @private
get_remote(NkPort, State) ->
    #state{
        remote_node_id = NodeId, 
        remote_listen = Listen, 
        remote_meta = Meta
    } = State,
    Remote = get_remote_id(NkPort),
    Status = nkcluster_agent:get_status(),
    {ok, NodeId, #{status=>Status, listen=>Listen, meta=>Meta, remote=>Remote}}.


%% @private
get_remote_id(NkPort) ->
    {ok, {_, Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    nklib_util:bjoin([Transp, nklib_util:to_host(Ip), Port], <<":">>).


%% @private
join_nodes(#{primary_nodes:=Nodes}) ->
    nkcluster_agent:join_nodes(Nodes);
join_nodes(_) ->
    ok.


%% @private
pbkdf2(Pass, Salt) ->
    Iters = nkcluster_app:get(pbkdf2_iters),
    {ok, Hash} = pbkdf2:pbkdf2(sha, Pass, Salt, Iters),
    Hash.

