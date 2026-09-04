import Foundation
import zlib

enum GzipCompressionError: Error, Equatable, LocalizedError {
    case inputTooLarge
    case initializationFailed(Int32)
    case compressionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .inputTooLarge:
            "The data is too large to compress."
        case let .initializationFailed(code):
            "The gzip encoder could not be initialized (code \(code))."
        case let .compressionFailed(code):
            "The gzip encoder failed (code \(code))."
        }
    }
}

enum GzipCompressor {
    /// Produces one RFC 1952 gzip member. Relay callers bound playlist input
    /// before invoking this helper, while the UInt32 guard protects zlib's
    /// single-buffer input interface from truncation.
    static func compress(_ input: Data) throws -> Data {
        guard input.count <= Int(UInt32.max) else {
            throw GzipCompressionError.inputTooLarge
        }

        var stream = z_stream()
        let initializationStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initializationStatus == Z_OK else {
            throw GzipCompressionError.initializationFailed(initializationStatus)
        }
        defer { deflateEnd(&stream) }

        let chunkSize = 64 * 1_024
        var output = Data()
        output.reserveCapacity(max(32, min(input.count, chunkSize)))
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        return try input.withUnsafeBytes { rawInput in
            let bytes = rawInput.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress)
            stream.avail_in = uInt(bytes.count)

            while true {
                stream.avail_out = uInt(chunkSize)
                let status: Int32 = outputBuffer.withUnsafeMutableBytes { rawOutput in
                    let bytes = rawOutput.bindMemory(to: Bytef.self)
                    stream.next_out = bytes.baseAddress
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: outputBuffer[0 ..< produced])
                }

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK:
                    continue
                default:
                    throw GzipCompressionError.compressionFailed(status)
                }
            }
        }
    }
}
