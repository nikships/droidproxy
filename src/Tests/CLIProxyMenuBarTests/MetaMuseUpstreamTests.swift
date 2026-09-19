import XCTest
@testable import CLIProxyMenuBar

final class MetaMuseUpstreamTests: XCTestCase {
    func testRecognizesMuseSparkModels() {
        XCTAssertTrue(MetaMuseUpstream.isMetaModel("muse-spark-1.3"))
        XCTAssertTrue(MetaMuseUpstream.isMetaModel("muse-spark-1.3-contributor"))
        XCTAssertFalse(MetaMuseUpstream.isMetaModel("muse-spark-1.2"))
        XCTAssertFalse(MetaMuseUpstream.isMetaModel("gpt-5.6-terra"))
        XCTAssertFalse(MetaMuseUpstream.isMetaModel("grok-4.6"))
        XCTAssertFalse(MetaMuseUpstream.isMetaModel(nil))
        XCTAssertFalse(MetaMuseUpstream.isMetaModel(""))
    }

    func testDetectsResponsesPathsIncludingCompact() {
        XCTAssertTrue(MetaMuseUpstream.isResponsesPath("/v1/responses"))
        XCTAssertTrue(MetaMuseUpstream.isResponsesPath("/api/v1/responses"))
        XCTAssertTrue(MetaMuseUpstream.isResponsesPath("/v1/responses?stream=true"))
        XCTAssertTrue(MetaMuseUpstream.isResponsesPath("/v1/responses/compact"))
        XCTAssertFalse(MetaMuseUpstream.isResponsesPath("/v1/chat/completions"))
        XCTAssertFalse(MetaMuseUpstream.isResponsesPath("/v1/models"))
    }

    func testTLSForwardsOnlyMuseResponses() {
        XCTAssertTrue(MetaMuseUpstream.shouldTLSForward(
            model: "muse-spark-1.3-contributor", path: "/v1/responses"
        ))
        XCTAssertTrue(MetaMuseUpstream.shouldTLSForward(
            model: "muse-spark-1.3", path: "/api/v1/responses"
        ))
        XCTAssertFalse(MetaMuseUpstream.shouldTLSForward(
            model: "muse-spark-1.3-contributor", path: "/v1/chat/completions"
        ))
        XCTAssertFalse(MetaMuseUpstream.shouldTLSForward(
            model: "gpt-5.4", path: "/v1/responses"
        ))
    }

    func testUpstreamPathMatchesGrokNormalization() {
        XCTAssertEqual(MetaMuseUpstream.upstreamPath("/v1/responses"), "/v1/responses")
        XCTAssertEqual(MetaMuseUpstream.upstreamPath("/api/v1/responses"), "/v1/responses")
        XCTAssertEqual(MetaMuseUpstream.upstreamPath("/v1/responses/compact"), "/v1/responses/compact")
        XCTAssertEqual(MetaMuseUpstream.apiHost, "api.meta.ai")
    }
}
