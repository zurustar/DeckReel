import AppKit
import AVFoundation
import CoreText
import CryptoKit
import Foundation

public struct MovieInfo: Equatable, Sendable {
    public let duration: Double
    public let videoDuration: Double
    public let audioDuration: Double
}

/// Slide rendering and video encoding. `MacMedia` uses AVFoundation/CoreGraphics; tests substitute fakes.
public protocol Media: Sendable {
    /// Identity of the rendering environment (OS, fonts, media code version) for cache keys.
    func info() throws -> String
    /// Renders each PDF page to `directory/0001.png`… at 1920x1080 and returns the page count.
    func render(pdf: URL, to directory: URL) throws -> Int
    func clip(image: URL, wav: URL, to destination: URL, frames: Int) throws
    func join(_ clips: [URL], to destination: URL) throws
    func inspect(_ movie: URL) throws -> MovieInfo
}

public struct MacMedia: Media {
    /// Bump whenever rendered or encoded output changes so cached images and clips are rebuilt.
    static let version = 2

    public init() {}

    public func info() throws -> String {
        let names = (CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []).sorted()
        var records: [String] = []
        for name in names {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            if let location = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
               let attrs = try? FileManager.default.attributesOfItem(atPath: location.path) {
                records.append("\(name)|\(location.path)|\(attrs[.modificationDate] ?? "")|\(attrs[.size] ?? "")")
            } else {
                records.append(name)
            }
        }
        return cacheKey(["os": ProcessInfo.processInfo.operatingSystemVersionString,
                         "fonts_sha256": sha256Hex(Data(records.joined(separator: "\n").utf8)),
                         "media_version": Self.version] as [String: Any])
    }

    public func inspect(_ movie: URL) throws -> MovieInfo {
        let asset = AVURLAsset(url: movie)
        guard asset.isReadable, let video = asset.tracks(withMediaType: .video).first,
              let audio = asset.tracks(withMediaType: .audio).first else { throw fail("MP4 must contain readable video and audio") }
        let size = video.naturalSize.applying(video.preferredTransform)
        let formats = audio.formatDescriptions as! [CMAudioFormatDescription]
        let asbd = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let videoFormats = video.formatDescriptions as! [CMVideoFormatDescription]
        let codec = videoFormats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        guard abs(size.width) == 1920, abs(size.height) == 1080, abs(video.nominalFrameRate - 30) < 0.01,
              codec == kCMVideoCodecType_H264, asbd?.mFormatID == kAudioFormatMPEG4AAC,
              asbd?.mSampleRate == 48000, asbd?.mChannelsPerFrame == 1 else { throw fail("unexpected MP4 stream format") }
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { throw fail("invalid duration") }
        return MovieInfo(duration: duration, videoDuration: CMTimeGetSeconds(video.timeRange.duration),
                         audioDuration: CMTimeGetSeconds(audio.timeRange.duration))
    }

    public func render(pdf: URL, to directory: URL) throws -> Int {
        guard let document = CGPDFDocument(pdf as CFURL) else { throw fail("cannot open exported PDF") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard document.numberOfPages > 0 else { throw fail("exported PDF has no pages") }
        for index in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw fail("missing PDF page") }
            let width = 1920, height = 1080
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw fail("cannot allocate image") }
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let box = page.getBoxRect(.cropBox)
            let rotated = abs(page.rotationAngle) % 180 != 0
            let sourceWidth = rotated ? box.height : box.width
            let sourceHeight = rotated ? box.width : box.height
            let scale = min(CGFloat(width) / sourceWidth, CGFloat(height) / sourceHeight)
            let rect = CGRect(x: (CGFloat(width) - sourceWidth * scale) / 2, y: (CGFloat(height) - sourceHeight * scale) / 2,
                              width: sourceWidth * scale, height: sourceHeight * scale)
            // A white slide background inside a black letterbox also supports PDFs without an explicit background.
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            // getDrawingTransform only scales down, never up, so scale explicitly and use it
            // just for crop-box origin and page rotation at the page's own size.
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: scale, y: scale)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                                                         rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw fail("cannot render page")
            }
            try png.write(to: directory.appendingPathComponent(String(format: "%04d.png", index)), options: .atomic)
        }
        return document.numberOfPages
    }

    public func clip(image: URL, wav: URL, to destination: URL, frames: Int) throws {
        guard frames > 0, let source = NSImage(contentsOf: image),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw fail("cannot read slide image") }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoExpectedSourceFrameRateKey: 30,
                                              AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false],
        ])
        video.mediaTimeScale = 30000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw fail("H.264/AAC encoding unavailable") }
        writer.add(video)
        writer.add(audio)
        let asset = AVURLAsset(url: wav)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw fail("cannot read WAV") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard writer.startWriting(), reader.startReading() else { throw fail("cannot start media processing") }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
              let buffer = pixel else { throw fail("cannot allocate video frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw fail("cannot draw video frame") }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // Interleave streams on one thread to avoid an unbounded asynchronous producer or data race.
        var frame = 0
        var audioDone = false
        var pending: CMSampleBuffer? = output.copyNextSampleBuffer()
        var lastProgress = Date()
        while frame < frames || !audioDone {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            var progress = false
            if frame < frames && video.isReadyForMoreMediaData {
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    throw fail("video append failed: \(writer.error?.localizedDescription ?? "unknown")")
                }
                frame += 1
                progress = true
                if frame == frames { video.markAsFinished() }
            }
            if !audioDone && audio.isReadyForMoreMediaData {
                if let sample = pending {
                    guard audio.append(sample) else { throw fail("audio append failed") }
                    pending = output.copyNextSampleBuffer()
                    progress = true
                } else {
                    guard reader.status != .failed else { throw fail("WAV decode failed") }
                    audio.markAsFinished()
                    audioDone = true
                    progress = true
                }
            }
            if writer.status == .failed || writer.status == .cancelled {
                throw fail(writer.error?.localizedDescription ?? "encoding failed")
            }
            if progress {
                lastProgress = Date()
            } else {
                if Date().timeIntervalSince(lastProgress) > 60 {
                    writer.cancelWriting()
                    throw fail("encoding stalled")
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 120) == .success, writer.status == .completed else {
            throw fail(writer.error?.localizedDescription ?? "encoding failed")
        }
        let result = try inspect(destination)
        guard abs(result.duration - Double(frames) / 30) <= 1.0 / 30 + 0.001 else { throw fail("clip duration mismatch") }
    }

    public func join(_ clips: [URL], to destination: URL) throws {
        guard !clips.isEmpty else { throw fail("no clips") }
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw fail("cannot create composition")
        }
        var cursor = CMTime.zero
        for clip in clips {
            try Task.checkCancellation()
            _ = try inspect(clip)
            let asset = AVURLAsset(url: clip)
            guard let vt = asset.tracks(withMediaType: .video).first, let at = asset.tracks(withMediaType: .audio).first else {
                throw fail("missing tracks")
            }
            let duration = vt.timeRange.duration
            try v.insertTimeRange(CMTimeRange(start: vt.timeRange.start, duration: duration), of: vt, at: cursor)
            // AAC priming/edit lists can produce a slightly shorter audio track. Preserve the video boundary;
            // the uncovered tail is a gap rather than shifting all subsequent slides.
            let audioDuration = CMTimeMinimum(duration, at.timeRange.duration)
            try a.insertTimeRange(CMTimeRange(start: at.timeRange.start, duration: audioDuration), of: at, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else { throw fail("passthrough MP4 export unavailable") }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: .zero, duration: cursor)
        session.shouldOptimizeForNetworkUse = true
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        var waited = 0.0
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            waited += 0.2
            if Task.isCancelled || waited > 600 {
                session.cancelExport()
                _ = done.wait(timeout: .now() + 10)
                if Task.isCancelled { throw CancellationError() }
                throw fail("join timed out")
            }
        }
        guard session.status == .completed else { throw fail(session.error?.localizedDescription ?? "join failed") }
        let result = try inspect(destination)
        guard abs(result.duration - CMTimeGetSeconds(cursor)) <= 1.0 / 30 + 0.001 else { throw fail("joined duration mismatch") }
    }
}
