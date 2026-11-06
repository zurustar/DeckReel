import Foundation

public enum EmptyNotes: String, Sendable {
    case silence, skip
}

public struct Config: Sendable {
    public var input: URL
    public var output: URL?
    public var workDir: URL?
    public var dictionary: URL?
    public var voicevoxURL = "http://127.0.0.1:50021"
    public var modelRevision = ""
    public var renderRevision = ""
    /// VOICEVOX style ID; required when any slide has narration.
    public var speaker = -1
    public var speed = 1.0
    public var silence = 3.0
    public var tail = 0.5
    public var emptyNotes = EmptyNotes.silence
    public var overwrite = false

    public init(input: URL) { self.input = input }

    /// Resolves defaults and rejects invalid settings before any work starts.
    public mutating func validate() throws {
        guard input.pathExtension.lowercased() == "pptx" else { throw fail("specify one .pptx input") }
        input = input.standardizedFileURL
        var st = stat()
        guard stat(input.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw fail("input must be a readable PPTX file") }
        guard st.st_size <= 512 << 20 else { throw fail("input exceeds 512MiB limit") }
        let out = (output ?? input.deletingPathExtension().appendingPathExtension("mp4")).standardizedFileURL
        guard out.pathExtension.lowercased() == "mp4" else { throw fail("output must end in .mp4") }
        var ost = stat()
        if lstat(out.path, &ost) == 0 {
            guard overwrite else { throw fail("output exists; choose another path or use --overwrite") }
            if stat(out.path, &ost) == 0, ost.st_dev == st.st_dev, ost.st_ino == st.st_ino {
                throw fail("output must not refer to input")
            }
        } else if errno != ENOENT {
            throw posixError("output")
        }
        output = out
        if workDir == nil {
            let base = input.deletingPathExtension().lastPathComponent
            let tag = String(sha256Hex(Data(input.path.utf8)).prefix(12))
            workDir = input.deletingLastPathComponent().appendingPathComponent("work").appendingPathComponent("\(base)-\(tag)")
        }
        workDir = workDir!.standardizedFileURL
        guard [speed, silence, tail].allSatisfy(\.isFinite) else { throw fail("settings must be finite") }
        guard (0.5...2).contains(speed), silence > 0, silence <= 3600, (0...3600).contains(tail) else {
            throw fail("speed must be 0.5..2; silence 0..3600 (exclusive zero); tail 0..3600")
        }
        _ = try Voicevox(voicevoxURL)
    }
}

public struct Pipeline: Sendable {
    public var media: Media
    public var renderer: Renderer
    public var log: @Sendable (String) -> Void = { _ in }
    /// Called before each slide is processed (current is 1-based).
    public var progress: @Sendable (_ current: Int, _ total: Int) -> Void = { _, _ in }
    /// Test hook: URLSession configuration for the VOICEVOX client.
    var voicevoxConfiguration: URLSessionConfiguration?

    public init(media: Media = MacMedia(), renderer: Renderer = PowerPoint()) {
        self.media = media
        self.renderer = renderer
    }

    func makeVoicevox(_ address: String) throws -> Voicevox {
        if let c = voicevoxConfiguration { return try Voicevox(address, configuration: c) }
        return try Voicevox(address)
    }

    /// Converts the presentation and returns the published MP4.
    @discardableResult
    public func run(_ configuration: Config) async throws -> URL {
        var cfg = configuration
        try cfg.validate()
        let output = cfg.output!
        let fm = FileManager.default
        let dictionary = try readDictionary(cfg.dictionary)
        let probe = output.deletingLastPathComponent().appendingPathComponent(".deckreel-check-\(UUID().uuidString)")
        guard fm.createFile(atPath: probe.path, contents: nil) else { throw fail("output directory is not writable") }
        try? fm.removeItem(at: probe)

        let cache = try Cache(cfg.workDir!)
        defer { cache.close() }
        // An output inside the cache can overwrite an intermediate artifact; keep publication separate.
        if output.path.hasPrefix(cache.dir.path + "/") { throw fail("output must be outside the work directory") }
        let snapshot = try cache.path("input/presentation.pptx")
        let raw = try Data(contentsOf: cfg.input)
        guard try fileHash(cfg.input) == sha256Hex(raw) else { throw fail("input changed while reading; retry") }
        try atomicWrite(snapshot, raw)
        let deck: Deck
        do { deck = try readDeck(snapshot) } catch { throw fail("read PPTX: \(error.localizedDescription)") }

        var slides: [Slide] = []
        var scripts: [String] = []
        for s in deck.slides where !s.hidden {
            let text = narrationScript(s.notes, dictionary)
            if text.isEmpty && cfg.emptyNotes == .skip { continue }
            slides.append(s)
            scripts.append(text)
        }
        let needSpeech = scripts.contains { !$0.isEmpty }
        guard !slides.isEmpty else { throw fail("no slides to render after hidden/empty-note filtering") }
        if needSpeech && cfg.speaker < 0 { throw fail("--speaker is required; use --list-speakers to see VOICEVOX styles") }
        cache.manifest.input = sha256Hex(raw)
        cache.manifest.order = slides.map(\.id)
        try cache.save()

        // All adapters are preflighted before PowerPoint export or synthesis.
        let env = try media.info()
        let version = try await renderer.version()
        let voice = try makeVoicevox(cfg.voicevoxURL)
        var info: VoiceInfo?
        if needSpeech { info = try await voice.info(style: cfg.speaker, revision: cfg.modelRevision) }
        var identity: [String: Any] = ["voice": NSNull(), "speed": cfg.speed]
        if let info { identity["voice"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) }
        if !cfg.modelRevision.isEmpty { identity["model_revision"] = cfg.modelRevision }
        try atomicWrite(cache.dir.appendingPathComponent("voice.json"),
                        JSONSerialization.data(withJSONObject: identity, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))

        log("Render: \(slides.count) slides")
        let renderKey = cacheKey(["render-v1", sha256Hex(raw), env, version, cfg.renderRevision])
        let visible = deck.slides.filter { !$0.hidden }
        let renderPaths = ["render/presentation.pdf", "render/pages.json"] + visible.map { "render/\($0.id).png" }
        if !cache.valid("render", key: renderKey) {
            do {
                try await stage(cache, "render", renderKey, renderPaths) {
                    let tmp = cache.dir.appendingPathComponent("render-tmp-\(UUID().uuidString)")
                    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: tmp) }
                    let pdf = tmp.appendingPathComponent("presentation.pdf")
                    try await renderer.export(snapshot, toPDF: pdf)
                    let pages = tmp.appendingPathComponent("pages")
                    let count = try media.render(pdf: pdf, to: pages)
                    // A PDF of all pages maps by position; a PDF of visible pages maps in visible order.
                    guard count == deck.slides.count || count == visible.count else {
                        throw fail("PDF page count \(count) does not match \(deck.slides.count) slides / \(visible.count) visible slides")
                    }
                    let dest = cache.dir.appendingPathComponent("render")
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    try? fm.removeItem(at: dest.appendingPathComponent("presentation.pdf"))
                    try fm.moveItem(at: pdf, to: dest.appendingPathComponent("presentation.pdf"))
                    var mapping: [String: Int] = [:]
                    for (index, s) in visible.enumerated() {
                        let page = count == deck.slides.count ? s.position : index + 1
                        mapping[s.id] = page
                        let target = dest.appendingPathComponent("\(s.id).png")
                        try? fm.removeItem(at: target)
                        try fm.moveItem(at: pages.appendingPathComponent(String(format: "%04d.png", page)), to: target)
                    }
                    try atomicWrite(dest.appendingPathComponent("pages.json"), JSONSerialization.data(withJSONObject: mapping, options: .sortedKeys))
                }
            } catch {
                throw wrap("render slides", error)
            }
        } else {
            log("Render: cached")
        }

        var clips: [URL] = []
        var clipHashes: [String] = []
        var totalFrames = 0
        for (i, s) in slides.enumerated() {
            try Task.checkCancellation()
            log("Slide \(i + 1)/\(slides.count) (PowerPoint \(s.position))")
            progress(i + 1, slides.count)
            let rel = "slides/\(s.id)"
            let dir = try cache.path(rel)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try atomicWrite(dir.appendingPathComponent("source.txt"), Data(s.notes.utf8))
            try atomicWrite(dir.appendingPathComponent("script.txt"), Data(scripts[i].utf8))
            let script = scripts[i]
            let audioURL = dir.appendingPathComponent("audio.wav")
            var audioKey = cacheKey(["audio-v1", script, info?.fingerprint ?? "", cfg.speaker, cfg.speed])
            var audioPaths = ["\(rel)/audio.wav", "\(rel)/audio_query.json"]
            if script.isEmpty {
                audioKey = cacheKey(["silence-v1", cfg.silence])
                audioPaths = ["\(rel)/audio.wav"]
            }
            if !cache.valid("\(s.id)/audio", key: audioKey) {
                do {
                    try await stage(cache, "\(s.id)/audio", audioKey, audioPaths) {
                        if script.isEmpty {
                            try atomicWrite(audioURL, paddedWAV(Data(), frames: frameCount(samples: 0, padding: cfg.silence)))
                            return
                        }
                        let q = try await voice.query(script, style: cfg.speaker, speed: cfg.speed)
                        let audio = try await voice.synthesize(q, style: cfg.speaker)
                        try atomicWrite(dir.appendingPathComponent("audio_query.json"), q)
                        try atomicWrite(audioURL, audio)
                    }
                } catch {
                    throw wrap("slide \(s.position) audio", error)
                }
            } else {
                log("  audio: cached")
            }
            let audio = try Data(contentsOf: audioURL)
            let samples = try pcm(fromWAV: audio)
            let frames = frameCount(samples: samples.count / 2, padding: script.isEmpty ? 0 : cfg.tail)
            totalFrames += frames
            let image = cache.dir.appendingPathComponent("render/\(s.id).png")
            let imageHash = try fileHash(image)
            let clipURL = dir.appendingPathComponent("clip.mp4")
            let clipKey = cacheKey(["clip-v1", imageHash, sha256Hex(audio), frames, env])
            var valid = cache.valid("\(s.id)/clip", key: clipKey)
            if valid { valid = (try? validateMovie(clipURL, seconds: Double(frames) / 30)) != nil }
            if !valid {
                do {
                    try await stage(cache, "\(s.id)/clip", clipKey, ["\(rel)/clip.mp4"]) {
                        let tmp = dir.appendingPathComponent("clip-tmp-\(UUID().uuidString)")
                        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                        defer { try? fm.removeItem(at: tmp) }
                        let padded = tmp.appendingPathComponent("padded.wav")
                        try atomicWrite(padded, paddedWAV(samples, frames: frames))
                        let out = tmp.appendingPathComponent("clip.mp4")
                        try media.clip(image: image, wav: padded, to: out, frames: frames)
                        try validateMovie(out, seconds: Double(frames) / 30)
                        try? fm.removeItem(at: clipURL)
                        try fm.moveItem(at: out, to: clipURL)
                    }
                } catch {
                    throw wrap("slide \(s.position) video", error)
                }
            } else {
                log("  video: cached")
            }
            clips.append(clipURL)
            clipHashes.append(try fileHash(clipURL))
        }

        let joinKey = cacheKey(["join-v1", clipHashes, env])
        let final = cache.dir.appendingPathComponent("output.mp4")
        var valid = cache.valid("join", key: joinKey)
        if valid { valid = (try? validateMovie(final, seconds: Double(totalFrames) / 30)) != nil }
        if !valid {
            log("Join: \(clips.count) clips (passthrough)")
            do {
                try await stage(cache, "join", joinKey, ["output.mp4"]) {
                    let tmp = cache.dir.appendingPathComponent("join-tmp-\(UUID().uuidString)")
                    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: tmp) }
                    let out = tmp.appendingPathComponent("output.mp4")
                    try media.join(clips, to: out)
                    try validateMovie(out, seconds: Double(totalFrames) / 30)
                    try? fm.removeItem(at: final)
                    try fm.moveItem(at: out, to: final)
                }
            } catch {
                throw wrap("join clips", error)
            }
        } else {
            log("Join: cached")
        }
        try Task.checkCancellation()
        if let info {
            let current = try await voice.info(style: cfg.speaker, revision: cfg.modelRevision)
            guard current.fingerprint == info.fingerprint else {
                throw fail("VOICEVOX environment changed during rendering; retry to rebuild affected audio")
            }
        }
        try publish(final, to: output, overwrite: cfg.overwrite)
        log("Completed: \(output.path)")
        return output
    }

    private func stage(_ cache: Cache, _ name: String, _ key: String, _ paths: [String],
                       _ body: () async throws -> Void) async throws {
        try cache.start(name, key: key)
        do {
            try await body()
        } catch {
            do { try cache.failStage(name, error) } catch let saveError {
                throw fail("\(error.localizedDescription) (manifest save also failed: \(saveError.localizedDescription))")
            }
            throw error
        }
        try cache.complete(name, key: key, paths: paths)
    }

    private func validateMovie(_ url: URL, seconds want: Double) throws {
        let v = try media.inspect(url)
        let tolerance = 1.0 / 30 + 0.001
        guard !v.duration.isNaN, abs(v.duration - want) <= tolerance, abs(v.videoDuration - want) <= tolerance,
              abs(v.audioDuration - want) <= tolerance else {
            throw fail(String(format: "media duration does not match planned duration %.3fs", want))
        }
    }

    private func wrap(_ context: String, _ error: Error) -> Error {
        if error is CancellationError { return error }
        return fail("\(context): \(error.localizedDescription)")
    }
}
