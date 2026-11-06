import Compression
import Foundation

/// Minimal read-only ZIP reader for PPTX packages: stored and deflated entries, no ZIP64,
/// no encryption. Every entry is CRC-checked and bounded to avoid decompression bombs.
struct ZIPArchive {
    struct Entry {
        let method: Int
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localHeader: Int
    }

    static let maxEntries = 20_000
    static let maxEntrySize = 64 << 20
    static let maxTotalSize = 1 << 30

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data.startIndex == 0 ? data : Data(data)
        guard self.data.count >= 22 else { throw fail("PPTX is not a ZIP archive") }
        var eocd = -1
        let lowest = max(0, self.data.count - 22 - 0xFFFF)
        var i = self.data.count - 22
        while i >= lowest {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw fail("PPTX is not a ZIP archive") }
        let count = u16(eocd + 10)
        let directorySize = u32(eocd + 12)
        let directoryOffset = u32(eocd + 16)
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw fail("ZIP64 PPTX is not supported")
        }
        guard count <= Self.maxEntries else { throw fail("PPTX has too many entries") }
        guard Int(directoryOffset) + Int(directorySize) <= eocd else { throw fail("corrupt ZIP directory") }
        var p = Int(directoryOffset)
        var total = 0
        for _ in 0..<count {
            guard p + 46 <= eocd, u32(p) == 0x0201_4B50 else { throw fail("corrupt ZIP directory") }
            let flags = u16(p + 8)
            let method = Int(u16(p + 10))
            let crc = u32(p + 16)
            let compressed = Int(u32(p + 20))
            let size = Int(u32(p + 24))
            let nameLength = Int(u16(p + 28)), extraLength = Int(u16(p + 30)), commentLength = Int(u16(p + 32))
            let local = Int(u32(p + 42))
            guard p + 46 + nameLength <= eocd else { throw fail("corrupt ZIP directory") }
            let name = String(decoding: self.data[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            guard flags & 0x1 == 0 else { throw fail("encrypted PPTX is not supported") }
            total += size
            guard size <= Self.maxEntrySize, total <= Self.maxTotalSize else { throw fail("PPTX exceeds expanded size limit") }
            guard entries[name] == nil else { throw fail("duplicate ZIP entry") }
            entries[name] = Entry(method: method, crc: crc, compressedSize: compressed, size: size, localHeader: local)
            p += 46 + nameLength + extraLength + commentLength
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw fail("missing PPTX part \(name)") }
        let h = e.localHeader
        guard h + 30 <= data.count, u32(h) == 0x0403_4B50 else { throw fail("corrupt ZIP entry \(name)") }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.compressedSize <= data.count else { throw fail("corrupt ZIP entry \(name)") }
        let raw = data.subdata(in: start..<(start + e.compressedSize))
        let out: Data
        switch e.method {
        case 0:
            guard raw.count == e.size else { throw fail("corrupt ZIP entry \(name)") }
            out = raw
        case 8:
            out = try inflate(raw, size: e.size, name: name)
        default:
            throw fail("unsupported ZIP compression in \(name)")
        }
        guard crc32(out) == e.crc else { throw fail("ZIP checksum mismatch in \(name)") }
        return out
    }

    private func inflate(_ raw: Data, size: Int, name: String) throws -> Data {
        if size == 0 { return Data() }
        // One spare byte detects output longer than the declared size.
        var out = Data(count: size + 1)
        let written = out.withUnsafeMutableBytes { o in
            raw.withUnsafeBytes { i in
                compression_decode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                          i.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw fail("corrupt ZIP entry \(name)") }
        out.count = size
        return out
    }

    private func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
    private func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
}

private let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    data.withUnsafeBytes { buffer in
        for byte in buffer { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
    }
    return c ^ 0xFFFF_FFFF
}
