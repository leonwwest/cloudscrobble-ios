import XCTest
@testable import CloudScrobbleCore

final class ArtworkImagePipelineTests: XCTestCase {
    func testPixelRequestsUseStableSizeBuckets() {
        XCTAssertEqual(ArtworkImagePipeline.pixelSizeBucket(for: 44), 96)
        XCTAssertEqual(ArtworkImagePipeline.pixelSizeBucket(for: 160), 160)
        XCTAssertEqual(ArtworkImagePipeline.pixelSizeBucket(for: 161), 256)
        XCTAssertEqual(ArtworkImagePipeline.pixelSizeBucket(for: 512), 512)
        XCTAssertEqual(ArtworkImagePipeline.pixelSizeBucket(for: 513), 768)
        XCTAssertEqual(ArtworkImagePipeline.pixelSizeBucket(for: 2_000), 1_536)
    }
}
