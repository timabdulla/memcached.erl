-module(memcached_conn).

-behaviour(gen_fsm).

%% public apis

-export([start_link/0]).

-export([get/2,binary_join/2]).

%% gen_fsm callbacks

%% state callbacks

-export([ready/3,
	 set/3,
	 set/4]).

%% generic callbacks

-export([init/1,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3,
	 code_change/4]).

-record(state, {
    socket :: pid(),
    waiter
  }).

%% public api

start_link() ->
  gen_fsm:start_link(?MODULE, ["localhost", 11211], []).

get(Pid, Key) when is_binary(Key) ->
  gen_fsm:sync_send_event(Pid, {get, Key}).

set(Pid, Key, Value) when is_binary(Key) and is_binary(Value) ->
  set(Pid, Key, Value, 0).

set(Pid, Key, Value, Expires) when is_binary(Key) and is_binary(Value) ->
  gen_fsm:sync_send_event(Pid, {set, Key, Value, Expires}).

%% gen_fsm callbacks

init([Host, Port]) ->
  {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {packet, 0}]),
  {ok, ready, #state{socket=Socket}}.

ready({get, Key}, From, State) ->
  gen_tcp:send(State#state.socket, <<"get ", Key/binary, "\n">>),
  {next_state, waiting, State#state{waiter=From}};
ready({set, Key, Value, Expires}, From, State) ->
  Length = integer_to_binary(byte_size(Value)),
  ExpiresBinary = integer_to_binary(Expires),
  CmdParts = [[<<"set">>, Key, <<"0">>, ExpiresBinary, Length], [Value]],
  Cmd = lists:foldl(fun(RawLine, Command) ->
	Line = binary_join(RawLine, <<" ">>),
	<<Command/binary, Line/binary, "\r\n">>
    end, <<"">>, CmdParts),
  gen_tcp:send(State#state.socket, Cmd),
  {next_state, waiting, State#state{waiter=From}}.

handle_event(_Event, StateName, State) ->
  {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
  {reply, ok, StateName, State}.

handle_info({tcp,Sock,<<"STORED\r\n">>},waiting,#state{socket=Sock,waiter=Waiter}) ->
  gen_fsm:reply(Waiter, true),
  {next_state, ready, #state{socket=Sock}};
handle_info({tcp,Sock,<<"END\r\n">>},waiting,#state{socket=Sock,waiter=Waiter}) ->
  gen_fsm:reply(Waiter, undefined),
  {next_state, ready, #state{socket=Sock}};
handle_info({tcp,Sock,Message = <<"VALUE", _/binary>>},waiting,#state{socket=Sock,waiter=Waiter}) ->
  [{_, Value} | _] = get_values(Message),
  gen_fsm:reply(Waiter, Value),
  {next_state, ready, #state{socket=Sock}};
handle_info(_Info, StateName, State) ->
  io:format("~p~n", [_Info]),
  {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
  ok.

code_change(_OldVsn, StateName, State, _Extra) ->
  {ok, StateName, State}.

%% Internal functions.

get_values(Message) ->
  get_values(Message, []).

get_values(<<"END\r\n">>, Acc) ->
  Acc;
get_values(Message, Acc) ->
  [Details, Remainder] = binary:split(Message, <<"\r\n">>),
  [_, Key, _, RawLength] = binary:split(Details, <<" ">>, [global]),
  Length = list_to_integer(binary_to_list(RawLength)),
  <<Value:Length/binary, "\r\n", Remainder2/binary>> = Remainder,
  get_values(Remainder2, [{Key, Value} | Acc]).

binary_join([Head | List], Pattern) ->
  binary_join(List, Pattern, Head).

binary_join([], _, Acc) ->
  Acc;
binary_join([Head | List], Pattern, Acc) ->
  binary_join(List, Pattern, <<Acc/binary, Pattern/binary, Head/binary>>).

integer_to_binary(Int) ->
  list_to_binary(lists:flatten(io_lib:format("~p", [Int]))).
