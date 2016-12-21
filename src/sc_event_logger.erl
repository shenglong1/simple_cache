%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. 十二月 2016 11:51
%%%-------------------------------------------------------------------
-module(sc_event_logger).
-author("shenglong").
-behaviour(gen_event).

%% API
-export([add_handler/0, delete_handler/0]).

%% callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, code_change/3, terminate/2]).

-record(state, {}).

add_handler() ->
  sc_event:add_handler(?MODULE, []).

delete_handler() ->
  sc_event:delete_handler(?MODULE, []).

init([]) ->
  {ok, #state{}}.

handle_event({create, {Key, Pid, Value, Node}}, State) ->
  error_logger:info_msg("sc_event_logger:create(~w, ~w, ~w, ~w)~n", [Key, Pid, Value, Node]),
  {ok, State};
handle_event({lookup, {Key, Pid, Value, Node}}, State) ->
  error_logger:info_msg("sc_event_logger:lookup(~w, ~w, ~w, ~w)~n", [Key, Pid, Value, Node]),
  {ok, State};
handle_event({delete, {Key, Pid, Node}}, State) ->
  error_logger:info_msg("sc_event_logger:delete(~w, ~w, ~w)~n", [Key, Pid, Node]),
  {ok, State};
handle_event({replace, {Key, Pid, Value, Node}}, State) ->
  error_logger:info_msg("sc_event_logger:replace(~w, ~w, ~w, ~w)~n", [Key, Pid, Value, Node]),
  {ok, State};

handle_event({show, L}, State) when is_list(L) ->
  lists:map(fun(X) -> error_logger:info_msg("sc_event_logger:show ~p~n", X) end, L),
  {ok, State}.

handle_call(_Request, State) ->
  Reply = ok,
  {ok, Reply, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.