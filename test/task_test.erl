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

-module(task_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").

-define(EVENT(NodeId), event(NodeId, ?LINE)).
-define(CLASS, test_job_class).

tasks_test_() ->
  	{setup,  
    	fun() -> 
    		ok = nkcluster_app:start(),
			{ok, NodeId, _Info, _} = nkcluster_nodes:connect("nkcluster://127.0.0.1:15001", #{}),
			NodeId
		end,
		fun(NodeId) -> 
			nkcluster_agent:clear_cluster_addr(),
			ok = nkcluster_nodes:stop(NodeId)
		end,
	    fun(NodeId) ->
		    [
		    	fun() -> req1(NodeId) end,
		    	fun() -> req2(NodeId) end,
		    	fun() -> task(NodeId) end,
		    	fun() -> status(NodeId) end
			]
		end
  	}.


req1(NodeId) ->
	?debugMsg("Starting REQ1 test"),

	{ok, [{<<"test1">>, []}]} = nkcluster:get_meta(NodeId),
	{ok, Meta1} = nkcluster:update_meta(NodeId, "meta2;a=1;b=2, meta3;master"),
	{ok, [
		{<<"test1">>, []},
		{<<"meta2">>, [{<<"a">>,<<"1">>}, {<<"b">>, <<"2">>}]},
		{<<"meta3">>, [<<"master">>]}]
	} = {ok, Meta1} = nkcluster:get_meta(NodeId),
	{ok, Meta2} = nkcluster:update_meta(NodeId, "meta2;c=2"),
	{ok, [
		{<<"test1">>, []},
		{<<"meta2">>, [{<<"c">>,<<"2">>}]},
		{<<"meta3">>, [<<"master">>]}]
	} = {ok, Meta2} = nkcluster:get_meta(NodeId),
	nkcluster:remove_meta(NodeId, "meta2, meta3"),
	{ok, [{<<"test1">>, []}]} = nkcluster:get_meta(NodeId),

	{ok, undefined} = nkcluster:get_data(NodeId, data1),
	ok = nkcluster:put_data(NodeId, data1, value1),
	{ok, value1} = nkcluster:get_data(NodeId, data1),
	ok = nkcluster:del_data(NodeId, data1),
	{ok, undefined} = nkcluster:get_data(NodeId, data1),

	{reply, 'nkcluster@127.0.0.1'} = nkcluster:call(NodeId, erlang, node, [], 1000),
	{reply, 'nkcluster@127.0.0.1'} = nkcluster:spawn_call(NodeId, erlang, node, [], 1000),
	{reply, ok} = nkcluster:call(NodeId, timer, sleep, [100], 1000),
	lager:notice("Next notice about 'unexpected response' is expected"),
	{error, timeout} = nkcluster:call(NodeId, timer, sleep, [200], 100),

	Bin1 = crypto:rand_bytes(500),
	ok = file:write_file("/tmp/nkcluster.1", Bin1),
	ok = nkcluster:send_file(NodeId, "/tmp/nkcluster.1", "/tmp/nkcluster.2"),
	{ok, Bin1} = file:read_file("/tmp/nkcluster.1"),

	Bin2 = crypto:rand_bytes(2*1024*1024),
	ok = file:write_file("/tmp/nkcluster.1", Bin2),
	ok = nkcluster:send_file(NodeId, "/tmp/nkcluster.1", "/tmp/nkcluster.2"),
	{ok, Bin2} = file:read_file("/tmp/nkcluster.1"),

	ok = nkcluster:load_module(NodeId, ?MODULE),
	ok = nkcluster:load_modules(NodeId, nkcluster),

	ok.



req2(NodeId) ->
	?debugMsg("Starting REQ2 test"),

	{reply, my_response} = nkcluster:request(NodeId, ?CLASS, my_request),
	{error, unknown_request} = nkcluster:request(NodeId, ?CLASS, other),
	{error, {{error, my_error}, _}} = 
		nkcluster:request(NodeId, ?CLASS, {error, my_error}),
	
	ok.


task(NodeId) ->
	?debugMsg("Starting TASK test"),
	nklib_config:put(nkcluster_test, pid, self()),

	{ok, []} = nkcluster:get_tasks(NodeId, ?CLASS),
	{ok, Task1} = nkcluster:task(NodeId, ?CLASS, task1),
	{nkcluster, {task_started, Task1}} = ?EVENT(NodeId),
	{ok, [Task1]} = nkcluster:get_tasks(NodeId, ?CLASS),
	{reply, reply2, Task2} = nkcluster:task(NodeId, ?CLASS, task2),
	{nkcluster, {task_started, Task2}} = ?EVENT(NodeId),
	{ok, List2} = nkcluster:get_tasks(NodeId, ?CLASS),
	true = lists:sort([Task1, Task2]) == lists:sort(List2),

	{ok, Pid2} = nkcluster_jobs:get_task(?CLASS, Task2),
	exit(Pid2, kill),
	{nkcluster, {task_stopped, Task2, killed}} = ?EVENT(NodeId),
	{ok, [Task1]} = nkcluster:get_tasks(NodeId, ?CLASS),

	{error, task_not_found} = nkcluster:command(NodeId, ?CLASS, Task2, cmd1),
	{reply, reply1} = nkcluster:command(NodeId, ?CLASS, Task1, cmd1),
	{reply, reply2} = nkcluster:command(NodeId, ?CLASS, Task1, cmd2),
	{reply, reply3} = nkcluster:command(NodeId, ?CLASS, Task1, cmd3),
	{nkcluster, {task_stopped, Task1, {error3, _}}} = ?EVENT(NodeId),
	{ok, []} = nkcluster:get_tasks(NodeId, ?CLASS),

	{ok, Task3} = nkcluster:task(NodeId, ?CLASS, task1),
	{nkcluster, {task_started, Task3}} = ?EVENT(NodeId),
	{reply, reply4} = nkcluster:command(NodeId, ?CLASS, Task3, cmd4),
	event4 = ?EVENT(NodeId),
	{reply, stop} = nkcluster:command(NodeId, ?CLASS, Task3, stop),
	{nkcluster, {task_stopped, Task3, normal}} = ?EVENT(NodeId),
	{ok, []} = nkcluster:get_tasks(NodeId, ?CLASS),

	ok.
	


status(NodeId) ->
	?debugMsg("Starting TASK test"),
	nklib_config:put(nkcluster_test, pid, self()),

	{ok, []} = nkcluster:get_tasks(NodeId, ?CLASS),
	{ok, Task1} = nkcluster:task(NodeId, ?CLASS, task1),
	{nkcluster, {task_started, Task1}} = ?EVENT(NodeId),

	ok = nkcluster:set_status(NodeId, standby),
	{nkcluster, {node_status, standby}} = ?EVENT(NodeId),
	{status, Task1, standby} = ?EVENT(NodeId),
	{error, {node_not_ready, standby}} = nkcluster:task(NodeId, ?CLASS, task1),

	ok = nkcluster:set_status(NodeId, stopped),
	{nkcluster, {node_status, stopping}} = ?EVENT(NodeId),
	{status, Task1, stopping} = ?EVENT(NodeId),
	%% The task receives the stop request and will stop after 0.5 secs
	{nkcluster, {task_stopped, Task1, normal}} = ?EVENT(NodeId),
	%% Agent will check every 1 sec to see if tasks have stopped
	{nkcluster, {node_status, stopped}} = ?EVENT(NodeId),
	
	ok = nkcluster:set_status(NodeId, ready),
	{nkcluster, {node_status, ready}} = ?EVENT(NodeId),

	ok.





%%% Internal

event(NodeId, Line) ->
	receive 
		{test_job_class_event, NodeId, Msg} -> Msg
	after 5000 -> 
		error(Line)
	end.













