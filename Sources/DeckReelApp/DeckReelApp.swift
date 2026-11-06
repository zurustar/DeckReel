// DeckReel macOS app: a SwiftUI front end that runs DeckReelCore in-process.
// Apple Events to PowerPoint (sent via osascript) are attributed to DeckReel.app,
// not to a terminal, by macOS privacy controls.
import AppKit
import DeckReelCore
import SwiftUI
import UniformTypeIdentifiers

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
    private var work: Task<URL, Error>?

    var outputExists: Bool {
        guard let outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }
    var canStart: Bool {
        state != .running && inputURL != nil && outputURL != nil && speakerID >= 0
            && (!outputExists || overwrite)
    }

    func loadSpeakers() {
        loadingSpeakers = true
        speakerError = nil
        Task {
            defer { loadingSpeakers = false }
            do {
                let styles = try await Voicevox("http://127.0.0.1:50021").talkStyles()
                self.styles = styles
                if styles.isEmpty {
                    speakerError = "読み上げに使える話者が見つかりません。VOICEVOXの音声ライブラリを確認してください。"
                } else if !styles.contains(where: { $0.id == speakerID }) {
                    speakerID = styles[0].id
                }
            } catch {
                styles = []
                speakerError = Self.friendly(error.localizedDescription)
            }
        }
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
        var cfg = Config(input: inputURL)
        cfg.output = outputURL
        cfg.speaker = speakerID
        cfg.speed = (speed * 100).rounded() / 100
        cfg.emptyNotes = skipEmptyNotes ? .skip : .silence
        cfg.dictionary = dictionaryURL
        cfg.overwrite = overwrite

        log = []
        progress = nil
        state = .running
        var pipeline = Pipeline()
        pipeline.log = { line in Task { @MainActor [weak self] in self?.log.append(line) } }
        pipeline.progress = { current, total in Task { @MainActor [weak self] in self?.progress = (current, total) } }
        // The pipeline does blocking media work; keep it off the main actor.
        let work = Task.detached { try await pipeline.run(cfg) }
        self.work = work
        Task {
            let result = await work.result
            // Let queued log lines land before showing the result.
            await Task.yield()
            switch result {
            case .success(let url): state = .finished(url)
            case .failure(let error) where error is CancellationError: state = .cancelled
            case .failure(let error): state = state == .cancelled ? .cancelled : .failed(Self.friendly(error.localizedDescription))
            }
            self.work = nil
        }
    }

    func cancel() {
        guard let work else { return }
        state = .cancelled
        // Finished stages stay cached; the running one is marked interrupted.
        work.cancel()
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
