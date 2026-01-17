// AutoAdvanceController.m
// Robust auto-advance handling for YTLocalQueue

#import "AutoAdvanceController.h"
#import "LocalQueueManager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Forward declarations for YouTube classes
@interface YTPlayerViewController : UIViewController
- (CGFloat)currentVideoMediaTime;
- (CGFloat)currentVideoTotalMediaTime;
- (NSString *)currentVideoID;
- (id)activeVideoPlayerOverlay;
@end

@interface YTAutoplayAutonavController : NSObject
- (void)setLoopMode:(NSInteger)mode;
@end

@interface YTICommand : NSObject
+ (id)watchNavigationEndpointWithVideoID:(NSString *)videoId;
@end

@interface YTCoWatchWatchEndpointWrapperCommandHandler : NSObject
- (void)sendOriginalCommandWithNavigationEndpoint:(id)endpoint fromView:(id)view entry:(id)entry sender:(id)sender completionBlock:(id)block;
@end

@interface GOOHUDManagerInternal : NSObject
+ (id)sharedInstance;
- (void)showMessageMainThread:(id)message;
@end

@interface YTHUDMessage : NSObject
+ (id)messageWithText:(NSString *)text;
@end

// Minimum time between advances (prevents double-triggering)
static const NSTimeInterval kAdvanceCooldown = 2.5;

// How close to end triggers proactive advance
static const CGFloat kNearEndThreshold = 1.5;

// Position threshold for loop detection
static const CGFloat kLoopDetectionThreshold = 1.0;

// Minimum position before loop detection activates
static const CGFloat kMinPositionForLoopDetection = 3.0;

@interface YTLPAutoAdvanceController ()

@property (nonatomic, assign) YTLPAutoAdvanceState state;
@property (nonatomic, weak) id playerViewController;
@property (nonatomic, strong) dispatch_source_t monitorTimer;
@property (nonatomic, strong) dispatch_queue_t monitorQueue;

// Tracking
@property (nonatomic, assign) CGFloat lastReportedPosition;
@property (nonatomic, assign) CGFloat maxPositionSeen;
@property (nonatomic, assign) NSTimeInterval lastAdvanceTime;
@property (nonatomic, assign) BOOL hasPlaybackProgressed;

// Thread safety
@property (nonatomic, strong) NSLock *stateLock;

@end

@implementation YTLPAutoAdvanceController

#pragma mark - Singleton

+ (YTLPAutoAdvanceController *)shared {
    static YTLPAutoAdvanceController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[YTLPAutoAdvanceController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = YTLPAutoAdvanceStateIdle;
        _stateLock = [[NSLock alloc] init];
        _monitorQueue = dispatch_queue_create("com.ytlocalqueue.autoadvance", DISPATCH_QUEUE_SERIAL);
        _lastAdvanceTime = 0;
        _hasPlaybackProgressed = NO;
        _maxPositionSeen = 0;
        _lastReportedPosition = 0;
        
        // Register for notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handlePlaybackDidEnd:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopMonitoring];
}

#pragma mark - Settings

- (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ytlp_queue_auto_advance_enabled"];
}

- (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_queue_auto_advance_enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    if (enabled && self.playerViewController) {
        [self startMonitoringWithPlayerViewController:self.playerViewController];
    } else if (!enabled) {
        [self stopMonitoring];
    }
}

#pragma mark - Lifecycle

- (void)startMonitoringWithPlayerViewController:(id)playerVC {
    [self.stateLock lock];
    
    self.playerViewController = playerVC;
    
    // Reset tracking
    self.hasPlaybackProgressed = NO;
    self.maxPositionSeen = 0;
    self.lastReportedPosition = 0;
    self.currentPosition = 0;
    self.totalDuration = 0;
    
    // Only monitor if enabled and queue has items
    if (!self.isEnabled || [[YTLPLocalQueueManager shared] isEmpty]) {
        self.state = YTLPAutoAdvanceStateIdle;
        [self.stateLock unlock];
        return;
    }
    
    self.state = YTLPAutoAdvanceStatePlaying;
    
    [self.stateLock unlock];
    
    // Start backup timer (runs on background queue for reliability)
    [self startBackupTimer];
    
    // Update autoplay state to force loop mode
    [self updateAutoplayState];
}

- (void)stopMonitoring {
    [self.stateLock lock];
    self.state = YTLPAutoAdvanceStateIdle;
    [self.stateLock unlock];
    
    [self stopBackupTimer];
}

#pragma mark - Backup Timer

- (void)startBackupTimer {
    [self stopBackupTimer];
    
    __weak typeof(self) weakSelf = self;
    
    self.monitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.monitorQueue);
    if (self.monitorTimer) {
        // Fire every 200ms with 100ms leeway
        dispatch_source_set_timer(self.monitorTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  200 * NSEC_PER_MSEC,
                                  100 * NSEC_PER_MSEC);
        
        dispatch_source_set_event_handler(self.monitorTimer, ^{
            [weakSelf checkPlaybackState];
        });
        
        dispatch_resume(self.monitorTimer);
    }
}

- (void)stopBackupTimer {
    if (self.monitorTimer) {
        dispatch_source_cancel(self.monitorTimer);
        self.monitorTimer = nil;
    }
}

- (void)checkPlaybackState {
    if (!self.isEnabled || [[YTLPLocalQueueManager shared] isEmpty]) {
        return;
    }
    
    // Get current position from player
    YTPlayerViewController *playerVC = (YTPlayerViewController *)self.playerViewController;
    if (!playerVC) return;
    
    __block CGFloat current = 0;
    __block CGFloat total = 0;
    
    // Must dispatch to main for UI access
    dispatch_sync(dispatch_get_main_queue(), ^{
        if ([playerVC respondsToSelector:@selector(currentVideoMediaTime)]) {
            current = [playerVC currentVideoMediaTime];
        }
        if ([playerVC respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            total = [playerVC currentVideoTotalMediaTime];
        }
    });
    
    if (total > 10.0) {
        [self handleTimeUpdate:current totalTime:total];
    }
}

#pragma mark - Detection Sources

- (void)handleTimeUpdate:(CGFloat)currentTime totalTime:(CGFloat)totalTime {
    [self.stateLock lock];
    
    // Skip if not monitoring or already advancing
    if (self.state == YTLPAutoAdvanceStateIdle || self.state == YTLPAutoAdvanceStateAdvancing) {
        [self.stateLock unlock];
        return;
    }
    
    // Skip if queue is empty or disabled
    if (!self.isEnabled || [[YTLPLocalQueueManager shared] isEmpty]) {
        [self.stateLock unlock];
        return;
    }
    
    // Skip invalid times
    if (totalTime < 10.0) {
        [self.stateLock unlock];
        return;
    }
    
    // Update tracking
    self.currentPosition = currentTime;
    self.totalDuration = totalTime;
    
    if (currentTime > self.maxPositionSeen) {
        self.maxPositionSeen = currentTime;
    }
    
    // Mark playback as progressed once we pass threshold
    if (currentTime > kMinPositionForLoopDetection) {
        self.hasPlaybackProgressed = YES;
    }
    
    // Check cooldown
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL cooldownOk = (now - self.lastAdvanceTime >= kAdvanceCooldown);
    
    BOOL shouldAdvance = NO;
    NSString *reason = nil;
    
    // DETECTION 1: Proactive - very close to end
    if (currentTime >= (totalTime - kNearEndThreshold) && cooldownOk) {
        shouldAdvance = YES;
        reason = @"proactive (near end)";
    }
    
    // DETECTION 2: Loop detected - position jumped from high to low
    if (!shouldAdvance && cooldownOk) {
        BOOL positionAtStart = (currentTime < kLoopDetectionThreshold);
        BOOL wasSignificant = (self.maxPositionSeen >= kMinPositionForLoopDetection ||
                               self.lastReportedPosition >= kMinPositionForLoopDetection);
        BOOL playbackHadProgressed = self.hasPlaybackProgressed;
        
        if (positionAtStart && (wasSignificant || playbackHadProgressed)) {
            shouldAdvance = YES;
            reason = @"loop detected";
        }
    }
    
    // DETECTION 3: Significant backward jump (scrubbing edge case)
    if (!shouldAdvance && cooldownOk) {
        BOOL jumpedBack = (self.lastReportedPosition > 5.0 &&
                          currentTime < 1.0 &&
                          (self.lastReportedPosition - currentTime) > 10.0);
        if (jumpedBack) {
            shouldAdvance = YES;
            reason = @"backward jump detected";
        }
    }
    
    self.lastReportedPosition = currentTime;
    
    if (shouldAdvance) {
        self.state = YTLPAutoAdvanceStateAdvancing;
        [self.stateLock unlock];
        
        NSLog(@"[YTLocalQueue] Auto-advance triggered: %@ (pos: %.1f, total: %.1f, max: %.1f)",
              reason, currentTime, totalTime, self.maxPositionSeen);
        
        // Advance on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performAdvance];
        });
    } else {
        [self.stateLock unlock];
    }
}

- (void)handleSeekToTime:(CGFloat)time totalTime:(CGFloat)totalTime {
    // If seeking to very near the end, treat as approaching end
    if (totalTime > 10.0 && time >= (totalTime - 0.5)) {
        [self handleTimeUpdate:time totalTime:totalTime];
    }
    
    // If seeking to start while we had progressed, might be a loop
    if (time < 1.0 && self.hasPlaybackProgressed) {
        [self handleTimeUpdate:time totalTime:totalTime];
    }
}

- (void)handlePlaybackRateChange:(float)rate {
    // Rate = 0 might mean video ended or paused
    // We rely more on time-based detection, but this can be a hint
    if (rate == 0 && self.currentPosition >= (self.totalDuration - 2.0) && self.totalDuration > 10.0) {
        // Video likely ended
        [self handleTimeUpdate:self.currentPosition totalTime:self.totalDuration];
    }
}

- (void)handleVideoDidEnd {
    // Direct notification that video ended
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastAdvanceTime >= kAdvanceCooldown) {
        if (self.isEnabled && ![[YTLPLocalQueueManager shared] isEmpty]) {
            NSLog(@"[YTLocalQueue] Auto-advance triggered: video did end notification");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self performAdvance];
            });
        }
    }
}

- (void)handleNewVideoStarted:(NSString *)videoId {
    [self.stateLock lock];
    
    // Reset tracking for new video
    self.currentVideoId = videoId;
    self.hasPlaybackProgressed = NO;
    self.maxPositionSeen = 0;
    self.lastReportedPosition = 0;
    self.currentPosition = 0;
    
    if (self.state != YTLPAutoAdvanceStateAdvancing) {
        self.state = YTLPAutoAdvanceStatePlaying;
    }
    
    [self.stateLock unlock];
    
    // Update autoplay state for new video
    [self updateAutoplayState];
}

#pragma mark - AVPlayerItem Notification

- (void)handlePlaybackDidEnd:(NSNotification *)notification {
    // This notification fires when AVPlayerItem reaches its end
    [self handleVideoDidEnd];
}

#pragma mark - Advance Logic

- (void)advanceToNextInQueue {
    [self performAdvance];
}

- (void)performAdvance {
    // Update timing
    self.lastAdvanceTime = [[NSDate date] timeIntervalSince1970];
    
    // Get next item
    NSDictionary *nextItem = [[YTLPLocalQueueManager shared] popNextItem];
    NSString *nextId = nextItem[@"videoId"];
    NSString *nextTitle = nextItem[@"title"];
    
    if (nextId.length == 0) {
        // Queue empty
        [self.stateLock lock];
        self.state = YTLPAutoAdvanceStateIdle;
        [self.stateLock unlock];
        
        [self stopMonitoring];
        [self restoreAutoplay];
        
        // Show HUD
        [self showHUDMessage:@"✓ Queue complete"];
        return;
    }
    
    // Reset tracking
    [self.stateLock lock];
    self.hasPlaybackProgressed = NO;
    self.maxPositionSeen = 0;
    self.lastReportedPosition = 0;
    self.currentVideoId = nextId;
    [self.stateLock unlock];
    
    // Update currently playing
    [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:nextId title:nextTitle];
    
    // Navigate to video
    [self navigateToVideo:nextId];
    
    // Restart monitoring after short delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.stateLock lock];
        self.state = YTLPAutoAdvanceStatePlaying;
        [self.stateLock unlock];
        
        if (self.playerViewController) {
            [self startMonitoringWithPlayerViewController:self.playerViewController];
        }
    });
}

- (void)navigateToVideo:(NSString *)videoId {
    // Method 1: YTICommand
    Class YTICommandClass = objc_getClass("YTICommand");
    if (YTICommandClass) {
        SEL sel = @selector(watchNavigationEndpointWithVideoID:);
        if ([YTICommandClass respondsToSelector:sel]) {
            id cmd = ((id (*)(id, SEL, NSString *))objc_msgSend)(YTICommandClass, sel, videoId);
            Class Handler = objc_getClass("YTCoWatchWatchEndpointWrapperCommandHandler");
            if (Handler && cmd) {
                id handler = [[Handler alloc] init];
                SEL sendSel = @selector(sendOriginalCommandWithNavigationEndpoint:fromView:entry:sender:completionBlock:);
                if ([handler respondsToSelector:sendSel]) {
                    ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(handler, sendSel, cmd, nil, nil, nil, nil);
                    NSLog(@"[YTLocalQueue] Navigated to video via YTICommand: %@", videoId);
                    return;
                }
            }
        }
    }
    
    // Method 2: URL Scheme
    NSString *urlString = [NSString stringWithFormat:@"youtube://watch?v=%@", videoId];
    NSURL *url = [NSURL URLWithString:urlString];
    UIApplication *app = [UIApplication sharedApplication];
    if ([app canOpenURL:url]) {
        [app openURL:url options:@{} completionHandler:nil];
        NSLog(@"[YTLocalQueue] Navigated to video via URL: %@", videoId);
        return;
    }
    
    // Method 3: Direct player if available
    id playerVC = self.playerViewController;
    if (playerVC) {
        // Try various navigation methods
        SEL selectors[] = {
            @selector(loadVideoWithVideoId:),
            @selector(playVideoWithVideoId:),
            @selector(loadWithVideoId:)
        };
        
        for (int i = 0; i < 3; i++) {
            if ([playerVC respondsToSelector:selectors[i]]) {
                ((void (*)(id, SEL, NSString *))objc_msgSend)(playerVC, selectors[i], videoId);
                NSLog(@"[YTLocalQueue] Navigated to video via player method: %@", videoId);
                return;
            }
        }
    }
    
    NSLog(@"[YTLocalQueue] WARNING: Could not navigate to video: %@", videoId);
}

#pragma mark - Autoplay State

- (void)updateAutoplayState {
    // Force loop mode to prevent YouTube's autoplay
    dispatch_async(dispatch_get_main_queue(), ^{
        YTPlayerViewController *playerVC = (YTPlayerViewController *)self.playerViewController;
        if (!playerVC) return;
        
        Class YTMainAppVideoPlayerOverlayViewControllerClass = objc_getClass("YTMainAppVideoPlayerOverlayViewController");
        if (!YTMainAppVideoPlayerOverlayViewControllerClass) return;
        
        SEL activeOverlaySel = @selector(activeVideoPlayerOverlay);
        if ([playerVC respondsToSelector:activeOverlaySel]) {
            id overlay = ((id (*)(id, SEL))objc_msgSend)(playerVC, activeOverlaySel);
            if (overlay && [overlay isKindOfClass:YTMainAppVideoPlayerOverlayViewControllerClass]) {
                if ([overlay respondsToSelector:@selector(valueForKey:)]) {
                    id autonavController = [overlay valueForKey:@"_autonavController"];
                    SEL setLoopModeSel = @selector(setLoopMode:);
                    if (autonavController && [autonavController respondsToSelector:setLoopModeSel]) {
                        if (self.isEnabled && ![[YTLPLocalQueueManager shared] isEmpty]) {
                            // Force loop mode 2 (loop current video)
                            ((void (*)(id, SEL, NSInteger))objc_msgSend)(autonavController, setLoopModeSel, 2);
                        }
                    }
                }
            }
        }
    });
}

- (void)restoreAutoplay {
    // Restore normal autoplay when queue is empty
    dispatch_async(dispatch_get_main_queue(), ^{
        YTPlayerViewController *playerVC = (YTPlayerViewController *)self.playerViewController;
        if (!playerVC) return;
        
        Class YTMainAppVideoPlayerOverlayViewControllerClass = objc_getClass("YTMainAppVideoPlayerOverlayViewController");
        if (!YTMainAppVideoPlayerOverlayViewControllerClass) return;
        
        SEL activeOverlaySel = @selector(activeVideoPlayerOverlay);
        if ([playerVC respondsToSelector:activeOverlaySel]) {
            id overlay = ((id (*)(id, SEL))objc_msgSend)(playerVC, activeOverlaySel);
            if (overlay && [overlay isKindOfClass:YTMainAppVideoPlayerOverlayViewControllerClass]) {
                if ([overlay respondsToSelector:@selector(valueForKey:)]) {
                    id autonavController = [overlay valueForKey:@"_autonavController"];
                    SEL setLoopModeSel = @selector(setLoopMode:);
                    if (autonavController && [autonavController respondsToSelector:setLoopModeSel]) {
                        ((void (*)(id, SEL, NSInteger))objc_msgSend)(autonavController, setLoopModeSel, 0);
                    }
                }
            }
        }
    });
}

#pragma mark - HUD

- (void)showHUDMessage:(NSString *)message {
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    if (HUD && HUDMsg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL sharedSel = @selector(sharedInstance);
            SEL showMsgSel = @selector(showMessageMainThread:);
            SEL msgWithTextSel = @selector(messageWithText:);
            
            if ([HUD respondsToSelector:sharedSel] && [HUDMsg respondsToSelector:msgWithTextSel]) {
                id hudInstance = ((id (*)(id, SEL))objc_msgSend)(HUD, sharedSel);
                id hudMessage = ((id (*)(id, SEL, NSString *))objc_msgSend)(HUDMsg, msgWithTextSel, message);
                if (hudInstance && hudMessage && [hudInstance respondsToSelector:showMsgSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(hudInstance, showMsgSel, hudMessage);
                }
            }
        });
    }
}

@end
