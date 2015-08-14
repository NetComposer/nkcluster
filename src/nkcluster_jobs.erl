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

%% @doc NkCLUSTER Job Management
%% This server manages all worker tasks
-module(nkcluster_jobs).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([request/3, task/4, command/3, reply/2, send_event/2, get_tasks/0, get_tasks/1]).
-export([updated_status/1]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).


%% ===================================================================
%% Public
%% ===================================================================

%% @private
-spec request(nkcluster:job_class(), nkcluster:request(), nkcluster_protocol:from()) ->
    {reply, term()} | {error, term()} | defer.

request(Class, Spec, From) ->
    lager:debug("New REQ '~p': ~p", [Class, Spec]),
    try Class:request(Spec, From) of
        {reply, Reply} ->
            {reply, Reply};
        {error, Error} ->
            {error, Error};
        defer ->
            defer
    catch
        C:E->
            {error, {{C, E}, erlang:get_stacktrace()}}
    end.


%% @private
-spec task(nkcluster:job_class(), nkcluster:task_id(), nkcluster:task(), 
           nkcluster_protocol:from()) ->
    {reply, term()} | {error, term()}.

task(Class, TaskId, Spec, _From) ->
    lager:debug("New TASK '~p' ~s: ~p", [Class, TaskId, Spec]),
    case nkcluster_agent:get_status() of
        ready ->
            case get_task(Class, TaskId) of
                not_found ->
                    try Class:task(TaskId, Spec) of
                        {ok, Pid} when is_pid(Pid) ->
                            task_started(Class, TaskId, Pid),
                            {reply, ok};
                        {ok, Reply, Pid} when is_pid(Pid) ->
                            task_started(Class, TaskId, Pid),
                            {reply, {ok, Reply}};
                        {error, Error} ->
                            {error, Error}
                    catch
                        C:E->
                            {error, {{C, E}, erlang:get_stacktrace()}}
                    end;
                {ok, _Pid} ->
                    {error, already_started}
            end;
        Status ->
            {error, {node_not_ready, Status}}
    end.


%% @private
-spec command(nkcluster:job_class(), nkcluster:task_id(), term(), 
              nkcluster_protocol:from()) ->
    {reply, term()} | {error, term()} | defer.

command(Class, TaskId, Spec, From) ->
    case get_task(Class, TaskId) of
        {ok, Pid} ->
            lager:debug("New Cmd '~p' ~s: ~p (~p)", [Class, TaskId, Spec, Pid]),
            try Class:command(Pid, Spec, From) of
                {reply, Reply} ->
                    {reply, Reply};
                {error, Error} ->
                    {error, Error};
                defer ->
                    defer
            catch
                C:E ->
                    {error, {{C, E}, erlang:get_stacktrace()}}
            end;
        not_found ->
            {error, task_not_found}
    end.


%% @private
-spec get_task(nkcluster:job_class(), nkcluster:task_id()) ->
    {ok, pid()} | not_found.

get_task(Class, TaskId) ->
    gen_server:call(?MODULE, {get_task, Class, TaskId}).


%% @private
-spec task_started(nkcluster:job_class(), nkcluster:task_id(), pid()) ->
    ok.

task_started(Class, TaskId, Pid) ->
    ok = gen_server:call(?MODULE, {task_started, Class, TaskId, Pid}).


%% @doc
-spec get_tasks() ->
    {ok, [{nkcluster:job_class(), nkcluster:task_id(), pid()}]}.

get_tasks() ->
    gen_server:call(?MODULE, get_tasks).


-spec get_tasks(nkcluster:job_class()) ->
    {ok, [{nkcluster:task_id(), pid()}]}.

get_tasks(Class) ->
    gen_server:call(?MODULE, {get_tasks, Class}).


%% @doc
-spec reply(nkcluster_protocol:from(), {reply, nkcluster:reply()} | {error, term()}) ->
    ok | {error, term()}.

reply({ConnId, TransId}, {Class, Reply}) when Class==reply; Class==error ->
    nkcluster_protocol:send_reply(ConnId, TransId, {Class, Reply}).
    

%% @doc
-spec send_event(nkcluster:job_class(), nkcluster:event()) ->
    ok.

send_event(Class, Event) ->
    nkcluster_protocol:send_event(Class, Event).


%% @private
-spec updated_status(nkcluster:node_status()) ->
    ok.

updated_status(Status) ->
    gen_server:cast(?MODULE, {updated_status, Status}).



%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-record(task, {
    class :: nkcluster:job_class(), 
    pid :: pid(),
    mon :: reference()
}).

-record(state, {
    tasks :: #{nkcluster:task_id() => #task{}},
    pids :: #{pid() => nkcuster:task_id()}
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}}.

init([]) ->
    process_flag(trap_exit, true),
    State = #state{tasks=#{}, pids=#{}},
    {ok, State}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call(get_tasks, _From, #state{tasks=Tasks}=State) ->
    Data = [
        {Class, TaskId, Pid} 
        || {TaskId, #task{class=Class, pid=Pid}} <- maps:to_list(Tasks)
    ],
    {reply, {ok, Data}, State};

handle_call({get_tasks, Class}, _From, #state{tasks=Tasks}=State) ->
    Data = [
        {TaskId, Pid} 
        || {TaskId, #task{class=C, pid=Pid}} <- maps:to_list(Tasks), C==Class
    ],
    {reply, {ok, Data}, State};

handle_call({get_job, TaskId}, _From, #state{tasks=Tasks} = State) ->
    case maps:get(TaskId, Tasks, undefined) of
        #task{class=Class, pid=Pid} ->
            {reply, {ok, Class, Pid}, State};
        undefined ->
            {reply, not_found, State}
    end;

handle_call({start, Class, TaskId, Pid}, _From, #state{tasks=Tasks, pids=Pids}=State) ->
    case maps:is_key(TaskId, Tasks) of
        true ->
            lager:warning("Started duplicated job '~p' ~s", [Class, TaskId]);
        false ->
            ok
    end,
    Task = #task{class=Class, pid=Pid, mon=monitor(process, Pid)},
    Tasks1 = maps:put(TaskId, Task, Tasks),
    Pids1 = maps:put(Pid, TaskId, Pids),
    {reply, ok, State#state{tasks=Tasks1, pids=Pids1}};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({updated_status, Status}, #state{tasks=Tasks}=State) ->
    Data = [{Class, Pid} || #task{class=Class, pid=Pid} <- maps:to_list(Tasks)],
    spawn(fun() -> send_updated_status(Status, Data) end),
    {noreply, State};
    

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info({'DOWN', _Ref, process, Pid, Reason}=Msg, State) ->
    #state{tasks=Tasks, pids=Pids} = State,
    case maps:get(Pid, Pids, undefined) of
        undefined ->
            lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
            {noreply, State};
        TaskId ->
            #task{class=Class} = maps:get(TaskId, Tasks),
            Tasks1 = maps:remove(TaskId, Tasks),
            Pids1 = maps:remove(Pid, Pids),
            send_event(Class, {nkcluster, {task_stopped, TaskId, Reason}}),
            {noreply, State#state{tasks=Tasks1, pids=Pids1}}
    end;
    
handle_info({'EXIT', Pid, _Reason}, #state{pids=Pids}=State) ->
    case maps:is_key(Pid, Pids) of
        true -> 
            ok;
        false -> 
            lager:warning("Module ~p received unexpected EXIT: ~p", [?MODULE, Pid])
    end,
    {noreply, State};

handle_info(Msg, State) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, #state{tasks=_Tasks}) ->
    ok.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
send_updated_status(_Status, []) ->
    ok;

send_updated_status(Status, [{Class, Pid}|Rest]) ->
    catch Class:status(Pid, Status),
    send_updated_status(Status, Rest).


