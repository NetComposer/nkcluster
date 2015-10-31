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

%% @private NkCLUSTER  main supervisor
-module(nkcluster_sup).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(supervisor).

-export([init/1, start_link/0]).
% -export([start_tasks_sup/0]).

-include("nkcluster.hrl").

%% @private
-spec start_link() ->
    {ok, pid()}.

start_link() ->
    Primary = case nkcluster_agent:is_primary() of
        true -> 
            [
                {nkcluster_nodes,
                    {nkcluster_nodes, start_link, []},
                    permanent,
                    5000,
                    worker,
                    [nkcluster_nodes]
                }
            ];
        false ->
            []
    end,
    ListenOpts1 = #{
        srv_id => nkcluster,
        idle_timeout => 180000,
        tcp_packet => 4,
        ws_proto => nkcluster,
        user => #{type=>listen}
    },
    ListenOpts2 = maps:merge(ListenOpts1, nkcluster_app:get(tls_opts)),
    ListenSpecs = lists:map(
        fun(Uri) ->
            {ok, Spec} = nkpacket:get_listener(Uri, ListenOpts2),
            Spec
        end,
        nkcluster_app:get(listen)),
    ChildsSpec = 
        Primary
        ++
        [
            {nkcluster_agent,
                {nkcluster_agent, start_link, []},
                permanent,
                5000,
                worker,
                [nkcluster_agent]
            },
            {nkcluster_jobs,
                {nkcluster_jobs, start_link, []},
                permanent,
                5000,
                worker,
                [nkcluster_jobs]
            }
        ] 
        ++ 
        ListenSpecs,
    supervisor:start_link({local, ?MODULE}, ?MODULE, {{one_for_one, 10, 60}, 
                          ChildsSpec}).


%% @private
init(ChildSpecs) ->
    {ok, ChildSpecs}.


% %% @private
% start_tasks_sup() ->
%     supervisor:start_link({local, nkcluster_tasks_sup}, 
%                           ?MODULE, {{one_for_one, 10, 60}, []}).


