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

%% @doc NkCLUSTER User Functions
-module(nkcluster).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_info/1, set_status/2]).
-export([get_tasks/1, get_tasks/2, get_meta/1, update_meta/2, get_data/2, put_data/3]).
-export([call/5, spawn_call/5]).
-export([send_file/3, send_bigfile/3, load_modules/2, load_module/2]).
-export([request/3, request/4, task/3, task/4, command/3, command/4]).

-export_type([node_id/0, conn_id/0, job_class/0, task_id/0]).
-export_type([request/0, task/0, command/0, reply/0, event/0]).
-export_type([node_status/0]).

-define(CLASS, nkcluster_jobs_core).


%% ===================================================================
%% Types
%% ===================================================================


-type node_id() :: binary().
-type conn_id() :: nkcluster_protocol:conn_id().
-type job_class() :: module().
-type request() :: term().
-type task_id() :: term().
-type task() :: term().
-type command() :: term().
-type reply() :: term().
-type event() :: term().
-type node_status() :: launching | connecting | ready | standby | stopping | stopped | 
                       not_connected.

-type conn_spec() :: node_id() | pid().
-type req_opts() :: nkcluster_node_proxy:rpc_opts().



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets remote status (from a control cluster cache)
-spec get_info(conn_spec()) ->
    {ok, nkcluster_nodes:info()} | {error, term()}.

get_info(Node) ->
    nkcluster_nodes:get_node_info(Node).


%% @doc Updates remote statyus
-spec set_status(conn_spec(), ready|standby|stopped) ->
    ok | {error, term()}.

set_status(Node, Status) when Status==ready; Status==standby; Status==stopped ->
    request2(Node, ?CLASS, {set_status, Status}).


%% @doc Gets all started jobs
-spec get_tasks(conn_spec()) ->
    {ok, [{job_class(), task_id(), pid()}]} | 
    {error, term()}.

get_tasks(Node) ->
    request2(Node, ?CLASS, get_tasks).


%% @doc Gets all started jobs
-spec get_tasks(conn_spec(), job_class()) ->
    {ok, [{task_id(), pid()}]} | 
    {error, term()}.

get_tasks(Node, Class) ->
    request2(Node, ?CLASS, {get_tasks, Class}).


%% @doc Gets all registered metadatas
-spec get_meta(conn_spec()) ->
    {ok, [nklib:token()]} | {error, term()}.

get_meta(Node) ->
    request2(Node, ?CLASS, get_meta).


%% @doc Registers a new metadata
-spec update_meta(conn_spec(), nklib:token()) ->
    {ok, [nklib:token()]} | {error, term()}.

update_meta(Node, Tokens) ->
    case nklib_parse:tokens(Tokens) of
        error -> 
            {error, invalid_tokens};
        Parsed -> 
            request2(Node, ?CLASS, {update_meta, Parsed})
    end.


%% @doc Gets remotely stored data
-spec get_data(conn_spec(), term()) ->
    {ok, term()} | {error, term()}.

get_data(Node, Key) ->
    request2(Node, ?CLASS, {get_data, Key}).


%% @doc Stores data remotely
-spec put_data(conn_spec(), term(), term()) ->
    ok | {error, term()}.

put_data(Node, Key, Val) ->
    request2(Node, ?CLASS, {put_data, Key, Val}).


%% @doc Calls a remote erlang functiond
-spec call(conn_spec(), atom(), atom(), list(), integer()) ->
    {reply, term()} | {error, term()}.

call(Node, Mod, Fun, Args, Timeout) ->
    request(Node, ?CLASS, {call, Mod, Fun, Args}, #{timeout=>Timeout}).


%% @doc Calls a remote erlang function, in a spwaned process
-spec spawn_call(conn_spec(), atom(), atom(), list(), integer()) ->
    {reply, term()} | {error, term()}.

spawn_call(Node, Mod, Fun, Args, Timeout) ->
    request(Node, ?CLASS, {spawn_call, Mod, Fun, Args}, #{timeout=>Timeout}).


%% @doc Sends a file.
%% If the size is bellow 4KB, it will be sent synchronously. If it is bigger,
%% send_bigfile/3 will be used.
%% If the remote directory does not exist, it will be created.
-spec send_file(conn_spec(), list(), list()) ->
    ok | {error, term()}.

send_file(Node, Path, RemotePath) ->
    Path1 = nklib_util:to_list(Path),
    case filelib:is_regular(Path1) of
        true ->
            case filelib:file_size(Path1) =< 4096 of
                true ->
                    case file:read_file(Path1) of
                        {ok, Bin} ->
                            Opts = #{timeout=>30000},
                            Msg = {write_file, nklib_util:to_binary(RemotePath), Bin},
                            request2(Node, ?CLASS, Msg, Opts);
                        {error, Error} ->
                            {error, Error}
                    end;
                false ->
                    send_bigfile(Node, Path, RemotePath)
            end;
        false ->
            {error, invalid_file}
    end.


%% @doc Sends a big file, in 1MB chunks.
%% If the remote directory does not exist, it will be created.
-spec send_bigfile(conn_spec(), list(), list()) ->
    ok | {error, term()}.

send_bigfile(Node, Path, RemotePath) ->
    Path1 = nklib_util:to_list(Path),
    case filelib:is_regular(Path1) of
        true ->
            try
                Device = case file:open(Path1, [read, binary]) of
                    {ok, Device0} -> Device0;
                    {error, FileError} -> throw(FileError)
                end,
                ConnPid = case nkcluster_nodes:new_connection(Node) of
                    {ok, ConnPid0} -> ConnPid0;
                    {error, ConnError} -> throw(ConnError)
                end,
                Opts = #{conn_pid=>ConnPid, timeout=>30000},
                Msg = {write_file, nklib_util:to_binary(RemotePath)},
                case task(Node, ?CLASS, Msg, Opts) of
                    {ok, TaskId} ->
                        do_send_bigfile(Node, Device, TaskId, Opts);
                    {error, CallError} ->
                        {error, CallError}
                end
            catch
                throw:Throw -> {error, Throw}
            end;
        false ->
            {error, invalid_file}
    end.


%% @private
-spec do_send_bigfile(conn_spec(), file:fd(), task_id(), map()) ->
    {reply, ok} | {error, term()}.

do_send_bigfile(Node, Device, TaskId, Opts) ->
    case file:read(Device, 1024*1024) of
        {ok, Data} ->
            case command(Node, TaskId, {write_file, Data}, Opts) of
                {reply, ok} ->
                    do_send_bigfile(Node, Device, TaskId, Opts);
                {error, Error} ->
                    file:close(Device),
                    {error, Error}
            end;
        eof ->
            file:close(Device),
            case command(Node, TaskId, {write_file, eof}, Opts) of
                {reply, ok} -> ok;
                {error, Error} -> {error, Error}
            end;
        {error, Error} ->
            file:close(Device),
            {error, Error}
    end.


%% @doc Sends and loads a module to the remote side
-spec load_module(conn_spec(), atom()) ->
    ok | {error, term()}.

load_module(Node, Mod) ->
    case code:get_object_code(Mod) of
        {Mod, Bin, File} -> 
            Opts = #{timeout=>30000},
            request2(Node, ?CLASS, {load_code, [{Mod, File, Bin}]}, Opts);
        error ->
            {error, module_not_found}
    end.


%% @doc Sends and loads all modules belonging to an application
-spec load_modules(conn_spec(), atom()) ->
    ok | {error, term()}.

load_modules(Node, App) ->
    application:load(App),
    case application:get_key(App, modules) of
        {ok, Modules} ->
            Data = lists:foldl(
                fun(Mod, Acc) ->
                    case code:get_object_code(Mod) of
                        {Mod, Bin, File} -> [{Mod, File, Bin}|Acc];
                        error -> Acc
                    end
                end,
                [],
                Modules),
            case nkcluster_nodes:new_connection(Node) of
                {ok, ConnPid} -> 
                    Opts = #{timeout=>30000, conn_pid=>ConnPid},
                    request2(Node, ?CLASS, {load_code, Data}, Opts);
                {error, Error} ->
                    {error, Error}
            end;
        undefined ->
            {error, app_not_found}
    end.


%% ===================================================================
%% Generic
%% ===================================================================


%% @doc Equivalent to request(Node, Class, Cmd, #{})
-spec request(conn_spec(), job_class(), request()) ->
    {reply, reply()} | {error, term()}.

request(Node, Class, Cmd) ->
    request(Node, Class, Cmd, #{}).


%% @doc Sends a remote synchrnous call, and wait for the result
-spec request(conn_spec(), job_class(), request(), req_opts()) ->
    {reply, reply()} | {error, term()}.

request(Node, Class, Cmd, Opts) ->
    nkcluster_nodes:rpc(Node, {req, Class, Cmd}, Opts).


%% @doc Equivalent to request2(Node, Class, Cmd, #{})
-spec request2(conn_spec(), job_class(), request()) ->
    ok | {ok, reply()} | {error, term()}.

request2(Node, Class, Cmd) ->
    request2(Node, Class, Cmd, #{}).


%% @doc Sends a remote synchrnous call, and wait for the result
-spec request2(conn_spec(), job_class(), request(), req_opts()) ->
    ok | {ok, reply()} | {error, term()}.

request2(Node, Class, Cmd, Opts) ->
    case request(Node, Class, Cmd, Opts) of
        {reply, ok} -> ok;
        {reply, Reply} -> {ok, Reply};
        {error, Error} -> {error, Error}
    end.


%% @doc Equivalent to task(Node, Class, Cmd, #{})
-spec task(conn_spec(), job_class(), task()) ->
    {ok, task_id()} | {reply, reply(), task_id()} | 
    {error, term()}.

task(Node, Class, Spec) ->
    task(Node, Class, Spec, #{}).


%% @doc Starts a new remote job. 
-spec task(conn_spec(), job_class(), task(), req_opts()) ->
    {ok, task_id()} | {reply, reply(), task_id()} | 
    {error, term()}.

task(Node, Class, Spec, Opts) ->
    TaskId = case Opts of
        #{task_id:=TaskId0} -> TaskId0;
        _ -> nklib_util:luid()
    end, 
    case nkcluster_nodes:rpc(Node, {tsk, Class, TaskId, Spec}, Opts) of
        {reply, ok} ->
            {ok, TaskId};
        {reply, {ok, Reply}} ->
            {reply, Reply, TaskId};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Equivalent to command(Node, TaskId, Cmd, #{})
-spec command(conn_spec(), task_id(), command()) ->
    {ok, reply()} | {error, term()}.

command(Node, TaskId, Cmd) ->
    command(Node, TaskId, Cmd, #{}).


%% @doc Sends a message to a remote job
-spec command(conn_spec(), task_id(), command(), req_opts()) ->
    {reply, reply()} | {error, term()}.

command(Node, TaskId, Cmd, Opts) ->
    nkcluster_nodes:rpc(Node, {cmd, TaskId, Cmd}, Opts).



