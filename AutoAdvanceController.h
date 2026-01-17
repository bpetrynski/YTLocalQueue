// AutoAdvanceController.h
// Robust auto-advance handling for YTLocalQueue

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTLPAutoAdvanceState) {
    YTLPAutoAdvanceStateIdle = 0,      // No active monitoring
    YTLPAutoAdvanceStatePlaying,        // Video is playing
    YTLPAutoAdvanceStateNearEnd,        // Within 2 seconds of end
    YTLPAutoAdvanceStateAdvancing,      // Currently advancing to next video
};

@interface YTLPAutoAdvanceController : NSObject

@property (class, readonly) YTLPAutoAdvanceController *shared;

// State
@property (nonatomic, readonly) YTLPAutoAdvanceState state;
@property (nonatomic, readonly) BOOL isEnabled;

// Current video info
@property (nonatomic, strong, nullable) NSString *currentVideoId;
@property (nonatomic, assign) CGFloat currentPosition;
@property (nonatomic, assign) CGFloat totalDuration;

// Lifecycle
- (void)startMonitoringWithPlayerViewController:(id)playerVC;
- (void)stopMonitoring;

// Detection sources - call from hooks
- (void)handleTimeUpdate:(CGFloat)currentTime totalTime:(CGFloat)totalTime;
- (void)handleSeekToTime:(CGFloat)time totalTime:(CGFloat)totalTime;
- (void)handlePlaybackRateChange:(float)rate;
- (void)handleVideoDidEnd;
- (void)handleNewVideoStarted:(NSString *)videoId;

// Manual advance
- (void)advanceToNextInQueue;

// Settings
- (void)setEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
