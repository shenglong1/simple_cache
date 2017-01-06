%%%-------------------------------------------------------------------
%%% @author shenglong
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. 十二月 2016 10:12
%%%-------------------------------------------------------------------
-module(my).
-author("shenglong").

%% API
-export([zip/2, test_zip/0,
  lock/2, lockimpl/5, hasPath/4, visited/1]).

-export([
  origin_generator/2,
  nopath_generate/1,
  generate_origin/3,
  mid_path/4,
  find_mids/6
]).

% zip: error?
test_zip() ->
  io:format("~p~n", [zip([], [1,2,3])]),
  io:format("~p~n", [zip([4,5,6], [])]),
  io:format("~p~n", [zip([7,8,9], [a,b,c])]),
  io:format("~p~n", [zip([11,21,31,41,51], [aa,bb,cc])]),
  io:format("~p~n", [zip([111,211,311], [aaa,bbb,ccc,ddd,eee,fff])]).

zip(L1, L2) ->
  case length(L1) >= length(L2) of
    true ->
      io:format("L1(~p) > L2(~p)~n", [length(L1), length(L2)]),
      zipimpl(L1, L2);
    false ->
      io:format("L1(~p) < L2(~p)~n", [length(L1), length(L2)]),
      zipimpl(L2, L1)
  end.

zipimpl([H1|T1], [H2|T2]) ->
  [{H1, H2}|zipimpl(T1, T2)];
zipimpl(_, []) -> [];
zipimpl([], _) -> [].

% return: [1,2,...,N]
origin_generator(N, Res) ->
  case N == 0 of
    true -> Res;
    false ->
      origin_generator(N-1, [N|Res])
  end.

% cell phone lock.
% 求维数为Dim的 Step步路径和
lock(Dim, Step) ->
  OriginList = origin_generator(Dim*Dim, []),
  SumList = lists:map(fun(X) -> lockimpl(X, Step, OriginList, [], Dim) end, OriginList),
  io:format("~p~n", [SumList]),
  sum1(SumList).

% lockimpl的含义是算 一个起点下的所有可能路径数量
% 起点为Cur， 步数为N
lockimpl(X, 1, _, Path, _Dim) ->
% io:format("~p~n",[X]),
  % erlang:put(Cur, false),
  io:format("patn is ~p~n",[Path++[X]]),
  1;

% Path中不包括Cur
% input: start_point, step, origin_point_list, path, dimesion
lockimpl(Cur, N, OriginList, Path, Dim) when is_list(Path) ->
  % erlang:put(Cur, true),

  FilterList = lists:filter(fun(X) -> hasPath(Cur, X, Path++[Cur], Dim) end, OriginList),

  SumList = lists:map(fun(X) -> lockimpl(X, N-1, OriginList, Path++[Cur], Dim) end, FilterList),

  sum1(SumList).

sum1([]) -> 0;
sum1([H|T]) -> H + sum1(T).

% 可访问：包括路径通，且End没有被访问过
%test_hasPath([H|T], L) ->
%  case erlang:get() of
%    [] ->
%      OriginList = [1,2,3,4,5,6,7,8,9],
%      lists:map(fun(W) -> erlang:put(W, false) end, OriginList);
%    _ -> 1
%  end,
% [[hasPath(H, X) || X <- L]|test_hasPath(T, L)];
%test_hasPath([], _) -> [].

% 如何用hasPath返回值为 true/false
% return: true | false
hasPath(Start, End, History_path, Dim) ->
  case Start == End of
    true -> false;
    % io:format("hasPath:[~p-~p]~p~n", [Start, End, false]);
    false ->
      % {start, end, mid}
      case End of
        false -> false;
        % io:format("hasPath:[~p-~p]~p~n", [Start, End, false]);
        _ ->
          case lists:member(End, History_path) of
            true -> false;
            false ->
              % Nopath = [{{1,3},[2]}, {{4,6},[5]}, {{7,9},[8]}, {{1,7},[4]}, {{2,8},[5]}, {{3,9},[6]}, {{1,9},[5]}, {{3,7},[5]}, {{3,1},[2]}, {{6,4},[5]}, {{9,7},[8]}, {{7,1},[4]}, {{8,2},[5]}, {{9,3},[6]}, {{9,1},[5]}, {{7,3},[5]}],
              Nopath = nopath_generate(Dim),
              T = lists:keyfind({Start, End}, 1, Nopath),
              % T is tuple: {{}, []}

              case T of
                false -> true;
                _ ->
                  % 判断中间节点是否访问过
                  {_, Mids} = T,
                  % Mids is list
                  Res = lists:map(fun(X) -> lists:member(X, History_path) end, Mids),
                  case lists:member(false, Res) of
                    true -> false;
                    false -> true
                  end
              end
          end
      end
  end.

visited(N) ->
  case erlang:get() of
    [] ->
      OriginList = [1,2,3,4,5,6,7,8,9],
      lists:map(fun(L) -> erlang:put(L, false) end, OriginList)
  end,
  erlang:get(N).


% 求出Dim维下所有跨越中间点的连接方式
% N 1 ~ dim*dim
% return [{{P1, P2}, [mids]}, {{}, []}]
nopath_generate(Dim) ->
  AllPoints = generate_origin(1, Dim, []),

  % return [{{P, Point}, [mids]}]
  Filter =
    fun(X) ->
      case is_tuple(X) of
        true -> true;
        false -> false
      end
    end,
  Fun =
    fun(P) ->
      Res = lists:map(
        fun(X) ->
          {Point, _} = X,
          case mid_path(P, Point, Dim, AllPoints) of
            [] -> 0;
            List -> {{P, Point}, List}
          end
        end,
        AllPoints
      ),
      % TODO: delete 0 in Res
      lists:filter(Filter, Res)
    end,

  Ress = lists:map(
    fun(T) ->
      {P, _} = T,
      Fun(P)
    end,
    AllPoints),
  lists:merge(Ress).


% 从Cur开始生成Dim维方阵，点值和坐标
% Row Col start from 0
% return [{Point, {Row, Col}}, {_, {_,_}}]
generate_origin(Cur, Dim, Res) ->
  case Cur == Dim * Dim + 1 of
    true -> Res;
    false ->
      Row = (Cur - 1) div Dim,
      Col = (Cur - 1) rem Dim,
      generate_origin(Cur+1, Dim, Res ++ [{Cur, {Row, Col}}])
  end.

% 在Dim维方阵中求出任意两点间的所有中间节点
% true | false(illegal)
% return [mids]
mid_path(P1, P2, _Dim, AllPoints) when is_list(AllPoints) ->
  {Point1, {Row1, Col1}} = lists:keyfind(P1, 1, AllPoints),
  {Point2, {Row2, Col2}} = lists:keyfind(P2, 1, AllPoints),

  case Point1 == Point2 of
    true -> [];
    false ->
      case (Row1 == Row2 andalso (abs(Col1 - Col2) > 1)) of
        true ->

          % 同行，找到中间点
          case Col1 < Col2 of
            true -> find_mids(Row1, Col1+1, Col2, row, [], AllPoints);
            false -> find_mids(Row1, Col2+1, Col1, row, [], AllPoints)
          end;

        false ->
          case (Col1 == Col2 andalso (abs(Row1 - Row2) > 1)) of
            true ->

              % 同列，找到中间点
              case Row1 < Row2 of
                true -> find_mids(Col1, Row1+1, Row2, col, [], AllPoints);
                false -> find_mids(Col1, Row2+1, Row1, col, [], AllPoints)
              end;

            false ->
              Rowsub = abs(Row1 - Row2),
              Colsub = abs(Col1 - Col2),
              case (Rowsub == Colsub) andalso (Rowsub > 1) of
                true ->

                  % 对角线找到中间点
                  [Delete|T] = find_mids(Row1, Col1, Row2, Col2, [], AllPoints),
                  T;

                false -> [] % 普通点：即非同行，非同列，也非对角线
              end
          end
      end
  end.

% input: [Col1, Col2)
% Res: [Points]
% Row Col starts from 0
find_mids(Row, Col1, Col2, row, Res, AllPoints) when Col1 =< Col2 ->
  case Col1 == Col2 of
    true -> Res;
    false ->
      % find {Row, Col1}
      {P, _} = lists:keyfind({Row, Col1}, 2, AllPoints),
      find_mids(Row, Col1+1, Col2, row, Res++[P], AllPoints)
  end;

% input: [Row1, Row2)
find_mids(Col, Row1, Row2, col, Res, AllPoints) when Row1 =< Row2 ->
  case Row1 == Row2 of
    true -> Res;
    false ->
      {P, _} = lists:keyfind({Row1, Col}, 2, AllPoints),
      find_mids(Col, Row1+1, Row2, col, Res++[P], AllPoints)
  end;

% move [{Row1, Col1}, {Row2, Col2})
% return: [Points]
find_mids(Row1, Col1, Row2, Col2, Res, AllPoints) when abs(Row1-Row2) == abs(Col1-Col2) ->
  % abs(Row1 - Row2) == abs(Col1 - Col2),

  {P, _} = lists:keyfind({Row1, Col1}, 2, AllPoints),
  case Row1 == Row2 of
    true -> Res;
    false ->

      case Row1 < Row2 of
        true ->
          case Col1 < Col2 of
            true ->
              find_mids(Row1+1, Col1+1, Row2, Col2, Res++[P], AllPoints);
            false ->
              find_mids(Row1+1, Col1-1, Row2, Col2, Res++[P], AllPoints)
          end;
        false ->
          case Col1 < Col2 of
            true ->
              find_mids(Row1-1, Col1+1, Row2, Col2, Res++[P], AllPoints);
            false ->
              find_mids(Row1-1, Col1-1, Row2, Col2, Res++[P], AllPoints)
          end
      end
  end.



















