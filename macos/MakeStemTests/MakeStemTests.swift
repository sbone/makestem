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
}
