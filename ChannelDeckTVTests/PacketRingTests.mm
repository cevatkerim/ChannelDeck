#import <XCTest/XCTest.h>
#include "../ChannelDeckTV/Playback/PacketRing.hpp"
using namespace channeldeck;

@interface PacketRingTests : XCTestCase
@end
@implementation PacketRingTests
- (void)testHourOfCaptureEvictsExpiredHistoryAndKeepsKeyframeSeeks {
    auto path = std::filesystem::path(NSTemporaryDirectory().UTF8String) / NSUUID.UUID.UUIDString.UTF8String;
    PacketRing ring(path, 600, 1000000);
    for (int second = 0; second < 3600; ++second) {
        MediaPacket packet; packet.time = second; packet.keyframe = second % 2 == 0;
        packet.pts = second * 90000; packet.bytes = std::vector<uint8_t>(100, uint8_t(second));
        XCTAssertTrue(ring.append(std::move(packet)));
    }
    XCTAssertEqual(ring.end(), 3599);
    XCTAssertEqual(ring.start(), 2999);
    XCTAssertLessThanOrEqual(ring.bytes(), 60200ULL);
    auto value = ring.read(ring.seek(3201));
    XCTAssertTrue(value.has_value());
    XCTAssertTrue(value->keyframe);
    XCTAssertEqual(value->time, 3200);
    XCTAssertEqual(value->bytes[0], uint8_t(3200));
}
- (void)testStoragePressureShortensHistoryAndOldCursorExpires {
    auto path = std::filesystem::path(NSTemporaryDirectory().UTF8String) / NSUUID.UUID.UUIDString.UTF8String;
    PacketRing ring(path, 600, 1000);
    for (int i = 0; i < 20; ++i) {
        MediaPacket p; p.time = i; p.keyframe = true; p.bytes.resize(100);
        XCTAssertTrue(ring.append(std::move(p)));
    }
    XCTAssertEqual(ring.bytes(), 1000ULL);
    XCTAssertFalse(ring.read(1).has_value());
    MediaPacket p; p.time = 20; p.keyframe = true; p.bytes.resize(100);
    XCTAssertTrue(ring.append(std::move(p), 0, 0));
    XCTAssertLessThanOrEqual(ring.bytes(), 1000ULL);
}
- (void)testCleanupAndRejectingUndecodableStarts {
    auto path = std::filesystem::path(NSTemporaryDirectory().UTF8String) / NSUUID.UUID.UUIDString.UTF8String;
    {
        PacketRing ring(path, 300, 500);
        MediaPacket p; p.bytes.resize(50);
        XCTAssertFalse(ring.append(p));
        p.keyframe = true; XCTAssertTrue(ring.append(p));
        ring.clear(); XCTAssertTrue(ring.empty()); XCTAssertEqual(ring.bytes(), 0ULL);
    }
    XCTAssertFalse(std::filesystem::exists(path));
}
- (void)testEvictionRestoresFreeSpaceReserveAfterAnotherAppUsesDisk {
    auto path = std::filesystem::path(NSTemporaryDirectory().UTF8String) / NSUUID.UUID.UUIDString.UTF8String;
    PacketRing ring(path, 600, 2000);
    for (int i = 0; i < 10; ++i) {
        MediaPacket p; p.time = i; p.keyframe = true; p.bytes.resize(100);
        XCTAssertTrue(ring.append(p));
    }
    MediaPacket p; p.time = 10; p.keyframe = true; p.bytes.resize(100);
    // Another process reduced free space to 300 bytes with a 500-byte reserve.
    XCTAssertTrue(ring.append(p, 300, 500));
    XCTAssertEqual(ring.bytes(), 800ULL);
    XCTAssertGreaterThanOrEqual(300ULL + 1000ULL - ring.bytes(), 500ULL);
    XCTAssertTrue(ring.read(ring.seek(0))->keyframe);
}
@end
