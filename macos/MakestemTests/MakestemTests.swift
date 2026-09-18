import XCTest
@testable import Makestem

final class MakestemTests: XCTestCase {
    @MainActor
    func testScreenshotStatesAreDeterministicAndOptIn() {
        XCTAssertNil(AppModel.screenshotModel(arguments: ["Makestem"]))
        XCTAssertNil(
            AppModel.screenshotModel(
                arguments: ["Makestem", "--screenshot-state", "unknown"]
            )
        )

        let ready = AppModel.screenshotModel(
            arguments: ["Makestem", "--screenshot-state", "ready"]
        )
        XCTAssertTrue(ready?.isScreenshotMode == true)
        XCTAssertTrue(ready?.canSelectTrack == true)
        guard case .empty = ready?.state else {
            return XCTFail("Expected the ready screenshot state")
        }

        let loaded = AppModel.screenshotModel(
            arguments: ["Makestem", "--screenshot-state", "loaded-compressed"]
        )
        guard case .inspected(let inspection) = loaded?.state else {
            return XCTFail("Expected the loaded screenshot state")
        }
        XCTAssertEqual(inspection.displayTitle, "Example Artist — Midnight Drive")

        let processing = AppModel.screenshotModel(
            arguments: ["Makestem", "--screenshot-state", "processing"]
        )
        guard case .processing(_, let status) = processing?.state else {
            return XCTFail("Expected the processing screenshot state")
        }
        XCTAssertEqual(status.percent, 42)
    }

    func testTrackDisplayTitleGracefullyHandlesMissingArtist() throws {
        let base = #"{"path":"/Music/Track.flac","title":"Track","format":"FLAC","codec":"flac","duration_seconds":120,"sample_rate":44100,"channels":2,"bit_depth":24,"lossless":true,"source_bitrate_kbps":null,"source_vbr":null,"output_quality":"320 kbps MP3","readiness":"ready","message":"Ready"}"#
        let withArtist = base.replacingOccurrences(
            of: #""title":"Track""#,
            with: #""artist":"The Artist","title":"Track""#
        )

        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(Inspection.self, from: Data(withArtist.utf8)).displayTitle,
            "The Artist — Track"
        )
        XCTAssertEqual(
            try decoder.decode(Inspection.self, from: Data(base.utf8)).displayTitle,
            "Track"
        )
    }

    @MainActor
    func testTracksAreUnavailableUntilModelIsReady() {
        let model = AppModel()

        model.modelState = .missing
        XCTAssertFalse(model.canSelectTrack)

        model.modelState = .downloading(ProcessingStatus(stage: "Downloading"))
        XCTAssertFalse(model.canSelectTrack)

        model.modelState = .failed("Network unavailable")
        XCTAssertFalse(model.canSelectTrack)

        model.modelState = .ready
        XCTAssertTrue(model.canSelectTrack)
    }

    @MainActor
    func testDroppedItemFailureIncludesRecoveryAction() {
        let model = AppModel()

        model.reportDropFailure("The provider returned unexpected data.")

        guard case .failed(let message) = model.state else {
            return XCTFail("Expected a failed state")
        }
        XCTAssertTrue(message.contains("unexpected data"))
        XCTAssertTrue(message.contains("Choose Another Track"))
    }

    func testOutputURLsMatchEveryChoice() {
        let source = URL(fileURLWithPath: "/Music/A Track.flac")

        XCTAssertEqual(
            Engine.outputURLs(source, choice: .acapella).map(\.lastPathComponent),
            ["A Track (Acapella).mp3"]
        )
        XCTAssertEqual(
            Engine.outputURLs(source, choice: .instrumental).map(\.lastPathComponent),
            ["A Track (Instrumental).mp3"]
        )
        XCTAssertEqual(
            Engine.outputURLs(source, choice: .both).map(\.lastPathComponent),
            ["A Track (Acapella).mp3", "A Track (Instrumental).mp3"]
        )

        let unusual = URL(fileURLWithPath: "/Music/Beyoncé – [DJ's Mix] 🎧.aiff")
        XCTAssertEqual(
            Engine.outputURLs(unusual, choice: .both).map(\.lastPathComponent),
            [
                "Beyoncé – [DJ's Mix] 🎧 (Acapella).mp3",
                "Beyoncé – [DJ's Mix] 🎧 (Instrumental).mp3"
            ]
        )
    }

    func testRemainingTimeRequiresMeasuredProgress() {
        let status = ProcessingStatus(stage: "Separating")
        XCTAssertNil(status.estimatedRemaining(at: Date().addingTimeInterval(30)))
    }

    @MainActor
    func testDockProgressTracksActiveWork() {
        let model = AppModel(state: .empty, modelState: .missing)
        XCTAssertEqual(model.dockProgress, .inactive)

        model.modelState = .downloading(ProcessingStatus(stage: "Starting download"))
        XCTAssertEqual(model.dockProgress, .indeterminate)

        model.modelState = .downloading(
            ProcessingStatus(stage: "Downloading", percent: 42)
        )
        XCTAssertEqual(model.dockProgress, .determinate(0.42))

        model.modelState = .ready
        XCTAssertEqual(model.dockProgress, .inactive)
    }

    func testMalformedEngineEventReturnsActionableError() {
        XCTAssertThrowsError(try Engine.decodeEvent(Data("not json".utf8))) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("unreadable progress update"))
            XCTAssertTrue(message.contains("Quit and reopen Makestem"))
        }
    }

    func testEngineEventDecodesValidProgress() throws {
        let event = try Engine.decodeEvent(
            Data(#"{"type":"stage_progress","detail":"Analyzing audio","percent":42}"#.utf8)
        )

        XCTAssertEqual(event.type, "stage_progress")
        XCTAssertEqual(event.detail, "Analyzing audio")
        XCTAssertEqual(event.percent, 42)
    }

    func testCancellationCleansTemporaryFilesAndRestoresOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("makestem-cancel-\(UUID().uuidString)")
        let outputDirectory = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = outputDirectory.appendingPathComponent("Track (Acapella).mp3")
        let controller = ProcessController(cleanup: [destination])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        controller.attach(process)

        let processID = process.processIdentifier
        let temporary = outputDirectory.appendingPathComponent(
            ".makestem-output-\(processID)-0.mp3"
        )
        let backup = outputDirectory.appendingPathComponent(
            ".makestem-backup-\(processID)-0.mp3"
        )
        let work = root.appendingPathComponent(".makestem-work-\(processID)")
        try Data("partial".utf8).write(to: destination)
        try Data("temporary".utf8).write(to: temporary)
        try Data("original".utf8).write(to: backup)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        controller.cancel()
        process.waitUntilExit()
        controller.finished()

        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }
}
