import Foundation

struct WhisperSegment: Decodable {
    let start: Double
    let end: Double
    let text: String
    let language: String?
    let speaker: String?
    let avg_logprob: Double?
    let no_speech_prob: Double?
}

struct WhisperResponse: Decodable {
    let text: String?
    let duration: Double?
    let language: String?
    let language_seconds: [String: Double]?
    let segments: [WhisperSegment]?
}

enum WhisperError: LocalizedError {
    case offline(String)        // server off or unreachable: retry later, quietly
    case unauthorized           // 401: wrong or missing key, never retry automatically
    case forbidden(String)      // 403
    case rateLimited            // 429
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .offline(let m): return L.format("Whisper server unavailable (%@)", m)
        case .unauthorized: return L.string("The Whisper server did not accept the key (401)")
        case .forbidden(let m): return L.format("Access denied (403): %@", m)
        case .rateLimited: return L.string("Too many requests, try again later (429)")
        case .http(let c, let m): return L.format("Server error %ld: %@", c, m)
        }
    }

    var retryable: Bool {
        switch self {
        case .offline, .rateLimited: return true
        case .http(let c, _): return c >= 500
        default: return false
        }
    }
}

/// Client for an OpenAI-compatible /v1/audio/transcriptions endpoint (a self-hosted Whisper server or the
/// OpenAI API).
struct WhisperClient {
    let config: Config

    /// The key lives in the login Keychain. When `security add-generic-password` created the item, reading it
    /// through the same tool never shows a prompt, even though every rebuild changes the app's ad-hoc signature.
    /// No item: requests go out without a key (local servers usually need none).
    func apiKey() -> String? {
        if let k = config.apiKeyOverride { return k }
        let k = Shell.run("/usr/bin/security", ["find-generic-password", "-s", config.keychainService,
                                                 "-a", config.keychainAccount, "-w"])
        return (k?.isEmpty ?? true) ? nil : k
    }

    /// Quick check (at most `timeout` s) that the server answers at all; any HTTP status counts. With the server
    /// off an upload only fails after the TCP connect timeout (over a minute), and the job queue is serial, so
    /// every waiting recording would hold the next call's note back by that long.
    func reachable(timeout: TimeInterval = 5) -> Bool {
        guard let url = URL(string: config.serverURL + "/v1/models") else { return true }
        let key = apiKey()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let sem = DispatchSemaphore(value: 0)
        var answered = false
        var req = URLRequest(url: url, timeoutInterval: timeout)
        // Sent with the key, so a server that blocks clients after failed logins does not count this as one.
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        session.dataTask(with: req) { _, response, _ in
            answered = response is HTTPURLResponse
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return answered
    }

    /// Blocking call; run it off the main thread.
    func transcribe(_ file: URL, diarize: Bool) throws -> WhisperResponse {
        guard let url = URL(string: config.serverURL + "/v1/audio/transcriptions") else {
            throw WhisperError.http(0, "bad URL \(config.serverURL)")
        }
        let key = apiKey()
        let boundary = "tapetum-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", config.model)
        field("response_format", "verbose_json")
        if diarize { field("diarize", "true") }
        let audio = try Data(contentsOf: file)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "POST"
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(WhisperError.offline("no response"))
        let started = Date()
        session.uploadTask(with: req, from: body) { data, response, error in
            if let error {
                result = .failure(WhisperError.offline(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                result = .success((data ?? Data(), http))
            }
            sem.signal()
        }.resume()
        sem.wait()

        let (data, http) = try result.get()
        let message = Self.errorMessage(data, status: http.statusCode)
        switch http.statusCode {
        case 200:
            do {
                let r = try JSONDecoder().decode(WhisperResponse.self, from: data)
                Log.info(String(format: "whisper: %@ -> %d segments in %.1f s", file.lastPathComponent,
                                r.segments?.count ?? 0, Date().timeIntervalSince(started)))
                return r
            } catch {
                throw WhisperError.http(200, L.format("unexpected response: %@", error.localizedDescription))
            }
        case 401: throw WhisperError.unauthorized
        case 403: throw WhisperError.forbidden(message)
        case 429: throw WhisperError.rateLimited
        default: throw WhisperError.http(http.statusCode, message)
        }
    }

    /// The server's own error message, short enough for the menu. An HTML error page says nothing useful there,
    /// so it is replaced by the standard status text.
    private static func errorMessage(_ data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
            if let m = obj["detail"] as? String ?? obj["error"] as? String { return m }
        }
        let text = String(decoding: data.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<") { return HTTPURLResponse.localizedString(forStatusCode: status) }
        let line = text.components(separatedBy: .newlines)[0]
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}
