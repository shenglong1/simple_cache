%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   sc_element的核心功能：一个element进程维护一个Name，即是API调用者和callback回发目标
%%%   LEASE_TIME后过期
%%%   Name和LEASE_TIME都在State中传递
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
  send_msg/3,
  flush/1
]).

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_LEASE_TIME, (10)).

-record(key_to_pid, {name, pid}).
-record(state, {user, lease_time, start_time}).

%% API
start_link(Name, LeaseTime) ->
  % TODO: 由element_sup自动拉起时调用
  % TODO: 且自动拉起时和首次启动时的Name, LeaseTime参数都完全相同!!!
  % TODO: call sc_element:init(_,_)
  gen_server:start_link(?MODULE, [Name, LeaseTime], []). % call element:init

%%% value container
%% local
% sc_element_sup:start_child最终还是回来调用MFA，即start_link(Name, LeaseTime)
create(Name, LeaseTime) ->
  % TODO: 首次建立element时由Caller调用,告诉sc_element_sup:supervisor去启动一个element child
  % TODO: 这么做之后，会导致supervisor:State中element的MFA更新，其中A包含Caller/LeaseTime，用于下次启动
  sc_element_sup:start_child(Name, LeaseTime).

create(Name) ->
  create(Name, ?DEFAULT_LEASE_TIME).

%% global
% 利用gen_server来完成跨进程发req，收res
fetch(Pid) ->
  % 发送到特定进程去执行fetch并返回给gen_server
  gen_server:call(Pid, fetch).

% 利用gen_server来完成跨进程发req，收res
replace(Pid, Name) ->
  gen_server:cast(Pid, {replace, Name}).

% 利用gen_server来完成跨进程发req，收res
delete(Pid) ->
  gen_server:cast(Pid, delete).

%%% communicate API
send_msg(Pid, Msg, Epid) ->
  erlang:send(Pid, {send, Epid, Msg}). % TODO: bug这里并没有进入element进程，还是属于caller进程；

%% callbacks
init([Name, LeaseTime]) ->
  % 无论是首次启动(create)或是自动拉起start_link，最终都是到这里，且都提供了Name参数

  % TODO: 如何区分是自动拉起的？如果是自动拉起的就必须通知Name更新pid
  % 用Name检查key_to_pid中是否已有记录，已有则看做是进程挂拉起的，需要更新对应项的element_pid
  case sc_store_server:lookup(key_to_pid, name, Name) of
    {ok, {Name_r, Epid_r}, Node} ->
      % key_to_pid中已有记录，非首次启动，视为拉起
      case Epid_r == self() of
        false ->
          % 按照Name修复pid-caller
          ok = sc_store_server:insert(Node, key_to_pid, #key_to_pid{name = Name_r, pid = self()})
      end;
    {error, _, _} -> first_run_element
  end,

  Now = calendar:local_time(),
  StartTime = calendar:datetime_to_gregorian_seconds(Now),
  {ok,
    #state{
      user = Name,
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
  % 从State中模式匹配出Caller, LeaseTime, StartTime
  #state{user = Name,
    lease_time = LeaseTime,
    start_time = StartTime} = State,
  TimeLeft = time_left(StartTime, LeaseTime),
  % 返回当前Value值
  {reply, {ok, Name}, State, TimeLeft}. %% -> loop(_, State, TimeLeft)

handle_cast({replace, Name}, State) ->
  % 从State中模式匹配出LeaseTime, StartTime
  #state{lease_time = LeaseTime,
    start_time = StartTime} = State,
  TimeLeft = time_left(StartTime, LeaseTime),
  % 更新当前value值为Value
  {noreply, State#state{user = Name}, TimeLeft};

handle_cast(delete, State) ->
  {stop, normal, State}. % 返回给gen_server, 会call handle_info

handle_info({send, From, Msg}, State) ->
  % #state{caller = Caller} = State,

  % TODO: 这里即是收到消息后的print
  case Msg of
    {From_name, To_name, Real_msg} ->
      io:format("[From:~p(~p) To:~p(~p)]:~p~n", [From_name, From, To_name, self(), Real_msg]);
    got ->
      io:format("message got by remote~n"); %TODO: can not print ?
    _ ->
      % raw msg
      io:format("[From:~p To:~p]:~p~n", [From, self(), Msg])
  end,

  % bug: case is not if
  case is_pid(From) of
    true ->
      % ack
      % TODO: cannot send? 由于sc_element:send_msg 中实际上还是在simple_cache进程中，但是用了self()，所以回复都是发给simple_cache了
      erlang:send(From, {send, noreply, got});
    false -> 1
  end,

  % notify local Caller
  % erlang:send(Caller, {recv, From, Msg}),
  {noreply, State};

handle_info(timeout, State) ->
  % gen_server:loop超时就结束
  {stop, normal, State}. % call terminate

terminate(_Reason, _State) ->
  % 正常终止，告知element
  ok = sc_element_sup:terminate_child(self()),
  ok = sc_element_sup:delete_child(self()),
  ok = sc_store_server:delete(key_to_pid, self()),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

% flush process
flush(Table) ->
  try
    dets:open_file(Table, [access, read_write]),
    dets:sync(Table),
    timer:sleep(10000),
    flush(Table)
  catch
    _ : _ ->
      flush(Table)
  end.
