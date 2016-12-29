-module(resource_discovery).

-export([
  add_target_resource_type/1,
  add_local_resource/2,
  fetch_resources/1,
  trade_resources/0,
  show/0,
  test/0
]).

fetch_resources(Type) ->
  rd_server:fetch_resources(Type).

add_target_resource_type(Type) ->
  rd_server:add_target_resource_type(Type).

add_local_resource(Type, Resource) ->
  rd_server:add_local_resource(Type, Resource).

trade_resources() ->
  rd_server:trade_resources().

show() ->
  rd_server:show_local().

test() ->
  net_adm:ping(c1@0280106PC0413),
  net_adm:ping(c2@0280106PC0413),
  rd_server:add_target_resource_type(simple_cache),
  rd_server:add_local_resource(simple_cache, c1),
  rd_server:add_local_resource(simple_cache, c2),
  rd_server:trade_resources().
