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
}
