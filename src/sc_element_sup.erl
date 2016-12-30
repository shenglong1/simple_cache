%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 14. 十二月 2016 15:17
%%%-------------------------------------------------------------------
-module(sc_element_sup).
-author("shenglong").

-behaviour(supervisor).

%% API
-export([start_link/0, start_child/2]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_child(Caller :: pid(), LeaseTime :: integer()) ->
  {ok, Pid :: pid()} | {error, Reason :: term()}
).
start_child(Caller, LeaseTime) ->
  % start all children which sc_element_sup:init returns
  supervisor:start_child(?SERVER, [Caller, LeaseTime]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
    MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
    [ChildSpec :: supervisor:child_spec()]
  }} |
  ignore |
  {error, Reason :: term()}).
init([]) ->
  RestartStrategy = one_for_one, % 仅能启动同一种子进程，但可以启动多个
  % 不自动重启
  % MaxRestarts = 0,
  % MaxSecondsBetweenRestarts = 1,
  % 需要自动重启
  MaxRestarts = 10,
  MaxSecondsBetweenRestarts = 60,

  SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

  RestartType = transient,
  % RestartType = permanent, % TODO: test auto startup
  Shutdown = 30,
  Type = worker,

  % 子进程规范
  % {ID, Start = {Mod, Fun, Args}, Restart, Shutdown, Type, Modules}
  AChild = {sc_element, {sc_element, start_link, []},
    RestartType, Shutdown, Type, [sc_element]},

  % TODO: 这里相当于是
  {ok, {SupFlags, [AChild]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
