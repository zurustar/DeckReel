import Foundation

public let sampleRate = 48_000
/// Samples per 30fps video frame at 48kHz.
let samplesPerFrame = 1_600

/// Returns the PCM payload of a 48kHz mono PCM16 RIFF/WAVE file (the format requested from VOICEVOX).
public func pcm(fromWAV wav: Data) throws -> Data {
    let w = wav.startIndex == 0 ? wav : Data(wav)
    func u16(_ o: Int) -> Int { Int(w[o]) | Int(w[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    guard w.count >= 12, w[0..<4] == Data("RIFF".utf8), w[8..<12] == Data("WAVE".utf8) else {
        throw fail("VOICEVOX returned invalid WAV")
    }
    guard u32(4) + 8 == w.count else { throw fail("truncated WAV") }
    var payload: Data?
    var valid = false
    var offset = 12
    while offset + 8 <= w.count {
        let id = w[offset..<(offset + 4)]
        let n = u32(offset + 4)
        offset += 8
        guard n <= w.count - offset else { throw fail("truncated WAV chunk") }
        if id == Data("fmt ".utf8) {
            guard n >= 16 else { throw fail("invalid WAV format") }
            valid = u16(offset) == 1 && u16(offset + 2) == 1 && u32(offset + 4) == sampleRate && u16(offset + 14) == 16
        } else if id == Data("data".utf8) {
            payload = w.subdata(in: offset..<(offset + n))
        }
        offset += n + n % 2
    }
    guard valid, let payload, !payload.isEmpty, payload.count % 2 == 0 else {
        throw fail("expected nonempty 48kHz mono PCM16 WAV")
    }
    return payload
}

public func wav(fromPCM pcm: Data) -> Data {
    var b = Data()
    func put32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { b.append(contentsOf: $0) } }
    func put16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { b.append(contentsOf: $0) } }
    b.append(contentsOf: Array("RIFF".utf8)); put32(36 + pcm.count)
    b.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
    put16(1); put16(1); put32(sampleRate); put32(sampleRate * 2); put16(2); put16(16)
    b.append(contentsOf: Array("data".utf8)); put32(pcm.count)
    b.append(pcm)
    return b
}

/// Video frames needed to cover `samples` plus `seconds` of padding, rounded up so audio is never cut.
public func frameCount(samples: Int, padding seconds: Double) -> Int {
    Int(((Double(samples) + seconds * Double(sampleRate)) / Double(samplesPerFrame)).rounded(.up))
}

/// Pads PCM with silence to exactly `frames` video frames and wraps it as WAV.
public func paddedWAV(_ pcm: Data, frames: Int) -> Data {
    var padded = Data(count: frames * samplesPerFrame * 2)
    padded.replaceSubrange(0..<min(pcm.count, padded.count), with: pcm.prefix(padded.count))
    return wav(fromPCM: padded)
}
