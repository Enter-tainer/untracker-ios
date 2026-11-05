//
//  UntrackFetch.swift
//  Untracker for iOS
//
//  Synchronous `fetch()` for the rule sandbox. The upstream `Common short links`
//  rule follows redirects to expand t.cn / b23.tv / amzn.to style short links,
//  which requires a blocking request from inside the JavaScript evaluation.
//
//  Requests therefore run on the engine's background queue (never on the main
//  thread) and are bounded by hard timeouts.
//

import Foundation

enum UntrackFetch {
    /// Handles one `__untrackNative.fetch(json)` invocation.
    ///
    /// `argumentsJSON` is the JSON encoding of the JS `arguments` array, i.e.
    /// `[resource, options?]` where `resource` is a URL string or a request
    /// object. The return value is a JSON object shaped like the upstream
    /// response: `{body, headers, ok, redirected, status, statusText, url}`.
    /// Failures are reported as `{__error: "..."}` which the JS shim throws.
    static func handle(argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let first = arguments.first else {
            return "{\"__error\":\"fetch: missing argument\"}"
        }

        var urlString: String?
        var options: [String: Any] = [:]
        if let resource = first as? String {
            urlString = resource
            if arguments.count > 1, let dictionary = arguments[1] as? [String: Any] {
                options = dictionary
            }
        } else if let request = first as? [String: Any] {
            urlString = request["url"] as? String
            options = request
        }

        guard let urlString = urlString, let url = URL(string: urlString) else {
            return "{\"__error\":\"fetch: invalid URL\"}"
        }

        let method = ((options["method"] as? String) ?? "GET").uppercased()
        let redirectMode = (options["redirect"] as? String) ?? "follow"
        guard ["follow", "error", "manual"].contains(redirectMode) else {
            return "{\"__error\":\"fetch: invalid redirect mode\"}"
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body = options["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        }
        if let headers = options["headers"] as? [[Any]] {
            for pair in headers where pair.count >= 2 {
                guard let name = pair[0] as? String, let value = pair[1] as? String else { continue }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        let follow = redirectMode == "follow"
        let outcome = perform(request, followRedirects: follow)

        if let error = outcome.error {
            return "{\"__error\":" + UntrackNativeBridge.quote(error) + "}"
        }
        if redirectMode == "error", let status = outcome.response?.statusCode, (300...399).contains(status) {
            return "{\"__error\":\"fetch: Request was redirected\"}"
        }

        let response = outcome.response
        let body = outcome.data.flatMap { String(data: $0, encoding: .utf8) }
            ?? outcome.data.map { String(decoding: $0, as: UTF8.self) }
            ?? ""
        let finalURL = outcome.finalURL?.absoluteString ?? url.absoluteString
        let status = response?.statusCode ?? 0
        let ok = (200...299).contains(status)
        let redirected = finalURL != url.absoluteString

        var headerPairs: [[String]] = []
        if let headers = response?.allHeaderFields {
            for (name, value) in headers {
                headerPairs.append([String(describing: name), String(describing: value)])
            }
        }

        let payload: [String: Any] = [
            "body": body,
            "headers": headerPairs,
            "ok": ok,
            "redirected": redirected,
            "status": status,
            "statusText": response.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) } ?? "",
            "url": finalURL
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: encoded, encoding: .utf8) else {
            return "{\"__error\":\"fetch: could not encode response\"}"
        }
        return string
    }

    // MARK: - Blocking HTTP

    private struct Outcome {
        var data: Data?
        var response: HTTPURLResponse?
        var finalURL: URL?
        var error: String?
    }

    /// Stops (or allows) redirects, mirroring `redirect: 'manual' | 'follow'`.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        private let followRedirects: Bool
        init(followRedirects: Bool) {
            self.followRedirects = followRedirects
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(followRedirects ? request : nil)
        }
    }

    private static func perform(_ request: URLRequest, followRedirects: Bool) -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let policy = RedirectPolicy(followRedirects: followRedirects)
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)

        var outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()

        let task = session.dataTask(with: request) { data, response, error in
            lock.lock()
            outcome.data = data
            outcome.response = response as? HTTPURLResponse
            outcome.finalURL = response?.url
            outcome.error = error?.localizedDescription
            lock.unlock()
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            task.cancel()
            lock.lock()
            outcome.error = "fetch: request timed out"
            lock.unlock()
        }
        session.finishTasksAndInvalidate()
        return outcome
    }
}
