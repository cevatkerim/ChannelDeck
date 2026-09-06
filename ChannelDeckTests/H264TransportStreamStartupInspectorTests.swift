import Foundation
import XCTest
@testable import ChannelDeck

final class H264TransportStreamStartupInspectorTests: XCTestCase {
    func testClosedGOPWithParameterSetsAndIDRIsClean() {
        XCTAssertEqual(inspectVideo(Self.parameterSets + Self.idr), .cleanIDR)
    }

    func testOpenGOPRecoveryPointIsNotMistakenForAnIDR() {
        let recoveryPointSEI: [UInt8] = [0, 0, 1, 0x06, 0x06, 0x01, 0x80, 0x80]
        let intraNonIDR: [UInt8] = [0, 0, 1, 0x41, 0xb8, 0x80]
        XCTAssertEqual(inspectVideo(Self.parameterSets + recoveryPointSEI + intraNonIDR), .nonIDRStart)
    }

    func testLaterIDRDoesNotCertifyAnUndecodableFirstPicture() {
        let predictedPicture: [UInt8] = [0, 0, 1, 0x41, 0xe0, 0x80]
        XCTAssertEqual(inspectVideo(Self.parameterSets + predictedPicture + Self.idr), .nonIDRStart)
    }

    func testIDRWithoutBothParameterSetsIsNotIndependent() {
        XCTAssertEqual(inspectVideo(Self.idr), .missingParameterSets)
        XCTAssertEqual(inspectVideo(Self.sps + Self.idr), .missingParameterSets)
        XCTAssertEqual(inspectVideo(Self.pps + Self.idr), .missingParameterSets)
        XCTAssertEqual(inspectVideo(Self.idr + Self.parameterSets), .missingParameterSets)
    }

    func testStartingWithLaterSliceOfAnIDRIsNotACompletePicture() {
        let laterIDRSlice: [UInt8] = [0, 0, 1, 0x65, 0x40, 0x80] // first_mb_in_slice is not zero.
        XCTAssertEqual(inspectVideo(Self.parameterSets + laterIDRSlice), .incompleteIDR)
    }

    func testPESAndAnnexBHeadersCanCrossTransportPacketBoundaries() {
        let bytes = Self.pes(Self.parameterSets + Self.idr)
        for split in 1 ..< bytes.count {
            var stream = SyntheticTransportStream()
            stream.addProgramTables()
            stream.add(pid: 256, payload: Array(bytes.prefix(split)), startsUnit: true)
            stream.add(pid: 256, payload: Array(bytes.dropFirst(split)), startsUnit: false)
            XCTAssertEqual(inspector.inspect(stream.data), .cleanIDR, "Split at byte \(split)")
        }
    }

    func testAnnexBStartCodeCanCrossPESBoundaries() {
        var stream = SyntheticTransportStream()
        stream.addProgramTables()
        stream.add(pid: 256, payload: Self.pes(Self.parameterSets + [0, 0]), startsUnit: true)
        stream.add(pid: 256, payload: Self.pes(Array(Self.idr.dropFirst(2))), startsUnit: true)
        XCTAssertEqual(inspector.inspect(stream.data), .cleanIDR)
    }

    func testSplitProgramTablesAndDescriptorsIdentifyOnlyTheAVCPID() {
        var stream = SyntheticTransportStream()
        stream.addProgramTables(splitSections: true, descriptors: [0x52, 1, 1])
        // A deliberately video-looking AAC payload must never certify startup.
        stream.add(pid: 257, payload: Self.pes(Self.parameterSets + Self.idr), startsUnit: true)
        stream.add(pid: 256, payload: Self.pes(Self.parameterSets + [0, 0, 1, 0x41, 0x80]), startsUnit: true)
        XCTAssertEqual(inspector.inspect(stream.data), .nonIDRStart)
    }

    func testNonAVCProgramIsNotProbedAsAVC() {
        var stream = SyntheticTransportStream()
        stream.addProgramTables(videoType: 0x24) // HEVC.
        stream.add(pid: 256, payload: Self.pes(Self.parameterSets + Self.idr), startsUnit: true)
        XCTAssertEqual(inspector.inspect(stream.data), .notH264)
    }

    func testMissingOrCorruptProgramTableCannotCertifyAnIDR() {
        var stream = SyntheticTransportStream()
        stream.add(pid: 256, payload: Self.pes(Self.parameterSets + Self.idr), startsUnit: true)
        XCTAssertEqual(inspector.inspect(stream.data), .inconclusive(.missingProgramMap))

        var withTables = SyntheticTransportStream()
        withTables.addProgramTables()
        withTables.add(pid: 256, payload: Self.pes(Self.parameterSets + Self.idr), startsUnit: true)
        var corrupted = withTables.data
        // The final PAT byte is part of its CRC (short payload is right-aligned).
        corrupted[187] ^= 1
        XCTAssertEqual(inspector.inspect(corrupted), .inconclusive(.missingProgramMap))
    }

    func testVideoContinuityGapCannotJoinParameterSetsToAnotherPicture() {
        var stream = SyntheticTransportStream()
        stream.addProgramTables()
        let bytes = Self.pes(Self.parameterSets + Self.idr)
        stream.add(pid: 256, payload: Array(bytes.prefix(12)), startsUnit: true)
        stream.add(pid: 256, payload: Array(bytes.dropFirst(12)), startsUnit: false, counter: 3)
        XCTAssertEqual(inspector.inspect(stream.data), .inconclusive(.transportDiscontinuity))
    }

    func testRepeatedTransportPacketIsIgnoredWithoutDuplicatingPESBytes() {
        var stream = SyntheticTransportStream()
        stream.addProgramTables()
        let bytes = Self.pes(Self.parameterSets + Self.idr)
        stream.add(pid: 256, payload: Array(bytes.prefix(12)), startsUnit: true)
        stream.add(pid: 256, payload: Array(bytes.prefix(12)), startsUnit: true, counter: 0)
        stream.add(pid: 256, payload: Array(bytes.dropFirst(12)), startsUnit: false)
        XCTAssertEqual(inspector.inspect(stream.data), .cleanIDR)
    }

    func testSameCounterWithChangedPayloadIsNotAnIdenticalDuplicate() {
        var stream = SyntheticTransportStream()
        stream.addProgramTables()
        let bytes = Self.pes(Self.parameterSets + Self.idr)
        stream.add(pid: 256, payload: Array(bytes.prefix(12)), startsUnit: true)
        stream.add(pid: 256, payload: Array(bytes.dropFirst(12)), startsUnit: false, counter: 0)
        XCTAssertEqual(inspector.inspect(stream.data), .inconclusive(.transportDiscontinuity))
    }

    func testMalformedPESAndForbiddenNALAreInconclusive() {
        var stream = SyntheticTransportStream()
        stream.addProgramTables()
        stream.add(pid: 256, payload: [0, 0, 1, 0xc0, 0, 0, 0x80, 0, 0] + Self.parameterSets + Self.idr, startsUnit: true)
        XCTAssertEqual(inspector.inspect(stream.data), .inconclusive(.malformedPES))
        XCTAssertEqual(inspectVideo(Self.parameterSets + [0, 0, 1, 0xe5, 0x80]), .inconclusive(.malformedNAL))
    }

    func testByteBudgetDoesNotSearchTheRestOfTheSegmentForAnIDR() throws {
        var stream = SyntheticTransportStream()
        stream.addProgramTables()
        stream.add(pid: 256, payload: Self.pes(Self.parameterSets + Self.idr), startsUnit: true)
        let bounded = H264TransportStreamStartupInspector(maximumBytes: 188 * 2)
        XCTAssertEqual(bounded.inspect(stream.data), .inconclusive(.noVideoAccessUnit))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ts")
        defer { try? FileManager.default.removeItem(at: file) }
        try stream.data.write(to: file)
        XCTAssertEqual(try bounded.inspect(segmentURL: file), .inconclusive(.noVideoAccessUnit))
        XCTAssertEqual(try inspector.inspect(segmentURL: file), .cleanIDR)
    }

    func testEmptyTruncatedAndNonTransportInputsAreInconclusive() {
        XCTAssertEqual(inspector.inspect(Data()), .inconclusive(.invalidTransport))
        XCTAssertEqual(inspector.inspect(Data(repeating: 0, count: 187)), .inconclusive(.invalidTransport))
        XCTAssertEqual(inspector.inspect(Data(repeating: 0, count: 188)), .inconclusive(.invalidTransport))
    }

    private let inspector = H264TransportStreamStartupInspector()
    private static let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x64, 0, 0x1f, 0xac, 0x80]
    private static let pps: [UInt8] = [0, 0, 1, 0x68, 0xee, 0x80]
    private static var parameterSets: [UInt8] { sps + pps }
    private static let idr: [UInt8] = [0, 0, 1, 0x65, 0x88, 0x80]

    private func inspectVideo(_ bytes: [UInt8]) -> H264TransportStreamStartupResult {
        var stream = SyntheticTransportStream()
        stream.addProgramTables()
        stream.add(pid: 256, payload: Self.pes(bytes), startsUnit: true)
        return inspector.inspect(stream.data)
    }

    private static func pes(_ bytes: [UInt8]) -> [UInt8] {
        // Unbounded video PES, with no optional timestamps in these fixtures.
        [0, 0, 1, 0xe0, 0, 0, 0x80, 0, 0] + bytes
    }
}

private struct SyntheticTransportStream {
    private(set) var data = Data()
    private var counters: [Int: UInt8] = [:]

    mutating func addProgramTables(splitSections: Bool = false, descriptors: [UInt8] = [], videoType: UInt8 = 0x1b) {
        let pat = Self.section(table: 0, bytes: [0, 1, 0xc1, 0, 0, 0, 1, 0xf0, 0])
        let pmt = Self.section(table: 2, bytes: [0, 1, 0xc1, 0, 0, 0xe1, 0, 0xf0, UInt8(descriptors.count)]
            + descriptors + [videoType, 0xe1, 0, 0xf0, 0, 0x0f, 0xe1, 1, 0xf0, 0])
        for (pid, section) in [(0, pat), (4_096, pmt)] {
            if splitSections {
                add(pid: pid, payload: [0] + section.prefix(7), startsUnit: true)
                add(pid: pid, payload: Array(section.dropFirst(7)), startsUnit: false)
            } else {
                add(pid: pid, payload: [0] + section, startsUnit: true)
            }
        }
    }

    mutating func add(pid: Int, payload: [UInt8], startsUnit: Bool, counter: UInt8? = nil) {
        precondition(!payload.isEmpty && payload.count <= 184)
        let count = counter ?? counters[pid, default: 0]
        counters[pid] = (count + 1) & 15
        let hasAdaptation = payload.count < 184
        var packet: [UInt8] = [0x47, UInt8(pid >> 8) | (startsUnit ? 0x40 : 0), UInt8(pid & 255), (hasAdaptation ? 0x30 : 0x10) | count]
        if hasAdaptation {
            let adaptationLength = 183 - payload.count
            packet.append(UInt8(adaptationLength))
            if adaptationLength > 0 {
                packet.append(0) // No flags; rest is adaptation stuffing.
                packet += Array(repeating: 0xff, count: adaptationLength - 1)
            }
        }
        data.append(contentsOf: packet + payload)
    }

    private static func section(table: UInt8, bytes: [UInt8]) -> [UInt8] {
        let length = bytes.count + 4
        var result = [table, 0xb0 | UInt8(length >> 8), UInt8(length & 255)] + bytes
        var crc: UInt32 = 0xffff_ffff
        for byte in result {
            crc ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                crc = crc & 0x8000_0000 == 0 ? crc << 1 : (crc << 1) ^ 0x04c1_1db7
            }
        }
        result += [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)]
        return result
    }
}
