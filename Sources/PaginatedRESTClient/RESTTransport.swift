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
    /// Supplying both body sources is rejected before any transport executes the request.
    public var bodyFileURL: URL?

    public nonisolated init(
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

    /// Validates backend-neutral request invariants before a transport receives the request.
    public nonisolated func validate() throws {
        guard body == nil || bodyFileURL == nil else {
            throw RESTRequestBodyError.multipleSources
        }
        guard Self.isValidHTTPMethod(method) else {
            throw RESTRequestError.invalidHTTPMethod(method)
        }
        guard Self.isHTTPURL(url) else {
            throw RESTRequestError.unsupportedURL(url)
        }
        guard headers.allSatisfy({ Self.isValidHeaderName($0.key) && Self.isValidHeaderValue($0.value) }) else {
            throw RESTRequestError.invalidHeaderField
        }
        var seenNames = Set<String>()
        for name in headers.keys {
            let canonical = name.lowercased()
            guard seenNames.insert(canonical).inserted else {
                throw RESTRequestError.duplicateHeaderField(name)
            }
        }
    }

    /// RFC 9110 method tokens: nonempty ASCII `tchar` sequences.
    nonisolated static func isValidHTTPMethod(_ method: String) -> Bool {
        !method.isEmpty && method.utf8.allSatisfy(isHTTPTchar)
    }

    /// HTTP transports require an absolute HTTP(S) URL and never accept userinfo.
    nonisolated static func isHTTPURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil
        else {
            return false
        }
        return true
    }

    /// RFC 9110 field names are tokens. Values may contain horizontal tabs, but not
    /// other control bytes or line breaks that could create a second field.
    nonisolated static func isValidHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy(isHTTPTchar)
    }

    nonisolated static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte == 0x09 || (0x20 ... 0x7E).contains(byte) || byte >= 0x80
        }
    }

    private nonisolated static func isHTTPTchar(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"):
            true
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"),
             UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
             UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
            true
        default:
            false
        }
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
    /// A caller-supplied `Content-Length` did not match the opened body file's size.
    case contentLengthMismatch(expected: Int, declared: String)
}

/// A request failed backend-neutral validation before any bytes were sent.
public nonisolated enum RESTRequestError: Error, Equatable, Sendable {
    /// The HTTP method is empty or contains characters outside the RFC 9110 token grammar.
    case invalidHTTPMethod(String)
    /// The URL is not an absolute HTTP(S) URL suitable for a REST response.
    case unsupportedURL(URL)
    /// A header name or value cannot be represented safely as an HTTP field.
    case invalidHeaderField
    /// Two header names differ only by case; HTTP field names are case-insensitive.
    case duplicateHeaderField(String)
    /// The session configuration cannot run the package's data-task transfer path.
    case unsupportedBackgroundSession
}

/// The raw result of one HTTP request. Header names are matched case-insensitively by
/// ``value(forHTTPHeaderField:)`` because HTTP field names are case-insensitive.
///
/// ``statusCode`` must be a real HTTP status (`100...599`). Values outside that range
/// are rejected at construction so a broken custom transport cannot masquerade as HTTP.
public nonisolated struct RESTResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    /// Final response URL after redirects, when supplied by the transport.
    public var url: URL?
    /// Normalized response headers (lowercase names, first-wins for case variants).
    /// Assigning re-runs canonicalization so the normalized invariant cannot be broken.
    public var headers: [String: String] {
        get { normalizedHeaderValues.mapValues { $0[0] } }
        set { normalizedHeaderValues = Self.canonicalized(newValue) }
    }

    /// All values for each lowercase field name, preserving repeated fields.
    public var headerValues: [String: [String]] {
        get { normalizedHeaderValues }
        set { normalizedHeaderValues = Self.canonicalized(newValue) }
    }

    private var normalizedHeaderValues: [String: [String]]

    public nonisolated init(
        data: Data,
        statusCode: Int,
        headers: [String: String] = [:],
        url: URL? = nil
    ) {
        precondition(
            (100 ... 599).contains(statusCode),
            "RESTResponse statusCode must be a valid HTTP status in 100...599"
        )
        self.data = data
        self.statusCode = statusCode
        self.url = url
        self.normalizedHeaderValues = Self.canonicalized(headers)
    }

    public nonisolated init(
        data: Data,
        statusCode: Int,
        headerValues: [String: [String]],
        url: URL? = nil
    ) {
        precondition(
            (100 ... 599).contains(statusCode),
            "RESTResponse statusCode must be a valid HTTP status in 100...599"
        )
        self.data = data
        self.statusCode = statusCode
        self.url = url
        self.normalizedHeaderValues = Self.canonicalized(headerValues)
    }

    /// Returns a response header without requiring callers or transports to agree on
    /// capitalization (for example, `Retry-After` versus `retry-after`).
    public func value(forHTTPHeaderField field: String) -> String? {
        values(forHTTPHeaderField: field).first
    }

    public func values(forHTTPHeaderField field: String) -> [String] {
        normalizedHeaderValues[field.lowercased()] ?? []
    }

    private static func canonicalized(_ headers: [String: String]) -> [String: [String]] {
        headers
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .reduce(into: [:]) { result, field in
                let name = field.key.lowercased()
                if result[name] == nil {
                    result[name] = [field.value]
                }
            }
    }

    private static func canonicalized(_ headers: [String: [String]]) -> [String: [String]] {
        headers
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .reduce(into: [:]) { result, field in
                result[field.key.lowercased(), default: []].append(contentsOf: field.value)
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
    /// Execute a request while retaining its response body, status, and headers.
    nonisolated func response(for request: RESTRequest) async throws -> RESTResponse
    /// Drains but does not retain successful response bytes. Error bytes are retained.
    nonisolated func responseDiscardingSuccessBody(for request: RESTRequest) async throws -> RESTResponse
}

public extension RESTTransport {
    /// A convenience projection for consumers that do not need response headers.
    nonisolated func data(for request: RESTRequest) async throws -> (Data, Int) {
        let response = try await response(for: request)
        return (response.data, response.statusCode)
    }

    nonisolated func responseDiscardingSuccessBody(for request: RESTRequest) async throws -> RESTResponse {
        var response = try await response(for: request)
        if (200 ..< 300).contains(response.statusCode) {
            response.data.removeAll(keepingCapacity: false)
        }
        return response
    }
}

/// Compatibility protocol for transports written against the original byte-and-status
/// seam. Prefer conforming new transports directly to ``RESTTransport`` so headers are
/// available to retry logic. This protocol deliberately owns the one-way adapter, avoiding
/// recursive defaults between the legacy and modern requirements.
public protocol LegacyRESTTransport: RESTTransport {
    nonisolated func data(for request: RESTRequest) async throws -> (Data, Int)
}

public extension LegacyRESTTransport {
    nonisolated func response(for request: RESTRequest) async throws -> RESTResponse {
        let (data, statusCode) = try await data(for: request)
        return RESTResponse(data: data, statusCode: statusCode)
    }
}
