-module(cake_protocol_statem).

-behaviour(proper_statem).

-include_lib("proper/include/proper.hrl").

-compile(export_all).

-export([initial_state/0, command/1, precondition/2, postcondition/3,
        next_state/3]).

% E.g. of model state structure:
% {
%   starttime = 13554171361963445,
%   counter = N,
%   streams = [
%     {StreamID_1, StreamName_1, [{TS_1,<<"DATA_1">>}, ..., {TS_M,<<"DATA_M">>}]},
%     ...,
%     {StreamID_N, StreamName_N, [{TS_1,<<"DATA_1">>}, ..., {TS_L,<<"DATA_L">>}]}
%   ]
% }
-record(state,{starttime,counter,streams}).

% Options
-define(NOOP, 0).
-define(REQUEST_STREAM_WITH_SIZE, 1).
-define(APPEND, 2).
-define(QUERY, 3).
-define(ALL_SINCE, 4).
-define(REQUEST_STREAM, 5).
-define(LAST_ENTRY_AT, 6).

% socket
-define(HOST,"localhost").
-define(PORT,8888).
-define(TIMEOUT,2000). % time delay in ms to let CakeDB flush

-define(STREAMNAMES, ["tempfile", "file001", "anotherfile",
        "somefile", "binfile", "cakestream"]).

%%-----------------------------------------------------------------------------
%% statem callbacks
%%-----------------------------------------------------------------------------

% initialize the state machine
initial_state() ->
    #state{
            starttime = timestamp(),
            counter = 0,
            streams = []
          }.

% define the commands to test
command(S) ->
    oneof([
        {call,?MODULE,request_stream,[streamname()]},
        {call,?MODULE,request_stream_with_size,[pos_integer(),streamname()]},
%        {call,?MODULE,append,[streamid(S),list(integer(32,255))]},
        {call,?MODULE,append,[streamid(S),"AAAAAA"]},
        {call,?MODULE,simple_query,[streamid(S),S#state.starttime,timestamp_wrapper()]}%,
%        {call,?MODULE,all_since,[streamid(S),S#state.starttime]},
%        {call,?MODULE,last_entry_at,[streamid(S),timestamp_wrapper()]}
    ]).

% define when a command is valid
precondition(S, {call,?MODULE,simple_query,[StreamID,_Start,_End]}) ->
    lists:keymember(StreamID,1,S#state.streams);
precondition(_S, _Command) ->
    true.

%% define the state transitions triggered
%% by each command
next_state(S,{ok,<<_,ID>>},{call,?MODULE,request_stream_with_size,[_Size,StreamName]}) ->
    case lists:keymember(StreamName,2,S#state.streams) of
        false ->
            S#state{
                counter = S#state.counter + 1,
                streams = [{ID, StreamName, []}|S#state.streams]
            };
        true ->
            S
    end;
next_state(S,_V,{call,?MODULE,append,[StreamID,Data]}) ->
    OldTuple = lists:keysearch(StreamID,1,S#state.streams),
    case OldTuple of
        {value, {StreamID,StreamName,OldData}} ->
            NewTuple = {StreamID,StreamName,[{timestamp(),Data}|OldData]},
            S#state{
                streams = lists:keyreplace(StreamID,1,S#state.streams,NewTuple)
            };
        false ->
            S
    end;
next_state(S,_V,{call,?MODULE,request_stream,[StreamName]}) ->
    case lists:keymember(StreamName,2,S#state.streams) of
        false ->
            S#state{
                counter = S#state.counter + 1,
                streams = [{S#state.counter +1, StreamName, []}|S#state.streams]
            };
        true ->
            S
    end;
%% all the other commands do not change the abstract state
next_state(S, _V, _Command) ->
    S.

%% define the conditions needed to be
%% met in order for a test to pass
postcondition(S, {call,?MODULE,request_stream_with_size,[_Size,StreamName]}, Result) ->
    Stream = lists:keysearch(StreamName,2,S#state.streams),
    case {Stream,Result} of
        {{value,{StreamID,_StreamName,_Data}},{ok,<<0,ID>>}} ->
            StreamID =:= ID;
        {false,{ok,_ID}} ->
            true;
        _ ->
            false
    end;
postcondition(S, {call,?MODULE,append,[StreamID,_Data]}, Result) ->
    case lists:keymember(StreamID,1,S#state.streams) of
        true ->
            Result =:= {error,timeout};
        false ->
            Result =:= {error,closed}
    end;
postcondition(S, {call,?MODULE,simple_query,[StreamID,_Start,_End]}, Result) ->
    Stream = lists:keysearch(StreamID,1,S#state.streams),
    io:format("~nStream: ~p~n",[Stream]),
    io:format("Result: ~p~n~n",[Result]),
    true;
postcondition(S, {call,?MODULE,request_stream,[_Size,StreamName]}, Result) ->
    Stream = lists:keysearch(StreamName,2,S#state.streams),
    case {Stream,Result} of
        {{value,{StreamID,_StreamName,_Data}},{ok,<<0,ID>>}} ->
            StreamID =:= ID;
        {false,{ok,_ID}} ->
            true;
        _ ->
            false
    end;
postcondition(_S, _Command, _Result) ->
    true.

%%-----------------------------------------------------------------------------
%% properties
%%-----------------------------------------------------------------------------

prop_cake_protocol_works() ->
    ?FORALL(Cmds, commands(?MODULE),
        begin
            application:start(cake),
            {History,State,Result} = run_commands(?MODULE, Cmds),
            application:stop(cake),
            [cake_streams_statem:cleanup(X) || {_,X,_} <- element(4,State)],
            ?WHENFAIL(
                io:format("\n\nHistory: ~w\n\nState: ~w\n\nResult: ~w\n\n",
                [History,State,Result]),
                aggregate(command_names(Cmds), Result =:= ok))
        end).

%%-----------------------------------------------------------------------------
%% generators
%%-----------------------------------------------------------------------------

streamname() -> 
    elements(?STREAMNAMES).

% Return any of the existing StreamID
streamid(#state{counter = Counter}) ->
    elements(lists:seq(1, Counter+1)).

%%-----------------------------------------------------------------------------
%% query operations
%%-----------------------------------------------------------------------------

request_stream_with_size(Size,StreamName) ->
    Message = list_to_binary([ <<Size:16>>,StreamName]),
    tcp_query(?HOST,?PORT,packet(?REQUEST_STREAM_WITH_SIZE,Message)).

append(StreamID,String) ->
    Message = list_to_binary([ <<StreamID:16>>,String]),
    tcp_query(?HOST,?PORT,packet(?APPEND,Message)).

simple_query(StreamID,Start,End) ->
    timer:sleep(?TIMEOUT),
    Message = list_to_binary([ <<StreamID:16>>, Start, End]),
    tcp_query(?HOST,?PORT,packet(?QUERY,Message)).

all_since(StreamID,Time) ->
    Message = list_to_binary([ <<StreamID:16>>, Time]),
    tcp_query(?HOST,?PORT,packet(?ALL_SINCE,Message)).

request_stream(StreamName) ->
    Message = list_to_binary(StreamName),
    tcp_query(?HOST,?PORT,packet(?REQUEST_STREAM,Message)).
 
last_entry_at(StreamID,Time) ->
    Message = list_to_binary([ <<StreamID:16>>, Time]),
    tcp_query(?HOST,?PORT,packet(?LAST_ENTRY_AT,Message)).

%%-----------------------------------------------------------------------------
%% utils
%%-----------------------------------------------------------------------------

tcp_query(Host,Port,Packet) ->
    % Send a binary query to CakeDB and listen for result
    {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active,false}]),
    gen_tcp:send(Socket, Packet),
    Output = gen_tcp:recv(Socket,0,500),
    gen_tcp:close(Socket),
    Output.

packet(Option,Message) ->
    % Returns a binary packet of type Option
    % to be sent to CakeDB
    Length = int_to_binary(size(Message),32),
    list_to_binary([Length, <<Option:16>>,Message]).

timestamp() ->
    {Mega, Sec, Micro} = now(),
    TS = Mega * 1000000 * 1000000 + Sec * 1000000 + Micro,
    <<TS:64/big-integer>>.

timestamp_wrapper() ->
    {call,?MODULE,timestamp,[]}.

int_to_binary(Int, Bits) ->
    <<Int:Bits>>.

