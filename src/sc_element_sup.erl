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
-spec(start_child(Value :: integer(), LeaseTime :: integer()) ->
  {ok, Pid :: pid()} | {error, Reason :: term()}
).
start_child(Value, LeaseTime) ->
  supervisor:start_child(?SERVER, [Value, LeaseTime]).

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
  RestartStrategy = simple_one_for_one, % 仅能启动同一种子进程，但可以启动多个
  MaxRestarts = 0,
  MaxSecondsBetweenRestarts = 1,

  SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

  Restart = temporary,
  Shutdown = brutal_kill,
  Type = worker,

  % 子进程规范
  % {ID, Start = {Mod, Fun, Args}, Restart, Shutdown, Type, Modules}
  AChild = {sc_element, {sc_element, start_link, []},
    Restart, Shutdown, Type, [sc_element]},

  {ok, {SupFlags, [AChild]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
