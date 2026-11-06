import Foundation
import AVFoundation
import AppKit
import CoreText
import CryptoKit

struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func fail(_ s: String) throws -> Never { throw Failure(s) }
func emit(_ object: Any) throws { let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); FileHandle.standardOutput.write(data) }
func url(_ s: String) -> URL { URL(fileURLWithPath: s) }
func inspect(_ file: String) throws -> [String: Any] {
    let asset = AVURLAsset(url: url(file))
    guard asset.isReadable, let video = asset.tracks(withMediaType: .video).first,
          let audio = asset.tracks(withMediaType: .audio).first else { try fail("MP4 must contain readable video and audio") }
    let size = video.naturalSize.applying(video.preferredTransform)
    let formats = audio.formatDescriptions as! [CMAudioFormatDescription]
    let asbd = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    let vf = video.formatDescriptions as! [CMVideoFormatDescription]
    let codec = vf.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
    guard abs(size.width) == 1920, abs(size.height) == 1080, abs(video.nominalFrameRate - 30) < 0.01,
          codec == kCMVideoCodecType_H264, asbd?.mFormatID == kAudioFormatMPEG4AAC,
          asbd?.mSampleRate == 48000, asbd?.mChannelsPerFrame == 1 else { try fail("unexpected MP4 stream format") }
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration.isFinite && duration > 0 else { try fail("invalid duration") }
    return ["duration": duration, "video_duration": CMTimeGetSeconds(video.timeRange.duration),
            "audio_duration": CMTimeGetSeconds(audio.timeRange.duration), "width": 1920, "height": 1080, "fps": 30]
}
func render(_ pdf: String, _ directory: String) throws {
    guard let document = CGPDFDocument(url(pdf) as CFURL) else { try fail("cannot open exported PDF") }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for index in 1...max(1, document.numberOfPages) {
        guard let page = document.page(at: index) else { try fail("missing PDF page") }
        let width = 1920, height = 1080
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { try fail("cannot allocate image") }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 != 0
        let sourceWidth = rotated ? box.height : box.width
        let sourceHeight = rotated ? box.width : box.height
        let scale = min(CGFloat(width) / sourceWidth, CGFloat(height) / sourceHeight)
        let rect = CGRect(x: (CGFloat(width)-sourceWidth*scale)/2, y: (CGFloat(height)-sourceHeight*scale)/2,
                          width: sourceWidth*scale, height: sourceHeight*scale)
        // A white slide background inside a black letterbox also supports PDFs without an explicit background.
        context.setFillColor(NSColor.white.cgColor); context.fill(rect)
        // getDrawingTransform only scales down, never up, so scale explicitly and use it
        // just for crop-box origin and page rotation at the page's own size.
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { try fail("cannot render page") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { try fail("cannot encode PNG") }
        try png.write(to: url(directory).appendingPathComponent(String(format: "%04d.png", index)), options: .atomic)
    }
    try emit(["count": document.numberOfPages])
}
func clip(_ image: String, _ wav: String, _ destination: String, _ frames: Int) throws {
    guard frames > 0, let source = NSImage(contentsOfFile: image),
          let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { try fail("cannot read slide image") }
    let writer = try AVAssetWriter(outputURL: url(destination), fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoExpectedSourceFrameRateKey: 30,
                                         AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false]])
    video.mediaTimeScale = 30000
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
    guard writer.canAdd(video), writer.canAdd(audio) else { try fail("H.264/AAC encoding unavailable") }
    writer.add(video); writer.add(audio)
    let asset = AVURLAsset(url: url(wav))
    guard let track = asset.tracks(withMediaType: .audio).first else { try fail("cannot read WAV") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    guard writer.startWriting(), reader.startReading() else { try fail("cannot start media processing") }
    writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool,
          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let buffer = pixel else { try fail("cannot allocate video frame") }
    CVPixelBufferLockBaseAddress(buffer, [])
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { try fail("cannot draw video frame") }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    // Interleave streams on one thread to avoid an unbounded asynchronous producer or data race.
    var frame = 0, audioDone = false
    var pending: CMSampleBuffer? = output.copyNextSampleBuffer()
    var lastProgress = Date()
    while frame < frames || !audioDone {
        var progress = false
        if frame < frames && video.isReadyForMoreMediaData {
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                try fail("video append failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
            frame += 1; progress = true
            if frame == frames { video.markAsFinished() }
        }
        if !audioDone && audio.isReadyForMoreMediaData {
            if let sample = pending {
                guard audio.append(sample) else { try fail("audio append failed") }
                pending = output.copyNextSampleBuffer(); progress = true
            } else {
                guard reader.status != .failed else { try fail("WAV decode failed") }
                audio.markAsFinished(); audioDone = true; progress = true
            }
        }
        if writer.status == .failed || writer.status == .cancelled { try fail(writer.error?.localizedDescription ?? "encoding failed") }
        if progress { lastProgress = Date() } else {
            if Date().timeIntervalSince(lastProgress) > 60 { writer.cancelWriting(); try fail("encoding stalled") }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    guard done.wait(timeout: .now()+120) == .success, writer.status == .completed else { try fail(writer.error?.localizedDescription ?? "encoding failed") }
    let result = try inspect(destination)
    guard let duration = result["duration"] as? Double, abs(duration-Double(frames)/30) <= 1.0/30+0.001 else { try fail("clip duration mismatch") }
    try emit(result)
}
func join(_ list: String, _ destination: String) throws {
    let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: url(list)))
    guard !paths.isEmpty else { try fail("no clips") }
    let composition = AVMutableComposition()
    guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { try fail("cannot create composition") }
    var cursor = CMTime.zero
    for path in paths {
        _ = try inspect(path)
        let asset = AVURLAsset(url: url(path))
        guard let vt = asset.tracks(withMediaType: .video).first, let at = asset.tracks(withMediaType: .audio).first else { try fail("missing tracks") }
        let duration = vt.timeRange.duration
        try v.insertTimeRange(CMTimeRange(start: vt.timeRange.start, duration: duration), of: vt, at: cursor)
        // AAC priming/edit lists can produce a slightly shorter audio track. Preserve the video boundary;
        // the uncovered tail is a gap rather than shifting all subsequent slides.
        let audioDuration = CMTimeMinimum(duration, at.timeRange.duration)
        try a.insertTimeRange(CMTimeRange(start: at.timeRange.start, duration: audioDuration), of: at, at: cursor)
        cursor = CMTimeAdd(cursor, duration)
    }
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
          session.supportedFileTypes.contains(.mp4) else { try fail("passthrough MP4 export unavailable") }
    session.outputURL = url(destination); session.outputFileType = .mp4
    session.timeRange = CMTimeRange(start: .zero, duration: cursor)
    session.shouldOptimizeForNetworkUse = true
    let done = DispatchSemaphore(value: 0)
    session.exportAsynchronously { done.signal() }
    guard done.wait(timeout: .now()+600) == .success, session.status == .completed else { session.cancelExport(); try fail(session.error?.localizedDescription ?? "join failed") }
    let result = try inspect(destination)
    guard let duration = result["duration"] as? Double, abs(duration-CMTimeGetSeconds(cursor)) <= 1.0/30+0.001 else { try fail("joined duration mismatch") }
    try emit(result)
}
func info() throws {
    let names = (CTFontManagerCopyAvailablePostScriptNames() as! [String]).sorted()
    var records = [String]()
    for name in names {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        if let location = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: location.path) {
            records.append("\(name)|\(location.path)|\(attrs[.modificationDate] ?? "")|\(attrs[.size] ?? "")")
        } else { records.append(name) }
    }
    let digest = SHA256.hash(data: Data(records.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    try emit(["os": ProcessInfo.processInfo.operatingSystemVersionString, "fonts_sha256": digest, "native_version": 1])
}

do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { try fail("missing command") }
    switch args[1] {
    case "info": try info()
    case "render": guard args.count == 4 else { try fail("render PDF DIRECTORY") }; try render(args[2], args[3])
    case "clip": guard args.count == 6, let frames = Int(args[5]) else { try fail("clip IMAGE WAV OUTPUT FRAMES") }; try clip(args[2], args[3], args[4], frames)
    case "join": guard args.count == 4 else { try fail("join JSON_LIST OUTPUT") }; try join(args[2], args[3])
    case "inspect": guard args.count == 3 else { try fail("inspect MP4") }; try emit(inspect(args[2]))
    default: try fail("unknown command")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
