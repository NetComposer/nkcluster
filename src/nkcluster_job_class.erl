%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Job Class Behaviour
-module(nkcluster_job_class).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-type from() :: nkcluster_protocol:from().


%% ===================================================================
%% Callbacks
%% ===================================================================

%% @doc This callback is called at the worker side, when a new request has arrived.
%% You must supply an inmediate response. 
%% If you are going to spend more than a few miliseconds and don't want to block
%% the network channel, can return 'defer' and call nkcluster_jobs:reply/2 at a
%% later time. However, you should consider using a task instead.
%% You should only use the {error, term()} form for class-wide errors, not specific
%% problems using this specific request (use {reply, {error, ...}} or similar).
-callback request(nkcluster:request(), from()) ->
    {reply, nkcluster:reply()} | {error, term()} | defer.
 

%% @doc This callback is called at the worker side, when a new task is requested to start.
%% You should start a new Erlang process and return its pid(), and, optionally,
%% a reply to send back to the caller.
%% You must return {error, term()} if you couldn't start the process.
%% NkCLUSTER will send an event {nkcluster, {task_started, TaskId}} to the class.
%% When the process ends, an event {nkcluster, {task_stopped, Reason, TaskId}} 
%% will be sent.
-callback task(nkcluster:task_id(), nkcluster:task()) ->
    {ok, pid()} | {ok, nkcluster:reply(), pid()} | {error, term()}.


%% @doc This callback is called at the worker side, when a command is sent to a
%% currenly running task. The pid() of the task is included.
%% You must supply and inmediate response.
%% If you are going to spend more than a few miliseconds and don't want to block
%% the network channel, can return 'defer' and call nkcluster_jobs:reply/2 at a
%% later time. However, you should consider using events instead.
%% You should only use the {error, term()} form for class-wide errors, not specific
%% problems using this specific request (use {reply, {error, ...}} or similar).
-callback command(pid(), nkcluster:command(), from()) ->
    {reply, nkcluster:reply()} | {error, term()} | defer.


%% @doc This callback is called at the worker side, for each started task, 
%% when the node status changes.
%% If the status changes to stopping, the task should stop as soon as possible,
%% in order to shut down the node.
-callback status(pid(), nkcluster:node_status()) ->
    ok.


%% @doc This callback is called at the control side, when an event is sent from
%% a task or request at the worker side.
%% NkCLUSTER will also sent the following events:
%%
%% - {nkcluster, {task_started, TaskId}
%%   Called when a new task has started at the remote node
%%
%% - {nkcluster, {task_stopped, TaskId, Reason}}
%%   Called when a task has stopped at the remote node
%%
%% - {nkcluster, connection_error}
%%	 It means that the communication channel has failed, and some events could
%%   have been lost. You should try to recover the state from the worker node
%%   sending requests to it.
%%
-callback event(nkcluster:node_id(), term()) ->
    ok.


