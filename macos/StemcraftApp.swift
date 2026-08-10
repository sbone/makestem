import AppKit
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
    let readiness: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case path, title, format, codec, channels, lossless, readiness, message
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
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
    @Published var outputChoice: OutputChoice = .both
    @Published var isDropTarget = false

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { inspect(url) }
    }

    func inspect(_ url: URL) {
        state = .inspecting(url.lastPathComponent)
        Task {
            do {
                let result = try await Task.detached { try Engine.inspect(url) }.value
                state = .inspected(result)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func process(_ inspection: Inspection) {
        state = .processing(inspection, ProcessingStatus(stage: "Checking tools and source audio"))
        let choice = outputChoice
        Task {
            do {
                for try await event in Engine.processEvents(
                    URL(fileURLWithPath: inspection.path),
                    choice: choice
                ) {
                    apply(event, to: inspection)
                }
                state = .complete(inspection)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ event: EngineEvent, to inspection: Inspection) {
        guard case .processing(_, var status) = state else { return }
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
        state = .processing(inspection, status)
    }

    func reset() { state = .empty }

    func reveal(_ inspection: Inspection) {
        let source = URL(fileURLWithPath: inspection.path)
        NSWorkspace.shared.open(source.deletingLastPathComponent().appendingPathComponent("output"))
    }
}

enum Engine {
    static var executable: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/stemcraft")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("target/release/stemcraft")
    }

    static func configuredProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [
            "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
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
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw AppError(message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Could not inspect this track.")
        }
        return try JSONDecoder().decode(Inspection.self, from: output.fileHandleForReading.readDataToEndOfFile())
    }

    static func processEvents(
        _ url: URL,
        choice: OutputChoice
    ) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    try process(url, choice: choice) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func process(
        _ url: URL,
        choice: OutputChoice,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) throws {
        var arguments: [String] = ["--events-json"]
        if choice == .acapella { arguments.append("-a") }
        if choice == .instrumental { arguments.append("-i") }
        arguments.append(url.path)
        let process = configuredProcess(arguments: arguments)
        let output = Pipe()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemcraft-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        process.standardOutput = output
        process.standardError = log
        try process.run()
        var buffer = Data()
        var reportedError: String?
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let event = try? JSONDecoder().decode(EngineEvent.self, from: line) else { continue }
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
        guard process.terminationStatus == 0 else {
            try log.synchronize()
            let message = try? String(contentsOf: logURL, encoding: .utf8)
            throw AppError(reportedError ?? message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Stem creation failed.")
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

    var body: some View {
        VStack(spacing: 24) {
            header
            Group {
                switch model.state {
                case .empty: dropZone
                case .inspecting(let name): activity(title: "Inspecting \(name)", detail: "Checking the audio source…")
                case .inspected(let inspection): inspectionCard(inspection)
                case .processing(let inspection, let status): processing(inspection, status)
                case .complete(let inspection): completion(inspection)
                case .failed(let message): failure(message)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 460, idealHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Stemcraft").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Find the blend live. Finish it with Stemcraft.").foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Drop a track here").font(.title2.weight(.semibold))
            Text("FLAC, WAV, and AIFF recommended").foregroundStyle(.secondary)
            Button("Choose Track…") { model.chooseFile() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(.quaternary.opacity(model.isDropTarget ? 0.9 : 0.45), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(model.isDropTarget ? Color.accentColor : .secondary.opacity(0.25), lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
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
            if item.readiness != "blocked" {
                Picker("Create", selection: $model.outputChoice) {
                    ForEach(OutputChoice.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            HStack {
                Button("Choose Another…") { model.chooseFile() }
                Spacer()
                if item.readiness != "blocked" {
                    Button(item.readiness == "warning" ? "Process Anyway" : "Create Stems") { model.process(item) }
                        .buttonStyle(.borderedProminent)
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
                Button("Quit Stemcraft") { NSApplication.shared.terminate(nil) }
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
}

@main
struct StemcraftApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
        Settings { Text("Stemcraft settings are coming soon.").padding(32) }
    }
}
