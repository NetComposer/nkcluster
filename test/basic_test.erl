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

-module(basic_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("nklib/include/nklib.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(RECV(Term), receive Term -> Term after 1000 -> error(?LINE) end).

-define(EVENT(NodeId), event(NodeId, ?LINE)).

basic_test_() ->
  	{setup, 


    	fun() -> 
    		ok = nkcluster_app:start()
		end,
		fun(_) -> 
			ok 
		end,
	    fun(_) ->
		    [
				fun() -> connect() end,
				{timeout, 10000, fun() -> proxy() end}
			]
		end
  	}.




connect() ->
	?debugMsg("Starting CONNECT test"),
	true = nkcluster_agent:is_control(),
	{ok, ready} = nkcluster_agent:get_status(),
	NodeId = nkcluster_agent:node_id(),
	{ok, []} = nkdist:get_procs(),
	{error, {invalid_scheme, http}} = nkcluster_agent:connect("http://localhost", #{}),
	{error, {invalid_transport, udp}} = nkcluster_agent:connect("nkcluster://localhost;transport=udp", #{}),

	{error, no_connections} = nkcluster_agent:connect("nkcluster://localhost", #{}),

	% We start a raw connection, with a 15secs timeout, no announce is sent
	{ok, NodeId, Info} = 
		nkcluster_agent:connect("nkcluster://localhost, nkcluster://localhost:15001", #{}),
	#{
		conn_pid:=ConnPid1, listen:=[#uri{}, #uri{}, #uri{}, #uri{}], meta:=[{<<"test1">>, []}],
		remote:=<<"tcp:127.0.0.1:15001">>, status:=ready
	} = Info,
	nkcluster_protocol:stop(ConnPid1),

	{error, no_connections} = nkcluster_agent:connect("nkcluster://localhost:15001", #{password=><<"bad">>}),
	{ok, NodeId, Info2} = nkcluster_agent:connect("nkcluster://localhost:15001", #{password=><<"testpass">>}),
	nkcluster_protocol:stop(maps:get(conn_pid, Info2)),

	{error, no_connections} = nkcluster_agent:connect("nkcluster://localhost:15001;password=bad", #{}),
	{ok, NodeId, Info3} = nkcluster_agent:connect(
		"nkcluster://localhost:15001;password=bad, nkcluster://localhost:15001;password=testpass", #{}),
	nkcluster_protocol:stop(maps:get(conn_pid, Info3)),

	{ok, NodeId, Info4} = nkcluster_agent:connect("nkcluster://localhost:15002;transport=tls", #{}),
	#{remote:=<<"tls:127.0.0.1:15002">>} = Info4,
	nkcluster_protocol:stop(maps:get(conn_pid, Info4)),

	% We must include a cacertfile to verify
	{error, no_connections} = nkcluster_agent:connect("nkcluster://localhost:15002;transport=tls", 
													  #{tls_opts=>#{verify=>true}}),
	{error, {invalid_key, tls_verify}} = nkcluster_agent:connect(
		"nkcluster://localhost:15002;transport=tls;tls_verify=hi", #{}),
	{error, no_connections} = nkcluster_agent:connect(
		"nkcluster://localhost:15002;transport=tls;tls_verify=true", #{}),

	{ok, NodeId, Info5} = nkcluster_agent:connect("nkcluster://localhost:15003;transport=ws", #{}),
	#{remote:=<<"ws:127.0.0.1:15003">>} = Info5,
	nkcluster_protocol:stop(maps:get(conn_pid, Info5)),

	{ok, NodeId, Info6} = nkcluster_agent:connect("nkcluster://localhost:15004;transport=wss", #{}),
	#{remote:=<<"wss:127.0.0.1:15004">>} = Info6,
	nkcluster_protocol:stop(maps:get(conn_pid, Info6)),
	timer:sleep(500),
	ok.


proxy() ->
	?debugMsg("Starting PROXY test"),
	lager:error("PROXY1"),
	[] = nkcluster_nodes:get_nodes(),
	lager:error("PROXY2"),

	% We connect from the control cluster to a known node
	{ok, NodeId, Info, Proxy1} = nkcluster_nodes:connect("nkcluster://localhost:15001", #{}),
	#{
		conn_pid:=_, listen:=[#uri{}, #uri{}, #uri{}, #uri{}], meta:=[{<<"test1">>, []}],
		remote:=<<"tcp:127.0.0.1:15001">>, status:=ready
	} = Info,
	timer:sleep(100),
	[NodeId] = nkcluster_nodes:get_nodes(),
	{ok, Info1} = nkcluster_nodes:get_node_info(NodeId),
	[NodeId] = nkcluster_nodes:get_local_nodes(),
	{ok, Info1} = nkcluster_nodes:get_local_node_info(NodeId),
	#{
		id := NodeId,
		listen := [#uri{}, #uri{}, #uri{}, #uri{}],
		meta := [{<<"test1">>, []}],
		proxies := [Proxy1],
		status := ready
	} = Info1,

	% Now we stop the node
	% However, the proxy has registered its address with the worker, and it will
	% connect again
	ok = nkcluster_nodes:stop(NodeId),
	timer:sleep(100),
	?debugMsg("waiting for Agent to reconnect..."),
	ok = wait_agent(NodeId, nklib_util:timestamp()+30),
	?debugMsg("...reconected!"),
	{ok, #{proxies:=[Proxy2]}} = nkcluster_nodes:get_node_info(NodeId),
	{ok, [{{nkcluster, NodeId}, Proxy2}]} = nkdist:get_procs(nkcluster_node_proxy),
	false = is_process_alive(Proxy1),
	true = Proxy1 /= Proxy2,

	% Now we kill the proxy process
	exit(Proxy2, kill),
	timer:sleep(100),
	?debugMsg("waiting for Agent to reconnect..."),
	ok = wait_agent(NodeId, nklib_util:timestamp()+30),
	?debugMsg("...reconected!"),
	{ok, #{proxies:=[Proxy3]}} = nkcluster_nodes:get_node_info(NodeId),
	{ok, [{{nkcluster, NodeId}, Proxy3}]} = nkdist:get_procs(nkcluster_node_proxy),
	true = Proxy2 /= Proxy3,

	% Now we kill the connection. The proxy should reconnect inmediatly
	% Register our class for notifications
	ok = nklib_config:put(nkcluster_test, pid, self()),
	{module, _} = code:ensure_loaded(test_jobs),
	nkcluster_jobs:send_event(test_jobs, hi),
	hi = ?EVENT(NodeId),
	[{_, ConnPid}] = nklib_proc:values(nkcluster_worker_master),
	exit(ConnPid, kill),
	{nkcluster, {node_status, not_connected}} = ?EVENT(NodeId),
	{nkcluster, {node_status, ready}} = ?EVENT(NodeId),
	timer:sleep(1000),

	% Stop the node
	nkcluster_agent:clear_cluster_addr(),
	nkcluster_nodes:stop(NodeId),
	timer:sleep(500),
	{nkcluster, {node_status, not_connected}} = ?EVENT(NodeId),
	[] = nkcluster_nodes:get_nodes(),
	{ok, []} = nkdist:get_procs(nkcluster_node_proxy),
	ok.












event(NodeId, Line) ->
	receive 
		{test_jobs_event, NodeId, Msg} -> Msg
	after 1000 -> 
		error(Line)
	end.

wait_agent(NodeId, End) ->
	case lists:member(NodeId, nkcluster_nodes:get_nodes()) of
		true -> 
			ok;
		false -> 
			case nklib_util:timestamp() > End of
				true -> 
					error;
				false -> 
					timer:sleep(100),
					wait_agent(NodeId, End)
			end
	end.



