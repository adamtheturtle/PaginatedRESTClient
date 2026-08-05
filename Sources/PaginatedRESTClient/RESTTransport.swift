//
//  RESTTransport.swift
//  PaginatedRESTClient
//
//  The pluggable networking seam. `PaginatedRESTClient` does request building, retry,
//  off-main decoding, error mapping, and concurrent pagination; the only thing it hands
//  out is "execute these bytes, give me back the response bytes, status, and headers". That single
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
    /// A local file to stream as the request body without first loading it into
    /// ``body``. The caller must keep the file in place until the request completes.
    /// Supplying both body sources is rejected by ``URLSessionTransport``.
    public var bodyFileURL: URL?

    public init(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyFileURL: URL? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.bodyFileURL = bodyFileURL
    }
}

/// A request selected an invalid source for its HTTP body.
public nonisolated enum RESTRequestBodyError: Error, Equatable, Sendable {
    /// An in-memory body and a file-backed body were both supplied.
    case multipleSources
    /// File-backed bodies must use a local `file:` URL.
    case bodyFileMustBeFileURL(URL)
    /// The local body file did not exist or was not readable before the request began.
    case unreadableBodyFile(URL)
}

/// The raw result of one HTTP request. Header names are matched case-insensitively by
/// ``value(forHTTPHeaderField:)`` because HTTP field names are case-insensitive.
public nonisolated struct RESTResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = Self.canonicalized(headers)
    }

    /// Returns a response header without requiring callers or transports to agree on
    /// capitalization (for example, `Retry-After` versus `retry-after`).
    public func value(forHTTPHeaderField field: String) -> String? {
        let values = headers
            .filter { $0.key.compare(field, options: .caseInsensitive) == .orderedSame }
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map(\.value)
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func canonicalized(_ headers: [String: String]) -> [String: String] {
        headers
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .reduce(into: [:]) { result, field in
                let name = field.key.lowercased()
                result[name] = [result[name], field.value].compactMap { $0 }.joined(separator: ", ")
            }
    }
}

/// Executes a `RESTRequest` and returns its raw response body, HTTP status, and headers.
///
/// A transport does exactly that and nothing more: no decoding, no retry, no backoff, no
/// auth - all of which the paginator owns. Conformers translate `RESTRequest` into their
/// HTTP client's request type, perform it, and report the resulting ``RESTResponse``. Throwing a
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

    /// Execute a request while retaining response headers. Existing transports that only
    /// implement ``data(for:)`` inherit a compatibility implementation with empty headers;
    /// transports should implement this requirement when retry policy needs response metadata.
    nonisolated func response(for request: RESTRequest) async throws -> RESTResponse
}

public extension RESTTransport {
    nonisolated func response(for request: RESTRequest) async throws -> RESTResponse {
        let (data, statusCode) = try await data(for: request)
        return RESTResponse(data: data, statusCode: statusCode)
    }
}
