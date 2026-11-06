import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import DeckReelCore

/// Real AVFoundation/CoreGraphics media: PDF rendering, clip encoding and passthrough joining.
@Suite struct MediaTests {
    /// A one-page 640x480 (4:3) PDF filled with red.
    func redPDF(_ url: URL) {
        var box = CGRect(x: 0, y: 0, width: 640, height: 480)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
    }

    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Image row 0 is the top; CoreGraphics' origin is the bottom-left.
        context.draw(image, in: CGRect(x: -x, y: y - (image.height - 1), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    @Test func renderClipAndJoin() throws {
        let media = MacMedia()
        let dir = try temporaryDirectory()
        let pdf = dir.appendingPathComponent("slide.pdf")
        redPDF(pdf)
        #expect(try media.render(pdf: pdf, to: dir) == 1)
        let png = dir.appendingPathComponent("0001.png")
        let source = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        #expect((image.width, image.height) == (1920, 1080))
        // A 640x480 page must be scaled up to fill 1440x1080 (x 240..1680), not drawn at its native size.
        for (x, y) in [(960, 540), (250, 540), (1670, 540), (960, 5), (960, 1074)] {
            let p = pixel(image, x, y)
            #expect(p.r > 230 && p.g < 5 && p.b < 5, "slide not scaled to fill the frame at \(x),\(y)")
        }
        let border = pixel(image, 0, 540)
        #expect(border.r == 0 && border.g == 0 && border.b == 0, "4:3 letterbox missing")

        var samples = Data(count: 1600 * 2 * 4)
        samples.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<s.count { s[i] = Int16(3000 * sin(2 * Double.pi * 440 * Double(i) / 48000)).littleEndian }
        }
        let wavURL = dir.appendingPathComponent("audio.wav")
        try wav(fromPCM: samples).write(to: wavURL)
        let clip = dir.appendingPathComponent("clip.mp4")
        try media.clip(image: png, wav: wavURL, to: clip, frames: 4)

        // Many short clips expose AAC priming and cumulative timestamp errors quickly.
        let out = dir.appendingPathComponent("out.mp4")
        try media.join(Array(repeating: clip, count: 24), to: out)
        let info = try media.inspect(out)
        let want = 24 * 4.0 / 30
        for d in [info.duration, info.videoDuration, info.audioDuration] {
            #expect(abs(d - want) <= 1.0 / 30 + 0.001, "duration \(d) vs \(want)")
        }
        #expect(!(try media.info()).isEmpty)
    }
}
