import Foundation

/// A small namespace-aware XML tree built with XMLParser.
/// XMLParser reports element namespaces but not attribute namespaces, so prefix
/// mappings are tracked here to resolve prefixed attributes such as `r:id`.
final class XMLNode {
    struct Attribute {
        let name: String
        let namespace: String?
        let value: String
    }

    let name: String
    let namespace: String?
    let attributes: [Attribute]
    private(set) var children: [XMLNode] = []
    /// Character data directly inside this element.
    fileprivate(set) var text = ""

    init(name: String, namespace: String?, attributes: [Attribute]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    /// The value of an attribute without a namespace (e.g. `id`, `type`, `Target`).
    func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name && $0.namespace == nil }?.value
    }

    func attribute(_ name: String, namespaceSuffix: String) -> String? {
        attributes.first { $0.name == name && ($0.namespace?.hasSuffix(namespaceSuffix) ?? false) }?.value
    }

    func children(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    /// Follows a path of direct child names, e.g. `["cSld", "spTree", "sp"]`.
    func path(_ names: [String]) -> [XMLNode] {
        var nodes = [self]
        for name in names { nodes = nodes.flatMap { $0.children(name) } }
        return nodes
    }

    /// Pre-order traversal of descendants (excluding self).
    func forEachDescendant(_ body: (XMLNode) -> Void) {
        for c in children {
            body(c)
            c.forEachDescendant(body)
        }
    }

    fileprivate func append(_ child: XMLNode) { children.append(child) }

    static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw fail("invalid XML: \(parser.parserError?.localizedDescription ?? "unknown error")")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        /// prefix -> URI stack; the empty prefix is the default namespace (which attributes do not use).
        var prefixes: [String: [String]] = [:]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            prefixes[prefix]?.removeLast()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            var attributes: [Attribute] = []
            for (qualified, value) in attributeDict {
                if let colon = qualified.firstIndex(of: ":") {
                    let prefix = String(qualified[..<colon])
                    if prefix == "xmlns" { continue }
                    let local = String(qualified[qualified.index(after: colon)...])
                    attributes.append(Attribute(name: local, namespace: prefixes[prefix]?.last ?? prefix, value: value))
                } else if qualified != "xmlns" {
                    attributes.append(Attribute(name: qualified, namespace: nil, value: value))
                }
            }
            let node = XMLNode(name: elementName, namespace: namespaceURI?.isEmpty == true ? nil : namespaceURI, attributes: attributes)
            if let parent = stack.last { parent.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
