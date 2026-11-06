import CryptoKit
import Foundation

/// A user-facing failure. Messages never include slide scripts.
public struct DeckReelError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

func fail(_ message: String) -> DeckReelError { DeckReelError(message) }

/// Lower-case hex SHA-256.
public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func fileHash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Cache key: SHA-256 of a deterministic JSON encoding of plain values
/// (String, numbers, Bool, arrays, dictionaries, NSNull, or JSON-decoded objects).
public func cacheKey(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    return sha256Hex(data)
}

/// Writes through a temporary file in the same directory, fsyncs, then renames.
public func atomicWrite(_ url: URL, _ data: Data) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let tmp = dir.appendingPathComponent(".deckreel-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw fail("cannot write \(url.lastPathComponent)")
    }
    defer { try? FileManager.default.removeItem(at: tmp) }
    let handle = try FileHandle(forWritingTo: tmp)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    } catch {
        try? handle.close()
        throw error
    }
    guard rename(tmp.path, url.path) == 0 else { throw posixError("rename") }
}

func posixError(_ what: String) -> DeckReelError {
    DeckReelError("\(what): \(String(cString: strerror(errno)))")
}

/// Copies `source` next to `dest` and publishes it. Without `overwrite`, publication uses
/// link(2), which fails if `dest` appeared in the meantime instead of replacing it.
public func publish(_ source: URL, to dest: URL, overwrite: Bool) throws {
    let tmp = dest.deletingLastPathComponent().appendingPathComponent(".deckreel-output-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
        throw fail("output directory is not writable")
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: tmp)
    do {
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
    } catch {
        try? output.close()
        throw error
    }
    if overwrite {
        guard rename(tmp.path, dest.path) == 0 else { throw posixError("publish output") }
        return
    }
    guard link(tmp.path, dest.path) == 0 else {
        throw fail("output already exists or cannot be published (use --overwrite only if intended): \(String(cString: strerror(errno)))")
    }
}

/// An exclusive, non-blocking flock(2) held until `close()`.
public final class FileLock {
    private var fd: Int32
    public init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("open lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            fd = -1
            throw fail("another DeckReel process holds \(url.path)")
        }
    }
    public func close() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }
    deinit { close() }
}

/// Runs a process without a shell, returning stdout. Cancelling the task terminates it.
func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    final class Box: @unchecked Sendable { var stdout = Data(); var stderr = Data(); var timedOut = false; var cancelled = false }
    let box = Box()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let group = DispatchGroup()
            group.enter(); group.enter()
            DispatchQueue.global().async { box.stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            DispatchQueue.global().async { box.stderr = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.terminationHandler = { p in
                group.notify(queue: .global()) {
                    if box.cancelled { continuation.resume(throwing: CancellationError()); return }
                    if box.timedOut { continuation.resume(throwing: fail("\(URL(fileURLWithPath: executable).lastPathComponent) timed out")); return }
                    if p.terminationStatus == 0 {
                        continuation.resume(returning: box.stdout)
                    } else {
                        let message = String(decoding: box.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: fail(message.isEmpty ? "process exited with status \(p.terminationStatus)" : message))
                    }
                }
            }
            if box.cancelled { continuation.resume(throwing: CancellationError()); return }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { box.timedOut = true; process.terminate() }
            }
        }
    } onCancel: {
        box.cancelled = true
        if process.isRunning { process.terminate() }
    }
}

public let deckReelVersion = "0.2.0"
