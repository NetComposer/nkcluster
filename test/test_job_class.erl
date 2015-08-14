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
-module(test_job_class).
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
    {ok, pid()} | {ok, term(), pid()} | {error, term()}.


task(TaskId, task1) ->
    {ok, spawn_link(fun() -> my_task(TaskId) end)};

task(TaskId, task2) ->
    {ok, reply2, spawn_link(fun() -> my_task(TaskId) end)};

task(_TaskId, _) ->
    {error, unknown_task}.


%% @private
-spec command(pid(), nkcluster:command(), nkcluster_protocol:from()) ->
    {reply, ok} | defer.

command(Pid, cmd1, _From) ->
    Ref = make_ref(),
    Pid ! {cmd1, Ref, self()},
    receive
        {Ref, Res} -> {reply, Res}
    after  
        1000 -> error(?LINE)
    end;

command(Pid, cmd2, From) ->
    Pid ! {cmd2, From},
    defer;

command(Pid, cmd3, _From) ->
    Pid ! cmd3,
    {reply, reply3};

command(Pid, cmd4, _From) ->
    Pid ! cmd4,
    {reply, reply4};

command(Pid, stop, _From) ->
    Pid ! stop,
    {reply, stop};

command(_Pid, _Cmd, _From) ->
    {reply, unknown_command}.


-spec status(pid(), nkcluster:node_status()) ->
    ok.

status(Pid, Status) ->
    Pid ! {status, Status},
    ok.
    

%% @private
-spec event(nkcluster:node_id(), nkcluster:event()) ->
    ok.

event(NodeId, Data) ->
    % lager:warning("W: ~p", [Data]),
    case nklib_config:get(nkcluster_test, pid) of
        Pid when is_pid(Pid) ->
            Pid ! {test_job_class_event, NodeId, Data};
        _ -> 
            lager:info("Test Jobs Event: ~p", [{NodeId, Data}])
    end.


%%%% Internal

my_task(TaskId) ->
    receive
        {cmd1, Ref, Pid} -> 
            Pid ! {Ref, reply1},
            my_task(TaskId);
        {cmd2, From} ->
            nkcluster_jobs:reply(From, {reply, reply2}),
            my_task(TaskId);
        cmd3 ->
            error(error3);
        cmd4 ->
            nkcluster_jobs:send_event(test_job_class, event4),
            my_task(TaskId);
        stop ->
            ok;
        {status, Status} ->
            nkcluster_jobs:send_event(test_job_class, {status, TaskId, Status}),
            case Status of
                stopping -> erlang:send_after(500, self(), stop);
                _ -> ok
            end,
            my_task(TaskId)
    end.








