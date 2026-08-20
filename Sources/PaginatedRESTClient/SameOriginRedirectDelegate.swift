//
//  SameOriginRedirectDelegate.swift
//  PaginatedRESTClient
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rejects redirects that would move an authenticated request to another origin,
/// while preserving the caller's task-delegate behavior for safe redirects.
final nonisolated class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    private let requestOrigin: Origin?
    private let bodyFileURL: URL?
    private let bodyStreamFailureBox: FileBodyStreamFailureBox?
    private let requiresSameOrigin: Bool
    private let sessionDelegate: (any URLSessionDelegate)?
    private let forwardingDelegate: (any URLSessionTaskDelegate)?

    init(
        requestURL: URL?,
        bodyFileURL: URL? = nil,
        bodyStreamFailureBox: FileBodyStreamFailureBox? = nil,
        requiresSameOrigin: Bool = true,
        forwardingDelegate: (any URLSessionDelegate)?
    ) {
        requestOrigin = Self.origin(from: requestURL)
        self.bodyFileURL = bodyFileURL
        self.bodyStreamFailureBox = bodyStreamFailureBox
        self.requiresSameOrigin = requiresSameOrigin
        sessionDelegate = forwardingDelegate
        self.forwardingDelegate = forwardingDelegate as? any URLSessionTaskDelegate
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let sessionDelegate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        #if canImport(FoundationNetworking)
        sessionDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        #else
        let forwarded: Void? = sessionDelegate.urlSession?(
            session,
            didReceive: challenge,
            completionHandler: completionHandler
        )
        if forwarded == nil {
            completionHandler(.performDefaultHandling, nil)
        }
        #endif
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        #if canImport(FoundationNetworking)
        sessionDelegate?.urlSession(session, didBecomeInvalidWithError: error)
        #else
        sessionDelegate?.urlSession?(session, didBecomeInvalidWithError: error)
        #endif
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard allows(request) else {
            completionHandler(nil)
            return
        }
        guard let forwardingDelegate else {
            completionHandler(request)
            return
        }
        #if canImport(FoundationNetworking)
        forwardingDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: { [self] forwardedRequest in
                completionHandler(forwardedRequest.flatMap { allows($0) ? $0 : nil })
            }
        )
        #else
        let forwarded: Void? = forwardingDelegate.urlSession?(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: { [self] forwardedRequest in
                completionHandler(forwardedRequest.flatMap { allows($0) ? $0 : nil })
            }
        )
        if forwarded == nil {
            completionHandler(request)
        }
        #endif
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let forwardingDelegate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        #if canImport(FoundationNetworking)
        forwardingDelegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
        #else
        let forwarded: Void? = forwardingDelegate.urlSession?(
            session,
            task: task,
            didReceive: challenge,
            completionHandler: completionHandler
        )
        if forwarded == nil {
            completionHandler(.performDefaultHandling, nil)
        }
        #endif
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        if let bodyFileURL {
            if let stream = InputStream(url: bodyFileURL) {
                completionHandler(stream)
            } else {
                bodyStreamFailureBox?.markFailed()
                completionHandler(nil)
            }
            return
        }
        guard let forwardingDelegate else {
            completionHandler(nil)
            return
        }
        #if canImport(FoundationNetworking)
        forwardingDelegate.urlSession(session, task: task, needNewBodyStream: completionHandler)
        #else
        let forwarded: Void? = forwardingDelegate.urlSession?(
            session,
            task: task,
            needNewBodyStream: completionHandler
        )
        if forwarded == nil {
            completionHandler(nil)
        }
        #endif
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        #if canImport(FoundationNetworking)
        forwardingDelegate?.urlSession(
            session,
            task: task,
            didSendBodyData: bytesSent,
            totalBytesSent: totalBytesSent,
            totalBytesExpectedToSend: totalBytesExpectedToSend
        )
        #else
        forwardingDelegate?.urlSession?(
            session,
            task: task,
            didSendBodyData: bytesSent,
            totalBytesSent: totalBytesSent,
            totalBytesExpectedToSend: totalBytesExpectedToSend
        )
        #endif
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willBeginDelayedRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        guard let forwardingDelegate else {
            completionHandler(.continueLoading, nil)
            return
        }
        let validatedHandler: @Sendable (
            URLSession.DelayedRequestDisposition,
            URLRequest?
        ) -> Void = { [self] disposition, newRequest in
            switch disposition {
            case .useNewRequest:
                guard let newRequest, allows(newRequest) else {
                    completionHandler(.cancel, nil)
                    return
                }
                completionHandler(.useNewRequest, newRequest)
            default:
                completionHandler(disposition, newRequest)
            }
        }
        #if canImport(FoundationNetworking)
        forwardingDelegate.urlSession(
            session,
            task: task,
            willBeginDelayedRequest: request,
            completionHandler: validatedHandler
        )
        #else
        let forwarded: Void? = forwardingDelegate.urlSession?(
            session,
            task: task,
            willBeginDelayedRequest: request,
            completionHandler: validatedHandler
        )
        if forwarded == nil {
            completionHandler(.continueLoading, nil)
        }
        #endif
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        #if canImport(FoundationNetworking)
        forwardingDelegate?.urlSession(session, task: task, didFinishCollecting: metrics)
        #else
        forwardingDelegate?.urlSession?(session, task: task, didFinishCollecting: metrics)
        #endif
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        #if canImport(FoundationNetworking)
        forwardingDelegate?.urlSession(session, task: task, didCompleteWithError: error)
        #else
        forwardingDelegate?.urlSession?(session, task: task, didCompleteWithError: error)
        #endif
    }

    #if !canImport(FoundationNetworking)
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        forwardingDelegate?.urlSession?(session, taskIsWaitingForConnectivity: task)
    }

    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceiveInformationalResponse response: HTTPURLResponse
    ) {
        forwardingDelegate?.urlSession?(session, task: task, didReceiveInformationalResponse: response)
    }
    #endif

    static func hasSameOrigin(_ first: URL?, _ second: URL?) -> Bool {
        guard let first = origin(from: first), let second = origin(from: second) else { return false }
        return first == second
    }

    private func allows(_ request: URLRequest) -> Bool {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil
        else {
            return false
        }
        guard ["http", "https"].contains(components.scheme?.lowercased()) else { return false }
        if requiresSameOrigin || Self.containsSensitiveHeaders(request) {
            return requestOrigin == Self.origin(from: url)
        }
        return true
    }

    private static func containsSensitiveHeaders(_ request: URLRequest) -> Bool {
        let sensitive = ["authorization", "cookie", "proxy-authorization"]
        return (request.allHTTPHeaderFields ?? [:]).keys.contains {
            sensitive.contains($0.lowercased())
        }
    }

    private static func origin(from url: URL?) -> Origin? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              let port = components.port ?? defaultPort(for: scheme)
        else { return nil }
        return Origin(scheme: scheme, host: canonicalHost(rawHost), port: port)
    }

    private static func canonicalHost(_ host: String) -> String {
        let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard unbracketed.contains(":"),
              let canonicalIPv6 = canonicalIPv6Address(unbracketed)
        else {
            return host
        }
        return canonicalIPv6
    }

    /// Expands an IPv6 literal into eight hexadecimal groups for comparison. This avoids
    /// treating equivalent compressed and expanded literals as separate origins.
    private static func canonicalIPv6Address(_ value: String) -> String? {
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func groups(in half: String) -> [String]? {
            guard !half.isEmpty else { return [] }
            let groups = half.split(separator: ":").map(String.init)
            guard groups.allSatisfy({
                (1 ... 4).contains($0.count) && UInt16($0, radix: 16) != nil
            }) else {
                return nil
            }
            return groups
        }

        guard let leading = groups(in: halves[0]),
              let trailing = halves.count == 2 ? groups(in: halves[1]) : [],
              leading.count + trailing.count <= 8
        else {
            return nil
        }
        let zeroCount = 8 - leading.count - trailing.count
        guard (halves.count == 2 && zeroCount >= 1) || (halves.count == 1 && zeroCount == 0) else {
            return nil
        }
        return (leading + Array(repeating: "0", count: zeroCount) + trailing)
            .compactMap { UInt16($0, radix: 16) }
            .map { String($0, radix: 16) }
            .joined(separator: ":")
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
