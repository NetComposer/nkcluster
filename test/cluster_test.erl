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

-module(cluster_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("nklib/include/nklib.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(RECV(Term), receive Term -> Term after 1000 -> error(?LINE) end).

-define(EVENT(NodeId), event(NodeId, ?LINE)).

basic_test_() ->
  	{setup, 
    	fun() -> ok = nkcluster_app:start() end,
		fun(_) -> ok end,
	    fun(_) -> 
		    [
				fun() -> master() end
			]
		end
  	}.


master() ->
	?debugMsg("Starting MASTER test"),
	{ok, Master1} = nkdist_gen_server:get_master(nkcluster_nodes),
	{ok, #{nkcluster_nodes:=[Master1]}} = nkdist:get_masters(),

	{ok, VNode1} = nkdist:register(nkcluster_nodes),
	_ = ?RECV({nkdist_master, nkcluster_nodes, Master1}),
	Self = self(),
	{ok, #{nkcluster_nodes:=[Master1, Self]}} = nkdist:get_masters(),

	% Lets register another thing, at the same vnode
	Spawn = spawn_link(
		fun() ->
			Self2 = self(),
			{ok, VNode1Id} = nkdist:get_vnode(nkcluster_nodes),
			{ok, VNode1} = nkdist_vnode:register(VNode1Id, test, Self2),
			_ = ?RECV({nkdist_master, test, Self2}),
			{ok, #{nkcluster_nodes:=[Master1, Self], test:=[Self2]}} = nkdist:get_masters(),
			receive	_Any -> error(?LINE)
			after 5000 -> ok
			end
		end),
	timer:sleep(500),
	{ok, #{nkcluster_nodes:=[Master1, Self], test:=[Spawn]}} = nkdist:get_masters(),

	lager:warning("Next warning about vnode been killed is expected"),
	exit(VNode1, kill),
	
	% We have killed the vnode
	% nkdist_gen_server processes like nkcluster_nodes will reconnect
	% again, we must do it ourselves
	timer:sleep(500),
	false = is_process_alive(VNode1),
	{ok, #{nkcluster_nodes:=[Master1]}} = nkdist:get_masters(),
	{ok, _VNode2} = nkdist:register(nkcluster_nodes),
	% After register, we receive a notify
	_ = ?RECV({nkdist_master, nkcluster_nodes, Master1}),
	{ok, #{nkcluster_nodes:=[Master1, Self]}} = nkdist:get_masters(),

	% If we kill the master, we will be elected
	exit(Master1, kill),
	_ = ?RECV({nkdist_master, nkcluster_nodes, Self}),
	% When the nkcluster_nodes process is restarted, we receive another notify
	_ = ?RECV({nkdist_master, nkcluster_nodes, Self}),
	timer:sleep(500),
	{ok, #{nkcluster_nodes:=[Self, Master2]}} = nkdist:get_masters(),
	Master2 = whereis(nkcluster_nodes),
	{ok, Self} = nkdist_gen_server:get_master(nkcluster_nodes),
	ok.

