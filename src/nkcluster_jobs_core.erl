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
-module(nkcluster_jobs_core).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkcluster_job_class).

-export([request/2, task/2, command/3, status/2, event/2]).

-include("nkcluster.hrl").


%% ===================================================================
%% nkcluster_jobs
%% ===================================================================

%% @private
-spec request(term(), nkcluster_protocol:from()) ->
    {reply, term()} | {error, term()} | defer.

request(get_status, _From) ->
    {ok, Status} = nkcluster_agent:get_status(),
    {reply, Status};

request({set_status, Status}, _From) ->
    case nkcluster_agent:set_status(Status) of
        ok -> {reply, ok};
        {error, Error} -> {error, Error}
    end;

request(get_meta, _From) ->
    {reply, nkcluster_app:get(meta)};

request({update_meta, Meta}, _From) ->
    OldMeta = nkcluster_app:get(meta),
    Meta1 = nklib_util:store_values(Meta, OldMeta),
    nkcluster_app:put(meta, Meta1),
    {reply, Meta1};

request({get_data, Key}, _From) ->
    Value = nkcluster_app:get({data, Key}),
    {reply, Value};

request({put_data, Key, Val}, _From) ->
    ok = nkcluster_app:put({data, Key}, Val),
    {reply, ok};

request(get_tasks, _From) ->
    {ok, Jobs} = nkcluster_jobs:get_tasks(),
    {reply, Jobs};

request({get_tasks, Class}, _From) ->
    {ok, Jobs} = nkcluster_jobs:get_tasks(Class),
    {reply, Jobs};

request({call, Mod, Fun, Args}, _From) ->
    {reply, catch apply(Mod, Fun, Args)};

request({spawn_call, Mod, Fun, Args}, From) ->
    spawn_link(
        fun() ->
            Reply = (catch apply(Mod, Fun, Args)),
            nkcluster_jobs:reply(From, {reply, Reply})
        end),
    defer;

request({write_file, Path, Bin}, _From) ->
    Path1 = nklib_util:to_list(Path),
    case filelib:ensure_dir(Path1) of
        ok ->
            case file:write_file(Path1, Bin) of
                ok -> 
                    {reply, ok};
                {error, Error} ->
                    {error, {write_error, Error}}
            end;
        {error, Error} ->
            {error, {write_error, Error}}
    end;

request({load_code, Data}, From) ->
    spawn_link(fun() -> load_code(Data, From) end),
    defer;

request(_, _From) ->
    {error, unknown_call}.


%% @private
-spec task(nkcluster:task_id(), term()) ->
    {ok, pid()} | {error, term()}.


task(_TaskId, {write_file, Path}) ->
    Path1 = nklib_util:to_list(Path),
    case filelib:ensure_dir(Path1) of
        ok ->
            case file:open(Path1, [write, binary]) of
                {ok, Device} ->
                    Pid = spawn_link(fun() -> write_file(Device) end),
                    {ok, Pid};
                {error, Error} ->
                    {error, {write_error, Error}}
            end;
        {error, Error} ->
            {error, {write_error, Error}}
    end;
            
task(_TaskId, _) ->
    {error, unknown_call}.


%% @private
-spec command(pid(), nkcluster:command(), nkcluster_protocol:from()) ->
    {reply, ok} | defer.

command(Pid, {write_file, Data}, From) ->
    Pid ! {write_file, Data, From},
    defer;

command(_Pid, _Cmd, _From) ->
    {reply, unknown_cmd}.


-spec status(pid(), nkcluster:node_status()) ->
    ok.

status(Pid, Status) ->
    lager:info("Core process ~p notified status ~p", [Pid, Status]),
    ok.


%% @private
-spec event(nkcluster:node_id(), nkcluster:event()) ->
    ok.

event(_NodeId, _Data) ->
    lager:info("Node ~s core event: ~p", [_NodeId, _Data]),
    ok.
    



%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
write_file(Device) ->
    receive 
        {write_file, eof, From} ->
            Reply = case file:close(Device) of
                ok -> 
                    {reply, ok};
                {error, Error} -> 
                    {error, {write_error, Error}}
            end,
            nkcluster_jobs:reply(From, Reply);
        {write_file, Data, From} ->
            case file:write(Device, Data) of
                ok ->
                    nkcluster_jobs:reply(From, {reply, ok}),
                    write_file(Device);
                {error, Error} ->
                    file:close(Device),
                    nkcluster_jobs:reply(From, {error, {write_error, Error}})
            end
    after 180000 ->
        error(write_file_timeout)
    end.

        

%% @private
load_code([], From) ->
    nkcluster_jobs:reply(From, {reply, ok});

load_code([{Mod, File, Bin}|Rest], From) ->
    case code:load_binary(Mod, File, Bin) of
        {module, Mod} ->
            lager:info("Worker loaded module ~p", [Mod]),
            load_code(Rest, From);
        {error, Error} ->
            nkcluster_jobs:reply(From, {error, {load_error, Error}})
    end.







