import Foundation

/// Exports a presentation to PDF. `PowerPoint` drives Microsoft PowerPoint; tests substitute fakes.
public protocol Renderer: Sendable {
    func version() async throws -> String
    func export(_ presentation: URL, toPDF output: URL) async throws
}

/// Drives Microsoft PowerPoint through /usr/bin/osascript. macOS attributes the Apple Events to the
/// responsible app (DeckReel.app, or the terminal for the CLI). osascript runs off the main thread,
/// unlike NSAppleScript, so the UI stays responsive and cancellation can terminate it.
public struct PowerPoint: Renderer {
    // All paths are passed as AppleScript argv, never interpolated as source.
    static let exportScript = """
    on run argv
     set inputFile to POSIX file (item 1 of argv)
     set outputFile to POSIX file (item 2 of argv)
     tell application "Microsoft PowerPoint"
      set ownedPresentation to missing value
      try
       open inputFile
       set ownedPresentation to active presentation
       save ownedPresentation in outputFile as save as PDF
       close ownedPresentation saving no
      on error errorMessage number errorNumber
       if ownedPresentation is not missing value then
        try
         close ownedPresentation saving no
        end try
       end if
       error errorMessage number errorNumber
      end try
     end tell
    end run
    """

    public init() {}

    public func version() async throws -> String {
        do {
            let out = try await runProcess("/usr/bin/osascript", ["-e", #"tell application "Microsoft PowerPoint" to get version"#], timeout: 30)
            return String(decoding: out, as: UTF8.self)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw fail("PowerPoint unavailable or automation not permitted; allow access in System Settings > Privacy & Security > Automation")
        }
    }

    public func export(_ presentation: URL, toPDF output: URL) async throws {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let lock = try FileLock(caches.appendingPathComponent("DeckReel/powerpoint.lock"))
        defer { lock.close() }
        do {
            _ = try await runProcess("/usr/bin/osascript", ["-e", Self.exportScript, presentation.path, output.path], timeout: 600)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw fail("PowerPoint PDF export failed; check Automation permission and open dialogs (see docs/development.md)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw fail("PowerPoint did not create PDF") }
    }
}
