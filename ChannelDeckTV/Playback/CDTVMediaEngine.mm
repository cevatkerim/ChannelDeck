#import "CDTVMediaEngine.h"
#import <AudioToolbox/AudioToolbox.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include "PacketRing.hpp"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
extern "C" {
// AVFoundation also declares AVMediaType (an NSString typedef).
#define AVMediaType FFAVMediaType
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#undef AVMediaType
}

@implementation CDTVPlaybackSnapshot
- (instancetype)init { if ((self = [super init])) { _message = @""; _failure = @""; _videoCodec = @""; _audioCodec = @""; } return self; }
@end

namespace {
using namespace channeldeck;
using Clock = std::chrono::steady_clock;
static int64_t nowMS() { return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count(); }
struct StreamInfo {
    AVCodecParameters *parameters = avcodec_parameters_alloc();
    AVRational timebase{1, 1};
    StreamInfo(AVStream *stream) { avcodec_parameters_copy(parameters, stream->codecpar); timebase = stream->time_base; }
    ~StreamInfo() { avcodec_parameters_free(&parameters); }
    bool matches(AVStream *stream) const {
        const AVCodecParameters *other = stream->codecpar;
        return av_cmp_q(timebase, stream->time_base) == 0 &&
            parameters->codec_id == other->codec_id && parameters->format == other->format &&
            parameters->width == other->width && parameters->height == other->height &&
            parameters->sample_rate == other->sample_rate &&
            av_channel_layout_compare(&parameters->ch_layout, &other->ch_layout) == 0 &&
            parameters->extradata_size == other->extradata_size &&
            (!parameters->extradata_size || memcmp(parameters->extradata, other->extradata, parameters->extradata_size) == 0);
    }
};
struct Session : std::enable_shared_from_this<Session> {
    std::atomic<bool> cancelled{false}, paused{false};
#if DEBUG
    std::atomic<bool> interruptTransport{false};
#endif
    std::atomic<int64_t> deadline{0};
    std::mutex mutex;
    std::condition_variable changed;
    std::unique_ptr<PacketRing> ring;
    std::vector<std::shared_ptr<StreamInfo>> streams;
    uint64_t epoch = 0;
    double seekRequest = NAN, position = 0, origin = 0;
    bool ready = false, ended = false;
    uint64_t videoFrames = 0, audioFrames = 0;
    std::string videoCodec, audioCodec;
    int videoWidth = 0, videoHeight = 0;
    bool hardwareVideo = false;
    CVPixelBufferRef thumbnailPixel = nullptr;
    int64_t thumbnailTime = 0;
    std::string message, failure;
    std::filesystem::path path;
    double seconds;
    __strong AVSampleBufferDisplayLayer *layer;
    __strong AVSampleBufferAudioRenderer *audio;
    __strong AVSampleBufferRenderSynchronizer *sync;

    Session(NSURL *directory, double duration, AVSampleBufferDisplayLayer *display)
      : path(directory.fileSystemRepresentation), seconds(duration), layer(display) {
        audio = [AVSampleBufferAudioRenderer new];
        sync = [AVSampleBufferRenderSynchronizer new];
        [sync addRenderer:layer.sampleBufferRenderer];
        [sync addRenderer:audio];
        sync.delaysRateChangeUntilHasSufficientMediaData = NO;
    }
    ~Session() { if (thumbnailPixel) CFRelease(thumbnailPixel); ring.reset(); }
    void stop() {
        cancelled = true; changed.notify_all(); [sync setRate:0];
        std::lock_guard guard(mutex);
        if (ring) ring->clear();
    }
    static int interrupt(void *opaque) {
        auto self = static_cast<Session *>(opaque);
#if DEBUG
        if (self->interruptTransport) return 1;
#endif
        return self->cancelled || (self->deadline > 0 && nowMS() > self->deadline);
    }
    void fail(const char *text) {
        std::lock_guard guard(mutex);
        failure = text; ended = true; cancelled = true;
        if (ring) ring->clear();
        changed.notify_all();
    }
    void ingest(std::string url) {
        @autoreleasepool {
            av_log_set_level(AV_LOG_QUIET); // Never log provider credentials.
            for (int attempt = 0; attempt < 4 && !cancelled; ++attempt) {
                AVFormatContext *input = avformat_alloc_context();
                input->interrupt_callback = {interrupt, this};
                AVDictionary *options = nullptr;
                av_dict_set(&options, "protocol_whitelist", "http,https,tcp,tls,crypto", 0);
                av_dict_set(&options, "tls_verify", "1", 0);
                av_dict_set(&options, "rw_timeout", "10000000", 0);
                av_dict_set(&options, "probesize", "4194304", 0);
                av_dict_set(&options, "analyzeduration", "5000000", 0);
                deadline = nowMS() + 15000;
                int result = avformat_open_input(&input, url.c_str(), nullptr, &options);
                av_dict_free(&options);
                if (result >= 0) result = avformat_find_stream_info(input, nullptr);
                if (result >= 0) {
                    const int videoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
                    const int audioIndex = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nullptr, 0);
                    if (videoIndex < 0 && audioIndex < 0) {
                        avformat_close_input(&input); fail("This stream contains no supported audio or video."); break;
                    }
                    {
                        std::lock_guard guard(mutex);
                        streams.clear();
                        for (unsigned i = 0; i < input->nb_streams; ++i)
                            streams.push_back(i == videoIndex || i == audioIndex ? std::make_shared<StreamInfo>(input->streams[i]) : nullptr);
                        ring.reset();
                        ring = std::make_unique<PacketRing>(path, seconds, 2ULL * 1024 * 1024 * 1024, videoIndex >= 0);
                        ++epoch; ready = true; seekRequest = 0; position = 0;
                        if (attempt) message = "Connection restored. A new live buffer has started.";
                    }
                    changed.notify_all();
                    AVPacket *packet = av_packet_alloc();
                    const int64_t connectedAt = nowMS();
                    bool haveOrigin = false;
                    double lastPrimaryTime = 0;
                    uint64_t freeBytes = 0;
                    int64_t lastSpaceCheck = 0;
                    while (!cancelled) {
                        deadline = nowMS() + 10000;
                        result = av_read_frame(input, packet);
                        if (result < 0) {
#if DEBUG
                            interruptTransport = false;
#endif
                            break;
                        }
                        const int index = packet->stream_index;
                        if (index != videoIndex && index != audioIndex) { av_packet_unref(packet); continue; }
                        {
                            std::lock_guard guard(mutex);
                            if (cancelled) break;
                            if (!streams[index]->matches(input->streams[index])) {
                                // A decoder configured for the new format must never
                                // seek back into packets captured with the old one.
                                streams[index] = std::make_shared<StreamInfo>(input->streams[index]);
                                ring->clear(); ++epoch; seekRequest = 0; position = 0;
                                haveOrigin = false;
                                message = "The stream format changed. A new live buffer has started.";
                            }
                        }
                        int64_t stamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
                        if (stamp == AV_NOPTS_VALUE) { av_packet_unref(packet); continue; }
                        const double rawTime = stamp * av_q2d(input->streams[index]->time_base);
                        const bool primary = index == (videoIndex >= 0 ? videoIndex : audioIndex);
                        const bool key = index == videoIndex && (packet->flags & AV_PKT_FLAG_KEY);
                        if (!haveOrigin) {
                            if (!(key || (videoIndex < 0 && primary))) { av_packet_unref(packet); continue; }
                            origin = rawTime; haveOrigin = true; lastPrimaryTime = rawTime;
                        }
                        if (nowMS() - lastSpaceCheck > 500) {
                            std::error_code error;
                            auto space = std::filesystem::space(path, error);
                            freeBytes = error ? 0 : space.available;
                            lastSpaceCheck = nowMS();
                        }
                        MediaPacket value;
                        value.stream = index; value.flags = packet->flags;
                        value.pts = packet->pts; value.dts = packet->dts; value.duration = packet->duration;
                        value.keyframe = key;
                        value.bytes.assign(packet->data, packet->data + packet->size);
                        for (int i = 0; i < packet->side_data_elems; ++i) {
                            auto &side = packet->side_data[i];
                            value.sideData.push_back({int(side.type), {side.data, side.data + side.size}});
                        }
                        try {
                            std::lock_guard guard(mutex);
                            if (cancelled) break;
                            if (primary && (rawTime < lastPrimaryTime - 3 || rawTime > lastPrimaryTime + 30)) {
                                ring->clear(); origin = rawTime; ++epoch; seekRequest = 0;
                                message = "The stream timing changed. A new live buffer has started.";
                            }
                            if (primary) lastPrimaryTime = rawTime;
                            value.time = std::max(0.0, rawTime - origin);
                            uint64_t previousBytes = ring->bytes();
                            if (!ring->append(std::move(value), freeBytes))
                                message = "Live history is limited by available storage or waiting for a video keyframe.";
                            uint64_t currentBytes = ring->bytes();
                            if (currentBytes >= previousBytes) freeBytes -= std::min(freeBytes, currentBytes - previousBytes);
                            else freeBytes += previousBytes - currentBytes;
                        } catch (...) { fail("The live buffer could not be written. Free some storage and retry."); result = AVERROR(EIO); break; }
                        av_packet_unref(packet);
                        changed.notify_all();
                    }
                    av_packet_free(&packet);
                    // The retry limit applies to consecutive failures. A channel
                    // that recovers and plays normally gets a fresh retry budget.
                    if (nowMS() - connectedAt >= 30000) attempt = 0;
                }
                avformat_close_input(&input);
#if DEBUG
                interruptTransport = false;
#endif
                if (!cancelled && attempt < 3) {
                    std::unique_lock lock(mutex);
                    message = "Connection interrupted. Reconnecting…";
                    changed.wait_for(lock, std::chrono::seconds(attempt + 1), [&] { return cancelled.load(); });
                }
            }
            if (!cancelled) fail("The channel could not be read. Check your connection or refresh the playlist and retry.");
            std::lock_guard guard(mutex); ended = true; changed.notify_all();
        }
    }
    void decode();
};

static AVPixelFormat hardwareFormat(AVCodecContext *, const AVPixelFormat *formats) {
    for (auto p = formats; *p != AV_PIX_FMT_NONE; ++p) if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return formats[0];
}
struct Decoder {
    AVCodecContext *context = nullptr;
    SwrContext *resampler = nullptr;
    SwsContext *scaler = nullptr;
    int resampleRate = 0;
    AVSampleFormat resampleFormat = AV_SAMPLE_FMT_NONE;
    AVChannelLayout resampleLayout{};
    AVRational timebase{1, 1};
    bool video = false;
    explicit Decoder(const StreamInfo &info) {
        auto codec = avcodec_find_decoder(info.parameters->codec_id);
        if (!codec) return;
        context = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(context, info.parameters);
        timebase = info.timebase;
        context->pkt_timebase = timebase;
        context->thread_count = 2;
        video = info.parameters->codec_type == AVMEDIA_TYPE_VIDEO;
        if (video) {
#if !TARGET_OS_SIMULATOR
            for (int i = 0; const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i); ++i) {
                if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX && (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                    if (av_hwdevice_ctx_create(&context->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) >= 0)
                        context->get_format = hardwareFormat;
                    break;
                }
            }
#endif
        }
        if (avcodec_open2(context, codec, nullptr) < 0) avcodec_free_context(&context);
    }
    ~Decoder() { av_channel_layout_uninit(&resampleLayout); swr_free(&resampler); sws_freeContext(scaler); avcodec_free_context(&context); }
};

static CMSampleBufferRef videoSample(Decoder &decoder, AVFrame *frame, double time) {
    CVPixelBufferRef pixel = nullptr;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        pixel = (CVPixelBufferRef)frame->data[3];
        if (pixel) CFRetain(pixel);
    } else {
        const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(AVPixelFormat(frame->format));
        bool tenBit = description && description->comp[0].depth > 8;
        OSType pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        if (CVPixelBufferCreate(kCFAllocatorDefault, frame->width, frame->height, pixelFormat, (__bridge CFDictionaryRef)attributes, &pixel) != kCVReturnSuccess) return nullptr;
        CVPixelBufferLockBaseAddress(pixel, 0);
        uint8_t *planes[4] = {(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel, 0), (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel, 1)};
        int strides[4] = {int(CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)), int(CVPixelBufferGetBytesPerRowOfPlane(pixel, 1))};
        decoder.scaler = sws_getCachedContext(decoder.scaler, frame->width, frame->height, AVPixelFormat(frame->format),
            frame->width, frame->height, tenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (decoder.scaler) sws_scale(decoder.scaler, frame->data, frame->linesize, 0, frame->height, planes, strides);
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        if (!decoder.scaler) { CFRelease(pixel); return nullptr; }
    }
    if (!pixel) return nullptr;
    if (frame->color_primaries == AVCOL_PRI_BT2020)
        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
    if (frame->color_trc == AVCOL_TRC_SMPTE2084)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVAttachmentMode_ShouldPropagate);
    else if (frame->color_trc == AVCOL_TRC_ARIB_STD_B67)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVAttachmentMode_ShouldPropagate);
    CMVideoFormatDescriptionRef format = nullptr;
    CMSampleBufferRef sample = nullptr;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &format) == noErr) {
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMakeWithSeconds(time, 90000), kCMTimeInvalid};
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, format, &timing, &sample);
        CFRelease(format);
    }
    CFRelease(pixel);
    return sample;
}

static CMSampleBufferRef audioSample(Decoder &decoder, AVFrame *frame, double time) {
    if (decoder.resampler && (decoder.resampleRate != frame->sample_rate || decoder.resampleFormat != frame->format ||
        av_channel_layout_compare(&decoder.resampleLayout, &frame->ch_layout) != 0)) swr_free(&decoder.resampler);
    if (!decoder.resampler) {
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        if (swr_alloc_set_opts2(&decoder.resampler, &stereo, AV_SAMPLE_FMT_FLT, 48000, &frame->ch_layout,
                              AVSampleFormat(frame->format), frame->sample_rate, 0, nullptr) < 0 || swr_init(decoder.resampler) < 0) return nullptr;
        decoder.resampleRate = frame->sample_rate;
        decoder.resampleFormat = AVSampleFormat(frame->format);
        av_channel_layout_uninit(&decoder.resampleLayout);
        av_channel_layout_copy(&decoder.resampleLayout, &frame->ch_layout);
    }
    int capacity = swr_get_out_samples(decoder.resampler, frame->nb_samples);
    if (capacity <= 0 || capacity > 192000) return nullptr;
    std::vector<uint8_t> bytes(size_t(capacity) * 2 * sizeof(float));
    uint8_t *output = bytes.data();
    int count = swr_convert(decoder.resampler, &output, capacity, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (count <= 0) return nullptr;
    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = 48000; asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame = 8;
    asbd.mFramesPerPacket = 1; asbd.mChannelsPerFrame = 2; asbd.mBitsPerChannel = 32;
    CMAudioFormatDescriptionRef format = nullptr;
    CMBlockBufferRef block = nullptr;
    CMSampleBufferRef sample = nullptr;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, 0, nullptr, nullptr, &format) != noErr) return nullptr;
    size_t length = size_t(count) * 8;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, length, kCFAllocatorDefault, nullptr, 0, length, 0, &block) == noErr) {
        CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, length);
        CMSampleTimingInfo timing = {CMTimeMake(1, 48000), CMTimeMakeWithSeconds(time, 90000), kCMTimeInvalid};
        size_t sampleSize = 8;
        CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, count, 1, &timing, 1, &sampleSize, &sample);
        CFRelease(block);
    }
    CFRelease(format);
    return sample;
}

void Session::decode() {
    @autoreleasepool {
        std::vector<std::unique_ptr<Decoder>> decoders;
        uint64_t currentEpoch = UINT64_MAX, cursor = 0;
        double localOrigin = 0, target = 0;
        bool clockStarted = false;
        AVFrame *frame = av_frame_alloc();
        AVPacket *packet = av_packet_alloc();
        while (!cancelled) {
            @autoreleasepool {
                std::optional<MediaPacket> value;
                {
                    std::unique_lock lock(mutex);
                    if (!ready || !ring || ring->empty()) {
                        changed.wait_for(lock, std::chrono::milliseconds(50));
                        if (ended && (!ring || ring->empty())) break;
                        continue;
                    }
                    if (epoch != currentEpoch) {
                        if (thumbnailPixel) { CFRelease(thumbnailPixel); thumbnailPixel = nullptr; thumbnailTime = 0; }
                        decoders.clear();
                        for (const auto &stream : streams) decoders.push_back(stream ? std::make_unique<Decoder>(*stream) : nullptr);
                        currentEpoch = epoch; localOrigin = origin; seekRequest = ring->start();
                        bool usable = false;
                        for (const auto &decoder : decoders) if (decoder && decoder->context) usable = true;
                        if (!usable) { failure = "This channel’s codecs could not be decoded on this device."; break; }
                    }
                    if (cursor < ring->firstSequence() && !std::isfinite(seekRequest)) {
                        seekRequest = ring->start();
                        message = "Earlier live history expired. Playback resumes at the oldest available point.";
                    }
                    if (std::isfinite(seekRequest)) {
                        target = std::clamp(seekRequest, ring->start(), ring->end());
                        cursor = ring->seek(target); position = target; seekRequest = NAN;
                        for (auto &decoder : decoders) if (decoder && decoder->context) {
                            avcodec_flush_buffers(decoder->context); swr_free(&decoder->resampler);
                        }
                        [sync setRate:0];
                        [layer.sampleBufferRenderer flush]; [audio flush];
                        clockStarted = false;
                    }
                    if (paused) { [sync setRate:0]; changed.wait_for(lock, std::chrono::milliseconds(50)); continue; }
                    if (clockStarted && sync.rate == 0) [sync setRate:1];
                    try { value = ring->read(cursor); }
                    catch (...) { failure = "The live buffer could not be read. Retry this channel."; break; }
                    if (!value) { changed.wait_for(lock, std::chrono::milliseconds(20)); continue; }
                    ++cursor;
                }
                auto &decoder = decoders[value->stream];
                if (!decoder || !decoder->context) continue;
                av_packet_unref(packet);
                if (av_new_packet(packet, int(value->bytes.size())) < 0) { fail("There is not enough memory to play this channel."); break; }
                memcpy(packet->data, value->bytes.data(), value->bytes.size());
                packet->pts = value->pts; packet->dts = value->dts;
                packet->duration = value->duration; packet->flags = value->flags;
                for (const auto &side : value->sideData) {
                    uint8_t *data = av_packet_new_side_data(packet, AVPacketSideDataType(side.type), side.bytes.size());
                    if (data) memcpy(data, side.bytes.data(), side.bytes.size());
                }
                if (avcodec_send_packet(decoder->context, packet) < 0) continue;
                while (!cancelled && avcodec_receive_frame(decoder->context, frame) >= 0) {
                    int64_t stamp = frame->best_effort_timestamp;
                    double time = stamp == AV_NOPTS_VALUE ? value->time : stamp * av_q2d(decoder->timebase) - localOrigin;
                    if (time + 0.04 < target || !std::isfinite(time)) { av_frame_unref(frame); continue; }
                    CMSampleBufferRef sample = decoder->video ? videoSample(*decoder, frame, time) : audioSample(*decoder, frame, time);
                    const int width = frame->width, height = frame->height;
                    const bool hardware = frame->format == AV_PIX_FMT_VIDEOTOOLBOX;
                    av_frame_unref(frame);
                    if (!sample) continue;
                    bool superseded = false;
                    while (!cancelled) {
                        {
                            std::lock_guard guard(mutex);
                            if (ring && cursor < ring->firstSequence()) {
                                seekRequest = ring->start();
                                message = "Earlier live history expired. Playback resumes at the oldest available point.";
                            }
                            if (epoch != currentEpoch || std::isfinite(seekRequest)) { superseded = true; break; }
                        }
                        // Pause can happen while a decoded sample is waiting
                        // for its render time. Resume that clock here too;
                        // otherwise this loop can never reach the next packet.
                        if (!paused && clockStarted && sync.rate == 0) [sync setRate:1];
                        const bool readyForData = decoder->video ? layer.sampleBufferRenderer.readyForMoreMediaData : audio.readyForMoreMediaData;
                        const double clockTime = CMTimeGetSeconds(sync.currentTime);
                        if (!paused && readyForData && (!clockStarted || time < clockTime + 0.5)) break;
                        std::unique_lock lock(mutex); changed.wait_for(lock, std::chrono::milliseconds(10));
                    }
                    if (!cancelled && !superseded) {
                        if (decoder->video) [layer.sampleBufferRenderer enqueueSampleBuffer:sample];
                        else [audio enqueueSampleBuffer:sample];
                        if (!clockStarted) { [sync setRate:1 time:CMTimeMakeWithSeconds(target, 90000)]; clockStarted = true; }
                        std::lock_guard guard(mutex);
                        if (decoder->video) {
                            ++videoFrames;
                            if (nowMS() - thumbnailTime >= 1000) {
                                auto pixel = CMSampleBufferGetImageBuffer(sample);
                                if (pixel) {
                                    CFRetain(pixel);
                                    if (thumbnailPixel) CFRelease(thumbnailPixel);
                                    thumbnailPixel = pixel; thumbnailTime = nowMS();
                                }
                            }
                            videoCodec = avcodec_get_name(decoder->context->codec_id);
                            videoWidth = width; videoHeight = height; hardwareVideo = hardware;
                        } else {
                            ++audioFrames;
                            audioCodec = avcodec_get_name(decoder->context->codec_id);
                        }
                        position = CMTimeGetSeconds(sync.currentTime);
                    }
                    CFRelease(sample);
                    if (superseded) break;
                }
            }
        }
        av_packet_free(&packet); av_frame_free(&frame);
        {
            std::lock_guard guard(mutex);
            if (!failure.empty()) {
                cancelled = true;
                if (ring) ring->clear();
                changed.notify_all();
            }
        }
        [sync setRate:0]; [layer.sampleBufferRenderer flush]; [audio flush];
    }
}
}

@implementation CDTVMediaEngine {
    NSURL *_directory;
    std::shared_ptr<Session> _session;
}

- (void)captureThumbnailWithCompletion:(void (^)(NSData *))completion {
    CVPixelBufferRef pixel = nullptr;
    if (_session) {
        std::lock_guard guard(_session->mutex);
        pixel = _session->thumbnailPixel;
        if (pixel) CFRetain(pixel);
    }
    if (!pixel) { completion(nil); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            CIImage *image = [CIImage imageWithCVPixelBuffer:pixel];
            CIContext *context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
            CGFloat scale = MAX(640.0 / image.extent.size.width, 360.0 / image.extent.size.height);
            image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
            CGRect crop = CGRectMake((image.extent.size.width - 640) / 2, (image.extent.size.height - 360) / 2, 640, 360);
            image = [[image imageByCroppingToRect:crop] imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
            // Ignore black transition frames so they do not replace a useful preview.
            CIImage *average = [image imageByApplyingFilter:@"CIAreaAverage" withInputParameters:@{kCIInputExtentKey: [CIVector vectorWithCGRect:image.extent]}];
            uint8_t rgba[4] = {};
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            [context render:average toBitmap:rgba rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:colorSpace];
            NSData *result = nil;
            if (MAX(rgba[0], MAX(rgba[1], rgba[2])) > 9) {
                CGImageRef cgImage = [context createCGImage:image fromRect:image.extent format:kCIFormatRGBA8 colorSpace:colorSpace];
                if (cgImage) {
                    NSMutableData *data = [NSMutableData data];
                    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, nullptr);
                    if (destination) {
                        CGImageDestinationAddImage(destination, cgImage, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.78});
                        if (CGImageDestinationFinalize(destination)) result = data;
                        CFRelease(destination);
                    }
                    CFRelease(cgImage);
                }
            }
            CFRelease(colorSpace); CFRelease(pixel);
            completion(result);
        }
    });
}
- (instancetype)initWithCacheDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        _directory = directory;
        _displayLayer = [AVSampleBufferDisplayLayer new];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    }
    return self;
}
- (void)playURL:(NSURL *)url bufferSeconds:(double)seconds {
    [self stop];
    if (![@[@"http", @"https"] containsObject:url.scheme.lowercaseString] || !url.host.length) return;
    NSURL *path = [_directory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    auto session = std::make_shared<Session>(path, seconds == 300 ? 300 : 600, _displayLayer);
    _session = session;
    std::string source(url.absoluteString.UTF8String);
    std::thread([session, source] { try { session->ingest(source); } catch (...) { session->fail("The stream could not be prepared."); } }).detach();
    std::thread([session] { try { session->decode(); } catch (...) { session->fail("The channel could not be decoded."); } }).detach();
}
- (void)setPaused:(BOOL)paused {
    if (!_session) return;
    _session->paused = paused;
    if (paused) [_session->sync setRate:0];
    _session->changed.notify_all();
}
- (void)seekTo:(double)seconds {
    if (!_session || !std::isfinite(seconds)) return;
    std::lock_guard guard(_session->mutex); _session->seekRequest = seconds; _session->changed.notify_all();
}
- (void)goLive {
    if (!_session) return;
    std::lock_guard guard(_session->mutex);
    if (_session->ring) _session->seekRequest = std::max(_session->ring->start(), _session->ring->end() - 1.0);
    _session->paused = false; _session->changed.notify_all();
}
- (void)stop { if (_session) { _session->stop(); _session.reset(); } }
#if DEBUG
- (void)interruptTransportForTesting { if (_session) _session->interruptTransport = true; }
#endif
- (void)dealloc { [self stop]; }
- (CDTVPlaybackSnapshot *)snapshot {
    auto value = [CDTVPlaybackSnapshot new];
    if (!_session) return value;
    std::lock_guard guard(_session->mutex);
    value.paused = _session->paused;
    value.position = _session->position;
    value.ready = _session->ready && (_session->position > 0 || _session->sync.rate > 0);
    value.videoFrames = _session->videoFrames;
    value.audioFrames = _session->audioFrames;
    value.videoCodec = [NSString stringWithUTF8String:_session->videoCodec.c_str()];
    value.audioCodec = [NSString stringWithUTF8String:_session->audioCodec.c_str()];
    value.videoWidth = _session->videoWidth; value.videoHeight = _session->videoHeight;
    value.hardwareVideo = _session->hardwareVideo;
    value.message = [NSString stringWithUTF8String:_session->message.c_str()];
    value.failure = [NSString stringWithUTF8String:_session->failure.c_str()];
    if (_session->ring && !_session->ring->empty()) {
        value.start = _session->ring->start(); value.end = _session->ring->end(); value.bytes = _session->ring->bytes();
    }
    return value;
}
@end
