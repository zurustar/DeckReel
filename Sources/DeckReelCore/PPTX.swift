import Foundation

public struct Slide: Codable, Equatable, Sendable {
    /// Stable `p:sldId/@id` from the presentation.
    public let id: String
    /// 1-based position in the presentation, hidden slides included.
    public let position: Int
    public let hidden: Bool
    public let notes: String
}

public struct Deck: Codable, Equatable, Sendable {
    public let slides: [Slide]
}

struct Relationship {
    let id: String
    let type: String
    let target: String
    let mode: String
}

/// Reads slide order, visibility and speaker notes from a PPTX without PowerPoint.
public func readDeck(_ url: URL) throws -> Deck {
    let zip = try ZIPArchive(url: url)
    let presentationPart = "ppt/presentation.xml"
    let presentation = try XMLNode.parse(zip.read(presentationPart))
    // Only presentation/sldIdLst/sldId lists slides. Sections (p14:sectionLst in extLst)
    // also contain sldId elements without r:id, which must be ignored.
    var ids: [(id: String, rid: String)] = []
    if presentation.name == "presentation" {
        for node in presentation.path(["sldIdLst", "sldId"]) {
            let id = node.attribute("id") ?? ""
            let rid = node.attribute("id", namespaceSuffix: "/relationships") ?? ""
            guard UInt32(id) != nil, !rid.isEmpty else { throw fail("invalid slide ID") }
            ids.append((id, rid))
        }
    }
    let rels = try relationships(zip, for: presentationPart)
    var seen = Set<String>()
    var slides: [Slide] = []
    for (index, entry) in ids.enumerated() {
        guard seen.insert(entry.id).inserted else { throw fail("duplicate slide ID") }
        guard let rel = rels[entry.rid], rel.type.hasSuffix("/slide") else { throw fail("missing slide relationship") }
        let part = try resolvePart(presentationPart, rel)
        let slide = try XMLNode.parse(zip.read(part))
        let show = slide.attribute("show")
        var notes = ""
        let notesRels = try relationships(zip, for: part).values.filter { $0.type.hasSuffix("/notesSlide") }
        guard notesRels.count <= 1 else { throw fail("multiple notes for slide \(index + 1)") }
        if let rel = notesRels.first {
            notes = try extractNotes(zip.read(resolvePart(part, rel)))
        }
        slides.append(Slide(id: entry.id, position: index + 1, hidden: show == "0" || show == "false", notes: notes))
    }
    return Deck(slides: slides)
}

func relationships(_ zip: ZIPArchive, for part: String) throws -> [String: Relationship] {
    let dir = (part as NSString).deletingLastPathComponent
    let file = (dir.isEmpty ? "" : dir + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
    guard zip.contains(file) else { return [:] }
    let root = try XMLNode.parse(zip.read(file))
    var result: [String: Relationship] = [:]
    for r in root.children("Relationship") {
        let rel = Relationship(id: r.attribute("Id") ?? "", type: r.attribute("Type") ?? "",
                               target: r.attribute("Target") ?? "", mode: r.attribute("TargetMode") ?? "")
        guard result[rel.id] == nil else { throw fail("duplicate relationship") }
        result[rel.id] = rel
    }
    return result
}

/// Resolves a relationship target inside the package. External, malformed or escaping targets are refused.
func resolvePart(_ source: String, _ rel: Relationship) throws -> String {
    if rel.mode == "External" || rel.target.contains(where: { "\\?#:".contains($0) }) {
        throw fail("unsupported external or malformed relationship")
    }
    var components: [Substring] = []
    if !rel.target.hasPrefix("/") {
        components = source.split(separator: "/")
        components.removeLast()
    }
    for part in rel.target.split(separator: "/", omittingEmptySubsequences: true) {
        switch part {
        case ".": continue
        case "..":
            guard !components.isEmpty else { throw fail("relationship escapes package") }
            components.removeLast()
        default: components.append(part)
        }
    }
    guard !components.isEmpty else { throw fail("relationship escapes package") }
    return components.joined(separator: "/")
}

/// Extracts paragraphs from the notes body placeholder only (not slide number, header, date or footer).
func extractNotes(_ data: Data) throws -> String {
    let root = try XMLNode.parse(data)
    var paragraphs: [String] = []
    for shape in root.path(["cSld", "spTree", "sp"]) {
        let placeholder = shape.path(["nvSpPr", "nvPr", "ph"]).last
        guard placeholder?.attribute("type") == "body" else { continue }
        for p in shape.path(["txBody", "p"]) {
            var out = ""
            p.forEachDescendant { node in
                if node.name == "t" { out += node.text } else if node.name == "br" { out += "\n" }
            }
            paragraphs.append(out)
        }
    }
    return paragraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
