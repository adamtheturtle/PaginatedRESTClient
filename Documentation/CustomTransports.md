# Custom transports

`PaginatedRESTClient` talks to the network through one small protocol:

```swift
public protocol RESTTransport: Sendable {
    func data(for request: RESTRequest) async throws -> (Data, Int)
}
```

A transport executes a `RESTRequest` and returns the response body and HTTP status code.
That's the whole contract - **no decoding, no retry, no auth.** All of that stays in the
paginator, so a transport is a thin translation from `RESTRequest` to whatever your HTTP
client understands and back.

The package ships [`URLSessionTransport`](../Sources/PaginatedRESTClient/URLSessionTransport.swift)
as the batteries-included default and depends only on Foundation. The adapters below show
how to layer the paginator over two popular HTTP clients **without making either a
dependency of this package** - drop the snippet into your own app or a small wrapper
module that already depends on the client.

## Two things worth getting right

- **Status, don't throw, for non-2xx.** The paginator decides what a 404 or 500 means via
  your `RESTTransportErrorMapping`. A transport should return `(body, statusCode)` for any
  completed HTTP response and only throw for genuine transport failures (offline, timeout).
- **Rethrow the underlying `URLError`.** The paginator routes a thrown `URLError` through
  your error mapping's `network(_:)` case (and your `isTransient(_:)` decides whether to
  retry). Clients that wrap transport errors in their own type should unwrap back to
  `URLError` so that mapping keeps working.

## Get (kean/Get)

[Get](https://github.com/kean/Get) is a thin async wrapper over `URLSession`. Its
`APIClient.data(for:)` returns the raw bytes plus the `URLResponse`, which is exactly what
the transport contract needs.

```swift
import Foundation
import Get
import PaginatedRESTClient

/// A `RESTTransport` backed by a Get `APIClient`.
struct GetTransport: RESTTransport {
    let client: APIClient

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        var get = Request<Data>(
            url: request.url,
            method: HTTPMethod(rawValue: request.method)
        )
        get.headers = request.headers
        // GET pagination is bodyless; pass raw bytes through for mutating requests.
        if let body = request.body {
            get.body = body
        }

        do {
            let response = try await client.data(for: get)
            let status = (response.response as? HTTPURLResponse)?.statusCode ?? 0
            return (response.data, status)
        } catch let urlError as URLError {
            // Surface the underlying URLError so the paginator's network mapping applies.
            throw urlError
        }
    }
}

// Usage:
// let transport = GetTransport(client: APIClient(baseURL: nil))
// let client = PaginatedRESTClient(apiKey: token, baseURL: base, transport: transport, …)
```

> Get's `Request.body` is `Encodable`. Wrapping it in a `Data`-carrying box (so already
> encoded bytes pass through untouched) is left to the caller; for plain paginated GETs the
> body is always `nil` and this never comes up.

## Alamofire

[Alamofire](https://github.com/Alamofire/Alamofire) handles raw `Data` bodies directly, so
the adapter builds a `URLRequest` and lets Alamofire run it. Crucially, **don't** add
`.validate()` - we want the real status code back, not a thrown error, so the paginator's
error mapping can classify it.

```swift
import Alamofire
import Foundation
import PaginatedRESTClient

/// A `RESTTransport` backed by an Alamofire `Session`.
struct AlamofireTransport: RESTTransport {
    let session: Session

    func data(for request: RESTRequest) async throws -> (Data, Int) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body

        let response = await session.request(urlRequest)
            .serializingData(emptyResponseCodes: [200, 204, 205])
            .response

        switch response.result {
        case let .success(data):
            return (data, response.response?.statusCode ?? 0)
        case let .failure(afError):
            // Rethrow the underlying URLError so the paginator's network mapping applies.
            if case let .sessionTaskFailed(error as URLError) = afError {
                throw error
            }
            throw afError
        }
    }
}

// Usage:
// let transport = AlamofireTransport(session: .default)
// let client = PaginatedRESTClient(apiKey: token, baseURL: base, transport: transport, …)
```

For any other stack (an in-house client, gRPC-Web gateway, a record/replay fixture for
tests) the recipe is the same: translate `RESTRequest`, perform it, return `(Data, Int)`.
