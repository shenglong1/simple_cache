%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   使用sc_element/sc_store_server/sc_event的API，对外提供接口
%%% @end
%%% Created : 14. 十二月 2016 17:00
%%%-------------------------------------------------------------------
-module(simple_cache).
-author("shenglong").

%% API
-export([insert/2, insert/3, lookup/1, delete/1]).
-define(LEASETIME, 5).

% 在simple_cache看来，不知道element进程细节，所以所有操作都是跨进程的，
% 由element使用gen_server来协调
insert(Key, Value) ->
  insert(Key, Value, ?LEASETIME).

insert(Key, Value, LeaseTime) ->
  case sc_store_server:lookup(Key) of %% error
    {ok, Pid, Node} ->
      % update: global Pid, global element:replace
      sc_element:replace(Pid, Value),
      sc_event:replace(Key, Pid, Value, Node);
    {error, _, _} ->
      % insert: create local
      {ok, Pid} = sc_element:create(Value, LeaseTime),
      ok = sc_store_server:insert(Key, Pid),
      sc_event:create(Key, Pid, Value, node())
  end.

lookup(Key) ->
  % provide global search {Key, Pid, Value, Node}
  try
    {ok, Pid, Node} = sc_store_server:lookup(Key),
    {ok, Value} = sc_element:fetch(Pid),
    sc_event:lookup(Key, Pid, Value, Node),
    {ok, Value}
  catch
    _Class:_Exception ->
      {error, not_found}
  end.

delete(Key) ->
  % global delete and terminate Pid
  case sc_store_server:lookup(Key) of
    {ok, Pid, Node} ->
      sc_store_server:delete(Pid),
      sc_element:delete(Pid),
      sc_event:delete(Key, Pid, Node);
    {error, _Reason, _} ->
      not_found
  end.