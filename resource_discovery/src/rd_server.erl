-module(rd_server).

-behaviour(gen_server).

-export([
  start_link/0,
  add_target_resource_type/1,
  add_local_resource/2,
  fetch_resources/1,
  trade_resources/0,
  show_local/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {target_resource_types, % 需要的资源 [type]
  local_resource_tuples, % 本地提供的资源 type resource, dict = {Key, [Value]}
  found_resource_tuples}). % 从外部获取到的资源 type resource, dict = {Key, [Value]}
%% 说明: tuple 的数据结构是{key:value} = {Type:[Resource]} = Dict

% -record(tables, {target_table, local_table, found_table}).

%% API

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

fetch_resources(Type) ->
  % 获取当前接地点的found_resource_tuple
  gen_server:call(?SERVER, {fetch_resources, Type}).

add_target_resource_type(Type) ->
  % 向本地节点中增加target_resource
  gen_server:cast(?SERVER, {add_target_resource_type, Type}).

add_local_resource(Type, Resource) ->
  % 增加到local_resource
  gen_server:cast(?SERVER, {add_local_resource, {Type, Resource}}).

trade_resources() ->
  % 将本地的local_resource同步到所有节点的found_resource
  gen_server:cast(?SERVER, trade_resources).

show_local() ->
  % 显示所有资源
  % 将tables中的所有内容写入ets表
  % -record(tables, {target_table, local_table, found_table}).
  gen_server:cast({?SERVER, node()}, show).

%% Callbacks

init([]) ->
  {ok, #state{target_resource_types = [],
    local_resource_tuples = dict:new(),
    found_resource_tuples = dict:new()}}.

% -spec(
% handle_call(Cmd :: {fetch_resources, Type::term()}, From::{pid(), Tag::term()}, State::term()) ->
%   {reply, Value::term(), State::term}
% ).

handle_call({fetch_resources, Type}, _From, State) ->
  % 按照type来获取found_resource_tuples
  % {reply, {ok, [Value]}, State}
  {reply, dict:find(Type, State#state.found_resource_tuples), State}.

handle_cast({add_target_resource_type, Type}, State) ->
  % 删除并重新插入
  % {noreply, State}
  TargetTypes = State#state.target_resource_types,
  NewTargetTypes = [Type | lists:delete(Type, TargetTypes)],
  {noreply, State#state{target_resource_types = NewTargetTypes}};

handle_cast({add_local_resource, {Type, Resource}}, State) ->
  % {noreply, State}
  ResourceTuples = State#state.local_resource_tuples,
  NewResourceTuples = add_resource(Type, Resource, ResourceTuples),
  {noreply, State#state{local_resource_tuples = NewResourceTuples}};

handle_cast(trade_resources, State) ->
  % 向所有节点发送trade_resources命令，并带上本地提供的资源
  ResourceTuples = State#state.local_resource_tuples,
  AllNodes = [node() | nodes()],
  lists:foreach(
    fun(Node) ->
      gen_server:cast({?SERVER, Node},
        {trade_resources, {node(), ResourceTuples}})
    end,
    AllNodes),
  {noreply, State};

handle_cast({trade_resources, {ReplyTo, Remotes}},
    #state{local_resource_tuples = Locals,
      target_resource_types = TargetTypes,
      found_resource_tuples = OldFound} = State) ->
  % 在Remotes中找到我所需要的TargetTypes
  FilteredRemotes = resources_for_types(TargetTypes, Remotes), % ret:[{type, resource}, {type, resource}]
  NewFound = add_resources(FilteredRemotes, OldFound),
  case ReplyTo of
    noreply ->
      ok;
    _ ->
      gen_server:cast({?SERVER, ReplyTo},
        {trade_resources, {noreply, Locals}})
  end,
  {noreply, State#state{found_resource_tuples = NewFound}};

handle_cast(show, State) ->
  % 新建ets并写入
  {noreply, State}.

handle_info(ok = _Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%% Utilities
add_resources([{Type, Identifier}|T], Dict) ->
  add_resources(T, add_resource(Type, Identifier, Dict));
add_resources([], Dict) ->
  Dict.

add_resource(Type, Resource, Dict) ->
  % Resource::term(), Dict::dict()
  case dict:find(Type, Dict) of
    {ok, ResourceList} ->
      NewList = [Resource | lists:delete(Resource, ResourceList)],
      dict:store(Type, NewList, Dict);
    error ->
      dict:store(Type, [Resource], Dict)
  end.

resources_for_types(Types, ResourceTuples) ->
  % Types: 本地TargetTypes
  % ResourceTuples: 外部节点提供的Resource
  % ret: [{type, resource}, {type, resource}]
  Fun =
    fun(Type, Acc) ->
      case dict:find(Type, ResourceTuples) of
        {ok, List} ->
          [{Type, Resource} || Resource <- List] ++ Acc;
        error ->
          Acc
      end
    end,
  % foldl(Fun, Acc0, List) -> Acc1
  lists:foldl(Fun, [], Types). % 返回所有从ResourceTuples获得的Types资源