run in simple_cache/src:
toolbar:start(),application:start(sasl),mnesia:start(),cd("../resource_discovery/ebin"),application:start(resource_discovery),net_adm:ping(c1@0280106PC0413),nodes(),resource_discovery:test(),cd("../../ebin"), application:start(simple_cache).