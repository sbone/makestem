import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum OutputChoice: String, CaseIterable, Identifiable {
    case both = "Both"
    case acapella = "Acapella"
    case instrumental = "Instrumental"
    var id: Self { self }
}

struct Inspection: Codable, Sendable {
    let path: String
    let title: String
    let format: String
    let codec: String
    let durationSeconds: Double
    let sampleRate: Int?
    let channels: Int?
    let bitDepth: Int?
    let lossless: Bool
    let sourceBitrateKbps: Int?
    let sourceVbr: Bool?
    let outputQuality: String
    let readiness: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case path, title, format, codec, channels, lossless, readiness, message
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case sourceBitrateKbps = "source_bitrate_kbps"
        case sourceVbr = "source_vbr"
        case outputQuality = "output_quality"
    }
}

enum ScreenState {
    case empty
    case inspecting(String)
    case inspected(Inspection)
    case processing(Inspection, ProcessingStatus)
    case complete(Inspection)
    case failed(String)
}

enum ModelState {
    case missing
    case downloading(ProcessingStatus)
    case ready
    case failed(String)
}

struct ProcessingStatus: Sendable {
    var stage: String
    var percent: Int?
    let startedAt: Date
    var phaseStartedAt: Date
    var progressStartedAt: Date?
    var progressBaseline: Int?

    init(stage: String) {
        self.stage = stage
        self.percent = nil
        self.startedAt = Date()
        self.phaseStartedAt = Date()
    }

    func estimatedRemaining(at now: Date) -> TimeInterval? {
        guard let percent, percent < 100,
              let progressStartedAt, let progressBaseline,
              percent > progressBaseline else { return nil }
        let elapsed = now.timeIntervalSince(progressStartedAt)
        guard elapsed >= 2 else { return nil }
        let rate = Double(percent - progressBaseline) / elapsed
        guard rate > 0 else { return nil }
        return Double(100 - percent) / rate
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: ScreenState = .empty
    @Published var modelState: ModelState = Engine.modelIsReady ? .ready : .missing
    @Published var outputChoice: OutputChoice = .both
    @Published var isDropTarget = false
    private var currentOperation: EventOperation?
    private var currentOperationID: UUID?
    private var inspectionID: UUID?

    var isDownloadingModel: Bool {
        if case .downloading = modelState { return true }
        return false
    }

    var canSelectTrack: Bool {
        if case .ready = modelState { return true }
        return false
    }

    func chooseFile() {
        guard canSelectTrack else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { inspect(url) }
    }

    func inspect(_ url: URL) {
        guard canSelectTrack else { return }
        let inspectionID = UUID()
        self.inspectionID = inspectionID
        state = .inspecting(url.lastPathComponent)
        Task {
            do {
                let result = try await Task.detached { try Engine.inspect(url) }.value
                guard self.inspectionID == inspectionID else { return }
                state = .inspected(result)
            } catch {
                guard self.inspectionID == inspectionID else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func reportDropFailure(_ detail: String?) {
        let detail = detail.map { "\n\n\($0)" } ?? ""
        state = .failed(
            "Couldn’t open the dropped item.\(detail)\n\nChoose Another Track and select an audio file."
        )
    }

    func process(_ inspection: Inspection, choice: OutputChoice, replace: Bool) {
        state = .processing(inspection, ProcessingStatus(stage: "Checking tools and source audio"))
        let operation = Engine.processEvents(
            URL(fileURLWithPath: inspection.path),
            choice: choice,
            replace: replace
        )
        let operationID = UUID()
        currentOperation = operation
        currentOperationID = operationID
        Task {
            do {
                for try await event in operation.events {
                    guard currentOperationID == operationID else { return }
                    apply(event, to: inspection)
                }
                guard currentOperationID == operationID else { return }
                finishOperation()
                modelState = .ready
                state = .complete(inspection)
            } catch {
                guard currentOperationID == operationID else { return }
                finishOperation()
                state = .failed(error.localizedDescription)
            }
        }
    }

    func downloadModel() {
        modelState = .downloading(ProcessingStatus(stage: "Starting model download"))
        let operation = Engine.modelEvents()
        let operationID = UUID()
        currentOperation = operation
        currentOperationID = operationID
        Task {
            do {
                for try await event in operation.events {
                    guard currentOperationID == operationID else { return }
                    applyModel(event)
                }
                guard currentOperationID == operationID else { return }
                finishOperation()
                modelState = .ready
            } catch {
                guard currentOperationID == operationID else { return }
                finishOperation()
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelModelDownload() {
        currentOperationID = nil
        currentOperation?.cancel()
        currentOperation = nil
        modelState = Engine.modelIsReady ? .ready : .missing
    }

    func cancelProcessing(_ inspection: Inspection) {
        currentOperationID = nil
        currentOperation?.cancel()
        currentOperation = nil
        state = .inspected(inspection)
    }

    private func finishOperation() {
        currentOperation = nil
        currentOperationID = nil
    }

    private func applyModel(_ event: EngineEvent) {
        guard case .downloading(var status) = modelState else { return }
        update(&status, with: event)
        modelState = .downloading(status)
    }

    private func apply(_ event: EngineEvent, to inspection: Inspection) {
        guard case .processing(_, var status) = state else { return }
        update(&status, with: event)
        state = .processing(inspection, status)
    }

    private func update(_ status: inout ProcessingStatus, with event: EngineEvent) {
        switch event.type {
        case "stage_started":
            status.stage = event.label ?? "Working…"
            status.percent = nil
            status.phaseStartedAt = Date()
            status.progressStartedAt = nil
            status.progressBaseline = nil
        case "stage_progress":
            status.stage = event.detail ?? status.stage
            if let percent = event.percent {
                if status.progressStartedAt == nil {
                    status.progressStartedAt = Date()
                    status.progressBaseline = percent
                }
                status.percent = percent
            }
        case "stage_completed":
            status.stage = event.label.map { "Finished \($0.lowercased())" } ?? status.stage
            status.percent = status.percent.map { _ in 100 }
        default:
            return
        }
    }

    func reset() { state = .empty }

    func reveal(_ inspection: Inspection) {
        let source = URL(fileURLWithPath: inspection.path)
        NSWorkspace.shared.open(source.deletingLastPathComponent().appendingPathComponent("output"))
    }
}

enum Engine {
    static let modelSize: UInt64 = 336_125_008

    static var modelIsReady: Bool {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let path = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Caches/demucs-rs/htdemucs_ft.safetensors").path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.uint64Value == modelSize
    }

    static var executable: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/makestem")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("target/release/makestem")
    }

    static func configuredProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundledTools = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin").path
        environment["PATH"] = [
            bundledTools, "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ].joined(separator: ":")
        process.environment = environment
        return process
    }

    static func inspect(_ url: URL) throws -> Inspection {
        let process = configuredProcess(arguments: ["--inspect-json", url.path])
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw AppError("Could not start MakeStem’s audio engine: \(error.localizedDescription)\n\nQuit and reopen MakeStem, then try again.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw AppError(message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Could not inspect this track.")
        }
        do {
            return try JSONDecoder().decode(
                Inspection.self,
                from: output.fileHandleForReading.readDataToEndOfFile()
            )
        } catch {
            throw AppError("MakeStem could not understand the audio inspection result.\n\nQuit and reopen MakeStem, then try the track again.")
        }
    }

    static func processEvents(
        _ url: URL,
        choice: OutputChoice,
        replace: Bool
    ) -> EventOperation {
        var arguments: [String] = ["--events-json"]
        if choice == .acapella { arguments.append("-a") }
        if choice == .instrumental { arguments.append("-i") }
        if replace { arguments.append("--replace") }
        arguments.append(url.path)
        return eventStream(arguments: arguments, cleanup: outputURLs(url, choice: choice))
    }

    static func modelEvents() -> EventOperation {
        eventStream(arguments: ["--prepare-model"], cleanup: [])
    }

    private static func eventStream(
        arguments: [String],
        cleanup: [URL]
    ) -> EventOperation {
        let controller = ProcessController(cleanup: cleanup)
        let events = AsyncThrowingStream<EngineEvent, Error> { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination { controller.cancel() }
            }
            Task.detached {
                do {
                    try run(arguments: arguments, controller: controller) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return EventOperation(events: events) { controller.cancel() }
    }

    private static func run(
        arguments: [String],
        controller: ProcessController,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) throws {
        let process = configuredProcess(arguments: arguments)
        process.environment?["MAKESTEM_PROCESS_GROUP"] = "1"
        let output = Pipe()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("makestem-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log: FileHandle
        do {
            log = try FileHandle(forWritingTo: logURL)
        } catch {
            throw AppError("Could not create a temporary processing log: \(error.localizedDescription)\n\nCheck available disk space and try again.")
        }
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        process.standardOutput = output
        process.standardError = log
        do {
            try process.run()
        } catch {
            throw AppError("Could not start MakeStem’s audio engine: \(error.localizedDescription)\n\nQuit and reopen MakeStem, then try again.")
        }
        controller.attach(process)
        var buffer = Data()
        var reportedError: String?
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let event = try decodeEvent(Data(line))
                if event.type == "error" {
                    reportedError = [event.message, event.guidance]
                        .compactMap { $0 }
                        .joined(separator: "\n\n")
                } else {
                    onEvent(event)
                }
            }
        }
        process.waitUntilExit()
        controller.finished()
        guard process.terminationStatus == 0 else {
            try log.synchronize()
            let message = try? String(contentsOf: logURL, encoding: .utf8)
            throw AppError(reportedError ?? message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Stem creation failed.")
        }
    }

    static func decodeEvent(_ data: Data) throws -> EngineEvent {
        do {
            return try JSONDecoder().decode(EngineEvent.self, from: data)
        } catch {
            throw AppError("MakeStem received an unreadable progress update.\n\nQuit and reopen MakeStem, then try again.")
        }
    }

    static func outputURLs(_ source: URL, choice: OutputChoice) -> [URL] {
        let parent = source.deletingLastPathComponent()
        let output = parent.appendingPathComponent("output")
        let base = source.deletingPathExtension().lastPathComponent
        var paths: [URL] = []
        if choice == .both || choice == .acapella {
            paths.append(output.appendingPathComponent("\(base) (Acapella).mp3"))
        }
        if choice == .both || choice == .instrumental {
            paths.append(output.appendingPathComponent("\(base) (Instrumental).mp3"))
        }
        return paths
    }

    static func existingOutputs(_ source: URL, choice: OutputChoice) -> [URL] {
        outputURLs(source, choice: choice).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

struct EventOperation: Sendable {
    let events: AsyncThrowingStream<EngineEvent, Error>
    let cancel: @Sendable () -> Void
}

final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let cleanup: [URL]

    init(cleanup: [URL]) { self.cleanup = cleanup }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { terminate(process) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if let process { terminate(process) }
    }

    func finished() {
        lock.lock()
        let wasCancelled = cancelled
        let processID = process?.processIdentifier
        process = nil
        lock.unlock()
        guard wasCancelled else { return }
        if let processID {
            let work = cleanup.first?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".makestem-work-\(processID)")
            if let work { try? FileManager.default.removeItem(at: work) }
            for (index, destination) in cleanup.enumerated() {
                let directory = destination.deletingLastPathComponent()
                let temporary = directory.appendingPathComponent(
                    ".makestem-output-\(processID)-\(index).mp3"
                )
                let backup = directory.appendingPathComponent(
                    ".makestem-backup-\(processID)-\(index).mp3"
                )
                try? FileManager.default.removeItem(at: temporary)
                if FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.moveItem(at: backup, to: destination)
                }
            }
        }
    }

    private func terminate(_ process: Process) {
        let group = -pid_t(process.processIdentifier)
        if Darwin.kill(group, SIGTERM) != 0, process.isRunning {
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            if process.isRunning { Darwin.kill(group, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { Darwin.kill(group, SIGKILL) }
        }
    }

}

struct EngineEvent: Codable, Sendable {
    let type: String
    let label: String?
    let detail: String?
    let percent: Int?
    let message: String?
    let guidance: String?
}

struct AppError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showsModelInfo = false
    @State private var replacementRequest: ReplacementRequest?

    var body: some View {
        VStack(spacing: 24) {
            header
            if model.canSelectTrack {
                switch model.state {
                case .empty: dropZone
                case .inspecting(let name): activity(title: "Inspecting \(name)", detail: "Checking the audio source…")
                case .inspected(let inspection): inspectionCard(inspection)
                case .processing(let inspection, let status): processing(inspection, status)
                case .complete(let inspection): completion(inspection)
                case .failed(let message): failure(message)
                }
            } else {
                modelAction
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Replace existing files?",
            isPresented: Binding(
                get: { replacementRequest != nil },
                set: { if !$0 { replacementRequest = nil } }
            ),
            presenting: replacementRequest
        ) { request in
            Button("Cancel", role: .cancel) {}
            Button("Replace Existing", role: .destructive) {
                model.process(request.inspection, choice: request.choice, replace: true)
                replacementRequest = nil
            }
        } message: { request in
            Text(replacementMessage(request.outputs))
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch model.modelState {
        case .missing:
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("One-time model download").font(.headline)
                    Text("MakeStem needs the fine-tuned htdemucs_ft audio model (about 336 MB). All processing stays local.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download Model") { model.downloadModel() }.buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        case .downloading(let status):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.circle.fill").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(status.stage).font(.headline)
                        if let percent = status.percent {
                            ProgressView(value: Double(percent), total: 100)
                            HStack {
                                Text("\(percent)%")
                                Spacer()
                                if let remaining = status.estimatedRemaining(at: context.date) {
                                    Text("About \(duration(remaining)) remaining")
                                }
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                        Button("Cancel") { model.cancelModelDownload() }
                    }
                }
                .padding(16)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        case .ready:
            EmptyView()
        case .failed(let message):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Model download failed").font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Try Again") { model.downloadModel() }
            }
            .padding(16)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MakeStem").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Find the blend live. Finish it with MakeStem.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            headerModelStatus
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var headerModelStatus: some View {
        HStack(spacing: 9) {
            switch model.modelState {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio model ready").font(.callout.weight(.semibold))
                    Text("Processing stays local").font(.caption).foregroundStyle(.secondary)
                }
            case .missing:
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio model needed").font(.callout.weight(.semibold))
                    Text("One-time download").font(.caption).foregroundStyle(.secondary)
                }
            case .downloading(let status):
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading model").font(.callout.weight(.semibold))
                    Text(status.percent.map { "\($0)% complete" } ?? "Preparing…")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model unavailable").font(.callout.weight(.semibold))
                    Text("Download needs attention").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("About the audio model", systemImage: "info.circle") {
                showsModelInfo.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("About the audio model")
            .popover(isPresented: $showsModelInfo, arrowEdge: .bottom) {
                modelInfo
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
    }

    private var modelInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("htdemucs_ft").font(.headline)
                    Text("Fine-tuned Demucs audio-separation model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("This model analyzes a track and separates vocals, drums, bass, and other sounds. MakeStem uses those parts to create its acapellas and instrumentals.")
                .fixedSize(horizontal: false, vertical: true)

            Text("The model is downloaded from a public repository hosted by Hugging Face, a platform for sharing machine-learning models. Once downloaded, it runs locally and your tracks are never uploaded.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(
                "View model source on Hugging Face",
                destination: URL(string: "https://huggingface.co/set-soft/audio_separation")!
            )
        }
        .font(.callout)
        .padding(18)
        .frame(width: 360)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Drop a track here").font(.title2.weight(.semibold))
            Text("Create an acapella, instrumental, or both")
                .font(.callout.weight(.medium))
            Text("FLAC, WAV, and AIFF recommended")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Track…") { model.chooseFile() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .background(.quaternary.opacity(model.isDropTarget ? 0.9 : 0.45), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(model.isDropTarget ? Color.accentColor : .secondary.opacity(0.25), lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    let detail = error?.localizedDescription
                    Task { @MainActor in model.reportDropFailure(detail) }
                    return
                }
                Task { @MainActor in model.inspect(url) }
            }
            return true
        }
    }

    private func inspectionCard(_ item: Inspection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: item.readiness == "ready" ? "checkmark.circle.fill" : item.readiness == "warning" ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .font(.title).foregroundStyle(statusColor(item.readiness))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(summary(item)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(item.message).fixedSize(horizontal: false, vertical: true)
            Label("Output: \(item.outputQuality)", systemImage: "waveform.badge.checkmark")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if item.readiness != "blocked" {
                Picker("Create", selection: $model.outputChoice) {
                    ForEach(OutputChoice.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            HStack {
                Button("Choose Another…") { model.chooseFile() }
                Spacer()
                if item.readiness != "blocked" {
                    Button(
                        model.isDownloadingModel
                            ? "Model Downloading…"
                            : item.readiness == "warning" ? "Process Anyway" : "Create Stems"
                    ) { beginProcessing(item) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDownloadingModel)
                }
            }
        }
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.secondary.opacity(0.2)))
    }

    private func activity(title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            Text(detail).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 260)
    }

    private func processing(_ item: Inspection, _ status: ProcessingStatus) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 16) {
                Image(systemName: "waveform").font(.system(size: 38)).foregroundStyle(.tint)
                Text(item.title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(status.stage).foregroundStyle(.secondary)
                if let percent = status.percent {
                    ProgressView(value: Double(percent), total: 100)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 420)
                    HStack {
                        Text("\(percent)%")
                        Spacer()
                        if let remaining = status.estimatedRemaining(at: context.date) {
                            Text("About \(duration(remaining)) remaining")
                        } else {
                            Text("Calculating time remaining…")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text("Elapsed \(duration(context.date.timeIntervalSince(status.startedAt)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Button("Cancel") { model.cancelProcessing(item) }
            }.frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    private func completion(_ item: Inspection) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("Stems created").font(.title2.weight(.semibold))
            Text("Your files are ready in the output folder.").foregroundStyle(.secondary)
            HStack {
                Button("Process Another") { model.reset() }
                Button("Quit MakeStem") { NSApplication.shared.terminate(nil) }
                Button("Reveal in Finder") { model.reveal(item) }.buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, minHeight: 260)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(.orange)
            Text("Couldn’t finish").font(.title2.weight(.semibold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Choose Another Track") { model.chooseFile() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, minHeight: 260)
    }

    private func statusColor(_ readiness: String) -> Color {
        readiness == "ready" ? .green : readiness == "warning" ? .orange : .red
    }

    private func summary(_ item: Inspection) -> String {
        var parts = [item.format, item.lossless ? "Lossless" : "Compressed"]
        if let bitrate = item.sourceBitrateKbps {
            parts.append(item.sourceVbr == true ? "~\(bitrate) kbps VBR" : "\(bitrate) kbps")
        }
        if let depth = item.bitDepth { parts.append("\(depth)-bit") }
        if let rate = item.sampleRate { parts.append(String(format: "%.1f kHz", Double(rate) / 1000)) }
        if let channels = item.channels { parts.append(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels") }
        let minutes = Int(item.durationSeconds) / 60
        let seconds = Int(item.durationSeconds) % 60
        parts.append(String(format: "%d:%02d", minutes, seconds))
        return parts.joined(separator: " • ")
    }

    private func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func beginProcessing(_ inspection: Inspection) {
        let choice = model.outputChoice
        let outputs = Engine.existingOutputs(
            URL(fileURLWithPath: inspection.path),
            choice: choice
        )
        if outputs.isEmpty {
            model.process(inspection, choice: choice, replace: false)
        } else {
            replacementRequest = ReplacementRequest(
                inspection: inspection,
                choice: choice,
                outputs: outputs
            )
        }
    }

    private func replacementMessage(_ outputs: [URL]) -> String {
        let names = outputs.map(\.lastPathComponent)
        let list = names.count == 1 ? names[0] : names.joined(separator: "\n")
        return "MakeStem already created:\n\n\(list)\n\nThe existing file\(names.count == 1 ? "" : "s") will be replaced only after the new stems finish successfully."
    }
}

private struct ReplacementRequest: Identifiable {
    let id = UUID()
    let inspection: Inspection
    let choice: OutputChoice
    let outputs: [URL]
}

@main
struct MakeStemApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}
