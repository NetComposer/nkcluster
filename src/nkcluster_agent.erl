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

%% @doc NkCLUSTER Agent Management
%% For masters, it tries to connect to other erlang nodes
%% For all:
%% - Monitors if any "primary" connection is available, and sends 
%%   os information
%% - If none is available, it tries to connect
%% - If cannot connect in a time, it powers off the machine if in cloud


-module(nkcluster_agent).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([node_id/0, is_control/0]).
-export([get_status/0, set_status/1, update_cluster_addr/3, connect/2]).
-export([connect_opts/3, ping_all_nodes/0, pong/0]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).

-include_lib("nklib/include/nklib.hrl").

-type connect_opts() ::
    #{
        password => binary(),
        tls_opts => nkpacket:tls_opts()
    }.

-define(PING_TIME, 15000).
-define(TIME_STATS, 10000).

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets current node ID
-spec node_id() ->
    nkcluster:node_id().

node_id() ->
    nkcluster_app:get(node_id).


%% @doc Finds if this node is a control node
-spec is_control() ->
    boolean().

is_control() ->
    nkcluster_app:get(is_control).


%% @doc Gets current node status
-spec get_status() ->
    {ok, nkcluster:node_status()}.

get_status() ->
    gen_server:call(?MODULE, get_status).


%% @doc Sets current node status
-spec set_status(ready|standby|stopped) ->
    ok | {error, term()}.

set_status(Status) when Status==ready; Status==standby; Status==stopped ->
    gen_server:call(?MODULE, {set_status, Status}).


%% @doc Update the announce list
-spec update_cluster_addr(boolean(), [nklib:user_uri()], connect_opts()) ->
    ok | {error, term()}.

update_cluster_addr(Preferred, ClusterAddr, Opts) ->
    case nkpacket:multi_resolve(ClusterAddr, Opts#{valid_schemes=>[nkcluster]}) of
        {ok, Conns} ->
            gen_server:cast(?MODULE, {update_addrs, Preferred, Conns});
        {error, Error} ->
            {error, Error}
    end.


%% @private Connects to remote node and gets info
-spec connect(nklib:user_uri(), connect_opts()) ->
    {ok, nkcluster:node_id(), map()}.

connect(NodeAddrs, Opts) ->
    case nkpacket:multi_resolve(NodeAddrs, Opts#{valid_schemes=>[nkcluster]}) of
        {ok, Conns} ->
            case do_connect(control, self(), Conns) of
                {ok, Pid, NodeId, Info} ->
                    {ok, NodeId, Info#{conn_pid=>Pid}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private Pings all control nodes to join them
ping_all_nodes() ->
    ClusterAddr = nkcluster_app:get(cluster_addr),
    case nkpacket:multi_resolve(ClusterAddr, #{valid_schemes=>[nkcluster]}) of
        {ok, Conns} ->
            lists:foreach(
                fun(Conn) ->
                    case do_connect(control, self(), [Conn]) of
                        {ok, Pid, NodeId, _Info} ->
                            lager:info("NkCLUSTER agent pinged ~s", [NodeId]),
                            nkpacket_connection:stop(Pid);
                        {error, Error} ->
                            lager:info("NkCLUSTER agent could not ping ~p: ~p", 
                                       [Conn, Error])
                    end
                end,
                Conns);
        {error, Error} ->
            {error, Error}
    end.


%% @private
pong() ->
    gen_server:cast(?MODULE, pong).



%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-record(state, {
    node_id :: binary(),
    cluster_addrs = [] :: [{[nkpacket:raw_connection()], map()}],
    pref_addrs = [] :: [{[nkpacket:raw_connection()], map()}],
    listen = [] :: [nklib:uri()],
    status :: nkcluster:node_status(),
    os_type :: term(),
    connecting :: boolean(),
    stats = #{} :: map(),
    timer :: reference()
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}}.

init([]) ->
    ok = update_cluster_addr(false, nkcluster_app:get(cluster_addr), #{}),
    OsType = case os:type() of
        {unix, Type} -> Type;
        _ -> unknown
    end,    
    State = #state{
        node_id = nkcluster_app:get(uuid),
        listen = nkcluster_app:get(listen),
        status = ready,
        os_type = OsType,
        connecting = false
    },
    case is_control() of
        true -> spawn(fun() -> ping_all_nodes() end);
        false -> ok
    end,
    erlang:send_after(1000, self(), get_stats),
    {ok, start_ping_timer(State)}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call(get_status, _From, #state{status=Status}=State) ->
    {reply, {ok, Status}, State};

handle_call({set_status, Status}, _From, #state{status=Status}=State) ->
    {reply, ok, State};

handle_call({set_status, New}, From, #state{status=Old}=State) ->
    case New of
        ready when Old==standby; Old==stopping; Old==stopped ->
            set_updated_status(ready, From, State);
        standby when Old==ready; Old==stopping; Old==stopped ->
            set_updated_status(standby, From, State);
        stopped when Old==ready; Old==standby; Old==stopping ->
            self() ! check_stopped,
            set_updated_status(stopping, From, State);
        _ ->
            {reply, {error, not_allowed}, State}
    end;

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({update_addrs, true, Addrs}, State) ->
    {noreply, State#state{pref_addrs=Addrs}};

handle_cast({update_addrs, false, Addrs}, State) ->
    {noreply, State#state{cluster_addrs=Addrs}};

handle_cast({send_update, Stats}, #state{connecting=Connecting}=State) ->
    Addrs = get_addrs(State),
    State1 = State#state{stats=Stats},
    State2 = case send_update(State1) of
        ok ->
            State1;
        {error, _} when Addrs==[] ->
            State1;
        {error, _} ->
            case nkcluster_protocol:send_announce() of
                ok ->
                    lager:info("Agent sent announcement", []),
                    State1;
                error when Connecting ->
                    State1;
                error ->
                    Self = self(),
                    spawn_link(fun() -> connect_and_announce(Self, Addrs) end),
                    State1#state{connecting=true}
            end
    end,
    erlang:send_after(?TIME_STATS, self(), get_stats),
    {noreply, State2};

handle_cast({connecting, false}, State) ->
    {noreply, State#state{connecting=false}};

handle_cast(pong, State) ->
    {noreply, start_ping_timer(State)};

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info(get_stats, State) ->
    spawn(fun() -> get_stats() end),
    {noreply, State};

handle_info(check_stopped, #state{status=stopping}=State) ->
    case nkcluster_jobs:get_tasks() of
        {ok, []} ->
            set_updated_status(stopped, none, State);
        _ ->
            erlang:send_after(5000, self(), check_stopped),
            {noreply, State}
    end;

handle_info(check_stopped, State) ->
    {noreply, State};

handle_info(ping_timeout, #state{connecting=false}=State) ->
    State1 = case get_addrs(State) of
        [] ->
            State;
        Addrs ->
            lager:notice("Agent ping timeout!", State),
            Self = self(),
            spawn_link(fun() -> connect_and_announce(Self, Addrs) end),
            State#state{connecting=true}
    end,
    {noreply, start_ping_timer(State1)};

handle_info(ping_timeout, #state{connecting=true}=State) ->
    {noreply, start_ping_timer(State)};

handle_info(Msg, State) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {noreply, start_ping_timer(State)}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->
    ok.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_stats() ->
    Stats = #{
        cpu => 
            #{
                nprocs => cpu_sup:nprocs(),
                avg1 => cpu_sup:avg1() / 256,
                avg5 => cpu_sup:avg5() / 256,
                avg15 => cpu_sup:avg15() / 256
            },
        memory =>
            maps:from_list(memsup:get_system_memory_data()),
        disks => 
            [
                #{path=>Path, size=>Size div 1024, user=>Use}
                || {Path, Size, Use} <- disksup:get_disk_data()
            ],
        time => 
            nklib_util:l_timestamp()
    },
    gen_server:cast(?MODULE, {send_update, Stats}).


%% @private
-spec send_update(#state{}) ->
    ok | {error, term()}.

send_update(#state{stats=Stats, listen=Listen, status=Status, os_type=OsType}) ->
    Update = #{
        status => Status,
        listen => Listen, 
        meta => nkcluster_app:get(meta),
        stats => Stats#{os_type=>OsType}
    },
    nkcluster_protocol:send_event(nkcluster, {agent_update, Update}).


%% @private
connect_and_announce(Self, Addrs) ->
    case do_connect(worker, Self, Addrs) of
        {ok, Pid, _NodeId, _Info} ->
            nkcluster_protocol:send_announce([Pid]);
        {error, Error} ->
            lager:info("Agent could not connect to any control node: ~p", [Error])
    end,
    gen_server:cast(Self, {connecting, false}).


%% @private
do_connect(_Type, _Host, []) ->
    {error, no_connections};

do_connect(Type, Host, [{Conns, Opts}|Rest]) ->
    ConnOpts = connect_opts(Type, Host, Opts),
    lager:info("Agent connecting to ~p", [Conns]),
    case catch nkpacket:connect(Conns, ConnOpts) of
        {ok, Pid} ->
            case nkcluster_protocol:wait_auth(Pid) of
                {ok, NodeId, Info} -> 
                    lager:info("Agent connected"),
                    {ok, Pid, NodeId, Info};
                {error, _} -> 
                    do_connect(Type, Host, Rest)
            end;
        {error, Error} ->
            lager:info("Agent could not connect to ~p: ~p", [Conns, Error]),
            do_connect(Type, Host, Rest)
    end.


%% @private
set_updated_status(Status, From, State) ->
    case From of
        none -> ok;
        _ -> gen_server:reply(From, ok)
    end,
    nkcluster_jobs:updated_status(Status),
    nkcluster_protocol:send_event(nkcluster, {node_status, Status}),
    {noreply, State#state{status=Status}}.


%% @private
-spec connect_opts(worker|{control, pid()}, pid(), map()) ->
    map().

connect_opts(Type, Host, Opts) ->
    UserOpts = maps:with([password], Opts),
    Opts#{
        group => nkcluster,
        valid_schemes => [nkcluster],
        monitor => Host,
        idle_timeout => maps:get(idle_timeout, Opts, 15000),
        ws_proto => nkcluster,
        tcp_packet => 4,
        tls_opts => maps:get(tls_opts, Opts, nkcluster_app:get(tls_opts)),
        user => maps:merge(#{type=>Type}, UserOpts)
    }.


%% @private
get_addrs(#state{pref_addrs=Pref, cluster_addrs=Cluster}) ->
    Pref ++ nklib_util:randomize(Cluster).


%% @private
start_ping_timer(#state{timer=Timer}=State) ->
    nklib_util:cancel_timer(Timer),
    State#state{timer=erlang:send_after(?PING_TIME, self(), ping_timeout)}.
    





