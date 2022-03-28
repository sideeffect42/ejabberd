%%%----------------------------------------------------------------------
%%% File    : mod_conversejs.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Serve simple page for Converse.js XMPP web browser client
%%% Created :  8 Nov 2021 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2022   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_conversejs).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, reload/3, process/2, depends/2,
         mod_opt_type/1, mod_options/1, mod_doc/0]).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("translate.hrl").
-include("ejabberd_web_admin.hrl").

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

process([], #request{method = 'GET', host = Host, raw_path = RawPath}) ->
    DomainRaw = gen_mod:get_module_opt(Host, ?MODULE, default_domain),
    Domain = misc:expand_keyword(<<"@HOST@">>, DomainRaw, Host),
    Script = get_file_url(Host, conversejs_script,
                          <<RawPath/binary, "/converse.min.js">>,
                          <<"https://cdn.conversejs.org/dist/converse.min.js">>),
    CSS = get_file_url(Host, conversejs_css,
                       <<RawPath/binary, "/converse.min.css">>,
                       <<"https://cdn.conversejs.org/dist/converse.min.css">>),
    Init = [{<<"discover_connection_methods">>, false},
            {<<"jid">>, Domain},
            {<<"default_domain">>, Domain},
            {<<"domain_placeholder">>, Domain},
            {<<"registration_domain">>, Domain},
            {<<"assets_path">>, RawPath},
            {<<"i18n">>, ejabberd_option:language(Host)},
            {<<"view_mode">>, <<"fullscreen">>}],
    Init2 =
        case gen_mod:get_module_opt(Host, ?MODULE, websocket_url) of
            undefined -> Init;
            WSURL -> [{<<"websocket_url">>, WSURL} | Init]
        end,
    Init3 =
        case gen_mod:get_module_opt(Host, ?MODULE, bosh_service_url) of
            undefined -> Init2;
            BoshURL -> [{<<"bosh_service_url">>, BoshURL} | Init2]
        end,
    {200, [html],
     [<<"<!DOCTYPE html>">>,
      <<"<html>">>,
      <<"<head>">>,
      <<"<meta charset='utf-8'>">>,
      <<"<link rel='stylesheet' type='text/css' media='screen' href='">>,
      fxml:crypt(CSS), <<"'>">>,
      <<"<script src='">>, fxml:crypt(Script), <<"' charset='utf-8'></script>">>,
      <<"</head>">>,
      <<"<body>">>,
      <<"<script>">>,
      <<"converse.initialize(">>, jiffy:encode({Init3}), <<");">>,
      <<"</script>">>,
      <<"</body>">>,
      <<"</html>">>]};
process(LocalPath, #request{host = Host}) ->
    case is_served_file(LocalPath) of
        true -> serve(Host, LocalPath);
        false -> ejabberd_web:error(not_found)
    end.

%%----------------------------------------------------------------------
%% File server
%%----------------------------------------------------------------------

is_served_file([<<"converse.min.js">>]) -> true;
is_served_file([<<"converse.min.css">>]) -> true;
is_served_file([<<"converse.min.js.map">>]) -> true;
is_served_file([<<"converse.min.css.map">>]) -> true;
is_served_file([<<"emojis.js">>]) -> true;
is_served_file([<<"locales">>, _]) -> true;
is_served_file([<<"locales">>, <<"dayjs">>, _]) -> true;
is_served_file([<<"webfonts">>, _]) -> true;
is_served_file(_) -> false.

serve(Host, LocalPath) ->
    case get_conversejs_resources(Host) of
        undefined -> ejabberd_web:error(not_found);
        MainPath -> serve2(LocalPath, MainPath)
    end.

get_conversejs_resources(Host) ->
    Opts = gen_mod:get_module_opts(Host, ?MODULE),
    mod_conversejs_opt:conversejs_resources(Opts).

%% Copied from mod_muc_log_http.erl

serve2(LocalPathBin, MainPathBin) ->
    LocalPath = [binary_to_list(LPB) || LPB <- LocalPathBin],
    MainPath = binary_to_list(MainPathBin),
    FileName = filename:join(filename:split(MainPath) ++ LocalPath),
    case file:read_file(FileName) of
        {ok, FileContents} ->
            ?DEBUG("Delivering content.", []),
            {200,
             [{<<"Content-Type">>, content_type(FileName)}],
             FileContents};
        {error, eisdir} ->
            {403, [], "Forbidden"};
        {error, Error} ->
            ?DEBUG("Delivering error: ~p", [Error]),
            case Error of
                eacces -> {403, [], "Forbidden"};
                enoent -> {404, [], "Not found"};
                _Else -> {404, [], atom_to_list(Error)}
            end
    end.

content_type(Filename) ->
    case string:to_lower(filename:extension(Filename)) of
        ".css"  -> "text/css";
        ".js"   -> "text/javascript";
        ".map"  -> "application/json";
        ".ttf"  -> "font/ttf";
        ".woff"  -> "font/woff";
        ".woff2"  -> "font/woff2"
    end.

%%----------------------------------------------------------------------
%% Options parsing
%%----------------------------------------------------------------------

get_file_url(Host, Option, Filename, Default) ->
    FileRaw = case gen_mod:get_module_opt(Host, ?MODULE, Option) of
                  auto -> get_auto_file_url(Host, Filename, Default);
                  F -> F
              end,
    misc:expand_keyword(<<"@HOST@">>, FileRaw, Host).

get_auto_file_url(Host, Filename, Default) ->
    case get_conversejs_resources(Host) of
        undefined -> Default;
        _ -> Filename
    end.

%%----------------------------------------------------------------------
%%
%%----------------------------------------------------------------------

mod_opt_type(bosh_service_url) ->
    econf:either(undefined, econf:binary());
mod_opt_type(websocket_url) ->
    econf:either(undefined, econf:binary());
mod_opt_type(conversejs_resources) ->
    econf:either(undefined, econf:directory());
mod_opt_type(conversejs_script) ->
    econf:binary();
mod_opt_type(conversejs_css) ->
    econf:binary();
mod_opt_type(default_domain) ->
    econf:binary().

mod_options(_) ->
    [{bosh_service_url, undefined},
     {websocket_url, undefined},
     {default_domain, <<"@HOST@">>},
     {conversejs_resources, undefined},
     {conversejs_script, auto},
     {conversejs_css, auto}].

mod_doc() ->
    #{desc =>
          [?T("This module serves a simple page for the "
              "https://conversejs.org/[Converse] XMPP web browser client."), "",
           ?T("This module is available since ejabberd 21.12."), "",
           ?T("To use this module, in addition to adding it to the 'modules' "
              "section, you must also enable it in 'listen' -> 'ejabberd_http' -> "
              "http://../listen-options/#request-handlers[request_handlers]."), "",
           ?T("You must also setup either the option 'websocket_url' or 'bosh_service_url'."), "",
           ?T("When 'conversejs_css' and 'conversejs_script' are 'auto', "
              "by default they point to the public Converse client.")
          ],
     example =>
         ["listen:",
          "  -",
          "    port: 5280",
          "    module: ejabberd_http",
          "    request_handlers:",
          "      /websocket: ejabberd_http_ws",
          "      /conversejs: mod_conversejs",
          "",
          "modules:",
          "  mod_conversejs:",
          "    conversejs_resources: \"/home/ejabberd/conversejs-9.0.0/package/dist\"",
          "    websocket_url: \"ws://example.org:5280/websocket\""],
      opts =>
          [{websocket_url,
            #{value => ?T("WebSocketURL"),
              desc =>
                  ?T("A WebSocket URL to which Converse.js can connect to.")}},
           {bosh_service_url,
            #{value => ?T("BoshURL"),
              desc =>
                  ?T("BOSH service URL to which Converse.js can connect to.")}},
           {default_domain,
            #{value => ?T("Domain"),
              desc =>
                  ?T("Specify a domain to act as the default for user JIDs. "
                     "The keyword '@HOST@' is replaced with the hostname. "
                     "The default value is '@HOST@'.")}},
           {conversejs_resources,
            #{value => ?T("Path"),
              desc =>
                  ?T("Local path to the Converse files. "
                     "If not set, the public Converse client will be used instead.")}},
           {conversejs_script,
            #{value => ?T("auto | URL"),
              desc =>
                  ?T("Converse main script URL. "
                     "The keyword '@HOST@' is replaced with the hostname. "
                     "The default value is 'auto'.")}},
           {conversejs_css,
            #{value => ?T("auto | URL"),
              desc =>
                  ?T("Converse CSS URL. "
                     "The keyword '@HOST@' is replaced with the hostname. "
                     "The default value is 'auto'.")}}]
     }.
