%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   日志事件发送API
%%% @end
%%% Created : 15. 十二月 2016 10:44
%%%-------------------------------------------------------------------
-module(sc_event).
-author("shenglong").
-define(SERVER, ?MODULE).

%% API
-export([start_link/0,
  add_handler/2,
  delete_handler/2,
  lookup/4,
  create/4,
  replace/4,
  delete/3,
  show/1,
  info/2]).

%% API
start_link() ->
  gen_event:start_link({local, ?SERVER}).

add_handler(Handler, Args) ->
  gen_event:add_handler(?SERVER, Handler, Args).

delete_handler(Handler, Args) ->
  gen_event:delete_handler(?SERVER, Handler, Args).

%% local
create(Key, Pid, Value, Node) ->
  gen_event:notify(?SERVER, {create, {Key, Pid, Value, Node}}).

%% global
lookup(Key, Pid, Value, Node) ->
  gen_event:notify(?SERVER, {lookup, {Key, Pid, Value, Node}}).

delete(Key, Pid, Node) ->
  gen_event:notify(?SERVER, {delete, {Key, Pid, Node}}).

replace(Key, Pid, Value, Node) ->
  gen_event:notify(?SERVER, {replace, {Key, Pid, Value, Node}}).

show(L) when is_list(L) ->
  gen_event:notify(?SERVER, {show, L}).

info(Format, Msglist) when is_list(Msglist) ->
  gen_event:notify(?SERVER, {info, Format, Msglist}).











