%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 13. 十二月 2016 18:34
%%%-------------------------------------------------------------------
{application, simple_cache,
  [
    {description, "shenglong's simple cache"},
    {vsn, "1.0.3"},
    {modules, [
      simple_cache,
      sc_app,
      sc_sup,
      sc_store_server,
      sc_event_logger,
      sc_event,
      sc_element_sup,
      sc_element]},
    {registered, [sc_sup, sc_element, sc_event, sc_store_server]},
    {applications, [kernel, stdlib, sasl, mnesia, resource_discovery]},
    {mod, {sc_app, []}}
  ]
}.