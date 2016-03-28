%% - Server module
%% - The server module creates a parallel registered process by spawning a process which
%% evaluates initialize().
%% The function initialize() does the following:
%%      1/ It makes the current process as a system process in order to trap exit.
%%      2/ It creates a process evaluating the store_loop() function.
%%      4/ It executes the server_loop() function.

-module(server).

%-import(lists).
-export([start/0]).

%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start() ->
    register(transaction_server, spawn(fun() ->
					       process_flag(trap_exit, true),
					       Val= (catch initialize()),
					       io:format("Server terminated with:~p~n",[Val])
				       end)).

initialize() ->
    process_flag(trap_exit, true),
    Initialvals = [{a,0,0,0},{b,0,0,0},{c,0,0,0},{d,0,0,0}], %% All variables are set to 0 as var,val,rts,wts}
    ServerPid = self(),
    StorePid = spawn_link(fun() -> store_loop(ServerPid,Initialvals) end),
    server_loop([],StorePid,[],1).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d

%%Adding transactionlist to isolate transactions, will have to remove transactions when removing clients
%%TansactionList = [{ClientPid,TS,[Dep],[Old],status}, {...}]
%%Status 'ok' keeps track of message number
server_loop(ClientList,StorePid,TransactionList,ServerTimestamp) ->
    receive
	{login, MM, Client} ->
	    MM ! {ok, self()},
	    io:format("New client has joined the server:~p.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(add_client(Client,ClientList),StorePid,TransactionList,ServerTimestamp);
	{close, Client} ->
	    io:format("Client~p has left the server.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(remove_client(Client,ClientList),StorePid,TransactionList,ServerTimestamp);
	{request, Client} ->
      io:format("~n###REQUESTED BY ~p.~n", [ServerTimestamp]),
	    Client ! {proceed, ServerTimestamp, self()},
      NewTimestamp = ServerTimestamp + 1,
	    server_loop(ClientList,StorePid,add_transaction(Client,ServerTimestamp,TransactionList),NewTimestamp);
  {action, Client, Act, Timestamp, ID} ->
	    io:format("~nReceived ~p from client ~p.~n", [Act, Client]),
      {ClientPid,TS,Dep,Old,Status} = lists:keyfind(Timestamp, 2, TransactionList),

      %% Status should NEVER be "committed"
      case Status of
        {ok,ID} ->
          StorePid ! {Act,Timestamp,self()},
          receive
            {readOk, WTS} -> %% Read done
              %% Don't add yourself or 0 (because 0 is default)
              if WTS == Timestamp -> NewDEP = Dep;
                 WTS == 0 -> NewDEP = Dep;
                 true -> NewDEP = sets:add_element(WTS, Dep)
              end,
              OkTransaction = {ClientPid,TS,NewDEP,Old,{ok,ID+1}},
              NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, OkTransaction);
            {writeOk, OldVal} -> %% Write done
              NewOLD = [OldVal|Old],
              OkTransaction = {ClientPid,TS,Dep,NewOLD,{ok,ID+1}},
              NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, OkTransaction);
            {noWrite} -> %% Nothing changed, increment ID (because we effectively received the message)
              OkTransaction = {ClientPid,TS,Dep,Old,{ok,ID+1}},
              NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, OkTransaction);
            {abortAction} -> %% Need to abort
              AbortedTransaction = {ClientPid,TS,Dep,Old,needAbort},
              NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, AbortedTransaction)
          end;
        {ok,_} ->
          io:format("###ACTION-DENIED: MESSAGE-LOST~n"),
          AbortedTransaction = {ClientPid,TS,Dep,Old,needAbort},
          NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, AbortedTransaction);
        needAbort ->
          io:format("###ACTION-DENIED: ABORTED~n"),
          NewTransactionList = TransactionList
      end,
	    server_loop(ClientList,StorePid,NewTransactionList,ServerTimestamp);
  {confirm, Client, Timestamp, ID} ->
      io:format("~n###CONFIRMED BY ~p~n", [Timestamp]),
      {_,_,Dep,Old,Status} = lists:keyfind(Timestamp, 2, TransactionList),
      %% Check transaction status, {ok, ID} -> proceed, else -> abort.
      case Status of
        {ok,ID} -> %% Check DEP, if not all committed -> wait, if one abort -> abort.
          %% Change status
          ConfirmedTransaction = {Client,Timestamp,Dep,Old,confirmed},
          NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, ConfirmedTransaction),
          %% Check dependencies
          io:format("###DEPENDENCIES: ~p~n", [sets:to_list(Dep)]),
          check_transaction_list_for_dep_status(sets:to_list(Dep), NewTransactionList, Client, Timestamp);
        {ok,_} -> %% Lost message, abort
          io:format("###CONFIRM-DENIED: LOST-MESSAGES~n"),
          NewTransactionList = TransactionList,
          self() ! {abortTransaction, Client, Timestamp};
        needAbort -> %% Abort status
          io:format("###CONFIRM-DENIED: NEED-ABORT~n"),
          NewTransactionList = TransactionList,
          self() ! {abortTransaction, Client, Timestamp}
      end,
      server_loop(ClientList,StorePid,NewTransactionList,ServerTimestamp);
  {commitTransaction, Client, Timestamp} ->
      %% Change status
      {_,_,Dep,Old,Status} = lists:keyfind(Timestamp, 2, TransactionList),
      case Status of
        committed -> %% Duplicate message, ignore it
          NewTransactionList = TransactionList;
        _notCommitted -> %% No yet committed, commit it
          CommittedTransaction = {Client,Timestamp,Dep,Old,committed},
          NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, CommittedTransaction),
          %% Notify client
          io:format("%%%COMMITTING-TRANSACTION: ~p~n", [{Client,Timestamp}]),
          Client ! {committed, self()},
          %% Broadcast update
          broadcast_event(NewTransactionList)
      end,
      server_loop(ClientList,StorePid,NewTransactionList,ServerTimestamp);
  {abortTransaction, Client, Timestamp} ->
    %% Change status
    {ClientPid,TS,Dep,Old,Status} = lists:keyfind(Timestamp, 2, TransactionList),
    case Status of
      aborted -> %% Duplicate message, ignore it
        NewTransactionList = TransactionList;
      _notAborted -> %% Not yet aborted, abort it
        AbortedTransaction = {ClientPid,TS,Dep,Old,aborted},
        NewTransactionList = lists:keyreplace(Timestamp, 2, TransactionList, AbortedTransaction),
        %% Revert any changes
        lists:foreach(fun({{OldVar, OldVal}, OldWTS}) ->
          StorePid ! {revert, {{OldVar, OldVal}, OldWTS, Timestamp}, self()} end
        , Old),
        %% Notify client
        io:format("%%%ABORTING-TRANSACTION: ~p~n", [{ClientPid,TS}]),
        Client ! {abort, self()},
        %% Broadcast update
        broadcast_event(NewTransactionList)
      end,
    server_loop(ClientList,StorePid,NewTransactionList,ServerTimestamp)
  after 50000 ->
	    case all_gone(ClientList) of
	      true -> exit(normal);
	      false -> server_loop(ClientList,StorePid,TransactionList,ServerTimestamp)
	    end
end.

%% - The values are maintained here
%% Entry = var,val,rts,wts
store_loop(ServerPid, Database) ->
    receive
	{print, ServerPid} ->
	    io:format("Database status:~n~p.~n", [Database]),
	    store_loop(ServerPid,Database);
  {{write,Var,NewVal}, NewTS, ServerPid} ->
          io:format("###WRITING BY ~p~n", [NewTS]),
          {_, Val, RTS, WTS} = lists:keyfind(Var, 1, Database),
      case testWrite(RTS,WTS,NewTS) of
        skip -> %% Thomas rule
          io:format("###SKIP-WRITE BY ~p~n", [NewTS]),
          UpdatedDatabase = Database,
          %% Signal server
          ServerPid ! {noWrite};
        proceed -> %% Safe to proceed
          io:format("###PROCEED-WRITE BY ~p~n", [NewTS]),
          %% Saving old values
          OldVal = {Var, Val},
          %% Update var's WTS
          NewEntry = {Var, NewVal, RTS, NewTS},
          UpdatedDatabase = lists:keyreplace(Var, 1, Database, NewEntry),
          %%Signal server
          ServerPid ! {writeOk, {OldVal, WTS}};
        abortWrite -> % A more recent thread is already relying on the old value
          io:format("Aborting write, another thread is relying on this value~n"),
          UpdatedDatabase = Database,
          ServerPid ! {abortAction}
      end,
      store_loop(ServerPid,UpdatedDatabase);
  {{read,Var}, TS, ServerPid} ->
      io:format("###READING BY ~p~n", [TS]),
      {_,Val,RTS,WTS} = lists:keyfind(Var, 1, Database),
      case testRead(WTS, TS) of
        true -> %read succesfull, keep going
          io:format("~p contains ~p.~n", [Var, {Val,RTS,WTS}]),
          %% Update var's RTS
          NewRTS = maximum(RTS,TS),
          NewEntry = {Var,Val,NewRTS,WTS},
          UpdatedDatabase = lists:keyreplace(Var, 1, Database, NewEntry),
          %%Signal server
          ServerPid ! {readOk, WTS};
        false -> % A more recent thread has overwritten the value
          io:format("Dirty read, aborting~n"),
          UpdatedDatabase = Database,
          %% Signal server
          ServerPid ! {abortAction}
      end,
      store_loop(ServerPid,UpdatedDatabase);
  {revert, {{OldVar, OldVal}, OldWTS, OldTimestamp}, ServerPid} ->
      {_,_,RTS,WTS} = lists:keyfind(OldVar, 1, Database),
      case OldTimestamp == WTS of
          true -> %% Last change made by us, revert
                NewEntry = {OldVar, OldVal, RTS, OldWTS},
                UpdatedDatabase = lists:keyreplace(OldVar, 1, Database, NewEntry);
          false -> %% Was updated more recently, do nothing
                UpdatedDatabase = Database
      end,
      store_loop(ServerPid,UpdatedDatabase);
  {_what, _whatAgain, ServerPid} ->
      io:format("Nonsense...~p and ~p~n", [_what, _whatAgain]),
      store_loop(ServerPid,Database)
    end.
%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Checks the dependencies of a transaction
%% Commits if all committed, aborts if one aborted or else it waits.
check_transaction_list_for_dep_status([], _, Client, TS) ->
  io:format(" - Everything is fine, now committing.~n"),
  self() ! {commitTransaction, Client, TS};
check_transaction_list_for_dep_status([Timestamp|DepRest], TransactionList, Client, TS) ->
  {ClientChecked,TSChecked,_,_,StatusChecked} = lists:keyfind(Timestamp, 2, TransactionList),
  io:format("###EVALUATING-DEPS~n"),
  case StatusChecked of
        {ok,_} ->
          io:format(" - ~p is still running, waiting...~n", [{ClientChecked, TSChecked}]);
        confirmed ->
          io:format(" - ~p is waiting to commit, waiting...~n", [{ClientChecked, TSChecked}]);
        needAbort ->
          io:format(" - ~p needs to abort, now aborting.~n", [{ClientChecked, TSChecked}]),
          self() ! {abortTransaction, Client, TS};
        aborted ->
          io:format(" - ~p has aborted, now aborting.~n", [{ClientChecked, TSChecked}]),
          self() ! {abortTransaction, Client, TS};
        committed ->
            check_transaction_list_for_dep_status(DepRest, TransactionList, Client, TS)
    end.

%% Function called by the server, prepares the waiting list and starts the broadcast
broadcast_event(TransactionList) ->
  io:format("~nPreparing waiting list...~n"),
  WaitingTransactionsList = lists:filter(fun({_,_,_,_,Status}) ->
    case Status of
      confirmed -> true;
      _notConfirmed -> false
    end
  end, TransactionList),
  broadcast_event(TransactionList, WaitingTransactionsList).
%% Broadcasts any commit/abortion by checking dependencies of confirmed transactions
broadcast_event(_, []) ->
  io:format("Nobody else is waiting.~n");
broadcast_event(TransactionList, [WaitingTransaction|WaitingTransactionsList]) ->
  {Client,TS,Dep,_,Status} = WaitingTransaction,
  io:format("###BROADCASTING FOR: ~p~n", [{Client,TS,Status}]),
  check_transaction_list_for_dep_status(sets:to_list(Dep), TransactionList, Client, TS),
  broadcast_event(TransactionList, WaitingTransactionsList).

%% - Tests if read or write operations can proceed
testRead(WTS, TS) -> (WTS =< TS).

testWrite(RTS,_,TS) when RTS > TS -> abortWrite;
testWrite(RTS,WTS,TS) when RTS =< TS, WTS > TS -> skip;
testWrite(_,_,_) -> proceed.

%% - Maximum function
maximum(A,B) when A >= B -> A;
maximum(A,B) when A < B -> B.

%% - Low level function to handle lists
%%TansactionList = [{ClientPid,TS,[Dep],[Old],status}, {...}]
%%Status keeps track of message number
add_transaction(Client,TS,T) -> [{Client,TS,sets:new(),[],{ok,0}}|T].

add_client(C,T) -> [C|T].

remove_client(_,[]) -> [];
remove_client(C, [C|T]) -> T;
remove_client(C, [H|T]) -> [H|remove_client(C,T)].

all_gone([]) -> true;
all_gone(_) -> false.
