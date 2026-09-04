import Foundation
import zlib

enum GzipDecompressionError: Error, Equatable, LocalizedError {
    case invalidMaximumSize
    case compressedInputTooLarge
    case invalidOrTruncatedData
    case expandedDataTooLarge
    case initializationFailed(Int32)
    case decompressionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidMaximumSize:
            "The decompression size limit is invalid."
        case .compressedInputTooLarge:
            "The compressed data is too large to decompress."
        case .invalidOrTruncatedData:
            "The compressed data is invalid or incomplete."
        case .expandedDataTooLarge:
            "The expanded data exceeds the allowed size."
        case let .initializationFailed(code):
            "The gzip decoder could not be initialized (code \(code))."
        case let .decompressionFailed(code):
            "The gzip decoder failed (code \(code))."
        }
    }
}

enum GzipDecompressor {
    /// Accepts gzip and zlib-wrapped streams. Output is produced in fixed-size
    /// chunks so a forged expansion ratio cannot allocate beyond the limit.
    static func decompress(
        _ compressed: Data,
        maximumExpandedBytes: Int = 512 * 1_024 * 1_024
    ) throws -> Data {
        guard maximumExpandedBytes >= 0 else {
            throw GzipDecompressionError.invalidMaximumSize
        }
        guard compressed.count <= Int(UInt32.max) else {
            throw GzipDecompressionError.compressedInputTooLarge
        }

        var stream = z_stream()
        let initializationStatus = inflateInit2_(
            &stream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initializationStatus == Z_OK else {
            throw GzipDecompressionError.initializationFailed(initializationStatus)
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1_024
        var output = Data()
        output.reserveCapacity(min(maximumExpandedBytes, max(compressed.count * 2, chunkSize)))
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        return try compressed.withUnsafeBytes { rawInput in
            let input = rawInput.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
            stream.avail_in = uInt(input.count)

            while true {
                stream.avail_out = uInt(chunkSize)
                let status: Int32 = outputBuffer.withUnsafeMutableBytes { rawOutput in
                    let bytes = rawOutput.bindMemory(to: Bytef.self)
                    stream.next_out = bytes.baseAddress
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)

                guard produced <= maximumExpandedBytes - output.count else {
                    throw GzipDecompressionError.expandedDataTooLarge
                }
                if produced > 0 {
                    output.append(contentsOf: outputBuffer[0 ..< produced])
                }

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK:
                    if stream.avail_in == 0 && produced == 0 {
                        throw GzipDecompressionError.invalidOrTruncatedData
                    }
                case Z_BUF_ERROR where stream.avail_in == 0:
                    throw GzipDecompressionError.invalidOrTruncatedData
                default:
                    throw GzipDecompressionError.decompressionFailed(status)
                }
            }
        }
    }
}
