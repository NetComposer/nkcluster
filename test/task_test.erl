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

jobs_test_() ->
  	{setup,  
    	fun() -> 
    		ok = nkcluster_app:start()
		end,
		fun(_) -> 
			ok 
		end,
	    fun(_) ->
		    [
		    	% fun() -> req1() end,
		    	% fun() -> req2() end
			]
		end
  	}.


req1() ->
	?debugMsg("Starting REQ1 test"),
	{ok, NodeId, _Info, _} = nkcluster_nodes:connect("nkcluster://127.0.0.1:15001", #{}),

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
	ok = nkcluster:load_modules(NodeId, nkcluster).


req2() ->
	?debugMsg("Starting REQ2 test"),
	{ok, NodeId, _Info, _} = nkcluster_nodes:connect("nkcluster://127.0.0.1:15001", #{}),

	{reply, my_response} = nkcluster:request(NodeId, test_jobs, my_request),
	{error, unknown_request} = nkcluster:request(NodeId, test_jobs, other),
	{error, {{error, my_error}, _}} = 
		nkcluster:request(NodeId, test_jobs, {error, my_error}).








