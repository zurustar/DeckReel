import Compression
import Foundation
@testable import DeckReelCore

/// Writes a ZIP with stored or deflated entries (deflate exercises the Compression path).
func makeZIP(_ files: [(String, Data)], deflate: Bool = true) -> Data {
    var out = Data()
    var central = Data()
    func put16(_ d: inout Data, _ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    func put32(_ d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    for (name, data) in files {
        var payload = data
        var method = 0
        if deflate && !data.isEmpty {
            let capacity = data.count + 1024
            var buffer = Data(count: capacity)
            let n = buffer.withUnsafeMutableBytes { o in
                data.withUnsafeBytes { i in
                    compression_encode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              i.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 { payload = buffer.prefix(n); method = 8 }
        }
        let offset = out.count
        let crc = crc32(data)
        let nameData = Data(name.utf8)
        put32(&out, 0x0403_4B50); put16(&out, 20); put16(&out, 0); put16(&out, method); put16(&out, 0); put16(&out, 0)
        put32(&out, crc); put32(&out, UInt32(payload.count)); put32(&out, UInt32(data.count))
        put16(&out, nameData.count); put16(&out, 0)
        out.append(nameData); out.append(payload)
        put32(&central, 0x0201_4B50); put16(&central, 20); put16(&central, 20); put16(&central, 0); put16(&central, method)
        put16(&central, 0); put16(&central, 0); put32(&central, crc); put32(&central, UInt32(payload.count))
        put32(&central, UInt32(data.count)); put16(&central, nameData.count); put16(&central, 0); put16(&central, 0)
        put16(&central, 0); put16(&central, 0); put32(&central, 0); put32(&central, UInt32(offset))
        central.append(nameData)
    }
    let centralOffset = out.count
    out.append(central)
    put32(&out, 0x0605_4B50); put16(&out, 0); put16(&out, 0); put16(&out, files.count); put16(&out, files.count)
    put32(&out, UInt32(central.count)); put32(&out, UInt32(centralOffset)); put16(&out, 0)
    return out
}

struct FixtureSlide {
    var id: String
    var file: String
    var notes: String
    var hidden = false
}

let relationshipsNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

func writeFixture(_ url: URL, _ slides: [FixtureSlide], presentationExtension: String = "") throws {
    var files: [(String, Data)] = []
    var ids = "", rels = ""
    for (i, s) in slides.enumerated() {
        ids += #"<p:sldId id="\#(s.id)" r:id="r\#(i)"/>"#
        rels += #"<Relationship Id="r\#(i)" Type="x/slide" Target="slides/\#(s.file).xml"/>"#
        files.append(("ppt/slides/\(s.file).xml", Data(#"<p:sld xmlns:p="p" show="\#(s.hidden ? "0" : "1")"/>"#.utf8)))
        files.append(("ppt/slides/_rels/\(s.file).xml.rels",
                      Data(#"<Relationships><Relationship Id="n" Type="x/notesSlide" Target="../notesSlides/\#(s.file).xml"/></Relationships>"#.utf8)))
        files.append(("ppt/notesSlides/\(s.file).xml", Data((#"<p:notes xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>"#
            + #"<p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>NOT SCRIPT</a:t></a:r></a:p></p:txBody></p:sp>"#
            + #"<p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\#(s.notes)</a:t></a:r></a:p></p:txBody></p:sp>"#
            + "</p:spTree></p:cSld></p:notes>").utf8)))
    }
    files.append(("ppt/presentation.xml", Data((#"<p:presentation xmlns:p="p" xmlns:r="\#(relationshipsNS)"><p:sldIdLst>"#
        + ids + "</p:sldIdLst>" + presentationExtension + "</p:presentation>").utf8)))
    files.append(("ppt/_rels/presentation.xml.rels", Data(("<Relationships>" + rels + "</Relationships>").utf8)))
    try makeZIP(files).write(to: url)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("deckreel-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

// MARK: - Fake adapters

final class FakeRenderer: Renderer, @unchecked Sendable {
    var exports = 0
    func version() async throws -> String { "test-powerpoint" }
    func export(_ presentation: URL, toPDF output: URL) async throws {
        exports += 1
        try JSONEncoder().encode(readDeck(presentation)).write(to: output)
    }
}

final class FakeMedia: Media, @unchecked Sendable {
    var clips = 0, joins = 0
    var failNextClip = false
    func info() throws -> String { "test-media" }
    func render(pdf: URL, to directory: URL) throws -> Int {
        let deck = try JSONDecoder().decode(Deck.self, from: Data(contentsOf: pdf))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (i, s) in deck.slides.enumerated() {
            try Data("fixed pixels \(s.id)".utf8).write(to: directory.appendingPathComponent(String(format: "%04d.png", i + 1)))
        }
        return deck.slides.count
    }
    func clip(image: URL, wav: URL, to destination: URL, frames: Int) throws {
        clips += 1
        if failNextClip {
            failNextClip = false
            throw DeckReelError("injected clip failure")
        }
        try writeMovie(destination, Double(frames) / 30)
    }
    func join(_ clips: [URL], to destination: URL) throws {
        joins += 1
        try writeMovie(destination, clips.map { try inspect($0).duration }.reduce(0, +))
    }
    func inspect(_ movie: URL) throws -> MovieInfo {
        let v = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: movie))
        return MovieInfo(duration: v["duration"]!, videoDuration: v["duration"]!, audioDuration: v["duration"]!)
    }
    private func writeMovie(_ url: URL, _ seconds: Double) throws {
        try JSONEncoder().encode(["duration": seconds]).write(to: url)
    }
}

/// Intercepts requests to http://127.0.0.1:<port> and routes them to a registered handler.
final class MockVoicevox: URLProtocol {
    typealias Handler = (URLRequest, Data) -> (status: Int, body: Data)
    private static let lock = NSLock()
    private static var handlers: [Int: Handler] = [:]
    private static var nextPort = 40_000

    /// Registers a handler and returns its base URL.
    static func register(_ handler: @escaping Handler) -> String {
        lock.lock()
        defer { lock.unlock() }
        nextPort += 1
        handlers[nextPort] = handler
        return "http://127.0.0.1:\(nextPort)"
    }

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockVoicevox.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.url?.port.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let (status, data) = handler(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FakeVoice: @unchecked Sendable {
    var syntheses = 0, queries = 0
    var dictionary = ""
    var invalidWAV = false
    var receivedTexts: [String] = []
    var formatErrors = 0

    lazy var url: String = MockVoicevox.register { [unowned self] request, body in self.handle(request, body) }

    private func handle(_ request: URLRequest, _ body: Data) -> (status: Int, body: Data) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch components.path {
        case "/version": return (200, Data(#""0.test""#.utf8))
        case "/speakers":
            return (200, Data(#"[{"name":"Test","speaker_uuid":"uuid","version":"1","styles":[{"name":"Normal","id":3,"type":"streaming_talk"}]}]"#.utf8))
        case "/core_versions": return (200, Data(#"["test"]"#.utf8))
        case "/engine_manifest": return (200, Data(#"{"uuid":"engine"}"#.utf8))
        case "/user_dict": return (200, try! JSONSerialization.data(withJSONObject: ["revision": dictionary]))
        case "/audio_query":
            queries += 1
            let text = query["text"] ?? ""
            receivedTexts.append(text)
            return (200, try! JSONSerialization.data(withJSONObject: ["accent_phrases": [], "speedScale": 1, "test_text": text] as [String: Any]))
        case "/synthesis":
            syntheses += 1
            let q = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if invalidWAV { return (200, Data("broken".utf8)) }
            if q["outputSamplingRate"] as? Int != sampleRate || q["outputStereo"] as? Bool != false { formatErrors += 1 }
            var samples = Data(count: sampleRate / 10 * 2)
            let hash = Data(sha256Hex(Data(((q["test_text"] as? String ?? "") + dictionary).utf8)).utf8)
            samples.replaceSubrange(0..<hash.count, with: hash)
            return (200, wav(fromPCM: samples))
        default: return (404, Data())
        }
    }
}
