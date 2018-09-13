%%%-------------------------------------------------------------------
%%% File    : mongoose_acc.erl
%%% Author  : Piotr Nosek <piotr.nosek@erlang-solutions.com>
%%% Author  : Bartlomiej Gorny <bartlomiej.gorny@erlang-solutions.com>
%%% Purpose : Mongoose accumulator implementation
%%% Created : 11 Sep 2018 by Piotr Nosek <piotr.nosek@erlang-solutions.com>
%%%
%%% NS:Key conventions:
%%% * hook:result should be used to return hook processing result
%%% * iq:* contains useful IQ metadata but must be provided by mongoose_iq.erl
%%%-------------------------------------------------------------------
-module(mongoose_acc).
-author("bartek").
-author("piotr.nosek@erlang-solutions.com").

-include("jlib.hrl").
-include("mongoose.hrl").

%% API
-export([new/1]).
-export([lserver/1, send_result/1, element/1, to_jid/1, from_jid/1, stanza_type/1, stanza_ref/1]).
-export([update_stanza/2]).
-export([set/4, set/5, append/4, append/5, get/3, get/4, delete/3]).
-export([strip/2]).
%% Debug API
-export([dump/1]).

-type location() :: {Module :: module(), Function :: atom(), Line :: pos_integer()}.
-type stanza_metadata() :: #{
        element => exml:element(),
        from_jid => jid:jid(),
        to_jid => jid:jid(),
        type => binary()
       }.

%% if it is defined as -opaque then dialyzer fails
-type t() :: #{
        mongoose_acc => true,
        ref => reference(),
        timestamp => erlang:timestamp(),
        origin_pid => pid(),
        origin_location => location(),
        from_jid => jid:jid(),
        to_jid => jid:jid(),
        lserver => jid:lserver(),
        non_strippable => sets:set(ns_key()),
        origin_stanza => stanza_metadata(),
        stanza => stanza_metadata()
       }.
-export_type([t/0]).

-type new_acc_params() :: #{
        location => location(),
        lserver => jid:lserver(),
        element => exml:element(), % optional
        from_jid => jid:jid(), % optional
        to_jid => jid:jid() % optional
       }.

-type new_stanza_params() :: #{
        element => exml:element(),
        from_jid => jid:jid(), % optional
        to_jid => jid:jid() % optional
       }.

-type ns_key() :: {NS :: any(), Key :: any()}.

-type strippable() :: boolean() | undefined.

%% --------------------------------------------------------
%% API
%% --------------------------------------------------------

-spec new(Params :: new_acc_params()) -> t().
new(#{ location := Location, lserver := LServer } = Params) ->
    Stanza = stanza_from_params(Params),
    #{
      mongoose_acc => true,
      ref => make_ref(),
      timestamp => os:timestamp(),
      origin_pid => self(),
      origin_location => Location,
      origin_stanza => Stanza, % Stanza that triggered the processing
      stanza => Stanza,
      lserver => LServer,
      non_strippable => sets:new()
     }.

lserver(#{ mongoose_acc := true, lserver := LServer }) ->
    LServer.

send_result(#{ mongoose_acc := true, send_result := SR }) ->
    hd(SR).

element(#{ mongoose_acc := true, stanza := #{ element := El } }) ->
    El;
element(#{ mongoose_acc := true }) ->
    undefined.

from_jid(#{ mongoose_acc := true, stanza := #{ from_jid := FromJID } }) ->
    FromJID;
from_jid(#{ mongoose_acc := true }) ->
    undefined.

to_jid(#{ mongoose_acc := true, stanza := #{ to_jid := ToJID } }) ->
    ToJID;
to_jid(#{ mongoose_acc := true }) ->
    undefined.

stanza_type(#{ mongoose_acc := true, stanza := #{ type := Type } }) ->
    Type;
stanza_type(#{ mongoose_acc := true }) ->
    undefined.

stanza_ref(#{ mongoose_acc := true, stanza := #{ ref := StanzaRef } }) ->
    StanzaRef;
stanza_ref(#{ mongoose_acc := true }) ->
    undefined.

-spec update_stanza(NewStanzaParams :: new_stanza_params(), Acc :: t()) -> t().
update_stanza(NewStanzaParams, #{ mongoose_acc := true } = Acc) ->
    Acc#{ stanza := stanza_from_params(NewStanzaParams) }.

-spec set(Namespace :: any(), K :: any(), V :: any(), Acc :: t()) -> t().
set(NS, K, V, Acc) ->
    set(NS, K, V, undefined, Acc).
 
-spec set(Namespace :: any(), K :: any(), V :: any(), IsStrippable :: strippable(), Acc :: t()) ->
    t().
set(NS, K, V, undefined, #{ mongoose_acc := true } = Acc) ->
    Acc#{ {NS, K} => V };
set(NS, K, V, IsStrippable, #{ mongoose_acc := true, non_strippable := NonStrippable } = Acc) ->
    Key = {NS, K},
    NewNonStrippable = case IsStrippable of
                           true -> sets:del_element(Key, NonStrippable);
                           false -> sets:add_element(Key, NonStrippable)
                       end,
    Acc#{ Key => V, non_strippable => NewNonStrippable }.

-spec append(NS :: any(), Key :: any(), Val :: any() | [any()], Acc :: t()) -> t().
append(NS, Key, Val, Acc) ->
    append(NS, Key, Val, undefined, Acc).

-spec append(NS :: any(),
            Key :: any(),
            Val :: any() | [any()],
            IsStrippable :: strippable(),
            Acc :: t()) -> t().
append(NS, Key, Val, IsStrippable, Acc) ->
    OldVal = get(NS, Key, [], Acc),
    set(NS, Key, append(OldVal, Val), IsStrippable, Acc).

get(NS, K, #{ mongoose_acc := true } = Acc) ->
    maps:get({NS, K}, Acc).

get(NS, K, Default, #{ mongoose_acc := true } = Acc) ->
    maps:get({NS, K}, Acc, Default).

delete(NS, K, #{ mongoose_acc := true, non_strippable := NonStrippable } = Acc0) ->
    Key = {NS, K},
    Acc1 = maps:remove(Key, Acc0),
    Acc1#{ non_strippable => sets:del_element(Key, NonStrippable) }.

%% Doesn't use 'location' param
-spec strip(ParamsToOverwrite :: new_acc_params(), Acc :: t()) -> t().
strip(#{ lserver := NewLServer } = Params,
      #{ mongoose_acc := true, non_strippable := NonStrippable } = Acc) ->
    NonStrippableL = sets:to_list(NonStrippable),
    StrippedAcc = maps:with(NonStrippableL ++ default_non_strippable(), Acc),
    StrippedAcc#{ lserver => NewLServer, stanza => stanza_from_params(Params) }.

%% --------------------------------------------------------
%% Debug API
%% --------------------------------------------------------

-spec dump(t()) -> ok.
dump(Acc) ->
    lists:foreach(fun(K) ->
                          ?ERROR_MSG("~p = ~p", [K, maps:get(K, Acc)])
                  end, lists:sort(maps:keys(Acc))).

%% --------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------

-spec stanza_from_params(Params :: new_acc_params()) -> stanza_metadata().
stanza_from_params(#{ element := El } = Params) ->
    FromJID = case Params of
                  #{ from_jid := FromJID0 } -> FromJID0;
                  _ -> #jid{} = jid:from_binary(exml_query:attr(El, <<"from">>))
              end,
    ToJID = case Params of
                  #{ to_jid := ToJID0 } -> ToJID0;
                  _ -> #jid{} = jid:from_binary(exml_query:attr(El, <<"to">>))
              end,
    #{
      element => El,
      from_jid => FromJID,
      to_jid => ToJID,
      type => exml_query:attrs(El, <<"type">>),
      ref => make_ref()
     }.

-spec default_non_strippable() -> [atom()].
default_non_strippable() ->
    [
     mongoose_acc,
     ref,
     timestamp,
     origin_pid,
     origin_location,
     origin_stanza,
     non_strippable
    ].

-spec append(OldVal :: list(), Val :: list() | any()) -> list().
append(OldVal, Val) when is_list(OldVal), is_list(Val) -> OldVal ++ Val;
append(OldVal, Val) when is_list(OldVal) -> [Val | OldVal].

