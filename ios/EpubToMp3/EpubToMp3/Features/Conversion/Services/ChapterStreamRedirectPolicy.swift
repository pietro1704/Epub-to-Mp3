import Foundation

/// A request-scoped delegate never forwards diagnostic identity to another origin.
final class ChapterStreamRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL
    let authorization: StreamingDiagnosticsSession.Authorization

    init(origin: URL, authorization: StreamingDiagnosticsSession.Authorization) {
        self.origin = origin
        self.authorization = authorization
    }

    static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs, let leftScheme = lhs.scheme?.lowercased(),
              let rightScheme = rhs.scheme?.lowercased(),
              leftScheme == rightScheme, lhs.host?.lowercased() == rhs.host?.lowercased() else { return false }
        func port(_ url: URL) -> Int? {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
        }
        return port(lhs) == port(rhs)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if !Self.sameOrigin(request.url, origin) || !authorization.isValid {
            redirected.setValue(nil, forHTTPHeaderField: "X-Playback-Journey-ID")
        }
        completionHandler(redirected)
    }
}
