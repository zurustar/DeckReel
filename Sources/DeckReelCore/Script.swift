import Foundation

public struct Reading: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Reads an ordered substitution dictionary: `[{"from": "API", "to": "エーピーアイ"}]`.
public func readDictionary(_ url: URL?) throws -> [Reading] {
    guard let url else { return [] }
    let readings: [Reading]
    do {
        readings = try JSONDecoder().decode([Reading].self, from: Data(contentsOf: url))
    } catch {
        throw fail("invalid dictionary \(url.lastPathComponent): \(error.localizedDescription)")
    }
    guard readings.allSatisfy({ !$0.from.isEmpty }) else { throw fail("dictionary contains empty from") }
    return readings
}

/// Normalizes line endings and whitespace, then applies readings in order.
/// Wording and punctuation are never changed otherwise.
public func narrationScript(_ raw: String, _ dictionary: [Reading]) -> String {
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var s = normalized.components(separatedBy: "\n")
        .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    for r in dictionary { s = s.replacingOccurrences(of: r.from, with: r.to) }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
