%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 13. 十二月 2016 18:34
%%%-------------------------------------------------------------------
{application, resource_discovery,
 [{description, "A simple resource discovery system"},
  {vsn, "0.1.0"},
  {modules, [resource_discovery,
             rd_app,
             rd_sup,
	     rd_server]},
  {registered, [rd_sup, rd_server]},
  {applications, [kernel, stdlib]},
  {mod, {rd_app, []}}
 ]}.