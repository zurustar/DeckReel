import Foundation

/// Bumped from the Go implementation (1): cache keys are computed differently.
let cacheVersion = 2

public struct Artifact: Codable, Equatable {
    public var path: String
    public var sha256: String
}

public struct Stage: Codable, Equatable {
    public var key: String
    public var state: String
    public var artifacts: [Artifact]?
    public var error: String?
}

public struct Manifest: Codable {
    public var version: Int
    public var input: String
    public var order: [String]
    public var stages: [String: Stage]
    public var updated: String

    enum CodingKeys: String, CodingKey {
        case version, stages, updated
        case input = "input_sha256"
        case order = "slide_order"
    }
}

/// Work directory with a manifest of stage keys and artifact hashes, guarded by a file lock.
/// `running`, `failed` and `interrupted` stages are never reused.
public final class Cache {
    public let dir: URL
    public var manifest: Manifest
    private let lock: FileLock

    public init(_ directory: URL) throws {
        let dir = directory.standardizedFileURL
        if let type = try? FileManager.default.attributesOfItem(atPath: dir.path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw fail("work directory must not be a symlink")
        }
        self.dir = dir
        lock = try FileLock(dir.appendingPathComponent(".lock"))
        manifest = Manifest(version: cacheVersion, input: "", order: [], stages: [:], updated: "")
        let file = dir.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            // Older or foreign manifests are rebuilt; a corrupt one is reported.
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lock.close()
                throw fail("invalid manifest; move work directory aside to rebuild")
            }
            if object["version"] as? Int == cacheVersion {
                guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
                    lock.close()
                    throw fail("invalid manifest; move work directory aside to rebuild")
                }
                manifest = m
            }
        }
    }

    public func close() { lock.close() }

    /// Resolves a relative path inside the work directory, refusing escapes and symlinks.
    public func path(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw fail("invalid cache path")
        }
        let full = dir.appendingPathComponent(relative)
        var p = full
        while p.path != dir.path {
            var st = stat()
            if lstat(p.path, &st) == 0 {
                if st.st_mode & S_IFMT == S_IFLNK { throw fail("symlink in cache path") }
            } else if errno != ENOENT {
                throw posixError("stat \(p.lastPathComponent)")
            }
            p = p.deletingLastPathComponent()
        }
        return full
    }

    public func valid(_ name: String, key: String) -> Bool {
        guard let s = manifest.stages[name], s.state == "succeeded", s.key == key,
              let artifacts = s.artifacts, !artifacts.isEmpty else { return false }
        return artifacts.allSatisfy { a in
            guard let p = try? path(a.path), let h = try? fileHash(p) else { return false }
            return h == a.sha256
        }
    }

    func start(_ name: String, key: String) throws {
        manifest.stages[name] = Stage(key: key, state: "running")
        try save()
    }

    func failStage(_ name: String, _ cause: Error) throws {
        var s = manifest.stages[name] ?? Stage(key: "", state: "failed")
        s.state = cause is CancellationError ? "interrupted" : "failed"
        s.error = cause.localizedDescription
        manifest.stages[name] = s
        try save()
    }

    func complete(_ name: String, key: String, paths: [String]) throws {
        let artifacts = try paths.map { Artifact(path: $0, sha256: try fileHash(path($0))) }
        manifest.stages[name] = Stage(key: key, state: "succeeded", artifacts: artifacts)
        try save()
    }

    public func save() throws {
        manifest.updated = ISO8601DateFormatter().string(from: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try atomicWrite(dir.appendingPathComponent("manifest.json"), encoder.encode(manifest))
    }
}
