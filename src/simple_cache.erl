%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%   使用sc_element/sc_store_server/sc_event的API，
%%%   对外提供业务接口，例如
%%%     login，signin，signout,
%%%     sendmsg, broadcast,
%%%     add_fr, del_fr, lookupfr
%%% @end
%%% Created : 14. 十二月 2016 17:00
%%%-------------------------------------------------------------------
-module(simple_cache).
-author("shenglong").

-define(LEASETIME, 5).

%% API for time lease
-export([insert/2, insert/3, lookup/1, delete/1]).

%% API for IM
-export([
  login/2,
  is_logined/1,
  sign_in/2,
  sign_out/1,
  friends_lookup/1,
  is_friend/2,
  friend_add/2,
  friend_add_impl/2,
  friend_del/2,
  friend_del_impl/2,
  id_generate/2,
  id_generate2/1,
  my_element_pid/0,
  send_msg/2,
  broadcast/2,
  broadcast_impl/4,
  in_group/2,
  create_group/1,
  destroy_group/1,
  join_group/1,
  quit_group/1,
  update_element_pid/0,
  get_offline_msgs/1
]).

-record(key_to_pid, {name, pid}). %　在线用户列表
-record(user_auth, {name, code, timestamp}). % 所有用户列表
-record(friend, {name, fr_names, timestamp}). % fr_names is list
-record(group_info, {group_id, group_name, members}).

% chat_id 是临时的，首次发起会话时建立
-record(single_chat, {name, other_name, chat_id}). % 同时需要添加name-other,other-name
% group_id是固定的，在create_group是建立
-record(group_chat, {name, group, group_id}).

-record(single_chat_record, {chat_id, from, to, timestamp, online, content}).
-record(group_chat_record, {group_id, from, timestamp, online, content}).

%% API for time lease,
%% insert/lookup/delete 使用element维护Name/LeaseTime的接口
% 在simple_cache看来，不知道element进程细节，所以所有操作都是跨进程的，
% 由element使用gen_server来协调
insert(Key, Value) ->
  insert(Key, Value, ?LEASETIME).

insert(Key, Value, LeaseTime) ->
  case sc_store_server:lookup(key_to_pid, name, Key) of
    {ok, {_, Pid}, Node} ->
      % update: global Pid, global element:replace
      sc_element:replace(Pid, Value),
      sc_event:replace(Key, Pid, Value, Node);
    {error, _, _} ->
      % insert: create local
      {ok, Pid} = sc_element:create(Value, LeaseTime),
      ok = sc_store_server:insert(node(), key_to_pid, #key_to_pid{name = Key, pid = Pid}),
      sc_event:create(Key, Pid, Value, node())
  end.

lookup(Key) ->
  % provide global search {Key, Pid, Value, Node}
  try
    {ok, {_, Pid}, Node} = sc_store_server:lookup(key_to_pid, name, Key),
    {ok, Value} = sc_element:fetch(Pid),
    sc_event:lookup(Key, Pid, Value, Node),
    {ok, Value}
  catch
    _Class:_Exception ->
      {error, not_found}
  end.

delete(Key) ->
  % global delete and terminate Pid
  case sc_store_server:lookup(key_to_pid, name, Key) of
    {ok, {_, Pid}, Node} ->
      sc_store_server:delete(key_to_pid, Key),
      sc_element:delete(Pid),
      sc_event:delete(Key, Pid, Node);
    {error, _Reason, _} ->
      not_found
  end.

%% API for IM
% return {ok, Reason} | {error, Reason}
login(User, Passwd) ->
  % 新用户注册
  case sc_store_server:lookup(user_auth, User) of
    {ok, _, _} ->
      {ok, already_login};
    {error, _, _} ->
      ok = sc_store_server:insert(node(), user_auth, #user_auth{name = User, code = Passwd, timestamp = sc_store_server:timestamp()}),
      {ok, login}
  end.

is_logined(User) ->
  case sc_store_server:lookup(user_auth, User) of
    {ok, _, _} -> true;
    {error, _, _} -> false
  end.

% TODO: need test, get Name's all offline msgs
get_offline_msgs(Name) ->
  % return [Records] | []
  Query_by_cid =
    fun(Cid, User) ->
      case sc_store_server:lookup(single_chat_record, Cid) of
        [] -> [];
        Records ->
          lists:foreach(
            fun(R) ->
              case R#single_chat_record.to =:= User of
                true -> R;
                false -> []
              end
            end, Records)
      end
    end,

  case sc_store_server:lookup(single_chat, Name) of
    [] ->
      [];
    Records ->
      case lists:foreach(fun(R) -> #single_chat{chat_id = Cid} = R, Cid end, Records) of
        [] -> [];
        Cid_list ->
          % return: [[Records], [Records]]
          lists:foreach(fun(X) -> Query_by_cid(X, Name) end, Cid_list)
      end
  end.

sign_in(User, Passwd) ->
  % 登录
  % 在哪儿登录，key_to_pid就记在哪个节点
  case sc_store_server:lookup(user_auth, User) of
    {ok, {_, Code, _}, _} ->
      case sc_store_server:lookup(key_to_pid, name, User) of
        {ok, {_, Pid}, _} ->

          case rpc:call(node(Pid), erlang, is_process_alive, [Pid]) of
            true ->
              {ok, already_running};
            false ->
              % after abnormal reboot
              case Code == Passwd of
                true ->
                  % TODO: 这里有两次修复key_to_pid登录数据，create中和sign_in中
                  % sign_in按照user修整条记录
                  {ok, New_pid} = sc_element:create(User, 3600), % TODO: element live 1 hour for test
                  ok = sc_store_server:insert(node(), key_to_pid, #key_to_pid{name = User, pid = New_pid}),
                  erlang:put(name, User),

                  {ok, sign_in_after_abnormal_reboot};
                false ->
                  {error, passwd_err}
              end
          end;

        {error, _, _} ->
          % key_to_pid没有记录，是首次登陆
          % 先检查密码
          case Code == Passwd of
            true ->
              % simple_cache和element互相持有对方pid
              % error
              {ok, Pid} = sc_element:create(User, 3600), % TODO: element live 1 hour for test
              ok = sc_store_server:insert(node(), key_to_pid, #key_to_pid{name = User, pid = Pid}),
              erlang:put(name, User),

              {ok, sign_in};
            false ->
              {error, passwd_err}
          end
      end;
    {error, _, _} ->
      {error, need_login_first}
  end.

sign_out(User) ->
  % bug: 可以异地sign_out，且没有任何验证
  case sc_store_server:lookup(user_auth, User) of
    {ok, _, _} ->
      case sc_store_server:lookup(key_to_pid, name, User) of
        {ok, {Name, Pid}, _} ->

          sc_element:delete(Pid),
          sc_store_server:delete(key_to_pid, Name),
          erlang:erase(name),
          {ok, sign_out};
        {error, _, _} ->
          {ok, already_sign_out}
      end;
    {error, _, _} ->
      {error, need_login_first}
  end.

client_running(User) ->
  try
    case sc_store_server:lookup(user_auth, User) of
      {ok, _, _} ->
        case sc_store_server:lookup(key_to_pid, name, User) of
          {ok, {_, Pid}, _} -> rpc:call(node(Pid), erlang, is_process_alive, [Pid]);
          {error, _, _} -> false
        end;
      {error, _, _} -> false
    end
  catch
    _ : _ -> false
  end.

% return [names] | {error, Reason}
friends_lookup(User) ->
  case client_running(User) of
    true ->
      case sc_store_server:lookup(friend, User) of
        {ok, {_Name, Frnames, _Time}, _} -> Frnames;
        {error, _, _} -> {error, not_found}
      end;
    false -> {error, client_not_running}
  end.

% return: true | false
% 双向查询
is_friend(User, Frname) ->
  case sc_store_server:lookup(friend, User) of
    {ok, {_, Frnames1, _}, _} ->
      lists:member(Frname, Frnames1);
    {error, _, _} ->
      case sc_store_server:lookup(friend, Frname) of
        {ok, {_, Frnames2, _}, _} ->
          lists:member(User, Frnames2);
        {error, _, _} ->
          false
      end
  end.

% return: {ok, Reason} | {error, Reason}
% 双向添加好友
% 已有friend的登记的User，它在哪个node，其所有好友就被添加到这个node.friend.User名下
friend_add(User, Frname) ->
  try
    ok = friend_add_impl(User, Frname),
    ok = friend_add_impl(Frname, User),
    {ok, normal}
  catch
    _ : _ -> {error, unknown}
  end.

% 单向添加好友
% return: ok | error
friend_add_impl(User, Frname) ->
  case is_logined(User) and is_logined(Frname) of
    true ->
      case sc_store_server:lookup(friend, User) of
        %% TODO：会造成数据不一致：node1读到，但本节点是node2写入
        {ok, {_, Frname_list, _}, Node} ->
          sc_store_server:insert(Node, friend,
            #friend{name = User,
              fr_names = (lists:delete(Frname, Frname_list) ++ [Frname]),
              timestamp = sc_store_server:timestamp()});
        {error, _, _} ->
          sc_store_server:insert(node(), friend, #friend{name = User, fr_names = [Frname], timestamp = sc_store_server:timestamp()})
      end;
    false ->
      error
  end.

% return: {ok, Reason} | {error, Reason}
friend_del(User, Frname) ->
  try
    ok = friend_del_impl(User, Frname),
    ok = friend_del_impl(Frname, User),
    {ok, normal}
  catch
    _ : _ -> {error, unknown}
  end.

% return: ok | error
friend_del_impl(User, Frname) ->
  case is_logined(User) and is_logined(Frname) of
    true ->
      sc_store_server:delete(friend, User, Frname),
      ok;
    false -> error
  end.

% Ref_table: single_chat_record | group_chat_record
id_generate(N, Ref_table) ->
  % TODO: auto generate id
  Id = random:uniform(N),
  case sc_store_server:lookup(Ref_table, Id) of
    [] -> Id;
    _ -> id_generate(N, Ref_table)
  end.

% 获取当前element进程Pid对应的Name
% return: Name | undefined
my_element_pid() ->
  % ele_pid -> ele_name
  % 所有element Name-Pid 信息必然存在本地
  try
    [#key_to_pid{pid = Pid}] = mnesia:dirty_read(key_to_pid, erlang:get(name)),
    Pid
  catch
    _ : _ -> undefined
  end.

% TODO: 目前只能发送给在线用户
% return: {ok, Reason} | {error, Reason}
send_msg(Name, Msg) ->
  % send from My_name to Name
  My_name = erlang:get(name),
  case is_logined(My_name) and is_logined(Name) and is_friend(My_name, Name) of
    true ->

      % construct chat connection
      % return {Cid, Node}
      Build_chat_id =
        fun(From, To) ->
          case sc_store_server:lookup(single_chat, #single_chat{name = From, other_name = To}) of
            {ok, {_, _, Cid}, Node} ->
              {Cid, Node};
            {error, _, _} ->
              Cid = id_generate(10000, single_chat_record),
              sc_store_server:insert(node(), single_chat, #single_chat{name = From, other_name = To, chat_id = Cid}),
              sc_store_server:insert(node(), single_chat, #single_chat{name = To, other_name = From, chat_id = Cid}),
              {Cid, node()}
          end
        end,

      % TODO: 无论在线离线，只要两人开启聊天就产生一个chat_id
      case client_running(Name) of
        true ->
          % online msg
          {ok, {_, Pid}, _} = sc_store_server:lookup(key_to_pid, name, Name),
          sc_element:send_msg(Pid, {My_name, Name, Msg}, my_element_pid()),

          % TODO: save record and build chat connection
          % write record to node where chat_id was written
          % 新增的record始终和其chat_id记录在同一个node
          {Cid, Node} = Build_chat_id(My_name, Name),
          sc_store_server:insert(Node, single_chat_record,
            #single_chat_record{
              chat_id = Cid,
              from = My_name,
              to = Name,
              timestamp = sc_store_server:timestamp(),
              online = true,
              content = Msg
            }),
          {ok, normal};

        false ->
          % TODO: offline msg, 离线消息会保存到single_chat_record中
          % TODO: save record and build chat connection
          {Cid, Node} = Build_chat_id(My_name, Name),
          sc_store_server:insert(Node, single_chat_record,
            #single_chat_record{
              chat_id = Cid,
              from = My_name,
              to = Name,
              timestamp = sc_store_server:timestamp(),
              online = false,
              content = Msg
            }),
          {ok, normal}
      end;

    false ->
      {error, not_login_or_not_friend}
  end.

% return: {ok, Reason} | {error, Reason}
broadcast(Group, Msg) ->
  % find Gid and Members
  My_name = erlang:get(name),
  case sc_store_server:lookup(group_chat, #group_chat{name = My_name, group = Group}) of
    {ok, {_, _, Gid}, _} ->

      case sc_store_server:lookup(group_info, gid, Gid) of
        {ok, {_, _, Members}, Node} ->
          lists:map(fun(X) -> broadcast_impl(X, Msg, Gid, Node) end, lists:delete(My_name, Members)),
          {ok, normal};
        {error, _, _} ->
          {error, members_not_found}
      end;

    {error, _, _} ->
      {error, not_in_group}
  end.

% TODO: 这个send_msg在线方式不变，发送到Name; 而离线发送时保存到group_chat_record中；
broadcast_impl(Name, Msg, Gid, Node) ->
  % broadcast 模式下的 一对一发送
  % send from My_name to Name
  My_name = erlang:get(name),
  case is_logined(My_name) and is_logined(Name) of
    true ->

      case client_running(Name) of
        true ->
          % online msg
          {ok, {_, Pid}, _} = sc_store_server:lookup(key_to_pid, name, Name),
          sc_element:send_msg(Pid, {My_name, Name, Msg}, my_element_pid()),
          % TODO: msg还需要保存到mnesia中
          sc_store_server:insert(Node, group_chat_record,
            #group_chat_record{
              group_id = Gid,
              from = My_name,
              timestamp = sc_store_server:timestamp(),
              online = true,
              content = Msg
            });
        false ->
          % TODO: offline msg, 离线消息会保存到single_chat_record中
          sc_store_server:insert(Node, group_chat_record,
            #group_chat_record{
              group_id = Gid,
              from = My_name,
              timestamp = sc_store_server:timestamp(),
              online = false,
              content = Msg
            })
      end;

    false ->
      {error, not_login}
  end.

id_generate2(N) ->
  % TODO: auto generate id
  Id = random:uniform(N),
  case sc_store_server:lookup(group_info, gid, Id) of
    {error, _, _} -> Id;
    _ -> id_generate2(N)
  end.

% TODO: 还需要有group相关操作，例如加入组，退出组，解散组
create_group(Group) ->
  % 建组时必须建立group_id
  case is_logined(erlang:get(name)) andalso client_running(erlang:get(name)) of
    false ->
      {error, not_login_or_not_running};
    true ->
      case sc_store_server:lookup(group_info, group, Group) of
        {ok, _, _} -> {error, group_already_exist};
        {error, _, _} ->

          % create a new group
          Id = id_generate2(1000),
          sc_store_server:insert(node(), group_chat, #group_chat{name = erlang:get(name), group = Group, group_id = Id}),
          sc_store_server:insert(node(), group_info, #group_info{group_id = Id, group_name = Group, members = [erlang:get(name)]})
      end
  end.

in_group(Name, Group) ->
  case sc_store_server:lookup(group_chat, #group_chat{name = Name, group = Group}) of
    {ok, {_, _, _}, _} -> true;
    {error, _, _} -> false
  end.

% TODO: complicated
destroy_group(Group) ->
  % clear group_chat and group_info when no one use
  case is_logined(erlang:get(name)) andalso client_running(erlang:get(name)) of
    false -> {error, not_login_or_not_running};
    true ->
      case sc_store_server:lookup(group_info, group, Group) of
        {error, _, _} -> {error, not_exist};
        {ok, {Gid, _Gname, Members}, _Node} ->
          case length(Members) == 0 of
            true ->
              % delete the group
              sc_store_server:delete(group_info, Gid);
            false ->
              {error, group_still_uesd}
          end
      end
  end.

% Gid在哪个node，就把和该Group相关的group_chat/group_info所有信息都添加到这个node
join_group(Group) ->
  case is_logined(erlang:get(name)) andalso client_running(erlang:get(name)) of
    false -> {error, not_login_or_not_running};
    true ->
      case sc_store_server:lookup(group_info, group, Group) of
        {error, _, _} -> {error, group_not_exist};
        {ok, {Gid, Gname, Members}, Node} ->
          % overwrite
          sc_store_server:insert(Node, group_chat, #group_chat{name = erlang:get(name), group = Gname, group_id = Gid}),
          sc_store_server:insert(Node, group_info, #group_info{group_id = Gid, group_name = Gname, members = [erlang:get(name)]++lists:delete(erlang:get(name), Members)})
      end
  end.

quit_group(Group) ->
  case is_logined(erlang:get(name)) andalso client_running(erlang:get(name)) of
    false -> {error, not_login_or_not_running};
    true ->
      case sc_store_server:lookup(group_info, group, Group) of
        {error, _, _} -> {error, group_not_exist};
        {ok, {Gid, _, _}, _} ->
          sc_store_server:delete(group_chat, erlang:get(name), Group),
          sc_store_server:delete(group_info, Gid, erlang:get(name))
      end
  end.

% never user，每次call sc_element前都去key_to_pid中先查到当前element_pid
% return: ok | error
% TODO: error call lookup(key_to_pid...)
update_element_pid() ->
  case sc_store_server:lookup(key_to_pid, caller, self()) of
    {ok, {_, Epid_r}, _} ->
      case Epid_r == erlang:get(element_pid) of
        false ->
          erlang:put(element_pid, Epid_r)
      end;
    {error, _, _} -> error
  end.




























