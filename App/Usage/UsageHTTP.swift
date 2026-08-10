import Foundation

/// The one way the usage layer reaches the network.
///
/// It exists as a protocol so the provider implementations can be tested
/// against fixtures without a socket: every parser bug this layer can have is
/// reachable from a recorded body, and none of them need a live account.
protocol UsageHTTPClient {
    func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse
}

struct UsageHTTPRequest {
    enum Method: String { case get = "GET", post = "POST" }

    var url: URL
    var method: Method = .get
    /// Values here are secrets more often than not. Nothing in this file logs
    /// them, and nothing that receives this struct should either.
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 10

    static func get(_ url: URL, bearer: String, headers: [String: String] = [:], timeout: TimeInterval = 10) -> UsageHTTPRequest {
        var all = headers
        all["Authorization"] = "Bearer \(bearer)"
        all["Accept"] = "application/json"
        return UsageHTTPRequest(url: url, method: .get, headers: all, timeout: timeout)
    }

    static func postJSON(_ url: URL, bearer: String, body: Data, headers: [String: String] = [:], timeout: TimeInterval = 10) -> UsageHTTPRequest {
        var all = headers
        all["Authorization"] = "Bearer \(bearer)"
        all["Content-Type"] = "application/json"
        all["Accept"] = "application/json"
        return UsageHTTPRequest(url: url, method: .post, headers: all, body: body, timeout: timeout)
    }
}

struct UsageHTTPResponse {
    var statusCode: Int
    var body: Data

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    func json() throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: body)
        } catch {
            throw UsageFetchError(.malformedResponse, detail: "response is not JSON")
        }
    }

    /// Maps a status onto the pipeline's vocabulary.
    ///
    /// 401 and 403 are told apart deliberately. A rejected token may be fixed
    /// by another route holding a different one, so it continues; a forbidden
    /// response to a token the provider accepted is about the account, and the
    /// caller decides whether that is terminal — it is the shape Gemini's
    /// withdrawn consumer tier arrives in.
    func failure(detail: String? = nil) -> UsageFetchError {
        switch statusCode {
        case 401:
            UsageFetchError(.credentialsExpired, detail: detail)
        case 403:
            UsageFetchError(.unauthorized, detail: detail)
        case 408, 504:
            UsageFetchError(.timedOut, detail: detail)
        default:
            UsageFetchError(.transport, detail: detail ?? "HTTP \(statusCode)")
        }
    }
}

/// `URLSession` behind the protocol. Deliberately thin: it adds a timeout, maps
/// transport failures into the layer's error type, and does nothing else.
struct UsageURLSessionClient: UsageHTTPClient {
    var session: URLSession = .shared

    func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return UsageHTTPResponse(statusCode: status, body: data)
        } catch let error as URLError where error.code == .timedOut {
            throw UsageFetchError(.timedOut, detail: nil)
        } catch let error as URLError where error.code == .cancelled {
            throw UsageFetchError(.cancelled, detail: nil)
        } catch {
            // The message can name a host but never a token, and the body is
            // not in it — a transport failure has no body.
            throw UsageFetchError(.transport, detail: nil)
        }
    }
}
