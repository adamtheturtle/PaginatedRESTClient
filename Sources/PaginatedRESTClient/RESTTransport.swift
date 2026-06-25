//
//  RESTTransport.swift
//  PaginatedRESTClient
//
//  The pluggable networking seam. `PaginatedRESTClient` does request building, retry,
//  off-main decoding, error mapping, and concurrent pagination; the only thing it hands
//  out is "execute these bytes, give me back the response bytes and status". That single
//  responsibility is `RESTTransport`, so the paginator can sit over any HTTP stack
//  (URLSession, Get, Alamofire, a test stub) without depending on any of them.
//
//  The seam is at the byte layer, not the decode layer: a transport does no decoding, no
//  retry, and no auth logic. Everything valuable stays in the paginator and stays
//  backend-independent.
//

import Foundation

/// A single HTTP request, described in backend-neutral terms. The paginator builds these
/// (setting the `Authorization` header and any body) and hands them to a `RESTTransport`,
/// which translates the fields into whatever its underlying HTTP client understands.
public nonisolated struct RESTRequest: Sendable {
    /// The absolute URL to request, including any query items.
    public var url: URL
    /// The HTTP method, e.g. `"GET"` or `"POST"`.
    public var method: String
    /// Request headers. The paginator sets `Authorization` (and `Accept`/`Content-Type`)
    /// here; a transport should pass them through verbatim.
    public var headers: [String: String]
    /// The request body, already encoded, or `nil` for bodyless requests like GET.
    public var body: Data?

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Executes a `RESTRequest` and returns its raw response body and HTTP status code.
///
/// A transport does exactly that and nothing more: no decoding, no retry, no backoff, no
/// auth — all of which the paginator owns. Conformers translate `RESTRequest` into their
/// HTTP client's request type, perform it, and report `(body, statusCode)`. Throwing a
/// `URLError` lets the paginator route the failure through its error mapping's
/// `network(_:)` case; any other thrown error propagates and is offered to the mapping's
/// `isTransient(_:)` for the retry decision.
public protocol RESTTransport: Sendable {
    /// Execute a request, returning the response body and HTTP status code.
    ///
    /// `nonisolated` (like `RESTTransportErrorMapping`) so the paginator can call it from
    /// the off-main pagination pipeline rather than pinning it to the module's default
    /// MainActor isolation.
    nonisolated func data(for request: RESTRequest) async throws -> (Data, Int)
}
