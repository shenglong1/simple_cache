%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. 十二月 2016 11:16
%%%-------------------------------------------------------------------
-module(sc_sup).
-author("shenglong").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
  % {ID, Start = {Mod, Fun, Args}, Restart, Shutdown, Type, Modules}
  ElementSup = {sc_element_sup, {sc_element_sup, start_link, []},
    permanent, 2000, supervisor, [sc_element]},

  EventManager = {sc_event, {sc_event, start_link, []},
    permanent, 2000, worker, [sc_event]},

  Store = {sc_store_server, {sc_store_server, start_link, []},
    permanent, 2000, worker, [sc_store_server]},

  Children = [ElementSup, EventManager, Store],
  RestartStrategy = {one_for_one, 4, 3600},
  {ok, {RestartStrategy, Children}}.