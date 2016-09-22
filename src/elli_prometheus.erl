%% @doc Elli middleware for collecting stats via Prometheus.
%% @author Eric Bailey
%% @version 0.0.1
%% @reference <a href="https://prometheus.io">Prometheus</a>
%% @copyright 2016 Eric Bailey
-module(elli_prometheus).
-author("Eric Bailey").

-behaviour(elli_handler).

%% elli_handler callbacks
-export([handle/2,handle_event/3]).

%% Macros.
-define(TOTAL, http_requests_total).
-define(REQUEST_DURATION, http_request_duration_microseconds).
-define(REQUEST_HEADERS_DURATION, http_request_headers_microseconds).
-define(REQUEST_BODY_DURATION, http_request_body_microseconds).
-define(REQUEST_USER_DURATION, http_request_user_microseconds).
-define(RESPONSE_SEND_DURATION, http_response_send_microseconds).

-define(RESPONSE_SIZE, http_response_size_bytes).
-define(RESPONSE_HEADERS_SIZE, http_response_headers_size_bytes).
-define(RESPONSE_BODY_SIZE, http_response_body_size_bytes).

%%%===================================================================
%%% elli_handler callbacks
%%%===================================================================

%% @doc Handle requests to `/metrics' and ignore all others.
%% TODO: Describe format.
%% TODO: Add links to Prometheus and Prometheus.erl docs.
handle(Req, _Config) ->
  Path = elli_prometheus_config:path(),
  case {elli_request:method(Req),elli_request:raw_path(Req)} of
    {'GET', Path} -> format_metrics();
    _             -> ignore
  end.

%% @doc On `elli_startup', register two metrics, a counter `http_requests_total'
%% and a histogram `http_request_duration_microseconds'. Then, on
%% `request_complete', {@link prometheus_counter:inc/2. increment}
%% `http_requests_total' and {@link prometheus_histogram:observe/3. observe}
%% `http_request_duration_microseconds'. Ignore all other events.
handle_event(request_complete, Args, Config) ->
  handle_full_response(request_complete, Args, Config);
handle_event(chunk_complete, Args, Config) ->
  handle_full_response(chunk_complete, Args, Config);
handle_event(elli_startup, _Args, _Config) ->
  Labels        = elli_prometheus_config:labels(),
  Buckets       = elli_prometheus_config:duration_buckets(),
  RequestCount  = metric(?TOTAL, Labels, "request count"),
  RequestDuration = metric(?REQUEST_DURATION, [response_type | Labels], Buckets,
                           " latencies in microseconds"),
  RequestHeadersDuration = metric(?REQUEST_HEADERS_DURATION,
                                  Labels, Buckets,
                                  "time spent receiving and parsing headers"),
  RequestBodyDuration = metric(?REQUEST_BODY_DURATION,
                               Labels, Buckets,
                               "time spent receiving and parsing body"),
  RequestUserDuration = metric(?REQUEST_USER_DURATION,
                               Labels, Buckets,
                               "time spent in user callback"),
  ResponseSendDuration = metric(?RESPONSE_SEND_DURATION,
                                [response_type | Labels], Buckets,
                                "time spent sending reply"),
  ResponseSize = metric(?RESPONSE_SIZE,
                        [response_type | Labels],
                        "total response size"),
  ResponseHeaders = metric(?RESPONSE_HEADERS_SIZE,
                           [response_type | Labels],
                           "response headers size"),
  ResponseBody = metric(?RESPONSE_BODY_SIZE,
                        [response_type | Labels],
                        "response body size"),
  prometheus_counter:declare(RequestCount),
  prometheus_histogram:declare(RequestDuration),
  prometheus_histogram:declare(RequestHeadersDuration),
  prometheus_histogram:declare(RequestBodyDuration),
  prometheus_histogram:declare(RequestUserDuration),

  prometheus_histogram:declare(ResponseSendDuration),
  prometheus_summary:declare(ResponseSize),
  prometheus_summary:declare(ResponseHeaders),
  prometheus_summary:declare(ResponseBody),
  ok;
handle_event(_Event, _Args, _Config) -> ok.

%%%===================================================================
%%% Private functions
%%%===================================================================

handle_full_response(Type, [Req,Code,_Hs,_B,{Timings, Sizes}], _Config) ->
  Labels = labels(Req, Code),
  TypedLabels = case Type of
                  request_complete -> ["full" | Labels];
                  chunk_complete -> ["chunks" | Labels];
                  _ -> Labels
                end,
  prometheus_counter:inc(?TOTAL, Labels),

  prometheus_histogram:observe(?REQUEST_DURATION, TypedLabels,
                               duration(Timings, request)),
  prometheus_histogram:observe(?REQUEST_HEADERS_DURATION, Labels,
                               duration(Timings, headers)),
  prometheus_histogram:observe(?REQUEST_BODY_DURATION, Labels,
                               duration(Timings, body)),
  prometheus_histogram:observe(?REQUEST_USER_DURATION, Labels,
                               duration(Timings, user)),
  prometheus_histogram:observe(?RESPONSE_SEND_DURATION, TypedLabels,
                               duration(Timings, send)),

  prometheus_summary:observe(?RESPONSE_SIZE, TypedLabels,
                             size(Sizes, response)),
  prometheus_summary:observe(?RESPONSE_HEADERS_SIZE, TypedLabels,
                             size(Sizes, response_headers)),
  prometheus_summary:observe(?RESPONSE_BODY_SIZE, TypedLabels,
                             size(Sizes, response_body)),
  ok.

format_metrics() ->
  Format = elli_prometheus_config:format(),
  {ok,[{<<"Content-Type">>,Format:content_type()}],Format:format()}.

duration(Timings, request) ->
  duration(request_start, request_end, Timings);
duration(Timings, headers) ->
  duration(headers_start, headers_end, Timings);
duration(Timings, body) ->
  duration(body_start, body_end, Timings);
duration(Timings, user) ->
  duration(user_start, user_end, Timings);
duration(Timings, send) ->
  duration(send_start, send_end, Timings).

duration(StartKey, EndKey, Timings) ->
  Start = proplists:get_value(StartKey, Timings),
  End   = proplists:get_value(EndKey, Timings),
  End - Start.

size(Sizes, response) ->
  size(Sizes, response_headers) +
    size(Sizes, response_body);
size(Sizes, response_headers) ->
  proplists:get_value(resp_headers, Sizes);
size(Sizes, response_body) ->
  case proplists:get_value(chunks, Sizes) of
    undefined ->
      case proplists:get_value(file, Sizes) of
        undefined ->
          proplists:get_value(resp_body, Sizes);
        FileSize -> FileSize
      end;
    ChunksSize -> ChunksSize
  end.

metric(Name, Labels, Desc) -> metric(Name, Labels, [], Desc).

metric(Name, Labels, Buckets, Desc) ->
  [{name,Name},{labels,Labels},{help,"HTTP request "++Desc},{buckets,Buckets}].

labels(Req, StatusCode) ->
  Labels = elli_prometheus_config:labels(),
  [label(Label, Req, StatusCode) || Label <- Labels].

label(method,  Req, _) -> elli_request:method(Req);
label(handler, Req, _) ->
  case elli_request:path(Req) of
    [H|_] -> H;
    []    -> ""
  end;
label(status_code,  _, StatusCode) -> StatusCode;
label(status_class, _, StatusCode) -> prometheus_http:status_class(StatusCode).

%% request_start
%% headers_start
%% headers_end
%% body_start
%% body_end
%% user_start
%% user_end
%% send_start
%% send_end
%% request_end


%% resp_headers
%% resp_body
%% file
%% chunk

%% exclusive event
%% `request_closed' is sent if the client closes the connection when
%% Elli is waiting for the next request on a keep alive connection.
%%
%% `request_timeout' is sent if the client times out when
%% Elli is waiting for the request.
%%
%% `request_parse_error' fires if the request is invalid and cannot be parsed by
%% [`erlang:decode_packet/3`][decode_packet/3] or it contains a path Elli cannot
%% parse or does not support.
%% `client_closed' can be sent from multiple parts of the request
%% handling. It's sent when the client closes the connection or if for
%% any reason the socket is closed unexpectedly. The `Where' atom
%% tells you in which part of the request processing the closed socket
%% was detected: `receiving_headers', `receiving_body' or `before_response'.
%%
%% `client_timeout' can as with `client_closed' be sent from multiple
%% parts of the request handling. If Elli tries to receive data from
%% the client socket and does not receive anything within a timeout,
%% this event fires and the socket is closed.
%%
%% `bad_request' is sent when Elli detects a request is not well
%% formatted or does not conform to the configured limits. Currently
%% the `Reason' variable can be `{too_many_headers, Headers}'
%% or `{body_size, ContentLength}'.
