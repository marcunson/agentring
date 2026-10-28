import Foundation

struct RelayAPIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Redirects are refused so a compromised endpoint cannot forward device credentials.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class RelayAPI {
    let baseURL: URL
    let jwt: String?
    private let session: URLSession

    init(url: String, jwt: String? = nil, session: URLSession? = nil) throws {
        baseURL = try RelayURLPolicy.validate(url)
        self.jwt = jwt
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    deinit { session.invalidateAndCancel() }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = method
        request.setValue("agentring-ios", forHTTPHeaderField: "User-Agent")
        if let jwt { request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = json?["error"] as? [String: String]
            throw RelayAPIError(status: response.statusCode, message: detail?["message"] ?? "HTTP \(response.statusCode)")
        }
        return data
    }

    func value<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        try RelayJSON.decoder().decode(T.self, from: await request(path, method: method, body: body))
    }

    func socket(after: Int64) -> URLSessionWebSocketTask {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/ws"
        components.queryItems = [URLQueryItem(name: "after_seq", value: String(after))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(jwt ?? "")", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }
}
