#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CDTVPlaybackSnapshot : NSObject
@property(nonatomic) double position;
@property(nonatomic) double start;
@property(nonatomic) double end;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL ready;
@property(nonatomic) unsigned long long videoFrames;
@property(nonatomic) unsigned long long audioFrames;
@property(nonatomic, copy) NSString *videoCodec;
@property(nonatomic, copy) NSString *audioCodec;
@property(nonatomic) NSInteger videoWidth;
@property(nonatomic) NSInteger videoHeight;
@property(nonatomic) BOOL hardwareVideo;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSString *failure;
@end

/// FFmpeg stays behind this Objective-C boundary; Swift never owns AVPacket
/// pointers or calls a decoder from the main actor.
@interface CDTVMediaEngine : NSObject
@property(nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
- (instancetype)initWithCacheDirectory:(NSURL *)directory;
- (void)playURL:(NSURL *)url bufferSeconds:(double)seconds;
- (void)setPaused:(BOOL)paused;
- (void)seekTo:(double)seconds;
- (void)goLive;
- (void)stop;
- (CDTVPlaybackSnapshot *)snapshot;
/// Encodes a recent decoded frame on a utility queue. Does not open a stream.
- (void)captureThumbnailWithCompletion:(void (^)(NSData * _Nullable))completion;
#if DEBUG
/// Fault injection for the development hardware probe; closes the current
/// transport through FFmpeg's normal interrupt path, preserving retry behavior.
- (void)interruptTransportForTesting;
#endif
@end
NS_ASSUME_NONNULL_END
