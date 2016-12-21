%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   分布式的mnesia表管理器
%%% @end
%%% Created : 20. 十二月 2016 11:36
%%%-------------------------------------------------------------------
-module(sc_store_server).
-author("shenglong").

-behaviour(gen_server).

%% test
-export([test_insert/0,
  test_lookup/0,
  test_delete/0,
  test/0,
  info/0,
  dump_to_file/1,
  load_from_file/1]).

%% API
-export([start_link/0,
  insert/2,
  lookup/2,
  delete/2,
  delete/3,
  stop/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(WAIT_FOR_TABLES, 5000).

-record(key_to_pid, {name, pid}).
-record(user_auth, {name, code, timestamp}).
-record(friend, {name, fr_names, timestamp}). % fr_names is list

-record(single_chat, {name, other_name, chat_id}). % 同时需要添加name-other,other-name
-record(single_chat_record, {chat_id, from, to, timestamp, content}).

-record(group_chat, {name, group, group_id}).
-record(group_info, {group_id, members}).
-record(group_chat_record, {group_id, from, to, timestamp, content}).

%%%===================================================================
%%% API
%%% multi_node
%%% insert/lookup/delete 重载不同表，模式匹配检查tuple参数，构造合法的Table Tuple给_sender
%%% _sender函数不负责Table-Tuple匹配，只管发送{Handle, Table, Tuple}
%%% req: {handle_type, table, args_tuple}
%%% res:
%%% insert: ok|error,
%%% lookup: {ok, tuple}|{error, not_found}
%%% delete: {noreply, State}
%%%===================================================================
% overload insert, check Param tuple
insert(key_to_pid, #key_to_pid{} = Param) ->
  insert_sender(key_to_pid, Param);
insert(user_auth, #user_auth{} = Param) ->
  insert_sender(user_auth, Param);
insert(friend, #friend{fr_names = Frnames} = Param) when is_list(Frnames) ->
  insert_sender(friend, Param);
insert(single_chat, #single_chat{} = Param) ->
  insert_sender(single_chat, Param);
insert(single_chat_record, #single_chat_record{} = Param) ->
  insert_sender(single_chat_record, Param);
insert(group_chat, #group_chat{} = Param) ->
  insert_sender(group_chat, Param);
insert(group_info, #group_info{members = Members} = Param) when is_list(Members) ->
  insert_sender(group_info, Param);
insert(group_chat_record, #group_chat_record{} = Param) ->
  insert_sender(group_chat_record, Param).

% insert req sender
insert_sender(Table, Args) when is_tuple(Args) ->
  gen_server:call(?SERVER, {insert, Table, Args}).

% global search
lookup(key_to_pid, Key) when is_atom(Key) ->
  lookup_sender([node()|nodes()], key_to_pid, #key_to_pid{name = Key});
lookup(user_auth, Key) when is_atom(Key) ->
  lookup_sender([node()|nodes()], user_auth, #user_auth{name = Key});
lookup(friend, Key) when is_atom(Key) ->
  lookup_sender([node()|nodes()], friend, #friend{name = Key});
lookup(group_info, Key) when is_atom(Key) ->
  lookup_sender([node()|nodes()], group_info, #group_info{group_id = Key});

lookup(single_chat, #single_chat{name = _X, other_name = _Y} = Param) ->
  lookup_sender([node()|nodes()], single_chat, Param);
lookup(single_chat_record, #single_chat_record{chat_id = _X} = Param) ->
  lookup_sender([node()|nodes()], single_chat_record, Param);
lookup(group_chat, #group_chat{name = _X, group = _Y} = Param) ->
  lookup_sender([node()|nodes()], group_chat, Param);
lookup(group_chat_record, #group_chat_record{group_id = _X} = Param) ->
  lookup_sender([node()|nodes()], group_chat_record, Param).

lookup_sender([], Table, Keys) when is_tuple(Keys) ->
  % send to local
  case gen_server:call({?SERVER, node()}, {lookup, Table, Keys}) of
    {ok, Value} when is_tuple(Value) -> {ok, Value, node()};
    {error, _} -> {error, not_found, all_nodes}
  end;
lookup_sender([N|OtherNodes], Table, Keys) when is_tuple(Keys) ->
  % send to all nodes, till find one
  try gen_server:call({?SERVER, N}, {lookup, Table, Keys}) of
    {ok, Value} when is_tuple(Value) -> {ok, Value, N};
    _ -> lookup_sender(OtherNodes, Table, Keys)
  catch
    % 如果其他已连接节点没有起sc_store_server进程，则会异常
    % exit: Why -> {exit, Why};
    % throw: Why -> {thrown, Why};
    % _: Why -> {unknown, Why}
    _ : _Why -> lookup_sender(OtherNodes, Table, Keys) % 忽略noproc而异常的查询节点，继续查下去
  end.

% broadcast delete
delete(key_to_pid, Pid) ->
  delete_sender(key_to_pid, #key_to_pid{pid = Pid});
delete(user_auth, Name) ->
  delete_sender(user_auth, #user_auth{name = Name});
delete(group_info, Group_id) ->
  delete_sender(group_info, #group_info{group_id = Group_id});
delete(single_chat_record, Chat_id) ->
  delete_sender(single_chat_record, #single_chat_record{chat_id = Chat_id});
delete(group_chat_record, Group_id) ->
  delete_sender(group_chat_record, #group_chat_record{group_id = Group_id}).

delete(friend, Name, Frname) ->
  delete_sender(friend, #friend{name = Name, fr_names = [Frname]});
delete(single_chat, Name, Frname) ->
  delete_sender(single_chat, #single_chat{name = Name, other_name = Frname});
delete(group_chat, Name, Group) ->
  delete_sender(group_chat, #group_chat{name = Name, group = Group}).

delete_sender(Table, Keys) when is_tuple(Keys) ->
  gen_server:abcast([node()|nodes()], ?MODULE, {delete, Table, Keys}).

stop() ->
  gen_server:cast(?SERVER, stop).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: term()} | {ok, State :: term(), timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  % mnesia:stop(),
  % mnesia:delete_schema([node()]),
  application:set_env(mnesia, dir, './'),
  mnesia:start(),
  %% {ok, Nodes} = resource_discovery:fetch_resources(simple_cache),
  Nodes = nodes(),
    catch(mnesia:change_table_copy_type(schema, node(), disc_copies)),
  create_all_tables(),
  _Tables = mnesia:system_info(local_tables),
  % TODO: it should be checked _Tables are all tables

  dynamic_db_init(lists:delete(node(), Nodes)),
  {ok, {}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: term()) ->
  {reply, Reply :: term(), NewState :: term()} |
  {reply, Reply :: term(), NewState :: term(), timeout() | hibernate} |
  {noreply, NewState :: term()} |
  {noreply, NewState :: term(), timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
  {stop, Reason :: term(), NewState :: term()}).
% overload handle insert
handle_call({insert, Table, Tuple}, _From, State) ->
  % write to local mnesia
  case mnesia:dirty_write(Table, Tuple) of
    ok -> {reply, ok, State};
    _ -> {reply, error, State}
  end;

%% [{#table{col1='$1', col2=value, col3='$2', _='_'}, [{'>', '$2', 30}], ['$1', '$2']},
%% {other}]
%% MatchHead = #person{name='$1', sex=male, age='$2', _='_'},
%% Guard = {'>', '$2', 30},
%% Result = '$1',
%% mnesia:select(Tab,[{MatchHead, [Guard], [Result]}]).

%% mnesia:dirty_select(key_to_pid, [{#key_to_pid{name='$2', pid='$1'}, [], ['$$']}]).
%% mnesia:dirty_select(key_to_pid, [{
%%                                  #key_to_pid{name='$2', pid='$1'},
%%                                  [{'==', '$2', 'shenglong1'}],
%%                                  ['$$']
%%                                 }]).

% overload handle lookup for tuple
% lookup returns {reply, {ok, {wholeline}}, State} | {reply, {error, not_found}, State}
handle_call({lookup, key_to_pid, #key_to_pid{name = Name}}, _From, State) ->
  case mnesia:dirty_read(key_to_pid, Name) of
    [{key_to_pid, _Name, Pid}] ->
      case is_pid_alive(Pid) of
        true -> {reply, {ok, {Name, Pid}}, State};
        false ->
          mnesia:dirty_delete(key_to_pid, Name),
          {reply, {error, not_found}, State}
      end;

    [] ->
      {reply, {error, not_found}, State}
  end;
handle_call({lookup, user_auth, #user_auth{name = Name}}, _From, State) ->
  case mnesia:dirty_read(user_auth, Name) of
    [{user_auth, _Name, Code, Time}] -> {reply, {ok, {Name, Code, Time}}, State};
    [] -> {reply, {error, not_found}, State}
  end;
handle_call({lookup, friend, #friend{name = Name}}, _From, State) ->
  case mnesia:dirty_read(friend, Name) of
    [{friend, _Name, Friend_list, Time}] -> {reply, {ok, {Name, Friend_list, Time}}, State};
    [] -> {reply, {error, not_found}, State}
  end;
handle_call({lookup, group_info, #group_info{group_id = Group_id}}, _From, State) ->
  case mnesia:dirty_read(group_info, Group_id) of
    [{group_info, _Group_id, Member_list}] -> {reply, {ok, {Group_id, Member_list}}, State};
    [] -> {reply, {error, not_found}, State}
  end;

handle_call({lookup, single_chat, #single_chat{name = Name, other_name = Oname}}, _From, State) ->
  % select * from single_chat where name=Name and other_name=Oname;
  % mnesia:dirty_select(single_chat, [{ #single_chat{name='shenglong1', other_name='James', chat_id='_'}, [], ['$_']    }]).
  MatchHead = #single_chat{name = Name, other_name = Oname, chat_id = '_'},
  _Guard = {},
  Result = '$_', % return [#record{}]
  try mnesia:dirty_select(single_chat, [{MatchHead, [], [Result]}]) of
    [#single_chat{chat_id = Chat_id}] -> {reply, {ok, {Name, Oname, Chat_id}}, State};
    _ -> {reply, {error, not_found}, State}
  catch
    _: _ -> {reply, {error, not_found}, State}
  end;

handle_call({lookup, group_chat, #group_chat{name = Name, group = Group}}, _From, State) ->
  % select * from group_chat where name=Name, and group=Group;
  % mnesia:dirty_select(group_chat, [{ #group_chat{name='shenglong1', group='mygroup', group_id='_'}, [], ['$_']        }])
  MatchHead = #group_chat{name = Name, group = Group, group_id = '_'},
  _Guard = {},
  Result = '$_',
  try mnesia:dirty_select(group_chat, [{MatchHead, [], [Result]}]) of
    [#group_chat{group_id = Group_id}] -> {reply, {ok, {Name, Group, Group_id}}, State};
    _ -> {reply, {error, not_found}, State}
  catch
    _: _ -> {reply, {error, not_found}, State}
  end;

handle_call({lookup, single_chat_record, #single_chat_record{chat_id = _Cid}}, _From, State) -> {reply, {error, not_implement}, State};
handle_call({lookup, group_chat_record, #group_chat_record{group_id = _Gid}}, _From, State) -> {reply, {error, not_implement}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: term()) ->
  {noreply, NewState :: term()} |
  {noreply, NewState :: term(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: term()}).
handle_cast({delete, key_to_pid, #key_to_pid{pid = Pid}}, State) ->
  % 删除本地的Key-Pid
  try mnesia:dirty_index_read(key_to_pid, Pid, #key_to_pid.pid) of
    [#key_to_pid{} = Record] ->
      mnesia:dirty_delete_object(key_to_pid, Record),
      {noreply, State};
    _ -> {noreply, State}
  catch
    _ : _ -> {noreply, State}
  end,
  {noreply, State};
handle_cast({delete, user_auth, #user_auth{name = Name}}, State) -> ok;

handle_cast({delete, friend, #friend{name = Name, fr_names = [Frname]}}, State) -> ok;
handle_cast({delete, group_info, #group_info{group_id = Gid}}, State) -> ok;

handle_cast({delete, single_chat, #single_chat{name = Name, other_name = Oname}}, State) -> ok;
handle_cast({delete, group_chat, #group_chat{name = Name, group = Group}}, State) -> ok;
handle_cast({delete, single_chat_record, #single_chat_record{chat_id = Cid}}, State) -> ok;
handle_cast({delete, group_chat_record, #group_chat_record{group_id = Gid}}, State) -> ok;


handle_cast(stop, State) ->
  {stop, normal, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: term()) ->
  {noreply, NewState :: term()} |
  {noreply, NewState :: term(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: term()}).
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: term()) -> term()).
terminate(_Reason, _State) ->
  mnesia:stop(),
  mnesia:delete_schema([node()]),
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: term(),
    Extra :: term()) ->
  {ok, NewState :: term()} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%-record(key_to_pid, {name, pid}).
%%-record(user_auth, {name, code, timestamp}).
%%-record(friend, {name, fr_names, timestamp}). % fr_name is list
%%-record(group_info, {group_id, members}).

%%-record(single_chat, {name, other_name, chat_id}). % 同时需要添加name-other,other-name
%%-record(single_chat_record, {chat_id, from, to, timestamp, content}).
%%-record(group_chat, {name, group, group_id}).
%%-record(group_chat_record, {group_id, from, to, timestamp, content}).
create_all_tables() ->
  % set
  %% {aborted,{already_exists,key_to_pid}}
    catch(mnesia:create_table(key_to_pid,
    [
      {type, set},
      {disc_copies, [node()]},
      {index, [#key_to_pid.pid]},
      {attributes, record_info(fields, key_to_pid)}
    ])),
    catch(mnesia:create_table(user_auth,
    [
      {type, set},
      {disc_copies, [node()]},
      {attributes, record_info(fields, user_auth)}
    ])),
    catch(mnesia:create_table(friend,
    [
      {type, set},
      {disc_copies, [node()]},
      {attributes, record_info(fields, friend)}
    ])),
    catch(mnesia:create_table(group_info,
    [
      {type, set},
      {disc_copies, [node()]},
      {attributes, record_info(fields, group_info)}
    ])),
  %% bag
    catch(mnesia:create_table(single_chat,
    [
      {type, bag},
      {disc_copies, [node()]},
      {attributes, record_info(fields, single_chat)}
    ])),
    catch(mnesia:create_table(single_chat_record,
    [
      {type, bag},
      {disc_copies, [node()]},
      {attributes, record_info(fields, single_chat_record)}
    ])),
    catch(mnesia:create_table(group_chat,
    [
      {type, bag},
      {disc_copies, [node()]},
      {attributes, record_info(fields, group_chat)}
    ])),
    catch(mnesia:create_table(group_chat_record,
    [
      {type, bag},
      {disc_copies, [node()]},
      {attributes, record_info(fields, group_chat_record)}
    ])).

dynamic_db_init([]) -> ok;
dynamic_db_init(OtherNodes) ->
  add_extra_nodes(OtherNodes).

add_extra_nodes([Node|T]) ->
  case mnesia:change_config(extra_db_nodes, [Node]) of % 连接无库新点
    {ok, [Node]} ->
      lists:map(
        fun(Table) -> mnesia:add_table_copy(Table, node(), disc_copies) end,
        [key_to_pid, user_auth, friend, group_info, single_chat, single_chat_record, group_chat, group_chat_record]
      ),

      Tables = mnesia:system_info(tables), % 返回当前节点所有表
      mnesia:wait_for_tables(Tables, ?WAIT_FOR_TABLES); % 等待所有表可用
    _ ->
      add_extra_nodes(T)
  end;
add_extra_nodes([]) -> ok.

is_pid_alive(_Pid) ->
  true.
%is_pid_alive(Pid) when node(Pid) =:= node() ->
% Pid 所在节点是当前节点
%  is_process_alive(Pid);
%is_pid_alive(Pid) ->
%  case lists:member(node(Pid), nodes()) of
%    false ->
%      false;
%    true ->
%      case rpc:call(node(Pid), erlang, is_process_alive, [Pid]) of
%        true ->
%          true;
%        false ->
%          false;
%        {badrpc, _Reason} ->
%          false
%      end
%  end.

info() ->
  mnesia:info().

dump_to_file(File) ->
  mnesia:dump_to_textfile(File).
load_from_file(File) ->
  mnesia:load_textfile(File).

test_insert() ->
  insert(key_to_pid, #key_to_pid{name='shenglong1', pid = 1}),
  insert(user_auth, #user_auth{name='shenglong1', code = '123qweasd', timestamp = 1482483822}),
  insert(friend, #friend{name = 'shenglong1', fr_names = ['James'], timestamp = 1482483822}),
  insert(single_chat, #single_chat{name = 'shenglong1', other_name = 'James', chat_id = 111}),
  insert(group_chat, #group_chat{name = 'shenglong1', group = 'mygroup', group_id = 1011}),
  insert(group_info, #group_info{group_id = 1011, members = ['shenglong1', 'James']}),

  insert(single_chat_record, #single_chat_record{chat_id = 111, from = 'shenglong1', to = 'James', timestamp = 1482483822, content = 'hello world!'}),
  insert(group_chat_record, #group_chat_record{group_id = 1011, from = 'shenglong1', to = 'James', timestamp = 1482483822, content = 'group hello world!'}).

test_lookup() -> ok.
test_delete() -> ok.

test() ->
  insert(key_to_pid, #key_to_pid{name = shenglong1, pid = 11}),
  insert(key_to_pid, #key_to_pid{name = shenglong2, pid = 12}),
  insert(user_auth, #user_auth{name = shenglong1, code = 'code_here1', timestamp = 20161223}),
  insert(user_auth, #user_auth{name = shenglong2, code = 'code_here2', timestamp = 20161223}).

