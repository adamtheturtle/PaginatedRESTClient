# PaginatedRESTClient

A pluggable, dependency-free Swift paginator for bearer-authenticated REST APIs.

[Documentation](https://swiftpackageindex.com/adamtheturtle/PaginatedRESTClient/documentation/paginatedrestclient) |
[Swift Package Index](https://swiftpackageindex.com/adamtheturtle/PaginatedRESTClient)

## Installation

```swift
.package(url: "https://github.com/adamtheturtle/PaginatedRESTClient.git", from: "0.1.0")
```

Add the `PaginatedRESTClient` product to your target dependencies.

## Quick start

Provide a page model, an error mapping, and decoder/encoder factories. The default
transport is `URLSessionTransport`.

```swift
import Foundation
import PaginatedRESTClient

struct Item: Decodable, Sendable {
    let id: Int
}

nonisolated struct ItemsPage: PagedResponse {
    let items: [Item]
    let nextPage: String?
    let total: Int?

    var pageItems: [Item] { items }

    static func identity(of item: Item) -> AnyHashable? { item.id }

    enum CodingKeys: String, CodingKey {
        case items
        case nextPage = "next_page"
        case total
    }
}

enum APIError: Error {
    case missingKey, http(Int), decode(String), offline
}

struct APIErrors: RESTTransportErrorMapping {
    nonisolated func missingAPIKey() -> Error { APIError.missingKey }
    nonisolated func http(status: Int, body _: String) -> Error { APIError.http(status) }
    nonisolated func decode(_ detail: String) -> Error { APIError.decode(detail) }
    nonisolated func network(_: URLError) -> Error { APIError.offline }
    nonisolated func isTransient(_ error: Error) -> Bool {
        if case let APIError.http(code) = error {
            return code == 429 || (500 ... 599).contains(code)
        }
        if case APIError.offline = error { return true }
        return false
    }
}

let client = try PaginatedRESTClient(
    apiKey: token,
    baseURL: URL(string: "https://api.example.com")!,
    decoderFactory: { JSONDecoder() },
    encoderFactory: { JSONEncoder() },
    errors: APIErrors()
)

let items = try await client.fetchAllPages(ItemsPage.self, path: "/items/")
```

See the [DocC overview](https://swiftpackageindex.com/adamtheturtle/PaginatedRESTClient/documentation/paginatedrestclient)
for the full API, and [Custom transports](Documentation/CustomTransports.md) for Get and
Alamofire adapters.

## Safety ceilings

`URLSessionTransport` (the default) reads at most **10 MiB** of a 2xx response body and
**64 KiB** for any other status code. The limit is chosen from the HTTP status as the
response arrives. Bodies that exceed the applicable limit throw `RESTResponseTooLargeError`
(with overflow phase and size metadata). `PaginatedRESTClient` maps a 2xx overflow through
your error mapping's `decode(_:)`, and a non-2xx overflow through `http(status:body:)`, so a
large 401/404/429/500 keeps its HTTP classification. Pass `successResponseLimit` and
`errorResponseLimit` to `URLSessionTransport` when you need different values.

Pagination is bounded per client. `defaultMaxSequentialPages` and `defaultMaxParallelPages`
both default to **1000**. Override them with `maxSequentialPages` and `maxParallelPages` on
`PaginatedRESTClient`'s initializer. Exceeding either cap throws through your error mapping's
`invalidRequest(_:)` rather than silently truncating. The sequential walk counts the first
page toward `maxSequentialPages`; the parallel path derives its page count from `total` and
`PagedResponse.pageSize`. A negative `total` is rejected via `decode(_:)`.

Request-body mistakes before the transport runs (for example supplying both an in-memory
body and a file URL) throw `RESTRequestBodyError`, which `PaginatedRESTClient` maps through
`invalidRequest(_:)`.

## Product

- `PaginatedRESTClient`: Fetch, stream, retry with shared rate-limit-aware backoff, decode,
  and de-duplicate paginated REST endpoints through a pluggable transport.

## Requirements

- Swift 6.2+
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, or visionOS 2+

## License

MIT. See [LICENSE](LICENSE).
