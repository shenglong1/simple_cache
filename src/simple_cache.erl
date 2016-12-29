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
  id_generate/0,
  my_element_name/1,
  send_msg/2,
  broadcast/2,
  broadcast_impl/3,
  in_group/2,
  create_group/0,
  destroy_group/0,
  join_group/0,
  quit_group/0
]).

-record(key_to_pid, {name, pid}). %　在线用户列表
-record(user_auth, {name, code, timestamp}). % 所有用户列表
-record(friend, {name, fr_names, timestamp}). % fr_names is list
-record(group_info, {group_id, members}).

% chat_id 是临时的，首次发起会话时建立
-record(single_chat, {name, other_name, chat_id}). % 同时需要添加name-other,other-name
% group_id是固定的，在create_group是建立
-record(group_chat, {name, group, group_id}).

-record(single_chat_record, {chat_id, from, to, timestamp, online, content}).
-record(group_chat_record, {group_id, from, timestamp, online, content}).

% simple_cache_status: [{key,value}]
-record(exit_status, {name, simple_cache_status, element_status}).

%% API for time lease,
%% insert/lookup/delete 使用element维护Caller/LeaseTime的接口
% 在simple_cache看来，不知道element进程细节，所以所有操作都是跨进程的，
% 由element使用gen_server来协调
insert(Key, Caller) ->
  insert(Key, Caller, ?LEASETIME).

insert(Key, Caller, LeaseTime) ->
  case sc_store_server:lookup(key_to_pid, Key) of
    {ok, Pid, Node} ->
      % update: global Pid, global element:replace
      sc_element:replace(Pid, Caller),
      sc_event:replace(Key, Pid, Caller, Node);
    {error, _, _} ->
      % insert: create local
      {ok, Pid} = sc_element:create(Caller, LeaseTime),
      ok = sc_store_server:insert(key_to_pid, #key_to_pid{name = Key, pid = Pid}),
      sc_event:create(Key, Pid, Caller, node())
  end.

lookup(Key) ->
  % provide global search {Key, Pid, Value, Node}
  try
    {ok, {_, Pid}, Node} = sc_store_server:lookup(key_to_pid, Key),
    {ok, Caller} = sc_element:fetch(Pid),
    sc_event:lookup(Key, Pid, Caller, Node),
    {ok, Caller}
  catch
    _Class:_Exception ->
      {error, not_found}
  end.

delete(Key) ->
  % global delete and terminate Pid
  case sc_store_server:lookup(key_to_pid, Key) of
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
      ok = sc_store_server:insert(user_auth, #user_auth{name = User, code = Passwd, timestamp = sc_store_server:timestamp()}),
      {ok, login}
  end.

is_logined(User) ->
  case sc_store_server:lookup(user_auth, User) of
    {ok, _, _} -> true;
    {error, _, _} -> false
  end.

sign_in(User, Passwd) ->
  % 登录
  % 在哪儿登录，key_to_pid就记在哪个节点
  case sc_store_server:lookup(user_auth, User) of
    {ok, {_, Code, _}, _} ->
      case sc_store_server:lookup(key_to_pid, User) of
        {ok, _, _} -> {ok, already_running};
        {error, _, _} ->
          % 先检查密码
          case Code == Passwd of
            true ->
              % simple_cache和element互相持有对方pid
              {ok, Pid} = sc_element:create(self(), 3600), % TODO: element live 1 hour for test
              ok = sc_store_server:insert(key_to_pid, #key_to_pid{name = User, pid = Pid}),

              erlang:put(element_pid, Pid),
              {ok, sign_in};
            false ->
              {error, passwd_err}
          end
      end;
    {error, _, _} ->
      {error, need_login_first}
  end.

sign_out(User) ->
  case sc_store_server:lookup(user_auth, User) of
    {ok, _, _} ->
      case sc_store_server:lookup(key_to_pid, User) of
        {ok, {Name, Pid}, _} ->
          sc_element:delete(Pid),
          sc_store_server:delete(key_to_pid, Name),

          erlang:erase(element_pid),
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
        case sc_store_server:lookup(key_to_pid, User) of
          {ok, _, _} -> true;
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
        {ok, {_, Frname_list, _}, _} ->
          sc_store_server:insert(friend,
            #friend{name = User,
              fr_names = (lists:delete(Frname, Frname_list) ++ [Frname]),
              timestamp = sc_store_server:timestamp()});
        {error, _, _} ->
          sc_store_server:insert(friend, #friend{name = User, fr_names = [Frname], timestamp = sc_store_server:timestamp()})
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

id_generate() -> 0.
% TODO: auto generate id

% 获取当前element进程Pid对应的Name
% return: Name | undefined
my_element_name(My_element_pid) ->
  % ele_pid -> ele_name
  try
    [#key_to_pid{name = Name}] = mnesia:dirty_index_read(key_to_pid, My_element_pid, #key_to_pid.pid),
      Name
  catch
    _ : _ -> undefined
  end.

% TODO: 目前只能发送给在线用户
% return: {ok, Reason} | {error, Reason}
send_msg(Name, Msg) ->
  % send from My_name to Name
  My_name = my_element_name(erlang:get(element_pid)),
  case is_logined(My_name) and is_logined(Name) and is_friend(My_name, Name) of
    true ->

      % construct chat connection
      Build_chat_id =
        fun(From, To) ->
          case sc_store_server:lookup(single_chat, #single_chat{name = From, other_name = To}) of
            {ok, {_, _, Cid}, _} ->
              Cid;
            {error, _, _} ->
              Cid = id_generate(),
              sc_store_server:insert(single_chat, #single_chat{name = From, other_name = To, chat_id = Cid}),
              sc_store_server:insert(single_chat, #single_chat{name = To, other_name = From, chat_id = Cid}),
              Cid
          end
        end,

      % TODO: 无论在线离线，只要两人开启聊天就产生一个chat_id
      case client_running(Name) of
        true ->
          % online msg
          {ok, {_, Pid}, _} = sc_store_server:lookup(key_to_pid, Name),
          ok = sc_element:send_msg(Pid, Msg),

          % TODO: save record and build chat connection
          sc_store_server:insert(single_chat_record,
            #single_chat_record{
              chat_id = Build_chat_id(My_name, Name),
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
          sc_store_server:insert(single_chat_record,
            #single_chat_record{
              chat_id = Build_chat_id(My_name, Name),
              from = My_name,
              to = Name,
              timestamp = sc_store_server:timestamp(),
              online = false,
              content = Msg
            }),
          {ok, normal}
      end;

    false ->
      {error, not_login}
  end.

% return: {ok, Reason} | {error, Reason}
broadcast(Group, Msg) ->
  % find Gid and Members
  My_name = my_element_name(erlang:get(element_pid)),
  case sc_store_server:lookup(group_chat, #group_chat{name = My_name, group = Group}) of
    {ok, {_, _, Gid}, _} ->

      case sc_store_server:lookup(group_info, Gid) of
        {ok, {_, Members}, _} ->
          lists:map(fun(X) -> broadcast_impl(X, Msg, Gid) end, Members),
          {ok, normal};
        {error, _, _} ->
          {error, members_not_found}
      end;

    {error, _, _} ->
      {error, gid_not_found}
  end.

% TODO: 这个send_msg在线方式不变，发送到Name; 而离线发送时保存到group_chat_record中；
broadcast_impl(Name, Msg, Gid) ->
  % broadcast 模式下的 一对一发送
  % send from My_name to Name
  My_name = my_element_name(erlang:get(element_pid)),
  case is_logined(My_name) and is_logined(Name) of
    true ->

      case client_running(Name) of
        true ->
          % online msg
          {ok, {_, Pid}, _} = sc_store_server:lookup(key_to_pid, Name),
          ok = sc_element:send_msg(Pid, Msg),
          % TODO: msg还需要保存到mnesia中
          sc_store_server:insert(group_chat_record,
            #group_chat_record{
              group_id = Gid,
              from = My_name,
              timestamp = sc_store_server:timestamp(),
              online = true,
              content = Msg
            });
        false ->
          % TODO: offline msg, 离线消息会保存到single_chat_record中
          sc_store_server:insert(group_chat_record,
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

% TODO: 还需要有group相关操作，例如加入组，退出组，解散组
create_group() ->
  % 建组时必须建立group_id
  ok.

in_group(Name, Group) ->
  case sc_store_server:lookup(group_chat, #group_chat{name = Name, group = Group}) of
    {ok, {_, _, _}, _} -> true;
    {error, _, _} -> false
  end.

destroy_group() -> ok.

join_group() -> ok.

quit_group() -> ok.
































