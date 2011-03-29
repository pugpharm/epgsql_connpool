%% Copyright (c) 2011 Smarkets Limited
%% Distributed under the MIT license; see LICENSE for details.
-module(epgsql_pool).

-behaviour(gen_server).

-export([name/1]).
-export([available/2, status/1, reserve/2, release/2]).
-export([transaction/2, transaction/3, transaction/4]).

%% gen_server
-export([start_link/1, init/1, code_change/3, terminate/2,
         handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
          name,
          min_size,
          max_size = 0,
          requests = queue:new(),
          conns    = queue:new(),
          tab      = gb_trees:empty()
         }).

-record(req, {
          from,
          pid,
          ref,
          timestamp,
          timeout
         }).

-define(TIMEOUT, timer:seconds(5)).

status(Name) -> gen_server:call(name(Name), stats, infinity).

available(Name, Pid) ->
    gen_server:cast(name(Name), {available, Pid}).

reserve(Name, Timeout) ->
    gen_server:call(name(Name), {reserve, self(), Timeout}, Timeout).

release(Name, Pid) ->
    gen_server:cast(name(Name), {release, self(), Pid}).

transaction(Name, F) -> transaction(Name, F, ?TIMEOUT).
transaction(Name, F, Timeout) -> transaction(Name, F, [], Timeout).
transaction(Name, F, Args, Timeout) ->
    {ok, Pid} = reserve(Name, Timeout),
    % If we exit here, the transaction never gets started
    try begin
            % Whereas an exit here will end up calling the 'after' block
            {ok, [], []} = pgsql:squery(Pid, "BEGIN"),
            R = apply(F, [Pid|Args]),
            {ok, [], []} = pgsql:squery(Pid, "COMMIT"),
            R
        end
    catch
        throw:Throw ->
            {ok, [], []} = pgsql:squery(Pid, "ROLLBACK"),
            throw(Throw);
        exit:Exit ->
            {ok, [], []} = pgsql:squery(Pid, "ROLLBACK"),
            exit(Exit)
    after
        ok = release(Name, Pid)
    end.

name(Name) when is_atom(Name) -> list_to_atom(atom_to_list(Name) ++ "_pool").

start_link(Name) ->
    gen_server:start_link({local, name(Name)}, ?MODULE, Name, []).

init(Name) ->
    case epgsql_pool_config:pool_size(Name) of
        {ok, Size}         -> {ok, new_connection(#state{min_size = Size, name = Name})};
        {error, not_found} -> {stop, {error, missing_configuration}}
    end.

terminate(_Reason, #state{}) -> ok.

handle_call(
  stats,
  _From,
  #state{min_size = MinSz,
         max_size = MaxSz,
         tab = T,
         requests = R,
         conns = C} = State) ->
    {B, M} =
        lists:foldl(
          fun({_, {_, busy_connection}}, {B0, M0})      -> {B0 + 1, M0};
             ({_, {Pid, _}}, {B0, M0}) when is_pid(Pid) -> {B0, M0 + 1};
             (_, Acc)                                   -> Acc
          end, {0, 0}, gb_trees:to_list(T)),
    {reply,
     {ok, [{min_size, MinSz},
           {max_size, MaxSz},
           {available, queue:len(C)},
           {requests, queue:len(R)},
           {busy, B},
           {monitored, M}]},
     State};

handle_call({reserve, Pid, Timeout}, From, #state{conns = C} = State0) ->
    Ref = erlang:monitor(process, Pid),
    State = queue_request(Pid, Ref, From, Timeout, State0),
    case queue:is_empty(C) of
        % No connections available
        true  -> {noreply, State};
        % Immediately hand off connection in reply
        false -> {noreply, dequeue_request(State)}
    end;

handle_call(Msg, _, _) -> exit({unknown_call, Msg}).

handle_cast({release, RPid, PPid}, State) ->
    {noreply, connection_returned(RPid, PPid, State)};
handle_cast({available, CPid}, State) ->
    {noreply, connection_available(CPid, State)};
handle_cast(Msg, _) -> exit({unknown_cast, Msg}).

handle_info({'DOWN', Ref, process, Pid, _Reason}, State) ->
    {noreply, process_died(Pid, Ref, State)};
handle_info(Msg, _) -> exit({unknown_info, Msg}).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

new_connection(#state{min_size = Sz, name = Name, conns = C0} = S) ->
    case queue:len(C0) of
        CSz when CSz < Sz -> epgsql_pool_conn_sup:start_connection(Name);
        _                 -> ok
    end,
    S.

connection_returned(RPid, PPid, #state{tab = T0} = S) ->
    {CPid, T1} = tree_pop(PPid, T0),
    {{RRef, CPid}, T2} = tree_pop(RPid, T1),
    {{RPid, busy_request}, T3} = tree_pop(RRef, T2),
    {{CRef, RPid}, T4} = tree_pop(CPid, T3),
    {{CPid, busy_connection}, T5} = tree_pop(CRef, T4),
    true = erlang:demonitor(CRef, [flush]),
    true = erlang:demonitor(RRef, [flush]),
    ok = epgsql_pool_conn:release(CPid),
    S#state{tab = T5}.

connection_available(CPid, #state{tab = T0, conns = C0} = S) ->
    CRef = erlang:monitor(process, CPid),
    C = queue:in(CPid, C0),
    T = gb_trees:insert(CPid, CRef, T0),
    T1 = gb_trees:insert(CRef, {CPid, available_connection}, T),
    S1 = new_connection(S#state{tab = T1, conns = C}),
    dequeue_request(S1).

queue_request(RPid, RRef, RFrom, Timeout, #state{tab = T0, requests = R0} = S) ->
    Item = #req{from = RFrom, pid = RPid, ref = RRef, timestamp = erlang:now(), timeout = Timeout},
    R = queue:in(Item, R0),
    T = gb_trees:insert(RRef, {RPid, waiting_request}, T0),
    T1 = gb_trees:insert(RPid, RRef, T),
    S#state{requests = R, tab = T1}.

dequeue_request(#state{tab = T0, requests = R0, conns = C0} = S) ->
    case queue:out(R0) of
        {empty, R0} -> S;
        {{value, Item}, R} ->
            #req{from = RFrom, pid = RPid, ref = RRef, timestamp = Ts, timeout = Timeout} = Item,
            {{RPid, waiting_request}, T} = tree_pop(RRef, T0),
            {RRef, T1} = tree_pop(RPid, T),
            S1 = S#state{tab = T1, requests = R},
            case timer:now_diff(erlang:now(), Ts) > (Timeout * 1000) of
                % Discard request which timed out
                true ->
                    true = erlang:demonitor(RRef, [flush]),
                    dequeue_request(S1);
                % Otherwise, reply and track new busy pair
                false ->
                    case queue:out(C0) of
                        % Revert to original queues as no connections are available
                        {empty, C0} -> S;
                        {{value, CPid}, C} ->
                            {CRef, T2} = tree_pop(CPid, S1#state.tab),
                            {{CPid, available_connection}, T3} = tree_pop(CRef, T2),
                            {ok, PPid} = epgsql_pool_conn:connection(CPid),
                            T4 = gb_trees:insert(PPid, CPid, T3),
                            T5 = gb_trees:insert(CRef, {CPid, busy_connection}, T4),
                            T6 = gb_trees:insert(CPid, {CRef, RPid}, T5),
                            T7 = gb_trees:insert(RPid, {RRef, CPid}, T6),
                            T8 = gb_trees:insert(RRef, {RPid, busy_request}, T7),
                            gen_server:reply(RFrom, {ok, PPid}),
                            dequeue_request(S1#state{tab = T8, conns = C})
                    end
            end
    end.

process_died(Pid, Ref, #state{tab = T0, conns = C0, requests = R0} = S) ->
    case tree_pop(Ref, T0) of
        {{CPid, busy_connection}, T1} ->
            CPid = Pid,
            {{CRef, RPid}, T2} = tree_pop(CPid, T1),
            CRef = Ref,
            {{RRef, CPid}, T3} = tree_pop(RPid, T2),
            {{RPid, busy_request}, T4} = tree_pop(RRef, T3),
            new_connection(S#state{tab = T4});
        {{CPid, available_connection}, T1} ->
            CPid = Pid,
            {CRef, T2} = tree_pop(CPid, T1),
            CRef = Ref,
            C = q_delete(CPid, C0),
            new_connection(S#state{tab = T2, conns = C});
        {{RPid, busy_request}, T1} ->
            RPid = Pid,
            {{RRef, CPid}, T2} = tree_pop(RPid, T1),
            RRef = Ref,
            {{CRef, RPid}, T3} = tree_pop(CPid, T2),
            {{CPid, busy_connection}, T4} = tree_pop(CRef, T3),
            {ok, PPid} = epgsql_pool_conn:connection(CPid),
            ok = epgsql_pool_conn:release(CPid),
            {CPid, T5} = tree_pop(PPid, T4),
            C = queue:in(CPid, C0),
            S#state{tab = T5, conns = C};
        {{RPid, waiting_request}, T1} ->
            RPid = Pid,
            {RRef, T2} = tree_pop(RPid, T1),
            RRef = Ref,
            R = q_delete(RRef, #req.ref, R0),
            S#state{tab = T2, requests = R}
    end.

tree_pop(K, T) -> {gb_trees:get(K, T), gb_trees:delete(K, T)}.

q_delete(Item, Q) -> queue:from_list(lists:delete(Item, queue:to_list(Q))).
q_delete(Key, I, Q) -> queue:from_list(lists:keydelete(Key, I, queue:to_list(Q))).
