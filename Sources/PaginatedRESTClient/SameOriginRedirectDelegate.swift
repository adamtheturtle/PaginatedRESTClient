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
    private let forwardingDelegate: (any URLSessionTaskDelegate)?

    init(requestURL: URL?, forwardingDelegate: (any URLSessionTaskDelegate)?) {
        requestOrigin = Self.origin(from: requestURL)
        self.forwardingDelegate = forwardingDelegate
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
        #if canImport(FoundationNetworking)
        forwardingDelegate.urlSession(
            session,
            task: task,
            willBeginDelayedRequest: request,
            completionHandler: completionHandler
        )
        #else
        let forwarded: Void? = forwardingDelegate.urlSession?(
            session,
            task: task,
            willBeginDelayedRequest: request,
            completionHandler: completionHandler
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

    static func hasSameOrigin(_ first: URL?, _ second: URL?) -> Bool {
        guard let first = origin(from: first), let second = origin(from: second) else { return false }
        return first == second
    }

    private func allows(_ request: URLRequest) -> Bool {
        requestOrigin == Self.origin(from: request.url)
    }

    private static func origin(from url: URL?) -> Origin? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              let port = components.port ?? defaultPort(for: scheme)
        else { return nil }
        return Origin(scheme: scheme, host: host, port: port)
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
