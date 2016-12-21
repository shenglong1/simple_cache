%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   维护{key, element_pid}, sc_store是pid表
%%%   分布式的mnesia表(key, pid)
%%%   本地性：仅能存储和查找本地key
%%%   sc_store只是一个方法类，用来访问本地mnesia
%%% @end
%%% Created : 14. 十二月 2016 16:10
%%%-------------------------------------------------------------------
-module(sc_store).
-author("shenglong").

-export([
  init/0,
  insert/2,
  delete/1,
  lookup/1
]).

-define(TABLE_ID, ?MODULE).
-define(WAIT_FOR_TABLES, 5000).

-record(key_to_pid, {key, pid}).

init() ->
  % ets:new(?TABLE_ID, [public, named_table]), % 建立命名表，可使用名字访问
  mnesia:stop(),
  mnesia:delete_schema([node()]),
  mnesia:start(),
  {ok, CacheNode} = resource_discovery:fetch_resources(simple_cache), % 发现所有节点
  % mnesia:create_table(key_to_pid, [{index, [pid]}, {attribute, record_info(fields, key_to_pid)}]).,
  dynamic_db_init([]), % 本节点建表
  dynamic_db_init(lists:delete(node(), CacheNode)), % 除本节点外的所有节点，执行
  ok.

insert(Key, Pid) ->
  % ets:insert(?TABLE_ID, {Key, Pid}).
  mnesia:dirty_write(#key_to_pid{key = Key, pid = Pid}).

lookup(Key) ->
  % case ets:lookup(?TABLE_ID, Key) of
  case mnesia:dirty_read(key_to_pid, Key) of
    [{key_to_pid, Key, Pid}] ->
      case is_pid_alive(Pid) of
        true -> {ok, Pid};
        false ->
          ok = mnesia:dirty_delete(key_to_pid, Key), % 清理死亡pid的表记录
          {error, not_found}
      end;
    [] ->
      % 本节点没有表
      {error, not_found}
  end.


delete(Pid) ->
  case mnesia:dirty_index_read(key_to_pid, Pid, #key_to_pid.pid) of
    [#key_to_pid{} = Record] ->
      mnesia:dirty_delete_object(Record);
    _ ->
      ok
  end.
  % ets:match_delete(?TABLE_ID, {'_', Pid}). % 按值来删

%% Internal Functions

dynamic_db_init([]) ->
  % 默认在本节点建立一个表
  mnesia:create_table(key_to_pid,
    [{index, [pid]},
      {attributes, record_info(fields, key_to_pid)}
    ]);
dynamic_db_init(OtherNodes) ->
  add_extra_nodes(OtherNodes).

add_extra_nodes([Node|T]) ->
  case mnesia:change_config(extra_db_nodes, [Node]) of % 连接无库新点
    {ok, [Node]} ->
      mnesia:add_table_copy(key_to_pid, node(), ram_copies), % 复制key_to_pid(ram_copies)表从node到Node点

      Tables = mnesia:system_info(tables), % 返回当前节点所有表
      mnesia:wait_for_tables(Tables, ?WAIT_FOR_TABLES); % 等待所有表可用
    _ ->
      add_extra_nodes(T)
  end;
add_extra_nodes([]) -> ok.

is_pid_alive(Pid) when node(Pid) =:= node() ->
  % Pid 所在节点是当前节点
  is_process_alive(Pid);
is_pid_alive(Pid) ->
  case lists:member(node(Pid), nodes()) of
    false ->
      false;
    true ->
      case rpc:call(node(Pid), erlang, is_process_alive, [Pid]) of
        true ->
          true;
        false ->
          false;
        {badrpc, _Reason} ->
          false
      end
  end.