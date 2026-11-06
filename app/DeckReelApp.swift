// DeckReel macOS app: a SwiftUI front end for the bundled deckreel CLI.
// The CLI runs as a child process so Apple Events to PowerPoint are attributed
// to DeckReel.app (not to a terminal) by macOS privacy controls.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TalkStyle: Decodable, Identifiable, Hashable {
    let id: Int
    let speaker: String
    let style: String
}

private struct CLIEvent: Decodable {
    let type: String
    let message: String?
    let current: Int?
    let total: Int?
    let output: String?
}

enum RunState: Equatable {
    case idle
    case running
    case finished(URL)
    case failed(String)
    case cancelled
}

@MainActor @Observable
final class AppModel {
    var inputURL: URL? {
        didSet {
            guard let inputURL else { return }
            outputURL = inputURL.deletingPathExtension().appendingPathExtension("mp4")
            overwrite = false
        }
    }
    var outputURL: URL?
    var overwrite = false
    var dictionaryURL: URL?

    var styles: [TalkStyle] = []
    var speakerError: String?
    var loadingSpeakers = false
    var speakerID: Int = UserDefaults.standard.object(forKey: "speakerID") as? Int ?? -1 {
        didSet { UserDefaults.standard.set(speakerID, forKey: "speakerID") }
    }
    var speed: Double = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(speed, forKey: "speed") }
    }
    var skipEmptyNotes = UserDefaults.standard.bool(forKey: "skipEmptyNotes") {
        didSet { UserDefaults.standard.set(skipEmptyNotes, forKey: "skipEmptyNotes") }
    }

    // View state lives here: Command Line Tools ship no SwiftUIMacros plugin for @State.
    var dropTargeted = false
    var showLog = false

    var state: RunState = .idle
    var progress: (current: Int, total: Int)?
    var log: [String] = []
    private var process: Process?

    var outputExists: Bool {
        guard let outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }
    var canStart: Bool {
        state != .running && inputURL != nil && outputURL != nil && speakerID >= 0
            && (!outputExists || overwrite)
    }

    /// The CLI bundled at Contents/Helpers/deckreel, or DECKREEL_CLI for development.
    private var cliURL: URL {
        if let override = ProcessInfo.processInfo.environment["DECKREEL_CLI"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/deckreel")
    }

    func loadSpeakers() {
        loadingSpeakers = true
        speakerError = nil
        let cli = cliURL
        Task.detached {
            let result = Self.runOnce(cli, ["--list-speakers", "--json"])
            await MainActor.run {
                self.loadingSpeakers = false
                switch result {
                case .success(let data):
                    if let styles = try? JSONDecoder().decode([TalkStyle].self, from: data), !styles.isEmpty {
                        self.styles = styles
                        if !styles.contains(where: { $0.id == self.speakerID }) {
                            self.speakerID = styles[0].id
                        }
                    } else {
                        self.styles = []
                        self.speakerError = "読み上げに使える話者が見つかりません。VOICEVOXの音声ライブラリを確認してください。"
                    }
                case .failure(let message):
                    self.styles = []
                    self.speakerError = message
                }
            }
        }
    }

    private enum OnceResult: Sendable { case success(Data), failure(String) }

    nonisolated private static func runOnce(_ cli: URL, _ args: [String]) -> OnceResult {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return .failure("DeckReelの処理本体を起動できません: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Self.friendly(message))
        }
        return .success(data)
    }

    nonisolated static func friendly(_ message: String) -> String {
        if message.contains("VOICEVOX") && message.contains("unavailable") {
            return "VOICEVOXに接続できません。VOICEVOXを起動してから再読み込みしてください。"
        }
        if message.contains("automation not permitted") || message.contains("Automation permission") {
            return "PowerPointを操作できません。システム設定 → プライバシーとセキュリティ → オートメーション で、DeckReelにMicrosoft PowerPointの操作を許可してください。"
        }
        return message.isEmpty ? "不明なエラーが発生しました。" : message
    }

    func start() {
        guard canStart, let inputURL, let outputURL else { return }
        var args = [inputURL.path, "--json", "--output", outputURL.path,
                    "--speaker", String(speakerID), "--speed", String(format: "%.2f", speed)]
        if skipEmptyNotes { args += ["--empty-notes", "skip"] }
        if let dictionaryURL { args += ["--dictionary", dictionaryURL.path] }
        if overwrite { args.append("--overwrite") }

        let p = Process()
        p.executableURL = cliURL
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        log = []
        progress = nil
        state = .running
        var stdoutBuffer = Data()
        var finalEvent: CLIEvent?
        var stderrText = ""

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                stdoutBuffer.append(chunk)
                while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = stdoutBuffer[stdoutBuffer.startIndex..<nl]
                    stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
                    guard let ev = try? JSONDecoder().decode(CLIEvent.self, from: Data(line)) else { continue }
                    switch ev.type {
                    case "log": self.log.append(ev.message ?? "")
                    case "progress":
                        if let c = ev.current, let t = ev.total { self.progress = (c, t) }
                    case "done", "error": finalEvent = ev
                    default: break
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { stderrText += String(decoding: chunk, as: UTF8.self) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // Drain remaining output after the readability handlers have run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.process = nil
                if status == 0, let path = finalEvent?.output {
                    self.state = .finished(URL(fileURLWithPath: path))
                } else if status == 130 || self.state == .cancelled {
                    self.state = .cancelled
                } else {
                    let message = finalEvent?.message ?? stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .failed(Self.friendly(message))
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            state = .failed("DeckReelの処理本体を起動できません: \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        state = .cancelled
        process.interrupt()  // SIGINT: the CLI stops cleanly and keeps finished cache entries.
    }
}

@main
struct DeckReelApp: App {
    private let model = AppModel()

    var body: some Scene {
        Window("DeckReel", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 520, minHeight: 560)
                .onAppear { model.loadSpeakers() }
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                Section("資料") {
                    DropZone()
                }
                Section("ナレーション") {
                    speakerRow
                    LabeledContent("速度") {
                        HStack {
                            Slider(value: $model.speed, in: 0.5...2.0, step: 0.05)
                            Text(String(format: "%.2f×", model.speed))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    Picker("ノートが空のスライド", selection: $model.skipEmptyNotes) {
                        Text("3秒表示").tag(false)
                        Text("除外").tag(true)
                    }
                    LabeledContent("読み辞書") {
                        HStack {
                            Text(model.dictionaryURL?.lastPathComponent ?? "なし")
                                .foregroundStyle(model.dictionaryURL == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if model.dictionaryURL != nil {
                                Button("解除") { model.dictionaryURL = nil }
                            }
                            Button("選択…") { chooseDictionary() }
                        }
                    }
                }
                Section("出力") {
                    LabeledContent("保存先") {
                        HStack {
                            Text(model.outputURL?.path(percentEncoded: false) ?? "資料を選ぶと自動で決まります")
                                .foregroundStyle(model.outputURL == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button("変更…") { chooseOutput() }.disabled(model.inputURL == nil)
                        }
                    }
                    if model.outputExists {
                        Toggle("既存のファイルを上書きする", isOn: $model.overwrite)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.state == .running)

            Divider()
            StatusBar().padding(16)
        }
    }

    @ViewBuilder private var speakerRow: some View {
        @Bindable var model = model
        if let error = model.speakerError {
            LabeledContent("話者") {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("再読み込み") { model.loadSpeakers() }
                }
            }
        } else {
            HStack {
                Picker("話者", selection: $model.speakerID) {
                    ForEach(groupedStyles, id: \.0) { speaker, styles in
                        Section(speaker) {
                            ForEach(styles) { s in Text("\(s.speaker)（\(s.style)）").tag(s.id) }
                        }
                    }
                }
                .disabled(model.styles.isEmpty)
                Button {
                    model.loadSpeakers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("VOICEVOXから話者一覧を再読み込み")
                .disabled(model.loadingSpeakers)
            }
        }
    }

    private var groupedStyles: [(String, [TalkStyle])] {
        var order: [String] = []
        var groups: [String: [TalkStyle]] = [:]
        for s in model.styles {
            if groups[s.speaker] == nil { order.append(s.speaker) }
            groups[s.speaker, default: []].append(s)
        }
        return order.map { ($0, groups[$0]!) }
    }

    private func chooseDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK { model.dictionaryURL = panel.url }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = model.outputURL?.lastPathComponent ?? "output.mp4"
        panel.directoryURL = model.outputURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            model.outputURL = url
            // NSSavePanel already asked the user to confirm replacing an existing file.
            model.overwrite = FileManager.default.fileExists(atPath: url.path)
        }
    }
}

struct DropZone: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: model.inputURL == nil ? "doc.badge.plus" : "doc.richtext")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            if let url = model.inputURL {
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            } else {
                Text("発表者ノート付きのPPTXをドロップ").font(.headline)
            }
            Button(model.inputURL == nil ? "ファイルを選択…" : "別のファイルを選択…") { choose() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(model.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pptx" }) else { return false }
            model.inputURL = url
            return true
        } isTargeted: { model.dropTargeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pptx") ?? .data]
        if panel.runModal() == .OK { model.inputURL = panel.url }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .running:
                if let p = model.progress {
                    ProgressView(value: Double(p.current), total: Double(p.total)) {
                        Text("スライド \(p.current) / \(p.total)")
                    }
                } else {
                    ProgressView { Text(model.log.last ?? "準備中…") }.progressViewStyle(.linear)
                }
            case .finished(let url):
                HStack {
                    Label("完成しました", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("再生") { NSWorkspace.shared.open(url) }
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .cancelled:
                Label("中止しました。再実行すると完了済みのスライドは再利用されます。", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
            HStack {
                if !model.log.isEmpty {
                    Toggle("ログ", isOn: $model.showLog).toggleStyle(.button)
                }
                Spacer()
                if model.state == .running {
                    Button("中止", role: .cancel) { model.cancel() }
                } else {
                    Button("動画を作成") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
            }
            if model.showLog {
                ScrollView {
                    Text(model.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
        }
    }
}
