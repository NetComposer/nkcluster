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

%% @doc NkCLUSTER Core Worker Processes
-module(test_jobs).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkcluster_job_class).

-export([request/2, task/2, command/3, status/2, event/2]).


%% ===================================================================
%% nkcluster_jobs
%% ===================================================================

%% @private
-spec request(term(), nkcluster_protocol:from()) ->
    {reply, term()} | {error, term()} | defer.

request(my_request, _From) ->
    {reply, my_response};

request({error, Error}, _From) ->
    error(Error);

request(_, _From) ->
    {error, unknown_request}.


%% @private
-spec task(nkcluster:task_id(), term()) ->
    {ok, pid()} | {error, term()}.


task(_TaskId, _) ->
    {error, unknown_task}.


%% @private
-spec command(pid(), nkcluster:command(), nkcluster_protocol:from()) ->
    {reply, ok} | defer.

command(_Pid, _Cmd, _From) ->
    {reply, unknown_command}.


-spec status(pid(), nkcluster:node_status()) ->
    ok.

status(Pid, Status) ->
    lager:warning("Test Jobs Event Status: ~p", [{Pid, Status}]),
    case nklib_config:get(nkcluster_test, pid) of
        Pid when is_pid(Pid) ->
            Pid ! {test_jobs_status, Pid, Status};
        _ -> 
            lager:info("Test Jobs Event Status: ~p", [{Pid, Status}])
    end.
    

%% @private
-spec event(nkcluster:node_id(), nkcluster:event()) ->
    ok.

event(NodeId, Data) ->
    case nklib_config:get(nkcluster_test, pid) of
        Pid when is_pid(Pid) ->
            Pid ! {test_jobs_event, NodeId, Data};
        _ -> 
            lager:info("Test Jobs Event: ~p", [{NodeId, Data}])
    end.

