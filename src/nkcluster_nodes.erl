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

%% @doc Master Management
-module(nkcluster_nodes).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkdist_gen_server).

-export([get_nodes/0, get_local_nodes/0]).
-export([get_node_info/1, get_local_node_info/1, get_node_pid/1]).
-export([rpc/3, new_connection/1, connect/2, stop/1]).
-export([announced/2, control_update/3]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2, handle_master/2]).

-export_type([info/0]).


-type update() ::
    #{
        status => nkcluster:node_status(),
        listen => [nklib:uri()],
        meta => [nklib:token()],
        stats => map()
    }.


-type info() ::

    #{
        id => nkcluster:node_id(),
        proxies => [pid()],
        status => nkcluster:node_status(),
        listen => [nklib:uri()],
        meta => [nklib:token()],
        stats => map()
    }.

-define(TIMEOUT, 60000).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Get the current recognized nodes
-spec get_nodes() ->
    [nkcluster:node_id()].

get_nodes() ->
    nkdist_gen_server:call(?MODULE, get_nodes, ?TIMEOUT).


%% @doc Get the current recognized nodes
-spec get_local_nodes() ->
    [nkcluster:node_id()].

get_local_nodes() ->
    gen_server:call(?MODULE, get_nodes, ?TIMEOUT).


%% @doc Get the current recognized nodes
-spec get_node_info(nkcluster:node_id()) ->
    {ok, info()} | {error, term()}.

get_node_info(NodeId) ->
    nkdist_gen_server:call(?MODULE, {get_node_info, NodeId}, ?TIMEOUT).


%% @doc Get the current recognized nodes
-spec get_local_node_info(nkcluster:node_id()) ->
    {ok, info()} | {error, term()}.

get_local_node_info(NodeId) ->
    gen_server:call(?MODULE, {get_node_info, NodeId}, ?TIMEOUT).


%% @doc Get the current pid for a node controller
-spec get_node_pid(nkcluster:node_id()) ->
    {ok, pid()} | {error, not_found} | {error, term()}.

get_node_pid(NodeId) ->
    nkdist:find_proc(nkcluster_node_proxy, NodeId).


%% @private Sends a remote request
-spec rpc(nkcluster:node_id(), nkcluster_protocol:rpc(), 
          nkcluster_node_proxy:rpc_opts()) ->
    {reply, nkcluster:reply()} | {error, term()}.

rpc(NodeId, Cmd, Opts) ->
    case get_node_pid(NodeId) of
        {ok, Pid} ->
            nkcluster_node_proxy:rpc(Pid, Cmd, Opts);
        {error, Error} ->
            {error, Error}
    end.

%% @private 
-spec new_connection(nkcluster:node_id()) ->
    {ok, pid()} | {error, term()}.

new_connection(NodeId) ->
    case get_node_pid(NodeId) of
        {ok, Pid} ->
            nkcluster_node_proxy:new_connection(Pid);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Manually connect to a remote worker, without knowing the NodeId
-spec connect(nklib:user_uri(), nkcluster_agent:connect_opts()) ->
    {ok, nkcluster:node_id(), map(), pid()} | {error, term()}.

connect(Uri, Opts) when is_map(Opts) ->
    case nkcluster_agent:connect(Uri, Opts) of
        {ok, NodeId, #{conn_pid:=ConnPid}=Info} ->
            case try_connect(NodeId, ConnPid, #{}) of
                {ok, Pid} -> {ok, NodeId, Info, Pid};
                {error, Error} -> {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


-spec stop(nkcluster:node_id()) ->
    ok | {error, term()}.

stop(NodeId) ->
    case get_node_pid(NodeId) of
        {ok, Pid} ->
            nkcluster_node_proxy:stop(Pid);
        {error, Error} ->
            {error, Error}
    end.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec announced(nkcluster:node_id(), pid()) ->
    ok.

announced(NodeId, ConnPid) ->
    gen_server:cast(?MODULE, {announced, NodeId, ConnPid}).


%% @private
-spec control_update(nkcluster:node_id(), pid(), update()) ->
    ok.

control_update(NodeId, ControlPid, Status) ->
    gen_server:cast(?MODULE, {control_update, NodeId, ControlPid, Status}).



% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_link() ->
    nkdist_gen_server:start_link(?MODULE, [], []).


%% We can have several controllers for remote node
-record(node, {
    info = #{} :: map(),
    pids = [] :: [pid()]
}).


-record(state, {
    master :: pid()|undefined,
    nodes = #{} :: #{nkcluster:node_id() => #node{}},
    pids = #{} :: #{pid() => nkcluster:node_id()}
}).


%% @private 
init([]) ->
	{ok, #state{}}.


-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call(get_nodes, _From, #state{nodes=Nodes}=State) ->
    {reply, maps:keys(Nodes), State};

handle_call({get_node_info, NodeId}, _From, #state{nodes=Nodes}=State) ->
    case maps:get(NodeId, Nodes, undefined) of
        #node{} = Node ->
            {reply, {ok, node_to_info(NodeId, Node)}, State};
        undefined ->
            {reply, {error, not_found}, State}
    end;

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({announced, NodeId, ConnPid}, State) ->
    lager:info("NkCLUSTER Nodes announce from ~s (~p)", [NodeId, ConnPid]),
    spawn(fun() -> try_connect(NodeId, ConnPid, #{}) end),
    {noreply, State};

handle_cast({control_update, NodeId, Pid, Info}, State) ->
    master_update(NodeId, Pid, Info, State),
    {noreply, do_update(NodeId, Pid, Info, State)};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info({'DOWN', _, process, Pid, _}, State) ->
    #state{nodes=Nodes, pids=Pids} = State,
    case maps:is_key(Pid, Pids) of
        true ->
            NodeId = maps:get(Pid, Pids),
            #node{pids=NodePids} = Node = maps:get(NodeId, Nodes),
            case NodePids -- [Pid] of
                [] ->
                    Nodes1 = maps:remove(NodeId, Nodes),
                    Pids1 = maps:remove(Pid, Pids),
                    {noreply, State#state{nodes=Nodes1, pids=Pids1}};
                NodePids1 ->
                    Node1 = Node#node{pids=NodePids1},
                    Nodes1 = maps:update(NodeId, Node1, Nodes),
                    Pids1 = maps:remove(Pid, Pids),
                    {noreply, State#state{nodes=Nodes1, pids=Pids1}}
            end;
        false ->
            lager:warning("Module ~p received unexpected 'DOWN': ~p", [?MODULE, Pid]),
            {noreply, State}
    end;

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec handle_master(pid()|undefined, #state{}) ->
    {ok, #state{}}.

handle_master(Master, State) when is_pid(Master) ->
    lager:notice("NkCLUSTER Nodes ~p master is ~p (~p)", [self(), node(Master), Master]),
    {ok, master_update_all(State#state{master=Master})};

handle_master(Master, State) ->
    lager:notice("NkCLUSTER Nodes ~p master is ~p", [self(), Master]),
    {ok, State#state{master=Master}}.


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


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Internal %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% @private
master_update(NodeId, Pid, Info, #state{master=Master}=State) 
        when is_pid(Master), Master /= self() ->
    gen_server:cast(Master, {control_update, NodeId, Pid, Info}),
    State;

master_update(_NodeId, _Pid, _Info, State) ->
    State.


%% private
master_update_all(#state{nodes=Nodes}=State) ->
    lists:foreach(
        fun({NodeId, #node{pids=Pids, info=Info}}) ->
            lists:foreach(
                fun(Pid) -> master_update(NodeId, Pid, Info, State) end,
                Pids)
        end,
        maps:to_list(Nodes)),
    State.


%% @private
node_to_info(NodeId, #node{info=Info, pids=Pids}) ->
    Info#{id=>NodeId, proxies=>Pids}.


%% @private
-spec do_update(nkcluster:node_id(), pid(), update(), #state{}) ->
    #state{}.

do_update(NodeId, Pid, Info, #state{nodes=Nodes, pids=Pids}=State) ->
    #node{info=NodeInfo, pids=NodePids} = maps:get(NodeId, Nodes, #node{}),
    Info2 = maps:merge(NodeInfo, Info),    
    Node2 = case lists:member(Pid, NodePids) of
        true -> 
            #node{info=Info2, pids=NodePids};
        false -> 
            #node{info=Info2, pids=[Pid|NodePids]}            
    end,
    Nodes2 = maps:put(NodeId, Node2, Nodes),
    Pids2 = case maps:get(Pid, Pids, undefined) of
        undefined ->
            monitor(process, Pid),
            maps:put(Pid, NodeId, Pids);
        NodeId ->
            Pids;
        _ ->
            lager:warning("NkCLUSTER Nodes received update for OLD node"),
            Pids
    end,
    State#state{nodes=Nodes2, pids=Pids2}.


%% @private
-spec try_connect(nkcluster:node_id(), term(), map()) ->
    {ok, pid()} | {error, term()}.

try_connect(NodeId, Connect, Opts) ->
    case nkdist:find_proc(nkcluster_node_proxy, NodeId) of
        {ok, Pid} ->
            {ok, Pid};
        {error, _} ->
            lager:info("NkCLUSTER Nodes starting proxy to ~s", [NodeId]),
            Arg = Opts#{connect=>Connect},
            case nkdist:start_proc(nkcluster_node_proxy, NodeId, Arg) of
                {ok, Pid} ->
                    {ok, Pid};
                {error, {already_started, Pid}} ->
                    {ok, Pid};
                {error, Error} ->
                    lager:warning("NkCLUSTER Nodes could not start proxy: ~p", [Error]),
                    {error, Error}
            end
    end.
        

