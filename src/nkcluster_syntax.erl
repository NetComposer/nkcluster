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

-module(nkcluster_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([app_syntax/0, app_defaults/0]).

-include_lib("nkpacket/include/nkpacket.hrl").

%% ===================================================================
%% Private
%% ===================================================================

app_syntax() -> 
    #{
        cluster_name => binary,
        cluster_addr => uris,
        password => binary,
        meta => tokens,
        is_control => boolean,
        listen => uris,
        ?TLS_SYNTAX,
        
        ping_time => {integer, 1000, 60000},          % Ping interval for agent and proxy
        proxy_connect_retry => {integer, 1000, none}, % After faillyre
        stats_time => {integer, 1000, none},          % Agent generation
        node_id => binary,                            % Force node id
        staged_joins => boolean,                      % For riak_core
        pbkdf2_iters => {integer, 1, none}            % Password hash
    }.


app_defaults() ->
    #{
        cluster_name => "nkcluster",
        cluster_addr => "",
        password => "nkcluster",
        meta => "",
        is_control => true,
        listen => "nkcluster://all;transport=tls",
        ping_time => 5000,
        proxy_connect_retry => 10000,
        stats_time => 10000,
        staged_joins => false,
        pbkdf2_iters => 20000
    }.
    