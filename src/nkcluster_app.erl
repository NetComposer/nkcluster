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

%% @doc NkCLUSTER OTP Application Module
-module(nkcluster_app).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(application).

-export([start/0, start/2, stop/1]).
-export([get/1, put/2]).

-include("nkcluster.hrl").
-include_lib("nklib/include/nklib.hrl").

-define(APP, nkcluster).

-compile({no_auto_import, [get/1, put/2]}).

%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    case nklib_util:ensure_all_started(?APP, temporary) of
        {ok, _Started} -> ok;
        {error, Error} -> {error, Error}
    end.


%% @private OTP standard start callback
start(_Type, _Args) ->
    ConfigSpec = #{
        cluster_name => binary,
        cluster_addr => uris,
        password => binary,
        meta => tokens,
        is_control => boolean,
        listen => uris,
        tls_opts => nkpacket_util:tls_spec(),
        node_id => binary,
        staged_joins => boolean
    },
    Defaults = [
        {cluster_name, "nkcluster"},
        {cluster_addr, ""},
        {password, "nkcluster"},
        {meta, ""},
        {is_control, true},
        {listen, "nkcluster://all;transport=tls"},
        {tls_opts, nkpacket_config:tls_opts()},
        {staged_joins, false}
    ],
    case nklib_config:load_env(?APP, ?APP, Defaults, ConfigSpec) of
        ok ->
            nkpacket_config:register_protocol(nkcluster, nkcluster_protocol),
            check_uris(get(cluster_addr)),
            check_uris(get(listen)),
            %% It is NOT recommended that you fix the NodeId!
            NodeId = case get(node_id) of
                Bin when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
                _ -> nklib_util:luid()
            end,
            nklib_config:put(?APP, node_id, NodeId),
            {ok, Vsn} = application:get_key(?APP, vsn),
            IsControl = get(is_control),
            case IsControl of
                true -> ok = nkdist_app:start();
                false -> ok
            end,
            MasterMsg = case IsControl of
                true -> "control";
                false -> "worker"
            end,
            lager:notice("NkCLUSTER v~s '~s' node ~s is starting (cluster '~s')", 
                         [Vsn, MasterMsg, NodeId, get(cluster_name)]),
            lager:notice("NkCLUSTER node listening on ~s", 
                         [nklib_unparse:uri(get(listen))]),
            case nklib_unparse:uri(get(cluster_addr)) of
                <<>> -> 
                    ok;
                Addrs -> 
                    lager:notice("NkCLUSTER cluster ~s addresses: ~s", 
                                 [get(cluster_name), Addrs])
            end,
            case nklib_unparse:token(get(meta)) of
                <<>> -> ok;
                Meta -> lager:notice("NkCLUSTER node metadata: ~s", [Meta])
            end,
            nkcluster_sup:start_link();
        {error, Error} ->
            lager:error("Error parsing config: ~p", [Error]),
            error(Error)
    end.


%% @private OTP standard stop callback
stop(_) ->
    ok.


%% @doc gets a configuration value
get(Key) ->
    get(Key, undefined).


%% @doc gets a configuration value
get(Key, Default) ->
    nklib_config:get(?APP, Key, Default).


%% @doc updates a configuration value
put(Key, Value) ->
    nklib_config:put(?APP, Key, Value).



%% @private
check_uris(Uris) ->
    case nkpacket:multi_resolve(Uris, #{valid_schemes=>[nkcluster]}) of
        {ok, _} -> 
            ok;
        {error, _} -> 
            lager:error("Error parsing config: invalid_uri ~p", [Uris]),
            error(invalid_uri)
    end.


