# ``PaginatedRESTClient``

A pluggable Swift paginator for bearer-authenticated REST APIs.

## Overview

`PaginatedRESTClient` turns a paginated REST endpoint into a single async call or a stream
of growing snapshots. You provide the page model, error mapping, and optional transport;
the client handles page traversal, concurrent fetches when the total is known, rate-limit-aware
retry backoff, JSON decoding, and item de-duplication.

Use the default ``URLSessionTransport`` for Foundation-only networking, or provide a custom
``RESTTransport`` adapter for another HTTP client. See <doc:CustomTransports> for Get and
Alamofire examples.

### Response body limits

``URLSessionTransport`` caps how much of each response body it reads. Defaults are 10 MiB for
2xx responses and 64 KiB for all other status codes. The applicable limit is chosen from
the HTTP status as headers arrive. Exceeding the limit throws ``RESTResponseTooLargeError``
(with phase, declared length, and observed byte count). ``PaginatedRESTClient`` maps a
2xx overflow through ``RESTTransportErrorMapping/decode(_:)`` and a non-2xx overflow through
``RESTTransportErrorMapping/http(status:body:)`` so large 4xx/5xx responses keep their HTTP
classification. Pass custom `successResponseLimit` and `errorResponseLimit` values to
``URLSessionTransport`` when you need different ceilings.

### Pagination ceilings

``PaginatedRESTClient/defaultMaxSequentialPages`` and
``PaginatedRESTClient/defaultMaxParallelPages`` both default to `1000`. Pass
`maxSequentialPages` and `maxParallelPages` to ``PaginatedRESTClient/init(apiKey:baseURL:transport:decoderFactory:encoderFactory:errors:log:maxSequentialPages:maxParallelPages:)``
to tune them per client. Hitting either cap throws through
``RESTTransportErrorMapping/invalidRequest(_:)`` rather than truncating the list. The
sequential walk counts the initial page toward `maxSequentialPages`; the parallel path
derives its page count from ``PagedResponse/total`` and ``PagedResponse/pageSize``. A
negative `total` is rejected via ``RESTTransportErrorMapping/decode(_:)``.

## Topics

### Client

- ``PaginatedRESTClient``
- ``PagedResponse``
- ``RESTTransport``
- ``RESTRequest``
- ``RESTResponse``
- ``RESTTransportErrorMapping``

### Default transport

- ``URLSessionTransport``

### Errors

- ``RESTRequestBodyError``
- ``RESTResponseTooLargeError``

### Guides

- <doc:CustomTransports>
