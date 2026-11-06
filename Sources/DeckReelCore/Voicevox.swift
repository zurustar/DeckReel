import Foundation

public struct Style: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let id: Int
    public let type: String?
}

public struct Speaker: Codable, Equatable, Sendable {
    public let name: String
    public let speakerUUID: String
    public let version: String?
    public let styles: [Style]

    enum CodingKeys: String, CodingKey {
        case name, version, styles
        case speakerUUID = "speaker_uuid"
    }
}

/// A talk style flattened for display: "speaker（style）".
public struct TalkStyle: Identifiable, Hashable, Sendable {
    public let id: Int
    public let speaker: String
    public let style: String
}

public struct VoiceInfo: Codable, Sendable {
    public let engineVersion: String
    public let speaker: Speaker
    public let style: Style
    public let fingerprint: String
    public let credit: String

    enum CodingKeys: String, CodingKey {
        case speaker, style, fingerprint
        case engineVersion = "engine_version"
        case credit = "credit_candidate"
    }
}

/// Whether a style type can be used for text-to-speech via /audio_query and /synthesis.
/// Engine 0.26+ reports talk styles as "streaming_talk".
public func isTalkStyle(_ type: String?) -> Bool {
    type == nil || type == "" || type == "talk" || type == "streaming_talk"
}

/// Client for a local VOICEVOX Engine. Only loopback hosts are accepted; proxies and redirects are refused.
public final class Voicevox: @unchecked Sendable {
    static let maxResponse = 128 << 20
    let base: URL
    private let session: URLSession

    public convenience init(_ address: String) throws {
        try self.init(address, configuration: .ephemeral)
    }

    init(_ address: String, configuration: URLSessionConfiguration) throws {
        let invalid = fail("VOICEVOX URL must be http://127.0.0.1:PORT or http://[::1]:PORT")
        guard let c = URLComponents(string: address), c.scheme == "http", c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/", var host = c.host, !host.isEmpty else {
            throw invalid
        }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        switch host {
        case "localhost", "127.0.0.1": host = "127.0.0.1"
        case "::1": host = "[::1]"
        default: throw fail("VOICEVOX must be a loopback address")
        }
        let port = c.port.map { ":\($0)" } ?? ""
        guard let url = URL(string: "http://\(host)\(port)") else { throw invalid }
        base = url
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 300
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    func request(_ method: String, _ endpoint: String, query: [URLQueryItem] = [], body: Data? = nil,
                 timeout: TimeInterval = 300) async throws -> Data {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = endpoint
        if !query.isEmpty {
            // URLComponents leaves "+" unescaped, which servers decode as a space; escape strictly.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            c.percentEncodedQuery = query.map {
                "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&")
        }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // Never echo the URL: its query carries the slide script.
            throw fail("VOICEVOX \(endpoint) unavailable (check Engine is running)")
        }
        guard let http = response as? HTTPURLResponse else { throw fail("VOICEVOX \(endpoint) returned no HTTP response") }
        guard http.statusCode == 200 else { throw fail("VOICEVOX \(endpoint) returned HTTP \(http.statusCode)") }
        guard data.count <= Self.maxResponse else { throw fail("VOICEVOX response too large") }
        return data
    }

    public func speakers() async throws -> [Speaker] {
        let data = try await request("GET", "/speakers", timeout: 15)
        do { return try JSONDecoder().decode([Speaker].self, from: data) } catch {
            throw fail("invalid VOICEVOX speaker list")
        }
    }

    public func talkStyles() async throws -> [TalkStyle] {
        try await speakers().flatMap { s in
            s.styles.filter { isTalkStyle($0.type) }.map { TalkStyle(id: $0.id, speaker: s.name, style: $0.name) }
        }
    }

    /// Engine, model and dictionary identity for the given style, used as an audio cache condition.
    public func info(style id: Int, revision: String) async throws -> VoiceInfo {
        let versionData = try await request("GET", "/version", timeout: 15)
        guard let version = try? JSONSerialization.jsonObject(with: versionData, options: .fragmentsAllowed) as? String,
              !version.isEmpty else { throw fail("unsupported Engine version response") }
        let speakersData = try await request("GET", "/speakers", timeout: 15)
        guard let speakers = try? JSONDecoder().decode([Speaker].self, from: speakersData),
              let speakersJSON = try? JSONSerialization.jsonObject(with: speakersData) else {
            throw fail("invalid VOICEVOX speaker list")
        }
        var found: (Speaker, Style)?
        for s in speakers { for style in s.styles where style.id == id && isTalkStyle(style.type) { found = (s, style) } }
        guard let (speaker, style) = found else { throw fail("VOICEVOX talk style \(id) not found; use --list-speakers") }
        var parts: [Any] = [version, speakersJSON, revision]
        for endpoint in ["/core_versions", "/engine_manifest", "/user_dict"] {
            let data = try await request("GET", endpoint, timeout: 15)
            guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
                throw fail("invalid Engine metadata at \(endpoint)")
            }
            parts.append(value)
        }
        return VoiceInfo(engineVersion: version, speaker: speaker, style: style, fingerprint: cacheKey(parts),
                         credit: "VOICEVOX:" + speaker.name)
    }

    /// AudioQuery with speed and an explicit 48kHz mono output format.
    public func query(_ text: String, style id: Int, speed: Double) async throws -> Data {
        guard text.unicodeScalars.count <= 10_000 else { throw fail("slide script exceeds 10000 characters; split the slide") }
        let data = try await request("POST", "/audio_query", query: [URLQueryItem(name: "text", value: text),
                                                                     URLQueryItem(name: "speaker", value: String(id))])
        guard var q = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw fail("invalid AudioQuery") }
        guard q["accent_phrases"] != nil else { throw fail("AudioQuery missing accent_phrases") }
        q["speedScale"] = speed
        q["outputSamplingRate"] = sampleRate
        q["outputStereo"] = false
        return try JSONSerialization.data(withJSONObject: q, options: [.sortedKeys])
    }

    public func synthesize(_ query: Data, style id: Int) async throws -> Data {
        let data = try await request("POST", "/synthesis", query: [URLQueryItem(name: "speaker", value: String(id)),
                                                                  URLQueryItem(name: "enable_interrogative_upspeak", value: "true")],
                                     body: query)
        _ = try pcm(fromWAV: data)
        return data
    }
}
