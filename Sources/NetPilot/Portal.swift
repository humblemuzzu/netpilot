import Foundation

enum PortalState: Equatable {
    case unknown
    case open
    case signInRequired(URL)
    case unreachable

    var needsSignIn: Bool {
        if case .signInRequired = self { return true }
        return false
    }
}

struct PortalSession: Equatable {
    var secondsRemaining: Int?
    var userPortal: URL?
    var checkedAt = Date()
}

/// Asks Apple's captive-portal endpoint the same question macOS asks, without following redirects.
enum Portal {
    static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        var location: URL?
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            location = request.url
            completionHandler(nil)
        }
    }

    private static func session(delegate: URLSessionDelegate? = nil, timeout: Double) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "CaptiveNetworkSupport wispr"]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private static func fetch(_ request: URLRequest, session: URLSession) -> (Data?, HTTPURLResponse?) {
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, HTTPURLResponse?) = (nil, nil)
        session.dataTask(with: request) { data, response, _ in
            result = (data, response as? HTTPURLResponse)
            done.signal()
        }.resume()
        done.wait()
        session.finishTasksAndInvalidate()
        return result
    }

    nonisolated static func check(timeout: Double = 5) -> PortalState {
        let delegate = NoRedirect()
        let (data, response) = fetch(URLRequest(url: probeURL), session: session(delegate: delegate, timeout: timeout))
        guard let response else { return .unreachable }
        let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if response.statusCode == 200 && body.contains("Success") { return .open }
        if let location = delegate.location ?? (response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))) {
            return .signInRequired(location)
        }
        return .signInRequired(probeURL)
    }

    /// RFC 8908: networks that advertise a captive-portal API (DHCP option 114) say how long the session lasts.
    nonisolated static func session(api: String) -> PortalSession? {
        guard let url = URL(string: api), url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/captive+json", forHTTPHeaderField: "Accept")
        let (data, response) = fetch(request, session: session(timeout: 5))
        guard let data, response?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return PortalSession(
            secondsRemaining: (json["seconds-remaining"] as? NSNumber)?.intValue,
            userPortal: (json["user-portal-url"] as? String).flatMap(URL.init(string:))
        )
    }
}
