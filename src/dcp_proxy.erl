%% @author Couchbase <info@couchbase.com>
%% @copyright 2013-2018 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc DCP proxy code that is common for consumer and producer sides
%%
-module(dcp_proxy).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_link/6, maybe_connect/1, maybe_connect/2,
         connect_proxies/2, nuke_connection/4, terminate_and_wait/2]).

-export([get_socket/1, get_partner/1, get_conn_name/1, get_bucket/1]).

-record(state, {sock = undefined :: port() | undefined,
                connect_info,
                packet_len = undefined,
                buf = <<>> :: binary(),
                ext_module,
                ext_state,
                proxy_to = undefined :: port() | undefined,
                partner = undefined :: pid() | undefined,
                connection_alive
               }).

-define(HIBERNATE_TIMEOUT, 10000).
-define(LIVELINESS_UPDATE_INTERVAL, 1000).

-define(CONNECT_TIMEOUT, ns_config:get_timeout(ebucketmigrator_connect, 180000)).

-define(RECBUF, ns_config:read_key_fast({node, node(), mc_replication_recbuf}, 64 * 1024)).
-define(SNDBUF, ns_config:read_key_fast({node, node(), mc_replication_sndbuf}, 64 * 1024)).

init([Type, ConnName, Node, Bucket, ExtModule, InitArgs]) ->
    {ExtState, State} = ExtModule:init(
                          InitArgs,
                          #state{connect_info = {Type, ConnName, Node, Bucket},
                                 ext_module = ExtModule}),
    self() ! check_liveliness,
    {ok, State#state{
           ext_state = ExtState,
           connection_alive = false
          }, ?HIBERNATE_TIMEOUT}.

start_link(Type, ConnName, Node, Bucket, ExtModule, InitArgs) ->
    gen_server:start_link(?MODULE, [Type, ConnName, Node, Bucket, ExtModule, InitArgs], []).

get_socket(State) ->
    State#state.sock.

get_partner(State) ->
    State#state.partner.

get_conn_name(State) ->
    {_, ConnName, _, _} = State#state.connect_info,
    ConnName.

get_bucket(State) ->
    {_, _, _, Bucket} = State#state.connect_info,
    Bucket.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_cast({setup_proxy, Partner, ProxyTo}, State) ->
    {noreply, State#state{proxy_to = ProxyTo, partner = Partner}, ?HIBERNATE_TIMEOUT};
handle_cast(Msg, State = #state{ext_module = ExtModule, ext_state = ExtState}) ->
    {noreply, NewExtState, NewState} = ExtModule:handle_cast(Msg, ExtState, State),
    {noreply, NewState#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT}.

terminate(_Reason, _State) ->
    ok.

handle_info({tcp, Socket, Data}, #state{sock = Socket} = State) ->
    %% Set up the socket to receive another message
    ok = inet:setopts(Socket, [{active, once}]),

    {noreply, process_data(Data, State), ?HIBERNATE_TIMEOUT};

handle_info({tcp_closed, Socket}, State) ->
    ?log_error("Socket ~p was closed. Closing myself. State = ~p", [Socket, State]),
    {stop, socket_closed, State};

handle_info({'EXIT', _Pid, _Reason} = ExitSignal, State) ->
    ?log_error("killing myself due to exit signal: ~p", [ExitSignal]),
    {stop, {got_exit, ExitSignal}, State};

handle_info(timeout, State) ->
    {noreply, State, hibernate};

handle_info(check_liveliness, #state{connection_alive = false} = State) ->
    erlang:send_after(?LIVELINESS_UPDATE_INTERVAL, self(), check_liveliness),
    {noreply, State, ?HIBERNATE_TIMEOUT};
handle_info(check_liveliness,
            #state{connect_info = {_, _, Node, Bucket},
                   connection_alive = true} = State) ->
    %% NOTE: The following comment only applies to pre-OTP18 Erlang.
    %%
    %% We are not interested in the exact time of the last DCP traffic.
    %% We mainly want to know whether there was atleast one DCP message
    %% during the last LIVELINESS_UPDATE_INTERVAL.
    %% An approximate timestamp is good enough.
    %% erlang:now() can be bit expensive compared to os:timestamp().
    %% But, os:timestamp() may not be monotonic.
    %% Since this function gets called only every 1 second, should
    %% be ok to use erlang:now().
    %% Alternatively, we can also attach the timestamp in
    %% dcp_traffic_monitor:node_alive(). But, node_alive is an async operation
    %% so I prefer to attach the timestamp here.
    Now = time_compat:monotonic_time(),
    dcp_traffic_monitor:node_alive(Node, {Bucket, Now, self()}),
    erlang:send_after(?LIVELINESS_UPDATE_INTERVAL, self(), check_liveliness),
    {noreply, State#state{connection_alive = false}, ?HIBERNATE_TIMEOUT};

handle_info(Msg, State) ->
    ?log_warning("Unexpected handle_info(~p, ~p)", [Msg, State]),
    {noreply, State, ?HIBERNATE_TIMEOUT}.

handle_call(get_socket, _From, State = #state{sock = Sock}) ->
    {reply, Sock, State, ?HIBERNATE_TIMEOUT};
handle_call(Command, From, State = #state{ext_module = ExtModule, ext_state = ExtState}) ->
    case ExtModule:handle_call(Command, From, ExtState, State) of
        {ReplyType, Reply, NewExtState, NewState} ->
            {ReplyType, Reply, NewState#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT};
        {ReplyType, NewExtState, NewState} ->
            {ReplyType, NewState#state{ext_state = NewExtState}, ?HIBERNATE_TIMEOUT}
    end.

handle_packet(<<Magic:8, Opcode:8, _Rest/binary>> = Packet,
              State = #state{ext_module = ExtModule,
                             ext_state = ExtState,
                             proxy_to = ProxyTo}) ->
    case (erlang:get(suppress_logging_for_xdcr) =:= true
          orelse suppress_logging(Packet)
          orelse not ale:is_loglevel_enabled(?NS_SERVER_LOGGER, debug)) of
        true ->
            ok;
        false ->
            ?log_debug("Proxy packet: ~s", [dcp_commands:format_packet_nicely(Packet)])
    end,

    Type = case Magic of
               ?REQ_MAGIC ->
                   request;
               ?RES_MAGIC ->
                   response
           end,
    {Action, NewExtState, NewState} = ExtModule:handle_packet(Type, Opcode, Packet, ExtState, State),
    case Action of
        proxy ->
            ok = gen_tcp:send(ProxyTo, Packet);
        block ->
            ok
    end,
    {ok, NewState#state{ext_state = NewExtState, connection_alive = true}}.

suppress_logging(<<?REQ_MAGIC:8, ?DCP_MUTATION:8, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?DCP_DELETION:8, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?DCP_SNAPSHOT_MARKER, _Rest/binary>>) ->
    true;
suppress_logging(<<?REQ_MAGIC:8, ?DCP_WINDOW_UPDATE, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?DCP_MUTATION:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?DCP_DELETION:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<?RES_MAGIC:8, ?DCP_SNAPSHOT_MARKER:8, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
%% TODO: remove this as soon as memcached stops sending these
suppress_logging(<<?RES_MAGIC:8, ?DCP_WINDOW_UPDATE, _KeyLen:16, _ExtLen:8,
                   _DataType:8, ?SUCCESS:16, _Rest/binary>>) ->
    true;
suppress_logging(<<_:8, ?DCP_NOP:8, _Rest/binary>>) ->
    true;
suppress_logging(_) ->
    false.

maybe_connect(State) ->
    maybe_connect(State, false).

maybe_connect(#state{sock = undefined,
                     connect_info = {Type, ConnName, Node, Bucket}} = State, XAttr) ->
    Sock = connect(Type, ConnName, Node, Bucket, XAttr),

    %% setup socket to receive the first message
    ok = inet:setopts(Sock, [{active, once}]),

    State#state{sock = Sock};
maybe_connect(State, _) ->
    State.

connect(Type, ConnName, Node, Bucket) ->
    connect(Type, ConnName, Node, Bucket, false).

connect(Type, ConnName, Node, Bucket, XAttr) ->
    Cfg = ns_config:latest(),
    Username = ns_config:search_node_prop(Node, Cfg, memcached, admin_user),
    Password = ns_config:search_node_prop(Node, Cfg, memcached, admin_pass),

    {Host, Port} = ns_memcached:host_port(Node),
    {ok, Sock} = gen_tcp:connect(Host, Port,
                                 [misc:get_net_family(), binary,
                                  {packet, raw}, {active, false},
                                  {nodelay, true}, {delay_send, true},
                                  {keepalive, true},
                                  {recbuf, ?RECBUF},
                                  {sndbuf, ?SNDBUF}],
                                 ?CONNECT_TIMEOUT),
    ok = mc_client_binary:auth(Sock, {<<"PLAIN">>,
                                      {list_to_binary(Username),
                                       list_to_binary(Password)}}),
    ok = mc_client_binary:select_bucket(Sock, Bucket),

    %% If XAttr is true that means that the cluster is XATTRs capable and we
    %% don't expect the XAttr negotiation to fail.
    %%
    %% Snappy is controlled by datatype_snappy flag and it defaults to true.
    %% So we try to negotiate it unconditionally, if it's enabled. In mixed
    %% clusters, if this fails we still go ahead with the connections as there
    %% will be no correctness issues. Also when the datatype_snappy flag is
    %% toggled by the user, only the newer connections see the change and it's
    %% semantically ok to retain the older connections as is.
    Snappy = ns_config:search_prop(Cfg, memcached, datatype_snappy, true),
    negotiate_features(Sock, Type, ConnName, XAttr, Snappy),

    ok = dcp_commands:open_connection(Sock, ConnName, Type, XAttr),
    Sock.

negotiate_features(Sock, Type, ConnName, XAttr, Snappy) ->
    Features = [<<V:16>> || {V, true} <-
                                [{?MC_FEATURE_XATTR, XAttr},
                                 {?MC_FEATURE_SNAPPY, Snappy}]],

    case do_negotiate_features(Sock, Type, ConnName, Features) of
        ok ->
            ok;
        {error, FailedFeatures} ->
            case lists:member(<<?MC_FEATURE_SNAPPY:16>>, FailedFeatures) of
                true ->
                    ?log_debug("Snappy negotiation failed for connection ~p:~p",
                               [ConnName, Type]);
                false ->
                    ok
            end,

            %% We don't expect the XAttr negotiation to fail.
            false = lists:member(<<?MC_FEATURE_XATTR:16>>, FailedFeatures),
            ok
    end.

do_negotiate_features(_Sock, _Type, _ConnName, []) ->
    ok;
do_negotiate_features(Sock, Type, ConnName, Features) ->
    case mc_client_binary:hello(Sock, "proxy", list_to_binary(Features)) of
        {ok, undefined} ->
            {error, Features};
        {ok, RV} ->
            Negotiated = [<<V:16>> || <<V:16>> <= RV],
            case Features -- Negotiated of
                [] ->
                    ok;
                Val ->
                    {error, Val}
            end;
        Error ->
            ?log_debug("HELLO cmd failed for connection ~p:~p, features = ~p,"
                       "err = ~p", [ConnName, Type, Features, Error]),
            {error, Features}
    end.

disconnect(Sock) ->
    gen_tcp:close(Sock).

nuke_connection(Type, ConnName, Node, Bucket) ->
    ?log_debug("Nuke DCP connection ~p type ~p on node ~p", [ConnName, Type, Node]),
    disconnect(connect(Type, ConnName, Node, Bucket)).

connect_proxies(Pid1, Pid2) ->
    Sock1 = gen_server:call(Pid1, get_socket, infinity),
    Sock2 = gen_server:call(Pid2, get_socket, infinity),

    gen_server:cast(Pid1, {setup_proxy, Pid2, Sock2}),
    gen_server:cast(Pid2, {setup_proxy, Pid1, Sock1}),
    [{Pid1, Sock1}, {Pid2, Sock2}].

terminate_and_wait(Pairs, normal) ->
    misc:terminate_and_wait([Pid || {Pid, _} <- Pairs], normal);
terminate_and_wait(Pairs, shutdown) ->
    misc:terminate_and_wait([Pid || {Pid, _} <- Pairs], shutdown);
terminate_and_wait(Pairs, _Reason) ->
    [disconnect(Sock) || {_, Sock} <- Pairs],
    misc:terminate_and_wait([Pid || {Pid, _} <- Pairs], kill).

process_data(NewData, #state{buf = PrevData,
                             packet_len = PacketLen} = State) ->
    Data = <<PrevData/binary, NewData/binary>>,
    process_data_loop(Data, PacketLen, State).

process_data_loop(Data, undefined, State) ->
    case Data of
        <<_Magic:8, _Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
          _VBucket:16, BodyLen:32, _Opaque:32, _CAS:64, _Rest/binary>> ->
            process_data_loop(Data, ?HEADER_LEN + BodyLen, State);
        _ ->
            State#state{buf = Data,
                        packet_len = undefined}
    end;
process_data_loop(Data, PacketLen, State) ->
    case byte_size(Data) >= PacketLen of
        false ->
            State#state{buf = Data,
                        packet_len = PacketLen};
        true ->
            {Packet, Rest} = split_binary(Data, PacketLen),
            {ok, NewState} = handle_packet(Packet, State),
            process_data_loop(Rest, undefined, NewState)
    end.

-ifdef(EUNIT).

negotiate_features_test() ->
    meck:new(mc_client_binary, [passthrough]),

    V = [<<?MC_FEATURE_XATTR:16>>, <<?MC_FEATURE_SNAPPY:16>>],
    meck:expect(mc_client_binary, hello,
                fun(_, _, _) -> {ok, list_to_binary(V)} end),
    ?assertEqual(ok, do_negotiate_features([], type, "xyz", V)),

    meck:expect(mc_client_binary, hello,
                fun(_, _, _) -> {ok, <<?MC_FEATURE_SNAPPY:16>>} end),
    ?assertEqual({error, [<<?MC_FEATURE_XATTR:16>>]},
                 do_negotiate_features([], type, "xyz", V)),
    ?assertEqual(ok, do_negotiate_features([], type, "xyz",
                                           [<<?MC_FEATURE_SNAPPY:16>>])),

    meck:expect(mc_client_binary, hello,
                fun(_, _, _) -> {ok, <<?MC_FEATURE_XATTR:16>>} end),
    ?assertEqual({error, [<<?MC_FEATURE_SNAPPY:16>>]},
                 do_negotiate_features([], type, "xyz", V)),
    ?assertEqual(ok, do_negotiate_features([], type, "xyz",
                                           [<<?MC_FEATURE_XATTR:16>>])),

    meck:expect(mc_client_binary, hello, fun(_, _, _) -> error end),
    ?assertEqual({error, V}, do_negotiate_features([], type, "xyz", V)),

    true = meck:validate(mc_client_binary),
    meck:unload(mc_client_binary).

-endif.
