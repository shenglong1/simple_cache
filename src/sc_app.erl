%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   Function: 维护一个Key Value对，超时时间为LEASETIME
%%%   本模块负责建立全局mnesia表(key, pid)，并连同集群
%%% @end
%%% Created : 14. 十二月 2016 15:18
%%%-------------------------------------------------------------------
-module(sc_app).
-author("shenglong").

-behaviour(application).

%% Application callbacks
-export([start/2,
  stop/1]).

-define(WAIT_FOR_RESOURCES, 2500).
%%%===================================================================
%%% Application callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called whenever an application is started using
%% application:start/[1,2], and should start the processes of the
%% application. If the application is structured according to the OTP
%% design principles as a supervision tree, this means starting the
%% top supervisor of the tree.
%%
%% @end
%%--------------------------------------------------------------------
-spec(start(StartType :: normal | {takeover, node()} | {failover, node()},
    StartArgs :: term()) ->
  {ok, pid()} |
  {ok, pid(), State :: term()} |
  {error, Reason :: term()}).
start(_StartType, _StartArgs) ->
  % 这里的设置都是全局的，跨节点
  ok = ensure_contact(), % connect all nodes
  resource_discovery:add_local_resource(simple_cache, node()),
  resource_discovery:add_target_resource_type(simple_cache),
  resource_discovery:trade_resources(),
  timer:sleep(?WAIT_FOR_RESOURCES),

  %%%% sc_store:init(),
  case sc_sup:start_link() of
    {ok, Pid} ->
      % 将sc_event_logger当做handler(callbacks提供者)注册给gen_event
      sc_event_logger:add_handler(),
      {ok, Pid};
    Error ->
      Error
  end.

% 连同集群
ensure_contact() ->
  DefaultNodes = ['contact2@0280106PC0413'],
  case get_env(simple_cache, contact_nodes, DefaultNodes) of
    [] ->
      {error, no_contact_nodes};
    ContactNodes ->
      % ContactNodes is list
      ensure_contact(ContactNodes)
  end.

ensure_contact(ContactNodes) ->
  Answering = [N || N <- ContactNodes, net_adm:ping(N) =:= pong],
  case Answering of
    [] ->
      {error, no_contact_nodes_reachable};
    _ ->
      % 有回复点
      DefaultTime = 6000,
      WaitTime = get_env(simple_cache, wait_time, DefaultTime),
      wait_for_nodes(length(Answering), WaitTime)
  end.

wait_for_nodes(MinNodes, WaitTime) ->
  Slices = 10,
  SliceTime = round(WaitTime/Slices),
  wait_for_nodes(MinNodes, SliceTime, Slices). % 等待Slices次递归

wait_for_nodes(_MinNodes, _SliceTime, 0) ->
  % 超过最大等待次数
  ok;
wait_for_nodes(MinNodes, SliceTime, Iterations) ->
  case length(nodes()) >= MinNodes of
    true ->
      ok;
    false ->
      timer:sleep(SliceTime),
      wait_for_nodes(MinNodes, SliceTime, Iterations - 1)
  end.

get_env(AppName, Key, Default) ->
  case application:get_env(AppName, Key) of
    undefined   -> Default;
    {ok, Value} -> Value
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called whenever an application has stopped. It
%% is intended to be the opposite of Module:start/2 and should do
%% any necessary cleaning up. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec(stop(State :: term()) -> term()).
stop(_State) ->
  ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
