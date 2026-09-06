#pragma once
#include <cstdint>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <deque>
#include <filesystem>
#include <memory>
#include <optional>
#include <stdexcept>
#include <vector>

namespace channeldeck {
struct PacketSideData { int type; std::vector<uint8_t> bytes; };
struct MediaPacket {
    uint64_t sequence = 0;
    int stream = 0;
    int flags = 0;
    int64_t pts = INT64_MIN, dts = INT64_MIN, duration = 0;
    double time = 0;
    bool keyframe = false;
    std::vector<uint8_t> bytes;
    std::vector<PacketSideData> sideData;
};

/// Single-writer store, called under the session mutex. Payloads live on disk;
/// the bounded index contains timing/codec side data, never decoded frames.
class PacketRing {
    struct Record {
        MediaPacket metadata;
        uint64_t offset, length;
    };
    struct Chunk {
        std::filesystem::path path;
        std::vector<Record> records;
        uint64_t bytes = 0;
        FILE *file = nullptr;
        explicit Chunk(std::filesystem::path value) : path(std::move(value)) {
            file = fopen(path.c_str(), "w+b");
            if (!file) throw std::runtime_error("Cannot create live buffer");
        }
        ~Chunk() {
            if (file) fclose(file);
            std::error_code error;
            std::filesystem::remove(path, error);
        }
    };
    std::filesystem::path directory;
    std::deque<std::unique_ptr<Chunk>> chunks;
    uint64_t nextSequence = 1, nextChunk = 1, bytesUsed = 0;
    double durationLimit;
    uint64_t byteLimit;
    bool video;
    double latest = 0;
public:
    PacketRing(std::filesystem::path path, double seconds = 600,
               uint64_t bytes = 2ULL * 1024 * 1024 * 1024, bool hasVideo = true)
      : directory(std::move(path)), durationLimit(seconds), byteLimit(bytes), video(hasVideo) {
        std::filesystem::create_directories(directory);
    }
    ~PacketRing() { clear(); std::error_code error; std::filesystem::remove(directory, error); }
    void clear() { chunks.clear(); bytesUsed = 0; latest = 0; }
    uint64_t bytes() const { return bytesUsed; }
    uint64_t firstSequence() const { return empty() ? nextSequence : chunks.front()->records.front().metadata.sequence; }
    bool empty() const { return chunks.empty() || chunks.front()->records.empty(); }
    double end() const { return latest; }
    double start() const {
        return empty() ? 0 : std::max(chunks.front()->records.front().metadata.time, latest - durationLimit);
    }
    // availableBytes is the space available BEFORE this write; reserve always
    // includes other applications. Never wait for the viewer before eviction.
    bool append(MediaPacket packet, uint64_t availableBytes = UINT64_MAX,
                uint64_t reserve = 512ULL * 1024 * 1024) {
        if (packet.bytes.empty() || !std::isfinite(packet.time)) return false;
        const uint64_t length = packet.bytes.size();
        if (length > byteLimit || length > 32ULL * 1024 * 1024) return false;
        const uint64_t writable = availableBytes > reserve ? availableBytes - reserve : 0;
        const uint64_t deficit = reserve > availableBytes ? reserve - availableBytes : 0;
        const uint64_t retained = bytesUsed > deficit ? bytesUsed - deficit : 0;
        const uint64_t capacity = std::min(byteLimit, retained + std::min(writable, byteLimit));
        while (!chunks.empty() && bytesUsed + length > capacity) {
            bytesUsed -= chunks.front()->bytes;
            chunks.pop_front();
        }
        if (bytesUsed + length > capacity) return false;
        const bool newChunk = packet.keyframe || (!video && (empty() || packet.time - chunks.back()->records.front().metadata.time >= 2));
        if (empty() && !newChunk) return false; // Wait for a decodable start.
        if (newChunk) {
            if (!chunks.empty() && chunks.back()->file) {
                fclose(chunks.back()->file); chunks.back()->file = nullptr;
            }
            chunks.push_back(std::make_unique<Chunk>(directory / (std::to_string(nextChunk++) + ".packets")));
        }
        auto &chunk = *chunks.back();
        const uint64_t offset = chunk.bytes;
        if (fseeko(chunk.file, 0, SEEK_END) || fwrite(packet.bytes.data(), 1, length, chunk.file) != length || fflush(chunk.file)) {
            clear(); throw std::runtime_error("Cannot write live buffer");
        }
        packet.bytes.clear();
        packet.bytes.shrink_to_fit();
        packet.sequence = nextSequence++;
        chunk.records.push_back({std::move(packet), offset, length});
        chunk.bytes += length;
        bytesUsed += length;
        latest = std::max(latest, chunk.records.back().metadata.time);
        while (chunks.size() > 1 && chunks[1]->records.front().metadata.time <= latest - durationLimit) {
            bytesUsed -= chunks.front()->bytes;
            chunks.pop_front();
        }
        return true;
    }
    uint64_t seek(double target) const {
        if (empty()) return nextSequence;
        target = std::clamp(target, start(), end());
        uint64_t result = firstSequence();
        for (const auto &chunk : chunks) {
            const auto &first = chunk->records.front().metadata;
            if (first.time > target) break;
            result = first.sequence;
        }
        return result;
    }
    std::optional<MediaPacket> read(uint64_t sequence) {
        for (const auto &chunk : chunks) {
            if (sequence < chunk->records.front().metadata.sequence || sequence > chunk->records.back().metadata.sequence) continue;
            const auto &record = chunk->records.at(size_t(sequence - chunk->records.front().metadata.sequence));
            MediaPacket result = record.metadata;
            result.bytes.resize(record.length);
            FILE *reader = chunk->file ? chunk->file : fopen(chunk->path.c_str(), "rb");
            const bool failed = !reader || fseeko(reader, off_t(record.offset), SEEK_SET) || fread(result.bytes.data(), 1, record.length, reader) != record.length;
            if (!chunk->file && reader) fclose(reader);
            if (failed)
                throw std::runtime_error("Cannot read live buffer");
            return result;
        }
        return std::nullopt;
    }
};
}
