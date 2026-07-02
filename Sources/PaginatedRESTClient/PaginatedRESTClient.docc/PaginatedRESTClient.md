# ``PaginatedRESTClient``

A pluggable Swift paginator for bearer-authenticated REST APIs.

## Overview

`PaginatedRESTClient` turns a paginated REST endpoint into a single async call or a stream
of growing snapshots. You provide the page model, error mapping, and optional transport;
the client handles page traversal, concurrent fetches when the total is known, retry
backoff, JSON decoding, and item de-duplication.

Use the default `URLSessionTransport` for Foundation-only networking, or provide a custom
``RESTTransport`` adapter for another HTTP client.

## Topics

### Client

- ``PaginatedRESTClient``
- ``PagedResponse``
- ``RESTTransport``
- ``RESTRequest``
- ``RESTTransportErrorMapping``

### Default transport

- ``URLSessionTransport``
