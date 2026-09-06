import Foundation

protocol H264TransportStreamStartupInspecting: Sendable {
    /// Call from a worker actor, not the main actor. Reads only a bounded prefix.
    func inspect(segmentURL: URL) throws -> H264TransportStreamStartupResult
}

enum H264TransportStreamStartupResult: Equatable, Sendable {
    case cleanIDR
    case nonIDRStart
    case missingParameterSets
    case incompleteIDR
    case notH264
    case inconclusive(H264TransportStreamStartupIssue)
}

enum H264TransportStreamStartupIssue: Equatable, Sendable {
    case invalidTransport
    case missingProgramMap
    case transportDiscontinuity
    case scrambledTransport
    case malformedPES
    case malformedNAL
    case noVideoAccessUnit
}

/// A conservative startup check for FFmpeg's 188-byte MPEG-TS output. In
/// particular, an I picture/recovery-point SEI in an open GOP is NOT an IDR.
/// Only the PMT-declared AVC PID is examined; AAC bytes cannot masquerade as
/// video. This verifies the random-access envelope, not full H.264 decodability.
struct H264TransportStreamStartupInspector: H264TransportStreamStartupInspecting {
    let maximumBytes: Int

    init(maximumBytes: Int = 2 * 1_024 * 1_024) {
        precondition(maximumBytes > 0 && maximumBytes <= 8 * 1_024 * 1_024)
        self.maximumBytes = maximumBytes
    }

    func inspect(segmentURL: URL) throws -> H264TransportStreamStartupResult {
        let handle = try FileHandle(forReadingFrom: segmentURL)
        defer { try? handle.close() }
        return inspect(try handle.read(upToCount: maximumBytes) ?? Data())
    }

    func inspect(_ data: Data) -> H264TransportStreamStartupResult {
        let bytes = Array(data.prefix(maximumBytes))
        guard bytes.count >= 188 else { return .inconclusive(.invalidTransport) }
        var pat = PSISectionAssembler()
        var pmt = PSISectionAssembler()
        var pmtPID: Int?
        var videoPID: Int?
        var continuity: [Int: Int] = [:]
        var previousPackets: [Int: [UInt8]] = [:]
        var video = H264PESScanner()

        for offset in stride(from: 0, through: bytes.count - 188, by: 188) {
            guard bytes[offset] == 0x47 else { return .inconclusive(.invalidTransport) }
            let pid = Int(bytes[offset + 1] & 0x1f) << 8 | Int(bytes[offset + 2])
            guard pid == 0 || pid == pmtPID || pid == videoPID else { continue }
            guard bytes[offset + 1] & 0x80 == 0 else {
                return .inconclusive(.invalidTransport)
            }
            guard bytes[offset + 3] & 0xc0 == 0 else {
                return .inconclusive(.scrambledTransport)
            }
            let adaptationControl = (bytes[offset + 3] >> 4) & 3
            guard adaptationControl != 0 else { return .inconclusive(.invalidTransport) }
            var payloadOffset = offset + 4
            if adaptationControl & 2 != 0 {
                let length = Int(bytes[payloadOffset])
                guard payloadOffset + length + 1 <= offset + 188 else {
                    return .inconclusive(.invalidTransport)
                }
                if length > 0, bytes[payloadOffset + 1] & 0x80 != 0 {
                    // Do not combine bytes from opposite sides of a declared
                    // discontinuity and accidentally certify a partial picture.
                    if continuity[pid] != nil { return .inconclusive(.transportDiscontinuity) }
                }
                payloadOffset += length + 1
            }
            guard adaptationControl & 1 != 0, payloadOffset < offset + 188 else { continue }
            let counter = Int(bytes[offset + 3] & 15)
            if let previous = continuity[pid] {
                if counter == previous {
                    guard previousPackets[pid]?.elementsEqual(bytes[offset ..< offset + 188]) == true else {
                        return .inconclusive(.transportDiscontinuity)
                    }
                    continue // Identical repeated transport packet.
                }
                guard counter == ((previous + 1) & 15) else {
                    return .inconclusive(.transportDiscontinuity)
                }
            }
            continuity[pid] = counter
            previousPackets[pid] = Array(bytes[offset ..< offset + 188])
            let startsUnit = bytes[offset + 1] & 0x40 != 0
            let payload = Array(bytes[payloadOffset ..< offset + 188])
            if pid == 0 {
                for section in pat.push(payload, startsUnit: startsUnit) {
                    guard section[0] == 0, section.count >= 12, section[5] & 1 == 1 else { continue }
                    // A relay segment has one selected programme. Ignore PAT
                    // network entries (programme number zero).
                    for index in stride(from: 8, to: section.count - 4, by: 4) {
                        guard index + 3 < section.count - 4 else { break }
                        if section[index] != 0 || section[index + 1] != 0 {
                            let discovered = Int(section[index + 2] & 0x1f) << 8 | Int(section[index + 3])
                            if pmtPID == nil { pmtPID = discovered }
                            break
                        }
                    }
                }
            } else if pid == pmtPID {
                for section in pmt.push(payload, startsUnit: startsUnit) {
                    guard section[0] == 2, section.count >= 16, section[5] & 1 == 1 else { continue }
                    let programInfoLength = Int(section[10] & 15) << 8 | Int(section[11])
                    var index = 12 + programInfoLength
                    guard index <= section.count - 4 else { return .inconclusive(.invalidTransport) }
                    while index + 5 <= section.count - 4 {
                        let streamType = section[index]
                        let elementaryPID = Int(section[index + 1] & 0x1f) << 8 | Int(section[index + 2])
                        let infoLength = Int(section[index + 3] & 15) << 8 | Int(section[index + 4])
                        guard index + 5 + infoLength <= section.count - 4 else {
                            return .inconclusive(.invalidTransport)
                        }
                        if streamType == 0x1b, videoPID == nil { videoPID = elementaryPID }
                        index += 5 + infoLength
                    }
                    guard index == section.count - 4 else { return .inconclusive(.invalidTransport) }
                    if videoPID == nil { return .notH264 }
                }
            } else if pid == videoPID, let result = video.push(payload, startsUnit: startsUnit) {
                return result
            }
        }
        return .inconclusive(videoPID == nil ? .missingProgramMap : .noVideoAccessUnit)
    }
}

private struct PSISectionAssembler {
    private var buffer: [UInt8] = []

    mutating func push(_ payload: [UInt8], startsUnit: Bool) -> [[UInt8]] {
        var sections: [[UInt8]] = []
        if startsUnit {
            guard let pointer = payload.first, Int(pointer) + 1 <= payload.count else {
                buffer.removeAll(keepingCapacity: true)
                return []
            }
            if !buffer.isEmpty { append(Array(payload[1 ..< Int(pointer) + 1]), to: &sections) }
            buffer.removeAll(keepingCapacity: true)
            append(Array(payload[(Int(pointer) + 1)...]), to: &sections)
        } else if !buffer.isEmpty {
            append(payload, to: &sections)
        }
        return sections
    }

    private mutating func append(_ bytes: [UInt8], to sections: inout [[UInt8]]) {
        buffer.append(contentsOf: bytes)
        while buffer.count >= 3 {
            if buffer[0] == 0xff { buffer.removeAll(keepingCapacity: true); return }
            let length = Int(buffer[1] & 15) << 8 | Int(buffer[2])
            guard buffer[1] & 0x80 != 0, (9 ... 1_021).contains(length) else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            let total = length + 3
            guard buffer.count >= total else { return }
            let section = Array(buffer.prefix(total))
            buffer.removeFirst(total)
            if Self.crc(section) == 0 { sections.append(section) }
        }
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in bytes {
            value ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                value = value & 0x8000_0000 == 0 ? value << 1 : (value << 1) ^ 0x04c1_1db7
            }
        }
        return value
    }
}

private struct H264PESScanner {
    private var started = false
    private var header: [UInt8] = []
    private var headerComplete = false
    private var remainingPayload: Int?
    private var annexB = H264AnnexBScanner()

    mutating func push(_ payload: [UInt8], startsUnit: Bool) -> H264TransportStreamStartupResult? {
        if startsUnit {
            guard !started || (headerComplete && (remainingPayload == nil || remainingPayload == 0)) else {
                return .inconclusive(.malformedPES)
            }
            started = true
            header.removeAll(keepingCapacity: true)
            headerComplete = false
            remainingPayload = nil
        }
        guard started else { return .inconclusive(.malformedPES) }
        for byte in payload {
            if !headerComplete {
                header.append(byte)
                if header.count == 9 {
                    guard header[0 ... 2].elementsEqual([0, 0, 1]),
                          (0xe0 ... 0xef).contains(header[3]), header[6] & 0xc0 == 0x80 else {
                        return .inconclusive(.malformedPES)
                    }
                }
                if header.count >= 9, header.count == 9 + Int(header[8]) {
                    let packetLength = Int(header[4]) << 8 | Int(header[5])
                    if packetLength > 0 {
                        let count = packetLength - 3 - Int(header[8])
                        guard count >= 0 else { return .inconclusive(.malformedPES) }
                        remainingPayload = count
                    }
                    headerComplete = true
                }
                continue
            }
            if let remaining = remainingPayload {
                if remaining == 0 { continue }
                remainingPayload = remaining - 1
            }
            if let result = annexB.push(byte) { return result }
        }
        return nil
    }
}

private struct H264AnnexBScanner {
    private var zeroes = 0
    private var inNAL = false
    private var prefix: [UInt8] = []
    private var hasSPS = false
    private var hasPPS = false

    mutating func push(_ byte: UInt8) -> H264TransportStreamStartupResult? {
        if byte == 0 { zeroes += 1; return nil }
        if byte == 1, zeroes >= 2 {
            if prefix.first.map({ $0 & 31 }) == 7, prefix.count >= 4 { hasSPS = true }
            if prefix.first.map({ $0 & 31 }) == 8, prefix.count >= 2 { hasPPS = true }
            prefix.removeAll(keepingCapacity: true)
            inNAL = true
            zeroes = 0
            return nil
        }
        if inNAL {
            for _ in 0 ..< min(zeroes, max(0, 8 - prefix.count)) { prefix.append(0) }
            if prefix.count < 8 { prefix.append(byte) }
            guard let header = prefix.first, header & 0x80 == 0 else {
                return .inconclusive(.malformedNAL)
            }
            let type = header & 31
            if type == 0 || (19 ... 21).contains(type) || type >= 24 {
                return .inconclusive(.malformedNAL)
            }
            if (1 ... 5).contains(type), prefix.count >= 2 {
                if type != 5 { return .nonIDRStart }
                guard header & 0x60 != 0 else { return .inconclusive(.malformedNAL) }
                // first_mb_in_slice == 0 is Exp-Golomb `1`. A later IDR
                // slice alone cannot reconstruct the beginning of its frame.
                guard prefix[1] & 0x80 != 0 else { return .incompleteIDR }
                return hasSPS && hasPPS ? .cleanIDR : .missingParameterSets
            }
        }
        zeroes = 0
        return nil
    }
}
