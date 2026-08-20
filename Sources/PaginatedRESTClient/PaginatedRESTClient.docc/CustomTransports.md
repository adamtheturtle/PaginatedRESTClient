# Custom transports

``PaginatedRESTClient`` talks to the network through one small protocol:

```swift
public protocol RESTTransport: Sendable {
    func response(for request: RESTRequest) async throws -> RESTResponse
}
```

A transport executes a ``RESTRequest`` and returns the response body, HTTP status code, and
headers. The paginator uses `Retry-After` to coordinate rate-limit cooldowns across concurrent
page requests. Implement `response(for:)` directly for every new transport. The convenience
`data(for:)` projection remains available when a caller does not need headers. Legacy transports
can temporarily conform to `LegacyRESTTransport`, whose one-way adapter supplies
an empty header collection.

That's the whole contract - **no decoding, no retry, no auth.** All of that stays in the
paginator, so a transport is a thin translation from ``RESTRequest`` to whatever your HTTP
client understands and back.

The package ships ``URLSessionTransport`` as the batteries-included default and depends only
on Foundation. The adapters below show how to layer the paginator over two popular HTTP
clients **without making either a dependency of this package** - drop the snippet into your
own app or a small wrapper module that already depends on the client.

## Three things worth getting right

- **Response, don't throw, for non-2xx.** The paginator decides what a 404 or 500 means via
  your ``RESTTransportErrorMapping``. A transport should return a ``RESTResponse`` for any
  completed HTTP response and only throw for genuine transport failures (offline, timeout).
- **Retain headers.** Copy response headers into ``RESTResponse`` so 429 retries can
  honor `Retry-After`. Header lookup in ``RESTResponse`` is case-insensitive.
- **Rethrow the underlying `URLError`.** The paginator routes a thrown `URLError` through
  your error mapping's `network(_:)` case (and your `isTransient(_:)` decides whether to
  retry). Clients that wrap transport errors in their own type should unwrap back to
  `URLError` so that mapping keeps working.

## Redirect credential safety

``PaginatedRESTClient/authorizedGET(_:)`` and the other authenticated builders validate only
the *initial* URL. Once a ``RESTRequest`` is handed to your transport, **redirect handling is
entirely yours.**

If the request carries `Authorization` (or any other secret header), a transport must either:

1. Refuse redirects that leave the request's HTTP(S) origin (scheme, host, and effective port),
   including destinations that add URL userinfo, or
2. Strip credential headers before following a cross-origin redirect.

``URLSessionTransport`` does (1) through ``SameOriginRedirectDelegate``. A literal adapter
that blindly replays the original ``RESTRequest/headers`` on every hop can reintroduce a
credential leak. Treat same-origin redirect policy as part of the ``RESTTransport`` contract,
not an optional URLSession detail.

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

    func response(for request: RESTRequest) async throws -> RESTResponse {
        var get = Request<Void>(
            url: request.url,
            method: HTTPMethod(rawValue: request.method)
        )
        get.headers = request.headers

        do {
            let response: Response<Data>
            if let body = request.body {
                // `Request.body` is JSON-encoded by Get. Use its upload API so the
                // already encoded RESTRequest bytes stay unchanged.
                response = try await client.upload(for: get, from: body)
            } else if let bodyFileURL = request.bodyFileURL {
                response = try await client.upload(for: get, fromFile: bodyFileURL)
            } else {
                response = try await client.data(for: get)
            }
            guard let http = response.response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
                let name = (field.key as? String) ?? String(describing: field.key)
                result[name] = String(describing: field.value)
            }
            return RESTResponse(
                data: response.data,
                statusCode: http.statusCode,
                headers: headers
            )
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

> Get validates non-2xx responses through its `APIClientDelegate` by default. Configure a
> delegate that permits HTTP responses so this adapter can return their status and body to the
> paginator's error mapping.

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

    func response(for request: RESTRequest) async throws -> RESTResponse {
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
            guard let http = response.response else {
                throw URLError(.badServerResponse)
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) {
                result, field in
                let name = (field.key as? String) ?? String(describing: field.key)
                result[name] = String(describing: field.value)
            }
            return RESTResponse(
                data: data,
                statusCode: http.statusCode,
                headers: headers
            )
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
tests) the recipe is the same: translate ``RESTRequest``, perform it, and return a
``RESTResponse`` that retains the status and headers.
