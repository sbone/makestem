import XCTest
@testable import MakeStem

final class MakeStemTests: XCTestCase {
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
    }

    func testRemainingTimeRequiresMeasuredProgress() {
        let status = ProcessingStatus(stage: "Separating")
        XCTAssertNil(status.estimatedRemaining(at: Date().addingTimeInterval(30)))
    }

    func testMalformedEngineEventReturnsActionableError() {
        XCTAssertThrowsError(try Engine.decodeEvent(Data("not json".utf8))) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("unreadable progress update"))
            XCTAssertTrue(message.contains("Quit and reopen MakeStem"))
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
