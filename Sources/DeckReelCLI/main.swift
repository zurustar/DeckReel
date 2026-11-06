// deckreel: command-line interface to DeckReelCore.
// Run from a terminal, macOS attributes PowerPoint automation to that terminal app.
import DeckReelCore
import Foundation

let usage = """
DeckReel — PowerPoint notes to narrated MP4

Usage: deckreel presentation.pptx --speaker ID [options]
       deckreel --list-speakers

  --output PATH            output MP4 (default: next to the input)
  --speaker ID             VOICEVOX talk style ID (required for narration)
  --speed X                VOICEVOX speed multiplier 0.5..2 (default 1)
  --dictionary PATH        reading substitutions JSON
  --empty-notes MODE       silence or skip (default silence)
  --silence-seconds X      empty-note duration (default 3)
  --tail-seconds X         post-narration pause (default 0.5)
  --overwrite              replace existing output after successful processing
  --work-dir PATH          cache directory
  --voicevox-url URL       local VOICEVOX Engine URL (default http://127.0.0.1:50021)
  --model-revision TEXT    manual model revision for cache invalidation
  --render-revision TEXT   manual render revision to invalidate image cache
  --list-speakers          list VOICEVOX talk styles and exit
  --version                show version

"""

struct UsageError: Error { let message: String }

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Parses Go-flag-compatible arguments: `-x`/`--x`, `--x value` or `--x=value`, input anywhere.
func parse(_ args: [String]) throws -> (config: Config?, list: Bool, version: Bool, help: Bool, url: String) {
    var input: String?
    var values: [String: String] = [:]
    var flags: Set<String> = []
    let valued: Set = ["output", "work-dir", "dictionary", "voicevox-url", "speaker", "speed", "silence-seconds",
                       "tail-seconds", "empty-notes", "model-revision", "render-revision"]
    let booleans: Set = ["overwrite", "list-speakers", "version", "help", "h"]
    var i = 0
    while i < args.count {
        let a = args[i]
        i += 1
        guard a.hasPrefix("-"), a != "-" else {
            guard input == nil else { throw UsageError(message: "specify one .pptx input") }
            input = a
            continue
        }
        var name = String(a.drop(while: { $0 == "-" }))
        var value: String?
        if let eq = name.firstIndex(of: "=") {
            value = String(name[name.index(after: eq)...])
            name = String(name[..<eq])
        }
        if booleans.contains(name) {
            if let value, !["true", "1"].contains(value) { if ["false", "0"].contains(value) { continue } else { throw UsageError(message: "invalid value for -\(name)") } }
            flags.insert(name)
        } else if valued.contains(name) {
            if value == nil {
                guard i < args.count else { throw UsageError(message: "flag needs an argument: -\(name)") }
                value = args[i]
                i += 1
            }
            values[name] = value
        } else {
            throw UsageError(message: "flag provided but not defined: -\(name)")
        }
    }
    let url = values["voicevox-url"] ?? "http://127.0.0.1:50021"
    let list = flags.contains("list-speakers"), version = flags.contains("version")
    let help = flags.contains("help") || flags.contains("h")
    guard let input else { return (nil, list, version, help, url) }
    var cfg = Config(input: URL(fileURLWithPath: input))
    func number(_ key: String) throws -> Double? {
        guard let s = values[key] else { return nil }
        guard let d = Double(s) else { throw UsageError(message: "invalid value \"\(s)\" for -\(key)") }
        return d
    }
    func path(_ key: String) -> URL? { values[key].map { URL(fileURLWithPath: $0) } }
    cfg.output = path("output")
    cfg.workDir = path("work-dir")
    cfg.dictionary = path("dictionary")
    cfg.voicevoxURL = url
    cfg.modelRevision = values["model-revision"] ?? ""
    cfg.renderRevision = values["render-revision"] ?? ""
    if let s = values["speaker"] {
        guard let id = Int(s) else { throw UsageError(message: "invalid value \"\(s)\" for -speaker") }
        cfg.speaker = id
    }
    cfg.speed = try number("speed") ?? cfg.speed
    cfg.silence = try number("silence-seconds") ?? cfg.silence
    cfg.tail = try number("tail-seconds") ?? cfg.tail
    if let mode = values["empty-notes"] {
        guard let m = EmptyNotes(rawValue: mode) else { throw UsageError(message: "--empty-notes must be silence or skip") }
        cfg.emptyNotes = m
    }
    cfg.overwrite = flags.contains("overwrite")
    return (cfg, list, version, help, url)
}

func run(_ args: [String]) async -> Int32 {
    let parsed: (config: Config?, list: Bool, version: Bool, help: Bool, url: String)
    do { parsed = try parse(args) } catch let e as UsageError {
        stderr(e.message)
        stderr(usage)
        return 2
    } catch { return 2 }
    if parsed.help {
        stderr(usage)
        return 0
    }
    if parsed.version {
        print("DeckReel \(deckReelVersion)")
        return 0
    }
    if parsed.list {
        do {
            let styles = try await Voicevox(parsed.url).talkStyles()
            guard !styles.isEmpty else {
                stderr("VOICEVOX Engine returned no talk styles; check that voice libraries are installed")
                return 1
            }
            for s in styles { print("\(s.id)\t\(s.speaker) / \(s.style)") }
            return 0
        } catch {
            stderr(error.localizedDescription)
            return error is DeckReelError && error.localizedDescription.hasPrefix("VOICEVOX URL") ? 2 : 1
        }
    }
    guard var cfg = parsed.config else {
        stderr(usage)
        return 2
    }
    do { try cfg.validate() } catch {
        stderr(error.localizedDescription)
        return 2
    }
    var pipeline = Pipeline()
    pipeline.log = { stderr($0) }
    do {
        let output = try await pipeline.run(cfg)
        print(output.path)
        return 0
    } catch is CancellationError {
        stderr("interrupted")
        return 130
    } catch {
        stderr(error.localizedDescription)
        return 1
    }
}

// SIGINT cancels the pipeline so finished stages stay cached and running ones are marked interrupted.
signal(SIGINT, SIG_IGN)
let task = Task { await run(Array(CommandLine.arguments.dropFirst())) }
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { task.cancel() }
interrupt.resume()
Task {
    let code = await task.value
    exit(code)
}
dispatchMain()
