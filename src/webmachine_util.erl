%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2008 Basho Technologies
%% (guess_mime/1 derived from code copyright 2007 Mochi Media, Inc.)
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc Utilities for parsing, quoting, and negotiation.

-module(webmachine_util).
-export([guess_mime/1]).
-export([convert_request_date/1, compare_ims_dates/2]).
-export([choose_media_type/2]).
-export([choose_charset/2]).
-export([choose_encoding/2]).
-export([now_diff_milliseconds/2]).
-export([media_type_to_detail/1,
         quoted_string/1,
         split_quoted_strings/1]).

-ifdef(TEST).
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.

convert_request_date(Date) ->
    try 
        case httpd_util:convert_request_date(Date) of
            ReqDate -> ReqDate
        end
    catch
        error:_ -> bad_date
    end.

%% returns true if D1 > D2
compare_ims_dates(D1, D2) ->
    GD1 = calendar:datetime_to_gregorian_seconds(D1),
    GD2 = calendar:datetime_to_gregorian_seconds(D2),
    GD1 > GD2.

%% @spec guess_mime(string()) -> string()
%% @doc  Guess the mime type of a file by the extension of its filename.
guess_mime(File) ->
    case filename:extension(File) of
        ".html" ->
            "text/html";
        ".xhtml" ->
            "application/xhtml+xml";
        ".xml" ->
            "application/xml";
        ".css" ->
            "text/css";
        ".js" ->
            "application/x-javascript";
        ".jpg" ->
            "image/jpeg";
        ".jpeg" ->
            "image/jpeg";
        ".gif" ->
            "image/gif";
        ".png" ->
            "image/png";
        ".ico" ->
            "image/x-icon";
        ".swf" ->
            "application/x-shockwave-flash";
        ".zip" ->
            "application/zip";
        ".bz2" ->
            "application/x-bzip2";
        ".gz" ->
            "application/x-gzip";
        ".tar" ->
            "application/x-tar";
        ".tgz" ->
            "application/x-gzip";
        ".htc" ->
            "text/x-component";
        ".manifest" ->
            "text/cache-manifest";
        ".svg" ->
            "image/svg+xml";
        _ ->
            "text/plain"
    end.

choose_media_type(Provided,AcceptHead) ->
    % Return the Content-Type we will serve for a request.
    % If there is no acceptable/available match, return the atom "none".
    % AcceptHead is the value of the request's Accept header
    % Provided is a list of media types the resource can provide.
    %  each is either a string e.g. -- "text/html"
    %   or a string and parameters e.g. -- {"text/html",[{level,1}]}
    % (the plain string case with no parameters is much more common)
    Requested = accept_header_to_media_types(AcceptHead),
    Prov1 = normalize_provided(Provided),
    choose_media_type1(Prov1,Requested).
choose_media_type1(_Provided,[]) ->
    none;
choose_media_type1(Provided,[H|T]) ->
    {_Pri,Type,Params} = H,
    case media_match({Type,Params}, Provided) of
        [] -> choose_media_type1(Provided,T);
        [{CT_T,CT_P}|_] -> format_content_type(CT_T,CT_P)
    end.

media_match(_,[]) -> [];
media_match({"*/*",[]},[H|_]) -> [H];
media_match({Type,Params},Provided) ->
    [{T1,P1} || {T1,P1} <- Provided,
                media_type_match(Type,T1), media_params_match(Params,P1)].
media_type_match(Req,Prov) ->
    case Req of
        "*" -> % might as well not break for lame (Gomez) clients
            true;
        "*/*" ->
            true;
        Prov ->
            true;
        _ ->
            [R1|R2] = string:tokens(Req,"/"),
            [P1,_P2] = string:tokens(Prov,"/"),
            case R2 of
                ["*"] ->
                    case R1 of
                        P1 -> true;
                        _ -> false
                    end;
                _ -> false
            end
    end.
media_params_match(Req,Prov) ->
    lists:sort(Req) =:= lists:sort(Prov).

prioritize_media(TyParam) ->
    {Type, Params} = TyParam,
    prioritize_media(Type,Params,[]).    
prioritize_media(Type,Params,Acc) ->
    case Params of
        [] ->
            {1, Type, Acc};
        _ ->
            [{Tok,Val}|Rest] = Params,
            case Tok of
                "q" ->
                    QVal = case Val of
                               "1" ->
                                   1;
                               [$.|_] ->
                                   %% handle strange FeedBurner Accept
                                   list_to_float([$0|Val]); 
                               _ -> list_to_float(Val)
                           end,
                    {QVal, Type, Rest ++ Acc};
                _ ->
                    prioritize_media(Type,Rest,[{Tok,Val}|Acc])
            end
    end.

media_type_to_detail(MType) ->
    [CType|Params] = string:tokens(MType, ";"),
    MParams = [list_to_tuple([string:strip(KV) || KV <- string:tokens(X,"=")])
                || X <- Params],
    {CType, MParams}.                       

accept_header_to_media_types(HeadVal) ->
    % given the value of an accept header, produce an ordered list
    % based on the q-values.  Results are [{Type,Params}] with the
    % head of the list being the highest-priority requested type.
    try
        lists:reverse(lists:keysort(1,
         [prioritize_media(media_type_to_detail(MType)) ||
             MType <- [string:strip(X) || X <- string:tokens(HeadVal, ",")]]))
    catch _:_ -> []
    end.

normalize_provided(Provided) ->
    [normalize_provided1(X) || X <- Provided].
normalize_provided1(Type) when is_list(Type) -> {Type, []};
normalize_provided1({Type,Params}) -> {Type, Params}.

format_content_type(Type,[]) -> Type;
format_content_type(Type,[H|T]) -> format_content_type(Type ++ "; " ++ H, T).

choose_charset(CSets, AccCharHdr) -> do_choose(CSets, AccCharHdr, "ISO-8859-1").

choose_encoding(Encs, AccEncHdr) -> do_choose(Encs, AccEncHdr, "identity").

do_choose(Choices, Header, Default) ->
    Accepted = build_conneg_list(string:tokens(Header, ",")),
    DefaultPrio = [P || {P,C} <- Accepted, C =:= Default],
    StarPrio = [P || {P,C} <- Accepted, C =:= "*"],
    DefaultOkay = case DefaultPrio of
        [] ->
            case StarPrio of
                [0.0] -> no;
                _ -> yes
            end;
        [0.0] -> no;
        _ -> yes
    end,
    AnyOkay = case StarPrio of
        [] -> no;
        [0.0] -> no;
        _ -> yes
    end,
    do_choose(Default, DefaultOkay, AnyOkay, Choices, Accepted).
do_choose(_Default, _DefaultOkay, _AnyOkay, [], []) ->
    none;
do_choose(_Default, _DefaultOkay, _AnyOkay, [], _Accepted) ->
    none;
do_choose(Default, DefaultOkay, AnyOkay, Choices, []) ->
    case AnyOkay of
        yes -> hd(Choices);
        no ->
            case DefaultOkay of
                yes ->
                    case lists:member(Default, Choices) of
                        true -> Default;
                        _ -> none
                    end;
                no -> none
            end
    end;
do_choose(Default, DefaultOkay, AnyOkay, Choices, [AccPair|AccRest]) ->
    {Prio, Acc} = AccPair,
    case Prio of
        0.0 ->
            do_choose(Default, DefaultOkay, AnyOkay,
                            lists:delete(Acc, Choices), AccRest);
        _ ->
            LAcc = string:to_lower(Acc),
            LChoices = [string:to_lower(X) || X <- Choices],
            % doing this a little more work than needed in
            % order to be easily insensitive but preserving
            case lists:member(LAcc, LChoices) of
                true -> 
                    hd([X || X <- Choices,
                             string:to_lower(X) =:= LAcc]);
                false -> do_choose(Default, DefaultOkay, AnyOkay,
                                         Choices, AccRest)
            end
    end.

build_conneg_list(AccList) ->
    build_conneg_list(AccList, []).
build_conneg_list([], Result) -> lists:reverse(lists:sort(Result));
build_conneg_list([Acc|AccRest], Result) ->
    XPair = list_to_tuple([string:strip(X) || X <- string:tokens(Acc, ";")]),
    Pair = case XPair of
        {Choice, "q=" ++ PrioStr} ->
            case PrioStr of
                "0" -> {0.0, Choice};
                "1" -> {1.0, Choice};
                [$.|_] ->
                    %% handle strange FeedBurner Accept
                    {list_to_float([$0|PrioStr]), Choice};
                _ -> {list_to_float(PrioStr), Choice}
            end;
        {Choice} ->
            {1.0, Choice}
    end,
    build_conneg_list(AccRest,[Pair|Result]).


quoted_string([$" | _Rest] = Str) ->
    Str;
quoted_string(Str) ->
    escape_quotes(Str, [$"]).                % Initialize Acc with opening quote

escape_quotes([], Acc) ->
    lists:reverse([$" | Acc]);               % Append final quote
escape_quotes([$\\, Char | Rest], Acc) ->
    escape_quotes(Rest, [Char, $\\ | Acc]);  % Any quoted char should be skipped
escape_quotes([$" | Rest], Acc) ->
    escape_quotes(Rest, [$", $\\ | Acc]);    % Unquoted quotes should be escaped
escape_quotes([Char | Rest], Acc) ->
    escape_quotes(Rest, [Char | Acc]).

split_quoted_strings(Str) ->
    split_quoted_strings(Str, []).

split_quoted_strings([], Acc) ->
    lists:reverse(Acc);
split_quoted_strings([$" | Rest], Acc) ->
    {Str, Cont} = unescape_quoted_string(Rest, []),
    split_quoted_strings(Cont, [Str | Acc]);
split_quoted_strings([_Skip | Rest], Acc) ->
    split_quoted_strings(Rest, Acc).

unescape_quoted_string([], Acc) ->
    {lists:reverse(Acc), []};
unescape_quoted_string([$\\, Char | Rest], Acc) -> % Any quoted char should be unquoted
    unescape_quoted_string(Rest, [Char | Acc]);
unescape_quoted_string([$" | Rest], Acc) ->        % Quote indicates end of this string
    {lists:reverse(Acc), Rest};
unescape_quoted_string([Char | Rest], Acc) ->
    unescape_quoted_string(Rest, [Char | Acc]).


%% @type now() = {MegaSecs, Secs, MicroSecs}

%% This is faster than timer:now_diff() because it does not use bignums.
%% But it returns *milliseconds*  (timer:now_diff returns microseconds.)
%% From http://www.erlang.org/ml-archive/erlang-questions/200205/msg00027.html

%% @doc  Compute the difference between two now() tuples, in milliseconds.
%% @spec now_diff_milliseconds(now(), now()) -> integer()
now_diff_milliseconds({M,S,U}, {M,S1,U1}) ->
    ((S-S1) * 1000) + ((U-U1) div 1000);
now_diff_milliseconds({M,S,U}, {M1,S1,U1}) ->
    ((M-M1)*1000000+(S-S1))*1000 + ((U-U1) div 1000).

%%
%% TEST
%%
-ifdef(TEST).

choose_media_type_test() ->
    Provided = "text/html",
    ShouldMatch = ["*", "*/*", "text/*", "text/html"],
    WantNone = ["foo", "text/xml", "application/*", "foo/bar/baz"],
    [ ?assertEqual(Provided, choose_media_type([Provided], I))
      || I <- ShouldMatch ],
    [ ?assertEqual(none, choose_media_type([Provided], I))
      || I <- WantNone ].

choose_media_type_qval_test() ->
    Provided = ["text/html", "image/jpeg"],
    HtmlMatch = ["image/jpeg;q=0.5, text/html",
                 "text/html, image/jpeg; q=0.5",
                 "text/*; q=0.8, image/*;q=0.7",
                 "text/*;q=.8, image/*;q=.7"], %% strange FeedBurner format
    JpgMatch = ["image/*;q=1, text/html;q=0.9",
                "image/png, image/*;q=0.3"],
    [ ?assertEqual("text/html", choose_media_type(Provided, I))
      || I <- HtmlMatch ],
    [ ?assertEqual("image/jpeg", choose_media_type(Provided, I))
      || I <- JpgMatch ].

convert_request_date_test() ->
    ?assertMatch({{_,_,_},{_,_,_}},
                 convert_request_date("Wed, 30 Dec 2009 14:39:02 GMT")),
    ?assertMatch(bad_date,
                 convert_request_date(<<"does not handle binaries">>)).

compare_ims_dates_test() ->
    Late = {{2009,12,30},{14,39,02}},
    Early = {{2009,12,30},{13,39,02}},
    ?assertEqual(true, compare_ims_dates(Late, Early)),
    ?assertEqual(false, compare_ims_dates(Early, Late)).

guess_mime_test() ->
    TextTypes = [".html",".css",".htc",".manifest",".txt"],
    AppTypes = [".xhtml",".xml",".js",".swf",".zip",".bz2",
                ".gz",".tar",".tgz"],
    ImgTypes = [".jpg",".jpeg",".gif",".png",".ico",".svg"],
    ?assertEqual([], [ T || T <- TextTypes,
                            1 /= string:str(guess_mime(T),"text/") ]),
    ?assertEqual([], [ T || T <- AppTypes,
                            1 /= string:str(guess_mime(T),"application/") ]),
    ?assertEqual([], [ T || T <- ImgTypes,
                            1 /= string:str(guess_mime(T),"image/") ]).


now_diff_milliseconds_test() ->
    Late = {10, 10, 10},
    Early1 = {10, 9, 9},
    Early2 = {9, 9, 9},
    ?assertEqual(1000, now_diff_milliseconds(Late, Early1)),
    ?assertEqual(1000001000, now_diff_milliseconds(Late, Early2)).

-ifdef(EQC).

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

prop_quoted_string() ->
    ?FORALL(String0, non_empty(list(oneof([char(), $", [$\\, char()]]))),
            begin
                String = lists:flatten(String0),

                Quoted = quoted_string(String),
                case String of
                    [$" | _] ->
                        ?assertEqual(String, Quoted),
                        true;
                    _ ->
                        %% Properties:
                        %% * strings must begin/end with quote
                        %% * All other quotes should be escaped
                        ?assertEqual($", hd(Quoted)),
                        ?assertEqual($", lists:last(Quoted)),
                        Partial = lists:reverse(tl(lists:reverse(tl(Quoted)))),
                        case check_quote(Partial) of
                            true ->
                                true;
                            false ->
                                io:format(user, "----\n", []),
                                io:format(user, "In: ~p\n", [[integer_to_list(C) || C <- String]]),
                                io:format(user, "Out: ~p\n", [[integer_to_list(C) || C <- Quoted]]),
                                false
                        end
                end
            end).

check_quote([]) ->
    true;
check_quote([$\\, _Any | Rest]) ->
    check_quote(Rest);
check_quote([$" | _Rest]) ->
    false;
check_quote([_Any | Rest]) ->
    check_quote(Rest).

prop_quoted_string_test() ->
    ?assert(eqc:quickcheck(?QC_OUT(prop_quoted_string()))).

-endif. % EQC
-endif. % TEST
