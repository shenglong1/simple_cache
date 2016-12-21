%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   sc_element的核心功能：一个element进程维护一个时间Value, LEASE_TIME后过期
%%% @end
%%% Created : 14. 十二月 2016 15:46
%%%-------------------------------------------------------------------
-module(sc_element).
-author("shenglong").

-behaviour(gen_server).

%% API
-export([
  start_link/2,
  create/2,
  create/1,
  fetch/1,
  replace/2,
  delete/1,
  send_msg/2
]).

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_LEASE_TIME, (10)).

-record(state, {value, lease_time, start_time}).

%% API
start_link(Value, LeaseTime) ->
  gen_server:start_link(?MODULE, [Value, LeaseTime], []). % call ?MODULE:init(Args)

%%% value container
%% local
create(Value, LeaseTime) ->
  sc_element_sup:start_child(Value, LeaseTime).

create(Value) ->
  create(Value, ?DEFAULT_LEASE_TIME).

%% global
% 利用gen_server来完成跨进程发req，收res
fetch(Pid) ->
  % 发送到特定进程去执行fetch并返回给gen_server
  gen_server:call(Pid, fetch).

% 利用gen_server来完成跨进程发req，收res
replace(Pid, Value) ->
  gen_server:cast(Pid, {replace, Value}).

% 利用gen_server来完成跨进程发req，收res
delete(Pid) ->
  gen_server:cast(Pid, delete).

%%% communicate API
send_msg(Pid, Msg) ->
  gen_server:call(Pid, {send, Msg}).


%% callbacks
init([Value, LeaseTime]) ->
  Now = calendar:local_time(),
  StartTime = calendar:datetime_to_gregorian_seconds(Now),
  {ok,
    #state{value = Value,
      lease_time = LeaseTime,
      start_time = StartTime},
    time_left(StartTime, LeaseTime)}. %% init 将这个State连带超时LeaseTime返回给gen_server:loop

time_left(_StartTime, infinity) ->
  infinity;
time_left(StartTime, LeaseTime) ->
  Now = calendar:local_time(),
  CurrentTime =  calendar:datetime_to_gregorian_seconds(Now),
  TimeElapsed = CurrentTime - StartTime,
  case LeaseTime - TimeElapsed of
    Time when Time =< 0 -> 0;
    Time                -> Time * 1000
  end.

handle_call(fetch, _From, State) ->
  % 从State中模式匹配出Value, LeaseTime, StartTime
  #state{value = Value,
    lease_time = LeaseTime,
    start_time = StartTime} = State,
  TimeLeft = time_left(StartTime, LeaseTime),
  % 返回当前Value值
  {reply, {ok, Value}, State, TimeLeft}; %% -> loop(_, State, TimeLeft)

handle_call({send, Msg}, From, State) ->
  io:format("[From:~p To:~p]:~p~n", [From, self(), Msg]),
  {reply, ok, State}.

handle_cast({replace, Value}, State) ->
  % 从State中模式匹配出LeaseTime, StartTime
  #state{lease_time = LeaseTime,
    start_time = StartTime} = State,
  TimeLeft = time_left(StartTime, LeaseTime),
  % 更新当前value值为Value
  {noreply, State#state{value = Value}, TimeLeft};

handle_cast(delete, State) ->
  {stop, normal, State}. % 返回给gen_server, 会call handle_info

handle_info(timeout, State) ->
  % gen_server:loop超时就结束
  {stop, normal, State}. % call terminate

terminate(_Reason, _State) ->
  sc_store_server:delete(self()),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
