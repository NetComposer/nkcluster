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

%% @doc Remote Node Control
-module(nkcluster_node_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkdist_proc).
-behaviour(gen_server).

-export([start_link/2, stop/1, get_info/1, get_all/0]).
-export([rpc/3, new_connection/1]).
-export([received_resp/3, received_event/3]).
-export([start/2, start_and_join/2, join/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([conn_spec/0, start_opts/0, rpc_opts/0]).


-type conn_spec() ::
    pid()|nklib:user_uri()|[pid()|nklib:user_uri()].

-type start_opts() ::
    #{
        connect => conn_spec(),
        password => binary(),
        tls_opts => nkpacket:tls_opts(),
        launch => launch_opts()
    }.

-type launch_opts() ::
    #{
    }.


-type rpc_opts() ::
   #{
        conn_pid => pid(),
        timeout => pos_integer()
    }.


-define(CONNECT_RETRY, 10000).
-define(PING_TIME, 5000).
-define(MAX_TIME_DIFF, 5000).
-define(DEF_REQ_TIME, 30000).

-include_lib("nklib/include/nklib.hrl").

-define(CLLOG(Type, Msg, Vars, State), 
    lager:Type("Node proxy ~s (~s) " Msg, 
               [State#state.node_id, State#state.conn_id|Vars])).

-define(TIMEOUT, 5*60*1000).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new node control process
%% If the key 'connect' is provided, it is supposed that the node is already
%% started, and we will try to connect to it.
%% If the key 'launch' is provided, the node will be started, using one of the
%% supported providers
-spec start_link(nkcluster:node_id(), start_opts()) ->
    {ok, pid()} | {error, term()}.

start_link(NodeId, Opts) ->
    gen_server:start_link(?MODULE, {NodeId, Opts}, []).


%% @doc Forces the stop of an started worker
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    gen_server:cast(Pid, stop).


%% @doc Gets info about a started worker
-spec get_info(pid()) ->
    {ok, map()} | {error, term()}.

get_info(Pid) ->
    do_call(Pid, get_info, ?TIMEOUT).


%% @doc Gets all started workers
-spec get_all() ->
    [{nkcluster:node_id(), binary(), pid()}].

get_all() ->
    [
        {NodeId, ConnId, Pid} ||
        {{NodeId, ConnId}, Pid} <- nklib_proc:values(?MODULE)
    ].


%% @private Sends a remote request
-spec rpc(pid(), nkcluster_protocol:rpc(), rpc_opts()) ->
    {reply, nkcluster:reply()} | {error, term()}.

rpc(Pid, Cmd, Opts) ->
    do_call(Pid, {rpc, Cmd, Opts}, ?TIMEOUT).


%% @private Sends a synchronous request
-spec new_connection(pid()) ->
    {ok, pid()} | {error, term()}.

new_connection(Pid) ->
    do_call(Pid, new_connection, ?TIMEOUT).


%% @private Called when a response is received
-spec received_resp(pid(), nkcluster_protocol:trans_id(), 
                    {reply, nkcluster:reply()} | {error, term()}) ->
    ok.

received_resp(Pid, TransId, Reply) ->
    gen_server:cast(Pid, {resp, TransId, Reply}).


%% @private Called when an event is received
-spec received_event(pid(), nkcluster:job_class(), nkcluster:event()) ->
    ok.

received_event(Pid, Class, Event) ->
    gen_server:cast(Pid, {event, Class, Event}).


% ===================================================================
%% nkdist_proc behaviour
%% ===================================================================


%% @doc Start a new process
-spec start(nkdist:proc_id(), Args::term()) ->
    {ok, pid()} | {error, term()}.

start({nkcluster, NodeId}, Opts) ->
    start_link(NodeId, Opts).


%% @doc Starts a new clone process
-spec start_and_join(nkdist:proc_id(), pid()) ->
    {ok, pid()} | {error, term()}.

start_and_join({nkcluster, NodeId}, Pid) ->
    start_link(NodeId, #{clone=>Pid}).


%% @doc Joins two existing processes
-spec join(Current::pid(), Old::pid()) ->
    ok | {error, term()}.

join(Pid, OldPid) ->
    gen_server:call(Pid, {join, OldPid}).



% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(req, {
    from :: {pid(), reference()} | ping,
    timer :: reference(),
    conn_pid :: pid()
}).


-record(state, {
    node_id :: nkcluster:node_id(),
    conn_id :: binary(),
    conn_pid :: pid(),
    status = init :: nkcluster:node_status() | init,
    connected = false :: boolean(),
    listen = [] :: [pid()|nklib:user_uri()],
    meta = [] :: [nklib:token()],
    latencies = [] :: [integer()],
    rpcs = #{} :: #{nkcluster_protocol:trans_id() => #req{}},
    classes = [] :: [module()],
    opts :: map()
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}}.

init({NodeId, #{connect:=Listen0}=Opts}) ->
    Listen = case is_list(Listen0) of
        false -> [Listen0];
        true when is_integer(hd(Listen0)) -> [Listen0];
        true -> Listen0
    end,
    State = #state{
        node_id = NodeId,
        conn_id = <<"unknown remote">>, 
        listen = Listen, 
        opts = Opts
    },
    ?CLLOG(info, "starting (~p)", [self()], State),
    self() ! connect,
    self() ! send_ping,
    {ok, State};

init({NodeId, #{launch:=_Launch}=Opts}) ->
    lager:info("Node proxy for ~s (~p) launching", [NodeId, self()]),
    State = #state{
        node_id = NodeId, 
        conn_id = <<"unknown remote">>, 
        opts = Opts
    },
    ?CLLOG(info, "launching (~p)", [self()], State),
    self() ! launch,
    {ok, State};

init({NodeId, #{clone:=Pid}}) ->
    case gen_server:call(Pid, freeze, 60000) of
        {ok, Data} ->
            #{
                node_id := NodeId,
                listen := Listen,
                meta := Meta,
                classes := Classes,
                opts := Opts
            } = Data,
            State = #state{
                node_id = NodeId,
                conn_id = <<"unknown remote">>,
                listen = Listen,
                meta = Meta,
                classes = Classes,
                opts = Opts
            },
            ?CLLOG(notice, "cloned from ~p (~p)", [Pid, self()], State),
            self() ! connect,
            self() ! send_ping,
            {ok, State};
        _ ->
            {stop, could_not_clone}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}}.

handle_call(new_connection, From, #state{connected=true}=State) ->
    #state{listen=Listen, conn_pid=ConnPid} = State,
    Opts = #{idle_timeout=>5000},
    Self = self(),
    spawn_link(
        fun() -> 
            Reply = case do_connect(Listen, Self, Opts) of
                {ok, NewConnPid, _NodeId, _Info} -> 
                    gen_server:cast(Self, {new_connection, NewConnPid}),
                    {ok, NewConnPid};
                error -> 
                    {ok, ConnPid}
            end,
            gen_server:reply(From, Reply)
        end),
    {noreply, State};

handle_call({new_connection, _New}, _From, State) ->
    {reply, {error, not_connected}, State};

handle_call(get_info, _From, State) ->
    #state{
        node_id = NodeId,
        conn_id = ConnId,
        listen = Listen,
        conn_pid = ConnPid,
        meta = Meta,
        status = Status,
        latencies = Latencies
    } = State,
    Lat = case length(Latencies) of
        0 -> 0;
        _ -> lists:sum(Latencies) div length(Latencies)
    end,
    Info = #{
        control_pid => self(),
        node_id => NodeId,
        conn_id => ConnId,
        listen => Listen,
        conn_pid => ConnPid,
        meta => Meta,
        status => Status,
        latency => Lat
    },
    {reply, {ok, Info}, State};

handle_call({rpc, Msg, Opts}, From, #state{connected=true}=State) ->
    case send_rpc(Msg, Opts, From, State) of
        {ok, State1} -> 
            {noreply, State1};
        {error, State1} ->
            {reply, {error, connection_failed}, State1}
    end;

handle_call({req, _Msg, _Opts}, _From, State) ->
    {reply, {error, not_connected}, State};

handle_call(freeze, From, State) ->
    #state{node_id=NodeId, listen=Listen, meta=Meta, classes=Classes, opts=Opts} = State,    
    Data = #{
        node_id => NodeId, 
        listen => Listen, 
        meta => Meta, 
        classes => Classes, 
        opts => Opts
    },
    gen_server:reply(From, {ok, Data}),
    {stop, normal, State};

handle_call({join, OldPid}, From, State) ->
    spawn(
        fun() ->
            Reply = case gen_server:call(OldPid, freeze, 60000) of
                {ok, _} -> ok;
                _ -> {error, could_not_join}
            end,
            gen_server:reply(From, Reply)
        end),
    {noreply, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, normal, #state{}}.

handle_cast({resp, TransId, Reply}, #state{rpcs=Rpcs}=State) ->
    case maps:get(TransId, Rpcs, undefined) of
        #req{from=From, timer=Timer} ->
            nklib_util:cancel_timer(Timer),
            do_reply(From, Reply),
            Rpcs1 = maps:remove(TransId, Rpcs),
            {noreply, State#state{rpcs=Rpcs1}};
        undefined ->
            ?CLLOG(notice, "received unexpected response", [], State),
            {noreply, State}
    end;

handle_cast({event, Class, Event}, State) ->
    #state{node_id=NodeId, classes=Classes} = State,
    State1 = case Class/=nkcluster andalso (not lists:member(Class, Classes)) of
        true -> State#state{classes=[Class|Classes]};
        false -> State
    end,
    State2 = case {Class, Event} of
        {nkcluster, {node_status, NodeStatus}} ->
            update_status(NodeStatus, true, State1);
        {nkcluster, {agent_update, Update}} ->
            nkcluster_nodes:control_update(NodeId, self(), Update),
            State1;
        _ ->
            send_event([Class], Event, State1),
            State1
    end,
    {noreply, State2};

handle_cast({pong, {reply, {LocTime, RemTime}}}, #state{connected=true}=State) ->
    #state{latencies=Latencies} = State,
    Now = nklib_util:l_timestamp(),
    Latency = (Now - LocTime),
    Diff = abs(Now - RemTime) div 1000,
    % lager:warning("LAT: ~p", [Latency div 1000]),
    case Diff  > ?MAX_TIME_DIFF of
        true ->
            ?CLLOG(warning, "has too much time drift (~p msecs)", [Diff], State),
            {stop, normal, State};
        false ->
            Latencies1 = Latencies++[Latency],
            {noreply, State#state{latencies=Latencies1}}
    end;

handle_cast({pong, {error, Error}}, #state{connected=true, conn_pid=ConnPid}=State) ->
    ?CLLOG(notice, "ping failed: ~p", [Error], State),
    nkpacket_connection:stop(ConnPid),
    {noreply, update_status(not_connected, false, State)};

handle_cast({new_connection, Pid}, State) ->
    monitor(process, Pid),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, normal, #state{}}.

handle_info(connect, #state{connected=true}=State) ->
    ?CLLOG(warning, "ordered to reconnect in ok status", [], State),
    {noreply, State};

handle_info(connect, State) ->
    connect(State);
    
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    #state{rpcs=Rpcs, conn_pid=ConnPid} = State,
    ListRpcs1 = lists:filter(
        fun({_TransId, #req{conn_pid=RpcPid, from=From}}) ->
            case RpcPid/=Pid of    
                true ->
                    true;
                false ->
                    do_reply(From, {error, connection_failed}),
                    false
            end
        end,
        maps:to_list(Rpcs)),
    State1 = State#state{rpcs=maps:from_list(ListRpcs1)},
    case Pid of
        ConnPid -> 
            State2 = update_status(not_connected, false, State1),
            connect(State2);
        _ -> 
            {noreply, State1}
    end;

handle_info({req_timeout, TransId}, State) ->
    handle_cast({resp, TransId, {error, timeout}}, State);

handle_info(send_ping, #state{connected=true}=State) ->
    Now = nklib_util:l_timestamp(),
    Cmd = {req, nkcluster, {ping, Now}},
    Timeout = ?PING_TIME * 75 div 100,
    % lager:error("SEND PING: ~p", [Timeout]),
    State2 = case send_rpc(Cmd, #{timeout=>Timeout}, ping, State) of
        {ok, State1} -> 
            State1;
        {error, State1} -> 
            ?CLLOG(notice, "ping send error", [], State1),
            State1
    end,
    erlang:send_after(?PING_TIME, self(), send_ping),
    {noreply, State2};

handle_info(send_ping, State) ->
    erlang:send_after(?PING_TIME, self(), send_ping),
    {noreply, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->  
    update_status(not_connected, false, State),
    ?CLLOG(debug, "terminating: ~p", [Reason], State).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Internal %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% @private
-spec connect(#state{}) ->
    {noreply, #state{}} | {stop, normal, #state{}}.

connect(#state{listen=[]}=State) ->
    ?CLLOG(notice, "exiting, no connections available", [], State),
    {stop, normal, State};

connect(#state{node_id=NodeId, listen=Listen, opts=Opts}=State) ->
    State1 = update_status(not_connected, false, State),
    case do_connect(Listen, self(), Opts) of
        {ok, ConnPid, NodeId, Info} ->
            MyListen = nkcluster_app:get(listen),
            case nkcluster_protocol:set_master(ConnPid, MyListen) of
                ok ->
                    Listen1 = maps:get(listen, Info, []),
                    case node(ConnPid)/=node() andalso Listen1/=[] of
                        true ->
                            ?CLLOG(info, "changing connection to local", [], State),
                            nkpacket_connection:stop(ConnPid),
                            connect(State1
                                #state{listen=Listen1});
                        false ->
                            monitor(process, ConnPid),
                            #{status:=NodeStatus, remote:=ConnId} = Info,
                            nklib_proc:put(?MODULE, {NodeId, ConnId}),
                            State2 = State1#state{
                                node_id = NodeId,
                                conn_id = ConnId,
                                listen = Listen1,
                                conn_pid = ConnPid,
                                meta = maps:get(meta, Info, #{}),
                                latencies = []
                            },
                            {noreply, update_status(NodeStatus, true, State2)}
                    end;
                {error, _} ->
                    connect_error(State1)
            end;
        {ok, _ConnPid, _OtherNodeId, _Info} ->
            lager:warning("Connected to node with different NodeId!"),
            {stop, normal, State};
        error ->
            connect_error(State1)
    end.


%% @private
connect_error(#state{conn_pid=ConnPid}=State) ->
    case is_pid(ConnPid) of
        true ->
            nkcluster_protocol:stop(ConnPid);
        false ->
            ok
    end,
    erlang:send_after(?CONNECT_RETRY, self(), connect),
    {noreply, update_status(not_connected, false, State)}.


%% @private
update_status(Status, Connected, State) ->
    #state{
        node_id = NodeId, 
        status = OldStatus, 
        listen = Listen, 
        meta = Meta,
        classes = Classes
    } = State,
    case OldStatus==Status of
        true -> 
            State;
        false -> 
            case NodeId of
                <<>> ->
                    ok;
                _ ->
                    Update = #{
                        status => Status,
                        meta => Meta, 
                        listen => Listen
                    },
                    nkcluster_nodes:control_update(NodeId, self(), Update),
                    send_event(Classes, {nkcluster, {node_status, Status}}, State),
                    ?CLLOG(info, "status changed from '~p' to '~p'", 
                           [OldStatus, Status], State)
            end,
            State#state{status=Status, connected=Connected}
    end.


%% @private
-spec send_rpc(term(), map(), {pid(), term()}|ping, #state{}) ->
    {ok|error, #state{}}.

send_rpc(Msg, Opts, From, #state{rpcs=Rpcs, conn_pid=ConnPid}=State) ->
    CurrentPid = case Opts of
        #{conn_pid:=UserPid} -> UserPid;
        _ -> ConnPid
    end,
    Timeout = maps:get(timeout, Opts, ?DEF_REQ_TIME),
    case nkcluster_protocol:send_rpc(CurrentPid, Msg) of
        {ok, TransId} ->
            Timer = erlang:send_after(Timeout, self(), {req_timeout, TransId}),
            Rpc = #req{from=From, timer=Timer, conn_pid=CurrentPid},
            Rpcs1 = maps:put(TransId, Rpc, Rpcs),
            {ok, State#state{rpcs=Rpcs1}};
        {error, _Error} when CurrentPid==ConnPid ->
            nkcluster_protocol:stop(CurrentPid),
            {error, update_status(not_connected, false, State)};
        {error, _} ->
            nkcluster_protocol:stop(CurrentPid),
            send_rpc(Msg, maps:remove(conn_pid, Opts), From, State)
    end.


%% @private
send_event([], _Event, _State) ->
    ok;

send_event([Class|Rest], Event, #state{node_id=NodeId}=State) ->
    case catch Class:event(NodeId, Event) of
        {'EXIT', Error} ->
            ?CLLOG(warning, "error calling ~p:event/3: ~p", [Class, Error], State);
        _ ->
            ok
    end,
    send_event(Rest, Event, State).


%% @private
-spec do_connect([nklib:uri()|pid()], pid(), map()) ->
    {ok, pid(), binary(), map()} | error.

do_connect([], _Host, _Opts) ->
    error;

do_connect([ConnPid|Rest], Host, Opts) when is_pid(ConnPid) ->
    case nkcluster_protocol:wait_auth(ConnPid) of
        {ok, NodeId, Info} ->
            % Probably the agent has started this connection
            nkcluster_protocol:take_control(ConnPid, Host),
            lager:info("Node proxy connected to ~p", [ConnPid]),
            {ok, ConnPid, NodeId, Info};
        {error, Error} ->
            lager:info("Node error connecting to ~p: ~p", [ConnPid, Error]),
            do_connect(Rest, Host, Opts)
    end;

do_connect([ConnUri|Rest], Host, Opts) ->
    Opts1 = Opts#{idle_timeout => 3*?PING_TIME},
    ConnOpts = nkcluster_agent:connect_opts({control, Host}, Host, Opts1),
    case nkpacket:connect(ConnUri, ConnOpts) of
        {ok, ConnPid} ->
            case nkcluster_protocol:wait_auth(ConnPid) of
                {ok, NodeId, Info} ->
                    ConnId = nklib_util:to_binary(ConnUri),
                    lager:info("Node proxy connected to ~s", [ConnId]),
                    {ok, ConnPid, NodeId, Info};
                {error, Error} ->
                    ConnId = nklib_util:to_binary(ConnUri),
                    lager:info("Node error connecting to ~s: ~p", [ConnId, Error]),
                    do_connect(Rest, Host, Opts)
            end;
        {error, Error} ->
            ConnId = nklib_util:to_binary(ConnUri),
            lager:info("Node error connecting to ~s: ~p", [ConnId, Error]),
            do_connect(Rest, Host, Opts)
    end.


%% @private
-spec do_reply({pid(), term()}|ping, term()) ->
    ok.

do_reply(ping, Reply) ->    
    gen_server:cast(self(), {pong, Reply});

do_reply(From, Reply) ->
    gen_server:reply(From, Reply).


%% @private
-spec do_call(pid(), term(), pos_integer()) ->
    term().

do_call(Pid, _Msg, _Timeout)  when Pid==self() ->
    {error, looped_request};

do_call(Pid, Msg, Timeout) ->
    case catch gen_server:call(Pid, Msg, Timeout) of
        {'EXIT', _} -> {error, worker_failed};
        Other -> Other
    end.


