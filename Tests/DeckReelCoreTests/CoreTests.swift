import Foundation
import Testing
@testable import DeckReelCore

@Suite struct PPTXTests {
    @Test func orderNotesAndHidden() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("a.pptx")
        try writeFixture(file, [FixtureSlide(id: "300", file: "slide9", notes: "First"),
                                FixtureSlide(id: "256", file: "slide1", notes: "Second", hidden: true)])
        let deck = try readDeck(file)
        #expect(deck.slides.map(\.id) == ["300", "256"])
        #expect(deck.slides[0].notes == "First")
        #expect(deck.slides[0].position == 1)
        #expect(deck.slides[1].hidden)
    }

    @Test func sectionsAreIgnored() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("a.pptx")
        let sections = #"<p:extLst><p:ext uri="{521415D9-36F7-43E2-AB2F-B90AF26B5E84}"><p14:sectionLst xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main"><p14:section name="A" id="{1}"><p14:sldIdLst><p14:sldId id="300"/></p14:sldIdLst></p14:section><p14:section name="B" id="{2}"><p14:sldIdLst><p14:sldId id="256"/></p14:sldIdLst></p14:section></p14:sectionLst></p:ext></p:extLst>"#
        try writeFixture(file, [FixtureSlide(id: "300", file: "slide9", notes: "First"),
                                FixtureSlide(id: "256", file: "slide1", notes: "Second")], presentationExtension: sections)
        #expect(try readDeck(file).slides.map(\.id) == ["300", "256"])
    }

    @Test func relationshipAttributeIsResolvedByNamespace() throws {
        // r:id is matched by namespace URI, not by the "r" prefix.
        let xml = #"<p:presentation xmlns:p="p" xmlns:rel="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" rel:id="rId2"/></p:sldIdLst></p:presentation>"#
        let node = try XMLNode.parse(Data(xml.utf8)).path(["sldIdLst", "sldId"]).first!
        #expect(node.attribute("id") == "256")
        #expect(node.attribute("id", namespaceSuffix: "/relationships") == "rId2")
    }

    @Test(arguments: ["../../../outside", "https://example.org/x", "x?query", "..\\outside"])
    func relationshipEscapeIsRefused(_ target: String) {
        #expect(throws: DeckReelError.self) {
            try resolvePart("ppt/slides/a.xml", Relationship(id: "", type: "", target: target, mode: ""))
        }
    }

    @Test func relationshipResolution() throws {
        #expect(try resolvePart("ppt/slides/slide1.xml", Relationship(id: "", type: "", target: "../notesSlides/n.xml", mode: ""))
            == "ppt/notesSlides/n.xml")
        #expect(try resolvePart("ppt/presentation.xml", Relationship(id: "", type: "", target: "/ppt/slides/s.xml", mode: ""))
            == "ppt/slides/s.xml")
    }

    @Test func notesParagraphs() throws {
        let xml = #"<notes><cSld><spTree><sp><nvSpPr><nvPr><ph type="body"/></nvPr></nvSpPr><txBody><p><r><t>A&amp;B</t></r><br/><r><t>C</t></r></p><p><r><t>D</t></r></p></txBody></sp></spTree></cSld></notes>"#
        #expect(try extractNotes(Data(xml.utf8)) == "A&B\nC\nD")
    }
}

@Suite struct ZIPTests {
    @Test func storedAndDeflatedEntries() throws {
        let big = Data(String(repeating: "スライド ", count: 5000).utf8)
        for deflate in [false, true] {
            let zip = try ZIPArchive(data: makeZIP([("a.txt", Data("hello".utf8)), ("b.txt", big), ("empty", Data())], deflate: deflate))
            #expect(try zip.read("a.txt") == Data("hello".utf8))
            #expect(try zip.read("b.txt") == big)
            #expect(try zip.read("empty") == Data())
        }
    }

    @Test func corruptionIsDetected() throws {
        var data = makeZIP([("a.txt", Data("hello world".utf8))], deflate: false)
        data[30 + 5] ^= 0xFF  // flip a payload byte after the local header and name
        let zip = try ZIPArchive(data: data)
        #expect(throws: DeckReelError.self) { try zip.read("a.txt") }
        #expect(throws: DeckReelError.self) { try ZIPArchive(data: Data("not a zip".utf8)) }
        #expect(throws: DeckReelError.self) { try ZIPArchive(data: makeZIP([("a", Data()), ("a", Data())])) }
    }
}

@Suite struct ScriptAndWAVTests {
    @Test func readingsAndWhitespace() {
        #expect(narrationScript(" API\r\n X ", [Reading(from: "API", to: "A"), Reading(from: "A", to: "B")]) == "B\nX")
        #expect(narrationScript("a\u{3000}\u{3000}b\n\n", []) == "a b")
    }

    @Test func wavRoundTripAndValidation() throws {
        let samples = Data(count: 3202)
        let file = wav(fromPCM: samples)
        let decoded = try pcm(fromWAV: file)
        #expect(decoded.count == samples.count)
        #expect(frameCount(samples: decoded.count / 2, padding: 0) == 2)  // never truncates audio
        #expect(throws: DeckReelError.self) { try pcm(fromWAV: file.prefix(file.count - 1)) }
        #expect(throws: DeckReelError.self) { try pcm(fromWAV: Data("not a wav".utf8)) }
        #expect(paddedWAV(decoded, frames: 3).count == 44 + 3 * 1600 * 2)
    }
}

@Suite struct VoicevoxTests {
    @Test(arguments: ["https://127.0.0.1:50021", "http://example.org:50021", "http://127.0.0.1:50021?token=x",
                      "http://127.0.0.1.evil/", "http://user:pass@127.0.0.1", "http://127.0.0.1:50021/path"])
    func nonLoopbackIsRefused(_ address: String) {
        #expect(throws: DeckReelError.self) { try Voicevox(address) }
    }

    @Test func loopbackForms() throws {
        #expect(try Voicevox("http://localhost:50021").base.absoluteString == "http://127.0.0.1:50021")
        #expect(try Voicevox("http://[::1]:50021").base.absoluteString == "http://[::1]:50021")
    }

    @Test func failuresAndPrivacy() async throws {
        let voice = FakeVoice()
        voice.invalidWAV = true
        let client = try Voicevox(voice.url, configuration: MockVoicevox.configuration)
        await #expect(throws: DeckReelError.self) { try await client.info(style: 99, revision: "") }
        await #expect(throws: DeckReelError.self) { try await client.synthesize(Data("{}".utf8), style: 3) }
        let styles = try await client.talkStyles()
        #expect(styles == [TalkStyle(id: 3, speaker: "Test", style: "Normal")])

        // Error text must not reveal the script carried in the URL query.
        let bad = try Voicevox(MockVoicevox.register { _, _ in (500, Data("secret script".utf8)) }, configuration: MockVoicevox.configuration)
        do {
            _ = try await bad.query("secret script", style: 3, speed: 1)
            Issue.record("HTTP 500 accepted")
        } catch {
            #expect(!error.localizedDescription.contains("secret"))
        }
    }

    @Test func queryTextIsEscaped() async throws {
        let voice = FakeVoice()
        let client = try Voicevox(voice.url, configuration: MockVoicevox.configuration)
        _ = try await client.query("C++ & a=b 日本語", style: 3, speed: 1.2)
        #expect(voice.receivedTexts == ["C++ & a=b 日本語"])
    }

    @Test func cancellation() async throws {
        let voice = FakeVoice()
        let client = try Voicevox(voice.url, configuration: MockVoicevox.configuration)
        let task = Task { try await client.speakers() }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }
}

@Suite struct CacheTests {
    @Test func lockEscapeAndPublish() throws {
        let root = try temporaryDirectory()
        let cache = try Cache(root.appendingPathComponent("work"))
        defer { cache.close() }
        #expect(throws: DeckReelError.self) { try Cache(cache.dir) }  // concurrent lock
        #expect(throws: DeckReelError.self) { try cache.path("../escape") }
        let outside = root.appendingPathComponent("outside")
        try Data("old".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: cache.dir.appendingPathComponent("link"), withDestinationURL: root)
        #expect(throws: DeckReelError.self) { try cache.path("link/outside") }
        let source = root.appendingPathComponent("source")
        try Data("new".utf8).write(to: source)
        #expect(throws: DeckReelError.self) { try publish(source, to: outside, overwrite: false) }
        #expect(try Data(contentsOf: outside) == Data("old".utf8))
        try publish(source, to: outside, overwrite: true)
        #expect(try Data(contentsOf: outside) == Data("new".utf8))
    }

    @Test func keysAreDeterministic() {
        #expect(cacheKey(["a", 1, 1.5, ["b": true, "a": NSNull()]] as [Any]) == cacheKey(["a", 1, 1.5, ["a": NSNull(), "b": true]] as [Any]))
        #expect(cacheKey(["a"]) != cacheKey(["b"]))
    }
}

@Suite struct PipelineTests {
    @Test func incrementalAndResume() async throws {
        let root = try temporaryDirectory()
        let input = root.appendingPathComponent("deck.pptx")
        var slides = [FixtureSlide(id: "300", file: "slide9", notes: "Hello"), FixtureSlide(id: "301", file: "slide1", notes: "World"),
                      FixtureSlide(id: "302", file: "slide3", notes: ""), FixtureSlide(id: "303", file: "slide4", notes: "hidden", hidden: true)]
        try writeFixture(input, slides)
        let voice = FakeVoice(), media = FakeMedia(), renderer = FakeRenderer()
        var pipeline = Pipeline(media: media, renderer: renderer)
        pipeline.voicevoxConfiguration = MockVoicevox.configuration
        var cfg = Config(input: input)
        cfg.output = root.appendingPathComponent("out.mp4")
        cfg.workDir = root.appendingPathComponent("work")
        cfg.voicevoxURL = voice.url
        cfg.speaker = 3
        cfg.silence = 0.1
        cfg.tail = 0.05
        cfg.overwrite = true
        func run() async throws { try await pipeline.run(cfg) }

        try await run()
        #expect((voice.syntheses, media.clips, media.joins) == (2, 3, 1))
        #expect(voice.formatErrors == 0)
        try await run()
        #expect((voice.syntheses, media.clips, media.joins, renderer.exports) == (2, 3, 1, 1))

        slides[0].notes = "Changed"
        try writeFixture(input, slides)
        try await run()
        #expect((voice.syntheses, media.clips, renderer.exports) == (3, 4, 2))

        cfg.tail = 0.1
        try await run()
        #expect((voice.syntheses, media.clips) == (3, 6))

        // A dictionary change at the Engine must invalidate spoken audio, but not silent slides.
        voice.dictionary = "updated"
        try await run()
        #expect(voice.syntheses == 5)

        slides[1].notes = "Interrupted"
        try writeFixture(input, slides)
        media.failNextClip = true
        await #expect(throws: (any Error).self) { try await run() }
        let n = voice.syntheses
        try await run()
        #expect(voice.syntheses == n, "resume synthesized successful audio again")

        // Tampering must be detected despite the manifest still saying succeeded.
        try Data("broken".utf8).write(to: root.appendingPathComponent("work/slides/300/audio.wav"))
        try await run()
        #expect(voice.syntheses == n + 1)

        cfg.emptyNotes = .skip
        try await run()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("work/manifest.json")))
        #expect(manifest.order == ["300", "301"])
        #expect(FileManager.default.fileExists(atPath: cfg.output!.path))
    }

    @Test func validation() throws {
        let root = try temporaryDirectory()
        let input = root.appendingPathComponent("deck.pptx")
        try writeFixture(input, [FixtureSlide(id: "1", file: "s", notes: "x")])
        var cfg = Config(input: input)
        try cfg.validate()
        #expect(cfg.output == root.appendingPathComponent("deck.mp4"))
        #expect(cfg.workDir!.path.hasPrefix(root.appendingPathComponent("work/deck-").path))
        for change in [{ (c: inout Config) in c.speed = .nan }, { $0.speed = 3 }, { $0.silence = 0 }, { $0.voicevoxURL = "http://example.org" },
                       { $0.output = root.appendingPathComponent("x.mov") }, { $0.input = root.appendingPathComponent("missing.pptx") }] {
            var c = Config(input: input)
            change(&c)
            #expect(throws: DeckReelError.self) { try c.validate() }
        }
        try Data().write(to: root.appendingPathComponent("deck.mp4"))
        var existing = Config(input: input)
        #expect(throws: DeckReelError.self) { try existing.validate() }
    }
}
