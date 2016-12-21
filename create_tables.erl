-module(create_tables).

-export([init_tables/0, insert_user/3, insert_project/2]).

-record(user, {
  id,
  name
}).

-record(project, {
  title,
  description
}).

-record(contributor, {
  user_id,
  project_title
}).

init_tables() ->
  % tablename = user, col 按照user record来, Key即是第一列
  mnesia:create_table(user,
    [{attributes, record_info(fields, user)}]),
  mnesia:create_table(project,
    [{attributes, record_info(fields, project)}]),
  mnesia:create_table(contributor,
    [{type, bag}, {attributes, record_info(fields, contributor)}]).

insert_user(Id, Name, ProjectTitles) when ProjectTitles =/= [] ->
  % 将一个User加到多个Title下
  User = #user{id = Id, name = Name},

  % 写入一个user
  Fun = fun() ->
    mnesia:write(User),

    % 保证每一个写入contributor的title都已经存在于project表中
    lists:foreach(
      fun(Title) ->
        [#project{title = Title}] = mnesia:read(project, Title),
        mnesia:write(#contributor{user_id = Id,
          project_title = Title})
      end,
      ProjectTitles)
        end,
  mnesia:transaction(Fun).

insert_project(Title, Description) ->
  mnesia:dirty_write(#project{title = Title,
    description = Description}).