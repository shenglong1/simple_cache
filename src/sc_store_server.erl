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
  test_clear/0,
  test_clear/1,
  timestamp/0,
  info/0,
  dump_to_file/1,
  load_from_file/1,
  list_delete/2,
  is_pid_alive/1,
  lookup_distributor/4
]).

%% API
-export([start_link/0,
  insert/3,
  lookup/2,
  lookup/3,
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

-record(key_to_pid, {name, pid, caller}).
-record(user_auth, {name, code, timestamp}).
-record(friend, {name, fr_names, timestamp}). % fr_names is list
-record(group_info, {group_id, members}).

-record(single_chat, {name, other_name, chat_id}). % 同时需要添加name-other,other-name,对应同一个chat_id
-record(group_chat, {name, group, group_id}).

% content contains bi-direct msg
% online: true/false
-record(single_chat_record, {chat_id, from, to, timestamp, online, content}).
-record(group_chat_record, {group_id, from, timestamp, online, content}).


%%%===================================================================
%%% API
%%% multi_node
%%% insert/lookup/delete 重载不同表，模式匹配检查tuple参数，构造合法的Table Tuple给_sender
%%% _sender函数不负责Table-Tuple匹配，只管发送{Handle, Table, Tuple}，负责分布式
%%% req: {handle_type, table, args_tuple}
%%% res:
%%% insert: ok|error,
%%% lookup: {ok, tuple}|{error, not_found}
%%% delete: {noreply, State}
%%%===================================================================
%% global insert
% overload insert, check Param tuple
% return: ok | error
insert(Node, key_to_pid, #key_to_pid{} = Param) ->
  insert_sender(Node, key_to_pid, Param);
insert(Node, user_auth, #user_auth{} = Param) ->
  insert_sender(Node, user_auth, Param);
insert(Node, friend, #friend{fr_names = Frnames} = Param) when is_list(Frnames) ->
  insert_sender(Node, friend, Param);
insert(Node, single_chat, #single_chat{} = Param) ->
  insert_sender(Node, single_chat, Param);
insert(Node, group_chat, #group_chat{} = Param) ->
  insert_sender(Node, group_chat, Param);
insert(Node, group_info, #group_info{members = Members} = Param) when is_list(Members) ->
  insert_sender(Node, group_info, Param);

insert(Node, single_chat_record, #single_chat_record{} = Param) ->
  insert_sender(Node, single_chat_record, Param);
insert(Node, group_chat_record, #group_chat_record{} = Param) ->
  insert_sender(Node, group_chat_record, Param).

% insert req sender
insert_sender(Node, Table, Args) when is_tuple(Args) ->
  gen_server:call({?SERVER, Node}, {insert, Table, Args}).

%% global search
% return: {ok, {wholeline}, node} | {error, not_found, all_nodes}
lookup(key_to_pid, name, Key) when is_atom(Key) ->
  lookup_sender([node()|nodes()], key_to_pid, #key_to_pid{name = Key, pid = undefined, caller = undefined});
lookup(key_to_pid, epid, Epid) when is_pid(Epid) ->
  lookup_sender([node()|nodes()], key_to_pid, #key_to_pid{name = undefined, pid = Epid, caller = undefined});
lookup(key_to_pid, caller, Caller) when is_pid(Caller) ->
  lookup_sender([node()|nodes()], key_to_pid, #key_to_pid{name = undefined, pid = undefined, caller = Caller}).

lookup(user_auth, Key) when is_atom(Key) ->
  lookup_sender([node()|nodes()], user_auth, #user_auth{name = Key});
lookup(friend, Key) when is_atom(Key) ->
  lookup_sender([node()|nodes()], friend, #friend{name = Key});
lookup(group_info, Key) when is_integer(Key) ->
  lookup_sender([node()|nodes()], group_info, #group_info{group_id = Key});

% return: {ok, wholeline, node} | {error, not_found, all_nodes}
% 接收参数为table,tuple时，当tuple需要多参数指定，但实际少给了参数，则未给定的是'undefined'，导致select结果空.
lookup(single_chat, #single_chat{name = _X, other_name = _Y} = Param) ->
  lookup_sender([node()|nodes()], single_chat, Param);
lookup(group_chat, #group_chat{name = _X, group = _Y} = Param) ->
  lookup_sender([node()|nodes()], group_chat, Param);

% return {ok, [records], node} | {error, not_found, all_nodes}
lookup(single_chat_record, #single_chat_record{chat_id = _X} = Param) ->
  lookup_sender([node()|nodes()], single_chat_record, Param);
lookup(group_chat_record, #group_chat_record{group_id = _X} = Param) ->
  lookup_sender([node()|nodes()], group_chat_record, Param);

% return: record list | []
lookup(single_chat, Name) ->
  lookup_distributor([node()|nodes()], single_chat, Name, []);
lookup(group_chat, Name) ->
  lookup_distributor([node()|nodes()], group_chat, Name, []);
lookup(single_chat_record, Cid) ->
  lookup_distributor([node()|nodes()], single_chat_record, Cid, []);
lookup(group_chat_record, Gid) ->
  lookup_distributor([node()|nodes()], group_chat_record, Gid, []).

% 集中式的sender，在一个node获取即返回
lookup_sender([], Table, Keys) when is_tuple(Keys) ->
  % send to local
  case gen_server:call({?SERVER, node()}, {lookup, Table, Keys}) of
    {ok, Value} -> {ok, Value, node()};
    {error, _} -> {error, not_found, all_nodes}
  end;
lookup_sender([N|OtherNodes], Table, Keys) when is_tuple(Keys) ->
  % send to all nodes, till find one
  try gen_server:call({?SERVER, N}, {lookup, Table, Keys}) of
    {ok, Value} -> {ok, Value, N};
    _ -> lookup_sender(OtherNodes, Table, Keys)
  catch
    % 如果其他已连接节点没有起sc_store_server进程，则会异常
    % exit: Why -> {exit, Why};
    % throw: Why -> {thrown, Why};
    % _: Why -> {unknown, Why}
    _ : _Why -> lookup_sender(OtherNodes, Table, Keys) % 忽略noproc而异常的查询节点，继续查下去
  end.

% 分布式的sender，在多个node获取才返回
% return: record list | []
lookup_distributor([Node|T], Table, Key, Res) when is_list(Res) ->
  try gen_server:call({?SERVER, Node}, {lookup, Table, Key}) of
    {ok, Record_list} -> lookup_distributor(T, Table, Key, Record_list ++ Res);
    {error, not_found} -> lookup_distributor(T, Table, Key, Res)
  catch
    _A : _B -> lookup_distributor(T, Table, Key, Res)
  end;
lookup_distributor([], _, _, Res) when is_list(Res) -> Res.


% broadcast lookup

% broadcast delete
% return: null
delete(key_to_pid, Name) when is_atom(Name) ->
  delete_sender(key_to_pid, #key_to_pid{name = Name});
delete(key_to_pid, Pid) when is_pid(Pid) ->
  delete_sender(key_to_pid, #key_to_pid{pid = Pid});

delete(user_auth, Name) ->
  delete_sender(user_auth, #user_auth{name = Name});

delete(friend, Name) ->
  % delete all friends in name
  delete_sender(friend, #friend{name = Name});

delete(group_info, Gid) ->
  % delete all members in group_id
  delete_sender(group_info, #group_info{group_id = Gid});

% TODO: not implement now
delete(single_chat_record, Cid) ->
  delete_sender(single_chat_record, #single_chat_record{chat_id = Cid});

delete(group_chat_record, Gid) ->
  delete_sender(group_chat_record, #group_chat_record{group_id = Gid}).

delete(friend, Name, Frname) ->
  % delete one friend in name
  delete_sender(friend, #friend{name = Name, fr_names = [Frname]});

delete(group_info, Gid, Member) ->
  % delete one member in group_id
  delete_sender(group_info, #group_info{group_id = Gid, members = [Member]});

delete(single_chat, Name, Frname) ->
  delete_sender(single_chat, #single_chat{name = Name, other_name = Frname});

delete(group_chat, Name, Group) ->
  % one name quit the group
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
  application:set_env(mnesia, dir, '../db'),
  mnesia:start(),
  %% {ok, Nodes} = resource_discovery:fetch_resources(simple_cache),
  _Nodes = nodes(),
    catch(mnesia:change_table_copy_type(schema, node(), disc_copies)),
  create_all_tables(),
  _Tables = mnesia:system_info(local_tables),

  % TODO: do not connect all node, need no synchronize
  % dynamic_db_init(lists:delete(node(), Nodes)),
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
handle_call({lookup, key_to_pid, #key_to_pid{} = Record}, _From, State) ->
  case Record of
    #key_to_pid{name = Name, pid = undefined, caller = undefined} ->
      case mnesia:dirty_read(key_to_pid, Name) of
        [#key_to_pid{name = Name_r, pid = Pid_r, caller = Caller_r}] ->
          {reply, {ok, {Name_r, Pid_r, Caller_r}}, State};
        [] ->
          {reply, {error, not_found}, State}
      end;

    #key_to_pid{name = undefined, pid = Epid, caller = undefined} ->
      case mnesia:dirty_index_read(key_to_pid, Epid, #key_to_pid.pid) of
        [#key_to_pid{name = Name_r, pid = Pid_r, caller = Caller_r}] ->
          {reply, {ok, {Name_r, Pid_r, Caller_r}}, State};
        [] ->
          {reply, {error, not_found}, State}
      end;

    #key_to_pid{name = undefined, pid = undefined, caller = Caller} ->
      case mnesia:dirty_index_read(key_to_pid, Caller, #key_to_pid.caller) of
        [#key_to_pid{name = Name_r, pid = Pid_r, caller = Caller_r}] ->
          {reply, {ok, {Name_r, Pid_r, Caller_r}}, State};
        [] ->
          {reply, {error, not_found}, State}
      end
  end;

handle_call({lookup, user_auth, #user_auth{name = Name}}, _From, State) ->
  case mnesia:dirty_read(user_auth, Name) of
    [#user_auth{code = Code, timestamp = Time}] ->
      {reply, {ok, {Name, Code, Time}}, State};
    [] ->
      {reply, {error, not_found}, State}
  end;
handle_call({lookup, friend, #friend{name = Name}}, _From, State) ->
  case mnesia:dirty_read(friend, Name) of
    [#friend{fr_names = Friend_list, timestamp = Time}] -> {reply, {ok, {Name, Friend_list, Time}}, State};
    [] -> {reply, {error, not_found}, State}
  end;
handle_call({lookup, group_info, #group_info{group_id = Group_id}}, _From, State) ->
  case mnesia:dirty_read(group_info, Group_id) of
    [#group_info{members = Member_list}] -> {reply, {ok, {Group_id, Member_list}}, State};
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

handle_call({lookup, single_chat_record, #single_chat_record{chat_id = Cid}}, _From, State) ->
  try mnesia:dirty_read(single_chat_record, Cid) of
    [] -> {reply, {error, not_found}, State};
    Record_list -> {reply, {ok, Record_list}, State}
  catch
    _ : _ -> {reply, {error, not_found}, State}
  end;
handle_call({lookup, group_chat_record, #group_chat_record{group_id = Gid}}, _From, State) ->
  try mnesia:dirty_read(group_chat_record, Gid) of
    [] -> {reply, {error, not_found}, State};
    Record_list -> {reply, {ok, Record_list}, State}
  catch
    _ : _ -> {reply, {error, not_found}, State}
  end;

% query by primary key
handle_call({lookup, Table, Key}, _From, State) ->
  try mnesia:dirty_read(Table, Key) of
    [] -> {reply, {error, not_found}, State};
    Record_list -> {reply, {ok, Record_list}, State}
  catch
    _ : _ -> {reply, {error, not_found}, State}
  end.

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

handle_cast({delete, key_to_pid, #key_to_pid{name = Name, pid = Pid}}, State) ->
  % try to delete by name or pid
  try mnesia:dirty_read(key_to_pid, Name) of
    [#key_to_pid{} = Record] ->
      mnesia:dirty_delete_object(key_to_pid, Record),
      {noreply, State};
    [] ->
      case mnesia:dirty_index_read(key_to_pid, Pid, #key_to_pid.pid) of
        [#key_to_pid{} = Record] ->
          mnesia:dirty_delete_object(key_to_pid, Record),
          {noreply, State};
        _ -> {noreply, State}
      end
  catch
    _ : _ -> {noreply, State}
  end;

handle_cast({delete, user_auth, #user_auth{name = Name}}, State) ->
  try mnesia:dirty_delete(user_auth, Name) of
    _ -> {noreply, State}
  catch
    _ : _ -> {noreply, State}
  end;

handle_cast({delete, friend, #friend{name = Name, fr_names = Fr_names}}, State) ->
  case Fr_names of
    [_Names] ->
      case mnesia:dirty_read(friend, Name) of
        [#friend{name = Name_ret, fr_names = Fr_names_ret}] when is_list(Fr_names_ret) ->
          Names_left = list_delete(Fr_names, Fr_names_ret),
            catch(mnesia:dirty_write(friend, #friend{name = Name_ret, fr_names = Names_left, timestamp = timestamp()})),
          {noreply, State};
        _ -> {noreply, State}
      end;
    _ ->
      mnesia:dirty_delete(friend, Name),
      {noreply, State}
  end;

handle_cast({delete, group_info, #group_info{group_id = Gid, members = Members}}, State) ->
  case Members of
    [_Members] ->
      case mnesia:dirty_read(group_info, Gid) of
        [#group_info{group_id = Gid_ret, members = Members_ret}] ->
          Members_left = list_delete(Members, Members_ret),
            catch(mnesia:dirty_write(group_info, #group_info{group_id = Gid_ret, members = Members_left})),
          {noreply, State};
        _ -> {noreply, State}
      end;
    _ ->
      mnesia:dirty_delete(group_info, Gid),
      {noreply, State}
  end;

handle_cast({delete, single_chat, #single_chat{name = Name, other_name = Oname}}, State) ->
  Check =
    fun(R) when is_record(R, single_chat) ->
      try
        #single_chat{name = Name_tmp, other_name = Oname_tmp} = R,
        case (Name_tmp == Name) and (Oname_tmp == Oname) of
          true -> true;
          false -> false
        end
      catch
        _ : _ -> false
      end
    end,
  Delete_one_record =
    fun(R) when is_record(R, single_chat) ->
        catch(mnesia:dirty_delete_object(single_chat, R))
    end,
  try
    Records = mnesia:dirty_read(single_chat, Name),
    Targets = lists:filter(Check, Records),
    lists:foreach(Delete_one_record, Targets),
    {noreply, State}
  catch
    _ : _ -> {noreply, State}
  end;

handle_cast({delete, group_chat, #group_chat{name = Name, group = Group}}, State) ->
  Check =
    fun(R) when is_record(R, group_chat) ->
      try
        #group_chat{name = Name_tmp, group = Group_tmp} = R,
        case (Name_tmp == Name) and (Group_tmp == Group) of
          true -> true;
          false -> false
        end
      catch
        _ : _ -> false
      end
    end,
  Delete_one_record =
    fun(R) when is_record(R, group_chat) ->
      mnesia:dirty_delete_object(group_chat, R)
    end,
  try
    Records = mnesia:dirty_read(group_chat, Name),
    Targets = lists:filter(Check, Records),
    lists:foreach(Delete_one_record, Targets),
    {noreply, State}
  catch
    _ : _ -> {noreply, State}
  end;

handle_cast({delete, single_chat_record, #single_chat_record{chat_id = Cid}}, State) ->
  try mnesia:dirty_read(single_chat_record, Cid) of
    [] -> {noreply, State};
    Record_list ->
      lists:map(fun(R) when is_record(R, single_chat_record) -> mnesia:dirty_delete_object(single_chat_record, R) end, Record_list),
      {noreply, State}
  catch
    _ : _ -> {noreply, State}
  end;

handle_cast({delete, group_chat_record, #group_chat_record{group_id = Gid}}, State) ->
  try mnesia:dirty_read(group_chat_record, Gid) of
    [] -> {noreply, State};
    Record_list ->
      lists:map(fun(R) when is_record(R, group_chat_record) -> mnesia:dirty_delete_object(group_chat_record, R) end, Record_list),
      {noreply, State}
  catch
    _ : _ -> {noreply, State}
  end;



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
      {index, [#key_to_pid.pid, #key_to_pid.caller]},
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
      {index, [#single_chat.other_name]},
      {disc_copies, [node()]},
      {attributes, record_info(fields, single_chat)}
    ])),
    catch(mnesia:create_table(single_chat_record,
    [
      {type, bag},
      {index, [#single_chat_record.from, #single_chat_record.to]},
      {disc_copies, [node()]},
      {attributes, record_info(fields, single_chat_record)}
    ])),
    catch(mnesia:create_table(group_chat,
    [
      {type, bag},
      {index, [#group_chat.group]},
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
  case mnesia:change_config(extra_db_nodes, [Node]) of % connect db on Node
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

is_pid_alive(Pid) when node(Pid) =:= node() ->
  %Pid 所在节点是当前节点
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

% delete [Del|H] from From list
list_delete([], From) when is_list(From) -> From;
list_delete([Del|H], From) ->
  list_delete(H, lists:delete(Del, From)).

% get unix time
timestamp() ->
  {M, S, _} = erlang:now(),
  M * 1000000 + S.

info() ->
  mnesia:info().

dump_to_file(File) ->
  mnesia:dump_to_textfile(File).
load_from_file(File) ->
  mnesia:load_textfile(File).

test_insert() ->
  insert(node(), key_to_pid, #key_to_pid{name='shenglong1', pid = 1, caller = 1}),
  insert(node(), key_to_pid, #key_to_pid{name='shenglong11', pid = 2, caller = 2}),

  insert(node(), user_auth, #user_auth{name='shenglong1', code = '123qweasd', timestamp = timestamp()}),
  insert(node(), user_auth, #user_auth{name='Allen', code = '123qweasd', timestamp = timestamp()}),
  insert(node(), user_auth, #user_auth{name='Bale', code = '123qweasd', timestamp = timestamp()}),
  insert(node(), user_auth, #user_auth{name='James', code = '123qweasd', timestamp = timestamp()}),

  insert(node(), friend, #friend{name = 'shenglong1', fr_names = ['James', 'Allen', 'Bale'], timestamp = timestamp()}),
  insert(node(), friend, #friend{name = 'Allen', fr_names = ['James', 'Allen', 'Bale'], timestamp = timestamp()}),
  insert(node(), friend, #friend{name = 'Bale', fr_names = ['James', 'Allen', 'Bale'], timestamp = timestamp()}),

  insert(node(), single_chat, #single_chat{name = 'shenglong1', other_name = 'James', chat_id = 111}),
  insert(node(), single_chat, #single_chat{name = 'shenglong1', other_name = 'Allen', chat_id = 112}),
  insert(node(), single_chat, #single_chat{name = 'shenglong1', other_name = 'Bale', chat_id = 113}),

  insert(node(), group_chat, #group_chat{name = 'shenglong1', group = 'mygroup', group_id = 1011}),

  insert(node(), group_info, #group_info{group_id = 1011, members = ['shenglong1', 'James', 'Allen', 'Bale']}),
  insert(node(), group_info, #group_info{group_id = 1012, members = ['shenglong1', 'Bale']}),

  insert(node(), single_chat_record, #single_chat_record{chat_id = 111, from = 'shenglong1', to = 'James', timestamp = timestamp(), online=false, content = 'hello world!'}),
  insert(node(), single_chat_record, #single_chat_record{chat_id = 111, from = 'James', to = 'shenglong', timestamp = timestamp(), online=false, content = 'received hello world, hello shenglong1'}),

  insert(node(), group_chat_record, #group_chat_record{group_id = 1011, from = 'shenglong1', timestamp = timestamp(), online = false, content = 'aaaaaaaaaaa'}),
  insert(node(), group_chat_record, #group_chat_record{group_id = 1011, from = 'James', timestamp = timestamp(), online = false, content = 'bbbbbbbbbbb'}),
  insert(node(), group_chat_record, #group_chat_record{group_id = 1011, from = 'Bale', timestamp = timestamp(), online = false, content = 'ccccccccccc'}),
  insert(node(), group_chat_record, #group_chat_record{group_id = 1011, from = 'Allen', timestamp = timestamp(), online = false, content = 'ddddddddddd'}),
  insert(node(), group_chat_record, #group_chat_record{group_id = 1011, from = 'shenglong1', timestamp = timestamp(), online = false, content = 'eeeeeeeeeee'}).

test_lookup() ->
  io:format("~p~n", [lookup(key_to_pid, name, shenglong1)]),
  io:format("~p~n", [lookup(key_to_pid, name, shenglong2)]),

  io:format("~p~n", [lookup(user_auth, shenglong1)]),
  io:format("~p~n", [lookup(user_auth, shenglong2)]),

  io:format("~p~n", [lookup(friend, shenglong1)]),
  io:format("~p~n", [lookup(friend, shenglong2)]),

  io:format("~p~n", [lookup(group_info, 1011)]),
  io:format("~p~n", [lookup(group_info, 1012)]),


  io:format("~p~n", [lookup(single_chat, #single_chat{name = 'shenglong1', other_name = 'James'})]),
  io:format("~p~n", [lookup(single_chat, #single_chat{name = 'shenglong2', other_name = 'Allen'})]),
  io:format("~p~n", [lookup(single_chat, #single_chat{name = 'shenglong1'})]),

  io:format("~p~n", [lookup(group_chat, #group_chat{name = 'shenglong1', group = 'mygroup'})]),
  io:format("~p~n", [lookup(group_chat, #group_chat{name = 'shenglong1'})]),
  io:format("~p~n", [lookup(group_chat, #group_chat{name = 'shenglong2', group = 'mygroup'})]),

  io:format("~n~p~n", [lookup(single_chat_record, #single_chat_record{chat_id = 111})]),
  io:format("~n~p~n", [lookup(group_chat_record, #group_chat_record{group_id = 1011})]).

test_delete() ->
  delete(key_to_pid, 'shenglong1'),
  delete(key_to_pid, 2),
  delete(user_auth, 'shenglong1'),
  delete(user_auth, 'shenglong2'),
  delete(friend, 'shenglong1'),
  delete(friend, 'Allen', 'Allen'),
  delete(group_info, 1011),
  delete(group_info, 1012, 'Bale'),
  delete(single_chat, 'shenglong1', 'James'),
  delete(single_chat, 'shenglong1', 'Allen'),
  delete(group_chat, 'shenglong1', 'mygroup'),

  delete(single_chat_record, 111), % error
  delete(group_chat_record, 1011).

test() ->
  insert(node(), key_to_pid, #key_to_pid{name = shenglong1, pid = 11, caller = 11}),
  insert(node(), key_to_pid, #key_to_pid{name = shenglong2, pid = 12, caller = 12}),
  insert(node(), user_auth, #user_auth{name = shenglong1, code = 'code_here1', timestamp = 20161223}),
  insert(node(), user_auth, #user_auth{name = shenglong2, code = 'code_here2', timestamp = 20161223}).

test_clear() ->
  lists:foreach(fun(X) -> mnesia:clear_table(X) end,
    [key_to_pid, user_auth, friend, group_info, single_chat, single_chat_record, group_chat, group_chat_record]).

test_clear(Table) ->
  mnesia:clear_table(Table).


