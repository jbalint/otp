%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2010-2015. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%
%% This module implements (as a process) the state machine documented
%% in Appendix A of RFC 3539.
%%

-module(diameter_watchdog).
-behaviour(gen_server).

%% towards diameter_service
-export([start/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% diameter_watchdog_sup callback
-export([start_link/1]).

-include_lib("diameter/include/diameter.hrl").
-include("diameter_internal.hrl").

-define(DEFAULT_TW_INIT, 30000). %% RFC 3539 ch 3.4.1
-define(NOMASK, {0,32}).  %% default sequence mask

-define(BASE, ?DIAMETER_DICT_COMMON).

-define(IS_NATURAL(N), (is_integer(N) andalso 0 =< N)).

-record(config,
        {suspect = 1 :: non_neg_integer(),    %% OKAY -> SUSPECT
         okay    = 3 :: non_neg_integer()}).  %% REOPEN -> OKAY

-record(watchdog,
        {%% PCB - Peer Control Block; see RFC 3539, Appendix A
         status = initial :: initial | okay | suspect | down | reopen,
         pending = false  :: boolean(),  %% DWA
         tw :: 6000..16#FFFFFFFF | {module(), atom(), list()},
                                %% {M,F,A} -> integer() >= 0
         num_dwa = 0 :: -1 | non_neg_integer(),
                     %% number of DWAs received in reopen,
                     %% or number of timeouts before okay -> suspect
         %% end PCB
         parent = self() :: pid(),              %% service process
         transport       :: pid() | undefined,  %% peer_fsm process
         tref :: reference(),     %% reference for current watchdog timer
         dictionary :: module(),  %% common dictionary
         receive_data :: term(),
                 %% term passed into diameter_service with incoming message
         sequence :: diameter:sequence(),     %% mask
         restrict :: {diameter:restriction(), boolean()},
         shutdown = false :: boolean(),
         config :: #config{}}).

%% ---------------------------------------------------------------------------
%% start/2
%%
%% Start a monitor before the watchdog is allowed to proceed to ensure
%% that a failed capabilities exchange produces the desired exit
%% reason.
%% ---------------------------------------------------------------------------

-spec start(Type, {RecvData, [Opt], SvcOpts, #diameter_service{}})
   -> {reference(), pid()}
 when Type :: {connect|accept, diameter:transport_ref()},
      RecvData :: term(),
      Opt :: diameter:transport_opt(),
      SvcOpts :: [diameter:service_opt()].

start({_,_} = Type, T) ->
    Ack = make_ref(),
    {ok, Pid} = diameter_watchdog_sup:start_child({Ack, Type, self(), T}),
    try
        {erlang:monitor(process, Pid), Pid}
    after
        send(Pid, Ack)
    end.

start_link(T) ->
    {ok, _} = proc_lib:start_link(?MODULE,
                                  init,
                                  [T],
                                  infinity,
                                  diameter_lib:spawn_opts(server, [])).

%% ===========================================================================
%% ===========================================================================

%% init/1

init(T) ->
    proc_lib:init_ack({ok, self()}),
    gen_server:enter_loop(?MODULE, [], i(T)).

i({Ack, T, Pid, {RecvData,
                 Opts,
                 SvcOpts,
                 #diameter_service{applications = Apps,
                                   capabilities = Caps}
                 = Svc}}) ->
    erlang:monitor(process, Pid),
    wait(Ack, Pid),
    {_, Seed} = diameter_lib:seed(),
    random:seed(Seed),
    putr(restart, {T, Opts, Svc, SvcOpts}),  %% save seeing it in trace
    putr(dwr, dwr(Caps)),                    %%
    {_,_} = Mask = proplists:get_value(sequence, SvcOpts),
    Restrict = proplists:get_value(restrict_connections, SvcOpts),
    Nodes = restrict_nodes(Restrict),
    Dict0 = common_dictionary(Apps),
    diameter_codec:setopts([{common_dictionary, Dict0},
                            {string_decode, false}]),
    #watchdog{parent = Pid,
              transport = start(T, Opts, SvcOpts, Nodes, Dict0, Svc),
              tw = proplists:get_value(watchdog_timer,
                                       Opts,
                                       ?DEFAULT_TW_INIT),
              receive_data = RecvData,
              dictionary = Dict0,
              sequence = Mask,
              restrict = {Restrict, lists:member(node(), Nodes)},
              config = config(Opts)}.

wait(Ref, Pid) ->
    receive
        Ref ->
            ok;
        {'DOWN', _, process, Pid, _} = D ->
            exit({shutdown, D})
    end.

%% config/1
%%
%% Could also configure counts for SUSPECT to DOWN and REOPEN to DOWN,
%% but don't.

config(Opts) ->
    Config = proplists:get_value(watchdog_config, Opts, []),
    lists:foldl(fun config/2, #config{}, Config).

config({suspect, N}, Rec)
  when ?IS_NATURAL(N) ->
    Rec#config{suspect = N};

config({okay, N}, Rec)
  when ?IS_NATURAL(N) ->
    Rec#config{okay = N}.

%% start/6

start(T, Opts, SvcOpts, Nodes, Dict0, Svc) ->
    {_MRef, Pid}
        = diameter_peer_fsm:start(T, Opts, {SvcOpts, Nodes, Dict0, Svc}),
    Pid.

%% common_dictionary/1
%%
%% Determine the dictionary of the Diameter common application with
%% Application Id 0. Fail on config errors.

common_dictionary(Apps) ->
    case
        orddict:fold(fun dict0/3,
                     false,
                     lists:foldl(fun(#diameter_app{dictionary = M}, D) ->
                                         orddict:append(M:id(), M, D)
                                 end,
                                 orddict:new(),
                                 Apps))
    of
        {value, Mod} ->
            Mod;
        false ->
            %% A transport should configure a common dictionary but
            %% don't require it. Not configuring a common dictionary
            %% means a user won't be able either send of receive
            %% messages in the common dictionary: incoming request
            %% will be answered with 3007 and outgoing requests cannot
            %% be sent. The dictionary returned here is only used for
            %% messages diameter sends and receives: CER/CEA, DPR/DPA
            %% and DWR/DWA.
            ?BASE
    end.

%% Each application should be represented by a single dictionary.
dict0(Id, [_,_|_] = Ms, _) ->
    config_error({multiple_dictionaries, Ms, {application_id, Id}});

%% An explicit common dictionary.
dict0(?APP_ID_COMMON, [Mod], _) ->
    {value, Mod};

%% A pure relay, in which case the common application is implicit.
%% This uses the fact that the common application will already have
%% been folded.
dict0(?APP_ID_RELAY, _, false) ->
    {value, ?BASE};

dict0(_, _, Acc) ->
    Acc.

config_error(T) ->
    exit({shutdown, {configuration_error, T}}).

%% handle_call/3

handle_call(_, _, State) ->
    {reply, nok, State}.

%% handle_cast/2

handle_cast(_, State) ->
    {noreply, State}.

%% handle_info/2

handle_info(T, #watchdog{} = State) ->
    case transition(T, State) of
        ok ->
            {noreply, State};
        #watchdog{} = S ->
            close(T, State),     %% service expects 'close' message
            event(T, State, S),  %%   before 'watchdog'
            {noreply, S};
        stop ->
            ?LOG(stop, T),
            event(T, State, State#watchdog{status = down}),
            {stop, {shutdown, T}, State}
    end.

close({'DOWN', _, process, TPid, {shutdown, Reason}},
      #watchdog{transport = TPid,
                parent = Pid}) ->
    send(Pid, {close, self(), Reason});

close(_, _) ->
    ok.

event(_,
      #watchdog{status = From, transport = F},
      #watchdog{status = To, transport = T})
  when F == undefined, T == undefined;  %% transport not started
       From == initial, To == down;     %% never really left INITIAL
       From == To ->                    %% no state transition
    ok;
%% Note that there is no INITIAL -> DOWN transition in RFC 3539: ours
%% is just a consequence of stop.

event(Msg,
      #watchdog{status = From, transport = F, parent = Pid},
      #watchdog{status = To, transport = T}) ->
    TPid = tpid(F,T),
    E = {[TPid | data(Msg, TPid, From, To)], From, To},
    send(Pid, {watchdog, self(), E}),
    ?LOG(transition, {From, To}).

data(Msg, TPid, reopen, okay) ->
    {recv, TPid, 'DWA', _Pkt} = Msg,  %% assert
    {TPid, T} = eraser(open),
    [T];

data({open, TPid, _Hosts, T}, TPid, _From, To)
  when To == okay;
       To == reopen ->
    [T];

data(_, _, _, _) ->
    [].

tpid(_, Pid)
  when is_pid(Pid) ->
    Pid;

tpid(Pid, _) ->
    Pid.

send(Pid, T) ->
    Pid ! T.

%% terminate/2

terminate(_, _) ->
    ok.

%% code_change/3

code_change(_, State, _) ->
    {ok, State}.

%% ===========================================================================
%% ===========================================================================

%% transition/2
%%
%% The state transitions documented here are extracted from RFC 3539,
%% the commentary is ours.

%% Service is telling the watchdog of an accepting transport to die
%% following transport death in state INITIAL, or after connect_timer
%% expiry; or another watchdog is saying the same after reestablishing
%% a connection previously had by this one.
transition(close, #watchdog{}) ->
    {accept, _} = role(), %% assert
    stop;

%% Service is asking for the peer to be taken down gracefully.
transition({shutdown, Pid, _}, #watchdog{parent = Pid,
                                         transport = undefined}) ->
    stop;
transition({shutdown = T, Pid, Reason}, #watchdog{parent = Pid,
                                                  transport = TPid}
                                        = S) ->
    send(TPid, {T, self(), Reason}),
    S#watchdog{shutdown = true};

%% Transport is telling us that DPA has been sent in response to DPR,
%% or that DPR has been explicitly sent: transport death should lead
%% to ours.
transition({'DPR', TPid}, #watchdog{transport = TPid} = S) ->
    S#watchdog{shutdown = true};

%% Parent process has died,
transition({'DOWN', _, process, Pid, _Reason},
           #watchdog{parent = Pid}) ->
    stop;

%% Transport has accepted a connection.
transition({accepted = T, TPid}, #watchdog{transport = TPid,
                                           parent = Pid}) ->
    send(Pid, {T, self(), TPid}),
    ok;

%%   STATE         Event                Actions              New State
%%   =====         ------               -------              ----------
%%   INITIAL       Connection up        SetWatchdog()        OKAY

%% By construction, the watchdog timer isn't set until we move into
%% state okay as the result of the Peer State Machine reaching the
%% Open state.
%%
%% If we're accepting then we may be resuming a connection that went
%% down in another watchdog process, in which case this is the
%% transition below, from down to reopen. That is, it's not until we
%% know the identity of the peer (ie. now) that we know that we're in
%% state down rather than initial.

transition({open, TPid, Hosts, _} = Open,
           #watchdog{transport = TPid,
                     status = initial,
                     restrict = {_,R},
                     config = #config{suspect = OS}}
           = S) ->
    case okay(role(), Hosts, R) of
        okay ->
            set_watchdog(S#watchdog{status = okay,
                                    num_dwa = OS});
        reopen ->
            transition(Open, S#watchdog{status = down})
    end;

%%   DOWN          Connection up        NumDWA = 0
%%                                      SendWatchdog()
%%                                      SetWatchdog()
%%                                      Pending = TRUE       REOPEN

transition({open = Key, TPid, _Hosts, T},
           #watchdog{transport = TPid,
                     status = down,
                     config = #config{suspect = OS,
                                      okay = RO}}
           = S) ->
    case RO of
        0 ->  %% non-standard: skip REOPEN
            set_watchdog(S#watchdog{status = okay,
                                    num_dwa = OS});
        _ ->
            %% Store the info we need to notify the parent to reopen
            %% the connection after the requisite DWA's are received,
            %% at which time we eraser(open).
            putr(Key, {TPid, T}),
            set_watchdog(send_watchdog(S#watchdog{status = reopen,
                                                  num_dwa = 0}))
    end;

%%   OKAY          Connection down      CloseConnection()
%%                                      Failover()
%%                                      SetWatchdog()        DOWN
%%   SUSPECT       Connection down      CloseConnection()
%%                                      SetWatchdog()        DOWN
%%   REOPEN        Connection down      CloseConnection()
%%                                      SetWatchdog()        DOWN

%% Transport has died after DPA or service requested termination ...
transition({'DOWN', _, process, TPid, _Reason},
           #watchdog{transport = TPid,
                     shutdown = true}) ->
    stop;

%% ... or not.
transition({'DOWN', _, process, TPid, _Reason} = D,
           #watchdog{transport = TPid,
                     status = T,
                     restrict = {_,R}}
           = S0) ->
    S = S0#watchdog{pending = false,
                    transport = undefined},
    {M,_} = role(),

    %% Close an accepting watchdog immediately if there's no
    %% restriction on the number of connections to the same peer: the
    %% state machine never enters state REOPEN in this case.

    if T == initial;
       M == accept, not R ->
            close(D, S0),
            stop;
       true ->
            set_watchdog(S#watchdog{status = down})
    end;

%% Incoming message.
transition({recv, TPid, Name, Pkt}, #watchdog{transport = TPid} = S) ->
    recv(Name, Pkt, S);

%% Current watchdog has timed out.
transition({timeout, TRef, tw}, #watchdog{tref = TRef} = S) ->
    set_watchdog(timeout(S));

%% Timer was canceled after message was already sent.
transition({timeout, _, tw}, #watchdog{}) ->
    ok;

%% State query.
transition({state, Pid}, #watchdog{status = S}) ->
    send(Pid, {self(), S}),
    ok.

%% ===========================================================================

putr(Key, Val) ->
    put({?MODULE, Key}, Val).

getr(Key) ->
    get({?MODULE, Key}).

eraser(Key) ->
    erase({?MODULE, Key}).

%% encode/3

encode(dwr = M, Dict0, Mask) ->
    Msg = getr(M),
    Seq = diameter_session:sequence(Mask),
    Hdr = #diameter_header{version = ?DIAMETER_VERSION,
                           end_to_end_id = Seq,
                           hop_by_hop_id = Seq},
    Pkt = #diameter_packet{header = Hdr,
                           msg = Msg},
    diameter_codec:encode(Dict0, Pkt);

encode(dwa, Dict0, #diameter_packet{header = H, transport_data = TD}
                   = ReqPkt) ->
    AnsPkt = #diameter_packet{header
                              = H#diameter_header{is_request = false,
                                                  is_error = undefined,
                                                  is_retransmitted = false},
                              msg = dwa(ReqPkt),
                              transport_data = TD},

    diameter_codec:encode(Dict0, AnsPkt).

%% okay/3

okay({accept, Ref}, Hosts, Restrict) ->
    T = {?MODULE, connection, Ref, Hosts},
    diameter_reg:add(T),
    if Restrict ->
            okay(diameter_reg:match(T));
       true ->
            okay
    end;
%% Register before matching so that at least one of two registering
%% processes will match the other.

okay({connect, _}, _, _) ->
    okay.

%% okay/2

%% The peer hasn't been connected recently ...
okay([{_,P}]) ->
    P = self(),  %% assert
    okay;

%% ... or it has.
okay(C) ->
    [_|_] = [send(P, close) || {_,P} <- C, self() /= P],
    reopen.

%% role/0

role() ->
    element(1, getr(restart)).

%% set_watchdog/1

set_watchdog(#watchdog{tw = TwInit,
                       tref = TRef}
             = S) ->
    cancel(TRef),
    S#watchdog{tref = erlang:start_timer(tw(TwInit), self(), tw)};
set_watchdog(stop = No) ->
    No.

cancel(undefined) ->
    ok;
cancel(TRef) ->
    erlang:cancel_timer(TRef).

tw(T)
  when is_integer(T), T >= 6000 ->
    T - 2000 + (random:uniform(4001) - 1); %% RFC3539 jitter of +/- 2 sec.
tw({M,F,A}) ->
    apply(M,F,A).

%% send_watchdog/1

send_watchdog(#watchdog{pending = false,
                        transport = TPid,
                        dictionary = Dict0,
                        sequence = Mask}
              = S) ->
    #diameter_packet{bin = Bin} = EPkt = encode(dwr, Dict0, Mask),
    diameter_traffic:incr(send, EPkt, TPid, Dict0),
    send(TPid, {send, Bin}),
    ?LOG(send, 'DWR'),
    S#watchdog{pending = true}.

%% Don't count encode errors since we don't expect any on DWR/DWA.

%% recv/3

recv(Name, Pkt, S) ->
    try rcv(Name, S) of
        #watchdog{} = NS ->
            rcv(Name, Pkt, S),
            NS
    catch
        {?MODULE, throwaway, #watchdog{} = NS} ->
            NS
    end.

%% rcv/3

rcv('DWR', Pkt, #watchdog{transport = TPid,
                          dictionary = Dict0}) ->
    ?LOG(recv, 'DWR'),
    DPkt = diameter_codec:decode(Dict0, Pkt),
    diameter_traffic:incr(recv, DPkt, TPid, Dict0),
    diameter_traffic:incr_error(recv, DPkt, TPid, Dict0),
    #diameter_packet{header = H,
                     transport_data = T,
                     bin = Bin}
        = EPkt
        = encode(dwa, Dict0, Pkt),
    diameter_traffic:incr(send, EPkt, TPid, Dict0),
    diameter_traffic:incr_rc(send, EPkt, TPid, Dict0),

    %% Strip potentially large message terms.
    send(TPid, {send, #diameter_packet{header = H,
                                       transport_data = T,
                                       bin = Bin}}),
    ?LOG(send, 'DWA');

rcv('DWA', Pkt, #watchdog{transport = TPid,
                          dictionary = Dict0}) ->
    ?LOG(recv, 'DWA'),
    diameter_traffic:incr(recv, Pkt, TPid, Dict0),
    diameter_traffic:incr_rc(recv,
                             diameter_codec:decode(Dict0, Pkt),
                             TPid,
                             Dict0);

rcv(N, _, _)
  when N == 'CER';
       N == 'CEA';
       N == 'DPR' ->
    false;
%% DPR can be sent explicitly with diameter:call/4. Only the
%% corresponding DPAs arrive here.

rcv(_, Pkt, #watchdog{transport = TPid,
                      dictionary = Dict0,
                      receive_data = T}) ->
    diameter_traffic:receive_message(TPid, Pkt, Dict0, T).

throwaway(S) ->
    throw({?MODULE, throwaway, S}).

%% rcv/2
%%
%% The lack of Hop-by-Hop and End-to-End Identifiers checks in a
%% received DWA is intentional. The purpose of the message is to
%% demonstrate life but a peer that consistently bungles it by sending
%% the wrong identifiers causes the connection to toggle between OPEN
%% and SUSPECT, with failover and failback as result, despite there
%% being no real problem with connectivity. Thus, relax and accept any
%% incoming DWA as being in response to an outgoing DWR.

%%   INITIAL       Receive DWA          Pending = FALSE
%%                                      Throwaway()          INITIAL
%%   INITIAL       Receive non-DWA      Throwaway()          INITIAL

rcv('DWA', #watchdog{status = initial} = S) ->
    throwaway(S#watchdog{pending = false});

rcv(_, #watchdog{status = initial} = S) ->
    throwaway(S);

%%   DOWN          Receive DWA          Pending = FALSE
%%                                      Throwaway()          DOWN
%%   DOWN          Receive non-DWA      Throwaway()          DOWN

rcv('DWA', #watchdog{status = down} = S) ->
    throwaway(S#watchdog{pending = false});

rcv(_, #watchdog{status = down} = S) ->
    throwaway(S);

%%   OKAY          Receive DWA          Pending = FALSE
%%                                      SetWatchdog()        OKAY
%%   OKAY          Receive non-DWA      SetWatchdog()        OKAY

rcv('DWA', #watchdog{status = okay} = S) ->
    set_watchdog(S#watchdog{pending = false});

rcv(_, #watchdog{status = okay} = S) ->
    set_watchdog(S);

%%   SUSPECT       Receive DWA          Pending = FALSE
%%                                      Failback()
%%                                      SetWatchdog()        OKAY
%%   SUSPECT       Receive non-DWA      Failback()
%%                                      SetWatchdog()        OKAY

rcv('DWA', #watchdog{status = suspect, config = #config{suspect = OS}} = S) ->
    set_watchdog(S#watchdog{status = okay,
                            num_dwa = OS,
                            pending = false});

rcv(_, #watchdog{status = suspect, config = #config{suspect = OS}} = S) ->
    set_watchdog(S#watchdog{status = okay,
                            num_dwa = OS});

%%   REOPEN        Receive DWA &        Pending = FALSE
%%                 NumDWA == 2          NumDWA++
%%                                      Failback()           OKAY

rcv('DWA', #watchdog{status = reopen,
                     num_dwa = N,
                     config = #config{suspect = OS,
                                      okay = RO}}
           = S)
  when N+1 == RO ->
    S#watchdog{status = okay,
               num_dwa = OS,
               pending = false};

%%   REOPEN        Receive DWA &        Pending = FALSE
%%                 NumDWA < 2           NumDWA++             REOPEN

rcv('DWA', #watchdog{status = reopen,
                     num_dwa = N}
           = S) ->
    S#watchdog{num_dwa = N+1,
               pending = false};

%%   REOPEN        Receive non-DWA      Throwaway()          REOPEN

rcv('DWR', #watchdog{status = reopen} = S) ->
    S;  %% ensure DWA: the RFC isn't explicit about answering

rcv(_, #watchdog{status = reopen} = S) ->
    throwaway(S).

%% timeout/1
%%
%% The caller sets the watchdog on the return value.

%%   OKAY          Timer expires &      SendWatchdog()
%%                 !Pending             SetWatchdog()
%%                                      Pending = TRUE       OKAY
%%   REOPEN        Timer expires &      SendWatchdog()
%%                 !Pending             SetWatchdog()
%%                                      Pending = TRUE       REOPEN

timeout(#watchdog{status = T,
                  pending = false}
        = S)
  when T == okay;
       T == reopen ->
    send_watchdog(S);

%%   OKAY          Timer expires &      Failover()
%%                 Pending              SetWatchdog()        SUSPECT

timeout(#watchdog{status = okay,
                  pending = true,
                  num_dwa = N}
        = S) ->
    case N of
        1 ->
            S#watchdog{status = suspect};
        0 ->  %% non-standard: never move to suspect
            S;
        N ->  %% non-standard: more timeouts before moving
            S#watchdog{num_dwa = N-1}
    end;

%%   SUSPECT       Timer expires        CloseConnection()
%%                                      SetWatchdog()        DOWN
%%   REOPEN        Timer expires &      CloseConnection()
%%                 Pending &            SetWatchdog()
%%                 NumDWA < 0                                DOWN

timeout(#watchdog{status = T,
                  pending = P,
                  num_dwa = N,
                  transport = TPid}
        = S)
  when T == suspect;
       T == reopen, P, N < 0 ->
    exit(TPid, {shutdown, watchdog_timeout}),
    S#watchdog{status = down};

%%   REOPEN        Timer expires &      NumDWA = -1
%%                 Pending &            SetWatchdog()
%%                 NumDWA >= 0                               REOPEN

timeout(#watchdog{status = reopen,
                  pending = true,
                  num_dwa = N}
        = S)
  when 0 =< N ->
    S#watchdog{num_dwa = -1};

%%   DOWN          Timer expires        AttemptOpen()
%%                                      SetWatchdog()        DOWN
%%   INITIAL       Timer expires        AttemptOpen()
%%                                      SetWatchdog()        INITIAL

%% RFC 3539, 3.4.1:
%%
%%   [5] While the connection is in the closed state, the AAA client MUST
%%       NOT attempt to send further watchdog messages on the connection.
%%       However, after the connection is closed, the AAA client continues
%%       to periodically attempt to reopen the connection.
%%
%%       The AAA client SHOULD wait for the transport layer to report
%%       connection failure before attempting again, but MAY choose to
%%       bound this wait time by the watchdog interval, Tw.

%% Don't bound, restarting the peer process only when the previous
%% process has died. We only need to handle state down since we start
%% the first watchdog when transitioning out of initial.

timeout(#watchdog{status = T} = S)
  when T == initial;
       T == down ->
    restart(S).

%% restart/1

restart(#watchdog{transport = undefined} = S) ->
    restart(getr(restart), S);
restart(S) ->  %% reconnect has won race with timeout
    S.

%% restart/2
%%
%% Only restart the transport in the connecting case. For an accepting
%% transport, there's no guarantee that an accepted connection in a
%% restarted transport if from the peer we've lost contact with so
%% have to be prepared for another watchdog to handle it. This is what
%% the diameter_reg registration in this module is for: the peer
%% connection is registered when leaving state initial and this is
%% used by a new accepting watchdog to realize that it's actually in
%% state down rather then initial when receiving notification of an
%% open connection.

restart({T, Opts, Svc}, S) ->  %% put in old code
    restart({T, Opts, Svc, []}, S);

restart({{connect, _} = T, Opts, Svc, SvcOpts},
        #watchdog{parent = Pid,
                  restrict = {R,_},
                  dictionary = Dict0}
        = S) ->
    send(Pid, {reconnect, self()}),
    Nodes = restrict_nodes(R),
    S#watchdog{transport = start(T, Opts, SvcOpts, Nodes, Dict0, Svc),
               restrict = {R, lists:member(node(), Nodes)}};

%% No restriction on the number of connections to the same peer: just
%% die. Note that a state machine never enters state REOPEN in this
%% case.
restart({{accept, _}, _, _, _}, #watchdog{restrict = {_, false}}) ->
    stop;  %% 'DOWN' was in old code: 'close' was not sent

%% Otherwise hang around until told to die, either by the service or
%% by another watchdog.
restart({{accept, _}, _, _, _}, S) ->
    S.

%% Don't currently use Opts/Svc in the accept case.

%% dwr/1

dwr(#diameter_caps{origin_host = OH,
                   origin_realm = OR,
                   origin_state_id = OSI}) ->
    ['DWR', {'Origin-Host', OH},
            {'Origin-Realm', OR},
            {'Origin-State-Id', OSI}].

%% dwa/1

dwa(#diameter_packet{header = H, errors = Es}) ->
    {RC, FailedAVP} = diameter_peer_fsm:result_code(H, Es),
    ['DWA', {'Result-Code', RC}
          | tl(getr(dwr)) ++ FailedAVP].

%% restrict_nodes/1

restrict_nodes(false) ->
    [];

restrict_nodes(nodes) ->
    [node() | nodes()];

restrict_nodes(node) ->
    [node()];

restrict_nodes(Nodes)
  when [] == Nodes;
       is_atom(hd(Nodes)) ->
    Nodes;

restrict_nodes(F) ->
    diameter_lib:eval(F).
