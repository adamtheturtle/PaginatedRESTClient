# PaginatedRESTClient

A pluggable, dependency-free Swift paginator for bearer-authenticated REST APIs.

[![CI](https://github.com/adamtheturtle/PaginatedRESTClient/actions/workflows/ci.yml/badge.svg)](https://github.com/adamtheturtle/PaginatedRESTClient/actions/workflows/ci.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fadamtheturtle%2FPaginatedRESTClient%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/adamtheturtle/PaginatedRESTClient)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fadamtheturtle%2FPaginatedRESTClient%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/adamtheturtle/PaginatedRESTClient)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`PaginatedRESTClient` turns a paginated, bearer-token REST endpoint into a single call —
or a stream of growing snapshots — and does the slow, fiddly parts for you: retry with
backoff, off-main JSON decoding, drift-tolerant error mapping, and **concurrent** page
fetching that turns a serial chain of round-trips into a few parallel waves. The core
depends only on Foundation and stays Linux-clean, and the networking backend is pluggable,
so it sits over `URLSession`, [Get](https://github.com/kean/Get),
[Alamofire](https://github.com/Alamofire/Alamofire), or a test stub without the package
depending on any of them.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/adamtheturtle/PaginatedRESTClient.git", from: "0.1.0")
]
```

…and add `PaginatedRESTClient` to your target's dependencies. In Xcode, use
**File ▸ Add Package Dependencies…** and paste the repository URL.

## Quick start

The client is domain-free: you tell it how to decode your pages, how to turn failures into
your own error type, and (optionally) which HTTP backend to use. The
batteries-included default is `URLSessionTransport`, so you can omit the transport entirely.

```swift
import PaginatedRESTClient
import Foundation

// 1. Describe a page of your list endpoint.
struct Repo: Decodable, Sendable {
    let id: Int
    let name: String
}

struct ReposPage: PagedResponse {
    let repos: [Repo]
    let nextPage: String?
    let total: Int?

    var pageItems: [Repo] { repos }

    // A stable identity de-duplicates items when stitching parallel pages.
    static func identity(of item: Repo) -> AnyHashable? { item.id }

    enum CodingKeys: String, CodingKey {
        case repos
        case nextPage = "next_page"
        case total
    }
}

// 2. Map transport failures onto your own error type.
enum APIError: Error {
    case missingKey, http(Int), decode(String), offline
}

struct APIErrors: RESTTransportErrorMapping {
    func missingAPIKey() -> Error { APIError.missingKey }
    func http(status: Int, body: String) -> Error { APIError.http(status) }
    func decode(_ detail: String) -> Error { APIError.decode(detail) }
    func network(_ error: URLError) -> Error { APIError.offline }
    func isTransient(_ error: Error) -> Bool {
        if case let APIError.http(code) = error { return code == 429 || (500...599).contains(code) }
        if case APIError.offline = error { return true }
        return false
    }
}

// 3. Build the client (URLSessionTransport is the default backend).
let client = PaginatedRESTClient(
    apiKey: token,
    baseURL: URL(string: "https://api.example.com")!,
    decoderFactory: { JSONDecoder() },
    encoderFactory: { JSONEncoder() },
    errors: APIErrors()
)

// 4a. Fetch every page, fully stitched and de-duplicated:
let repos = try await client.fetchAllPages(ReposPage.self, path: "/repos/")

// 4b. …or stream growing snapshots, page one first, so the UI can render early:
for try await snapshot in client.streamAllPages(ReposPage.self, path: "/repos/") {
    render(snapshot) // [page 1], then [page 1 + 2], … then the complete, ordered list
}

// Single objects and mutating requests too:
let me = try await client.fetch(User.self, path: "/user")
let created = try await client.send(Repo.self, method: "POST", path: "/repos/", body: newRepo)
```

## How pagination works

Many REST APIs cap items per page and return an absolute `next_page` URL when more remain.
Callers that ignore it silently see only the first page. `PaginatedRESTClient` handles the
whole list for you, and picks the fastest correct strategy automatically:

- **Read `total` and go parallel.** When the first response reports a `total` count, the
  page count is known up front, so pages `?page=2…N` are fetched **concurrently** in a
  bounded window (8 in flight) rather than walked one blocking round-trip at a time. On a
  large list this is the difference between tens of seconds and a few.
- **Ordered-prefix streaming.** Pages finish out of order, but each emitted snapshot is a
  correctly-ordered, contiguous prefix — the stream only grows, and never shows page 3
  before page 2.
- **`next_page` fallback.** Endpoints that omit `total` (or use cursor-style pagination)
  fall back to walking `next_page` one page at a time, emitting a snapshot per page. A
  safety cap surfaces a runaway server as an error rather than silently truncating.
- **De-duplication.** A server that echoes page 1 for an over-requested `page` can't
  produce duplicate rows: items are de-duplicated by the stable identity you return from
  `PagedResponse.identity(of:)` (return `nil` to opt out).
- **Resilience, off the main actor.** Idempotent GETs retry transient failures (5xx, 429,
  network timeouts) with exponential backoff, and JSON is decoded on a background task so a
  large parse never hitches the UI.

To conform a page type, implement `PagedResponse`:

| Requirement | Meaning |
| --- | --- |
| `pageItems: [Item]` | The items on this page. |
| `nextPage: String?` | Absolute URL of the next page, or `nil` at the end. |
| `total: Int?` | Total count across all pages, when the API reports it — enables the concurrent fast path. |
| `static func identity(of:) -> AnyHashable?` | Stable per-item identity for de-duplication; defaults to `nil` (no de-dup). |

## Pluggable transports

The networking backend is one small protocol:

```swift
public protocol RESTTransport: Sendable {
    func data(for request: RESTRequest) async throws -> (Data, Int)
}
```

A transport executes a `RESTRequest` and returns `(body, HTTP status)` — no decoding, no
retry, no auth; all of that stays in the paginator. `URLSessionTransport` is the default
and depends only on Foundation. To layer the paginator over another HTTP client, pass your
own transport:

```swift
let client = PaginatedRESTClient(
    apiKey: token,
    baseURL: base,
    transport: GetTransport(client: apiClient), // or AlamofireTransport, or a test stub
    decoderFactory: { JSONDecoder() },
    encoderFactory: { JSONEncoder() },
    errors: APIErrors()
)
```

See **[Documentation/CustomTransports.md](Documentation/CustomTransports.md)** for ready-to-use
`GetTransport` (kean/Get) and `AlamofireTransport` adapter examples. Because they're
examples rather than products, neither client becomes a dependency of this package.

## Logging

The paginator owns no logging subsystem. Pass a `log` closure to see retry diagnostics; it
defaults to a no-op, so logging is opt-in and Foundation-only:

```swift
import os
let logger = Logger(subsystem: "com.example.app", category: "pagination")
let client = PaginatedRESTClient(
    apiKey: token, baseURL: base,
    decoderFactory: { JSONDecoder() }, encoderFactory: { JSONEncoder() },
    errors: APIErrors(),
    log: { logger.debug("\($0, privacy: .public)") }
)
```

## Requirements

- Swift 6.2+
- macOS 15+, or Linux (the core is Foundation-only)

## License

[MIT](LICENSE).
