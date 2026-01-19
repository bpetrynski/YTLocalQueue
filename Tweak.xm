// Tweaks/YTLocalQueue/Tweak.xm
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "Headers/YouTubeHeader/YTPlayerViewController.h"
#import <MediaPlayer/MediaPlayer.h>
#import "Headers/YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h"
#import "Headers/YouTubeHeader/YTMainAppVideoPlayerOverlayView.h"
#import "Headers/YouTubeHeader/YTMainAppControlsOverlayView.h"
#import "Headers/YouTubeHeader/YTQTMButton.h"
#import "Headers/YouTubeHeader/YTUIUtils.h"
#import "Headers/YouTubeHeader/YTICommand.h"
#import "Headers/YouTubeHeader/YTCoWatchWatchEndpointWrapperCommandHandler.h"
#import "Headers/YouTubeHeader/GOOHUDManagerInternal.h"
#import "Headers/YouTubeHeader/YTAppDelegate.h"
#import "Headers/YouTubeHeader/YTIMenuRenderer.h"
#import "Headers/YouTubeHeader/YTIMenuItemSupportedRenderers.h"
#import "Headers/YouTubeHeader/YTIMenuNavigationItemRenderer.h"
#import "Headers/YouTubeHeader/YTIButtonRenderer.h"
//#import "Headers/YouTubeHeader/YTIcon.h" // File doesn't exist, not needed (we draw our own icons)
#import "Headers/YouTubeHeader/YTIMenuItemSupportedRenderersElementRendererCompatibilityOptionsExtension.h"
#import "Headers/YouTubeHeader/YTIMenuConditionalServiceItemRenderer.h"
#import "Headers/YouTubeHeader/YTActionSheetAction.h"
#import "Headers/YouTubeHeader/YTActionSheetController.h"
#import "Headers/YouTubeHeader/YTActionSheetDialogViewController.h"
#import "Headers/YouTubeHeader/YTDefaultSheetController.h"
#import "Headers/YouTubeHeader/GOODialogView.h"
#import "Headers/YouTubeHeader/GOODialogViewAction.h"
#import "Headers/YouTubeHeader/QTMIcon.h"
#import "Headers/YouTubeHeader/YTUIResources.h"
#import "Headers/YouTubeHeader/YTVideoCellController.h"
#import "Headers/YouTubeHeader/YTCollectionViewCell.h"

#import "LocalQueueManager.h"
#import "LocalQueueViewController.h"
#import <objc/runtime.h>

// Associated-object keys used across this file (only needed if we add advanced thumbnail injection)

// ============================================================================
// STATE MANAGEMENT FOR AUTO-ADVANCE
// ============================================================================

typedef enum : NSInteger {
    YTLPStateIdle = 0,              // Nothing happening
    YTLPStatePlaying,               // Video playing normally
    YTLPStateNearEnd,               // Within 5s of end
    YTLPStateEnded,                 // Video has ended
    YTLPStateTransitioning,         // We initiated navigation to next video
    YTLPStateWaitingForLoad,        // Waiting for new video to load
    YTLPStateUserPaused             // User paused, don't auto-advance
} YTLPAdvanceState;

// Current state
static YTLPAdvanceState ytlp_advanceState = YTLPStateIdle;

// Track last known player VC
static __weak YTPlayerViewController *ytlp_currentPlayerVC = nil;
static __weak id ytlp_currentWatchPlaybackController = nil;
static __weak id ytlp_currentAutonavController = nil;

// Timing and cooldown tracking
static NSTimeInterval ytlp_lastQueueAdvanceTime = 0;
static NSTimeInterval ytlp_lastStateChangeTime = 0;
static NSString *ytlp_lastPlayedVideoId = nil;
static NSString *ytlp_currentPlayingVideoId = nil;
static NSTimer *ytlp_endCheckTimer = nil;

// Store the last tapped video info for menu operations
static NSString *ytlp_lastTappedVideoId = nil;
static NSString *ytlp_lastTappedVideoTitle = nil;
static NSTimeInterval ytlp_lastTapTime = 0;
static NSString *ytlp_lastMenuContextVideoId = nil;
static NSString *ytlp_lastMenuContextTitle = nil;
static NSTimeInterval ytlp_lastMenuContextTime = 0;

// Track last known playback position for scrubbing/loop detection
static CGFloat ytlp_lastTimeChangePosition = 0;

// Flags to prevent duplicate triggers
static BOOL ytlp_advanceInProgress = NO;
static BOOL ytlp_endDetected = NO;
static BOOL ytlp_userInitiated = NO;

static BOOL YTLP_AutoAdvanceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ytlp_queue_auto_advance_enabled"];
}

static BOOL YTLP_ShowPlayNextButton(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"ytlp_show_play_next_button"] == nil) {
        return YES; // Default: on
    }
    return [defaults boolForKey:@"ytlp_show_play_next_button"];
}

static BOOL YTLP_ShowQueueButton(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"ytlp_show_queue_button"] == nil) {
        return YES; // Default: on
    }
    return [defaults boolForKey:@"ytlp_show_queue_button"];
}

// Forward declarations
static void ytlp_updateAutoplayState(void);
static void ytlp_setupRemoteCommands(void);
static void ytlp_captureVideoTap(id view, NSString *videoId, NSString *title);

// Interface for YTAutoplayAutonavController (like YouLoop declares)
@interface YTAutoplayAutonavController : NSObject
- (void)setLoopMode:(NSInteger)mode;
- (NSInteger)loopMode;
@end

// YTSingleVideoTime interface for time change tracking (from iSponsorBlock)
@interface YTSingleVideoTime : NSObject
@property (nonatomic, readonly, assign) CGFloat time;
@property (nonatomic, readonly, assign) CGFloat absoluteTime;
@end

@interface YTICommand (YTLocalQueue)
+ (id)watchNavigationEndpointWithVideoID:(NSString *)videoId;
@end

// Forward declarations for YTHUDMessage
@interface YTHUDMessage : NSObject
+ (id)messageWithText:(NSString *)text;
@end

// Forward declarations for video objects
@interface NSObject (YTLocalQueueVideoHelpers)
- (id)singleVideo;
- (NSString *)videoID;
- (id)videoData;
@end

// Overlay button size (matches YTVideoOverlay)
#define OVERLAY_BUTTON_SIZE 24

// Queue list icon (three horizontal lines) - draws white directly
static UIImage *YTLPIconQueueList(void) {
    CGFloat size = OVERLAY_BUTTON_SIZE;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [[UIColor whiteColor] setFill];
    
    // Draw three horizontal lines
    CGFloat lineHeight = 2.0;
    CGFloat lineWidth = size * 0.65;
    CGFloat startX = (size - lineWidth) / 2;
    CGFloat spacing = 5.0;
    CGFloat startY = (size - (3 * lineHeight + 2 * spacing)) / 2;
    
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(startX, startY, lineWidth, lineHeight) cornerRadius:1] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(startX, startY + lineHeight + spacing, lineWidth, lineHeight) cornerRadius:1] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(startX, startY + 2 * (lineHeight + spacing), lineWidth, lineHeight) cornerRadius:1] fill];
    
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

// Next icon (skip forward arrow) - draws white directly
static UIImage *YTLPIconNext(void) {
    CGFloat size = OVERLAY_BUTTON_SIZE;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [[UIColor whiteColor] setFill];
    [[UIColor whiteColor] setStroke];
    
    CGFloat centerY = size / 2;
    CGFloat arrowWidth = size * 0.35;
    CGFloat arrowHeight = size * 0.5;
    CGFloat barWidth = 2.5;
    
    // Draw first triangle (play arrow)
    UIBezierPath *arrow1 = [UIBezierPath bezierPath];
    [arrow1 moveToPoint:CGPointMake(3, centerY - arrowHeight/2)];
    [arrow1 addLineToPoint:CGPointMake(3 + arrowWidth, centerY)];
    [arrow1 addLineToPoint:CGPointMake(3, centerY + arrowHeight/2)];
    [arrow1 closePath];
    [arrow1 fill];
    
    // Draw second triangle (play arrow)
    UIBezierPath *arrow2 = [UIBezierPath bezierPath];
    [arrow2 moveToPoint:CGPointMake(3 + arrowWidth, centerY - arrowHeight/2)];
    [arrow2 addLineToPoint:CGPointMake(3 + arrowWidth * 2, centerY)];
    [arrow2 addLineToPoint:CGPointMake(3 + arrowWidth, centerY + arrowHeight/2)];
    [arrow2 closePath];
    [arrow2 fill];
    
    // Draw end bar
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(size - barWidth - 3, centerY - arrowHeight/2, barWidth, arrowHeight) cornerRadius:1] fill];
    
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}


// Fetch video title from YouTube oembed API (same method as LocalQueueViewController)
static void ytlp_fetchTitleForVideoId(NSString *videoId, void (^completion)(NSString *title)) {
    if (!videoId || videoId.length == 0) {
        if (completion) completion(nil);
        return;
    }
    
    NSString *urlString = [NSString stringWithFormat:@"https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=%@&format=json", videoId];
    NSURL *url = [NSURL URLWithString:urlString];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (json && !jsonError) {
                NSString *title = json[@"title"];
                if (completion) completion(title);
                return;
            }
        }
        if (completion) completion(nil);
    }];
    
    [task resume];
}

// ============================================================================
// STATE CHANGE HELPERS
// ============================================================================

static void ytlp_setState(YTLPAdvanceState newState, NSString *reason) {
    if (ytlp_advanceState != newState) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] State: %ld -> %ld (%@)", (long)ytlp_advanceState, (long)newState, reason);
        #endif
        ytlp_advanceState = newState;
        ytlp_lastStateChangeTime = [[NSDate date] timeIntervalSince1970];
    }
}

static void ytlp_resetState(NSString *reason) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] Reset state: %@", reason);
    #endif
    ytlp_setState(YTLPStateIdle, reason);
    ytlp_advanceInProgress = NO;
    ytlp_endDetected = NO;
    ytlp_userInitiated = NO;
}

// ============================================================================
// SMART ADVANCE DECISION LOGIC
// ============================================================================

static BOOL ytlp_shouldAllowQueueAdvance(NSString *reason) {
    // Auto-advance must be enabled
    if (!YTLP_AutoAdvanceEnabled()) {
        return NO;
    }

    // Queue must not be empty
    if ([[YTLPLocalQueueManager shared] isEmpty]) {
        return NO;
    }

    // If advance is already in progress, don't trigger again
    if (ytlp_advanceInProgress) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] Blocked: advance already in progress");
        #endif
        return NO;
    }

    // If we're already transitioning or waiting, don't trigger again
    if (ytlp_advanceState == YTLPStateTransitioning || ytlp_advanceState == YTLPStateWaitingForLoad) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] Blocked: state is %ld", (long)ytlp_advanceState);
        #endif
        return NO;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    // Cooldown check - reduced to 2 seconds for better responsiveness
    NSTimeInterval cooldownTime = ytlp_userInitiated ? 1.0 : 2.0;
    if (now - ytlp_lastQueueAdvanceTime < cooldownTime) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] Blocked: cooldown (%.1fs remaining)", cooldownTime - (now - ytlp_lastQueueAdvanceTime));
        #endif
        return NO;
    }

    // Check current video state
    if (ytlp_currentPlayerVC) {
        NSString *currentVideoId = [ytlp_currentPlayerVC currentVideoID];
        CGFloat currentTime = [ytlp_currentPlayerVC currentVideoMediaTime];
        CGFloat totalTime = [ytlp_currentPlayerVC currentVideoTotalMediaTime];

        // If this is the same video as last advance attempt, and we haven't moved far, block
        if (ytlp_lastPlayedVideoId && [currentVideoId isEqualToString:ytlp_lastPlayedVideoId]) {
            if (currentTime < 10.0) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] Blocked: same video as last advance (%.1fs)", currentTime);
                #endif
                return NO;
            }
        }

        // Check if we're actually near the end or user initiated
        BOOL nearEnd = (totalTime > 0 && currentTime >= (totalTime - 5.0));
        BOOL atEnd = (totalTime > 0 && currentTime >= (totalTime - 1.0));

        // Allow if:
        // - At the very end (< 1s remaining)
        // - Near end AND end was detected
        // - User initiated (button press)
        if (!atEnd && !ytlp_userInitiated && !(nearEnd && ytlp_endDetected)) {
            // Video is still playing normally, not at end
            if (currentTime < 10.0) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] Blocked: video just started (%.1fs)", currentTime);
                #endif
                return NO;
            }
        }
    }

    #if DEBUG
    NSLog(@"[YTLocalQueue] ✓ Allowing advance: %@", reason);
    #endif
    return YES;
}

// ============================================================================
// PLAY NEXT FROM QUEUE (Core Navigation Function)
// ============================================================================

// Play next video in background without waking screen
// Triggers YouTube's native autonav which uses our hooked endpoint
static BOOL ytlp_playNextInBackground(void) {
    if (!ytlp_currentAutonavController) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] No autonav controller available");
        #endif
        return NO;
    }

    if ([[YTLPLocalQueueManager shared] isEmpty]) {
        return NO;
    }

    #if DEBUG
    NSLog(@"[YTLocalQueue] Triggering native autonav for background playback");
    #endif

    // Trigger YouTube's native autonav - our hooks will:
    // 1. autonavEndpoint returns queue video
    // 2. playNext/playAutonav consumes queue item
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL playNextSel = @selector(playNext);
        SEL playAutonavSel = @selector(playAutonav);

        if ([ytlp_currentAutonavController respondsToSelector:playNextSel]) {
            ((void (*)(id, SEL))objc_msgSend)(ytlp_currentAutonavController, playNextSel);
        } else if ([ytlp_currentAutonavController respondsToSelector:playAutonavSel]) {
            ((void (*)(id, SEL))objc_msgSend)(ytlp_currentAutonavController, playAutonavSel);
        }
    });

    return YES;
}

// Check if app is in background
static BOOL ytlp_isAppInBackground(void) {
    __block BOOL isBackground = NO;
    if ([NSThread isMainThread]) {
        isBackground = ([UIApplication sharedApplication].applicationState != UIApplicationStateActive);
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            isBackground = ([UIApplication sharedApplication].applicationState != UIApplicationStateActive);
        });
    }
    return isBackground;
}

static void ytlp_playNextFromQueue(void) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] === playNextFromQueue called ===");
    #endif

    // If in background, try to use direct player transition to avoid waking screen
    if (ytlp_isAppInBackground()) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] App in background, trying direct player transition");
        #endif
        if (ytlp_playNextInBackground()) {
            return;
        }
        // If background transition failed, fall through to navigation method
        #if DEBUG
        NSLog(@"[YTLocalQueue] Background transition failed, falling back to navigation");
        #endif
    }

    // Set advance in progress flag
    ytlp_advanceInProgress = YES;
    ytlp_setState(YTLPStateTransitioning, @"playNextFromQueue");

    NSDictionary *nextItem = [[YTLPLocalQueueManager shared] popNextItem];
    NSString *nextId = nextItem[@"videoId"];
    NSString *nextTitle = nextItem[@"title"];

    if (nextId.length == 0) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] Queue is now empty");
        #endif
        // Queue is now empty, update autoplay state to re-enable YouTube's autoplay
        ytlp_updateAutoplayState();
        ytlp_resetState(@"queue empty");

        // Notify user that queue is complete
        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"✓ Queue complete"]];
        }
        return;
    }

    // Store the video we're leaving from (for navigation failure detection)
    NSString *previousVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;

    // Update tracking variables
    ytlp_lastQueueAdvanceTime = [[NSDate date] timeIntervalSince1970];
    ytlp_lastPlayedVideoId = nextId;
    ytlp_currentPlayingVideoId = nextId;

    // Update currently playing for the Local Queue view
    [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:nextId title:nextTitle];

    #if DEBUG
    NSLog(@"[YTLocalQueue] Navigating: %@ -> %@", previousVideoId ?: @"(unknown)", nextId);
    #endif

    // Schedule a check to detect navigation failure and re-add video to queue if needed
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (ytlp_currentPlayerVC) {
            NSString *currentVideoId = [ytlp_currentPlayerVC currentVideoID];
            // If we're still on the previous video (not the one we tried to navigate to),
            // navigation probably failed - re-add the video to the front of the queue
            if (previousVideoId && [currentVideoId isEqualToString:previousVideoId] && ![currentVideoId isEqualToString:nextId]) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] Navigation failed, re-adding video to queue");
                #endif
                [[YTLPLocalQueueManager shared] insertVideoId:nextId title:nextTitle atIndex:0];
                ytlp_resetState(@"navigation failed");

                Class HUD = objc_getClass("GOOHUDManagerInternal");
                Class HUDMsg = objc_getClass("YTHUDMessage");
                if (HUD && HUDMsg) {
                    [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"⚠ Navigation failed, video re-added"]];
                }
            } else if ([currentVideoId isEqualToString:nextId]) {
                // Successfully navigated
                ytlp_setState(YTLPStateWaitingForLoad, @"navigation success");
                ytlp_advanceInProgress = NO;
                ytlp_userInitiated = NO;

                // Reset state after video loads
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ytlp_resetState(@"video loaded");
                });
            }
        }
    });

    // Show toast with video title or ID (only if app is in foreground)
    if (!ytlp_isAppInBackground()) {
        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            NSInteger remaining = [[YTLPLocalQueueManager shared] allItems].count;
            NSString *displayName = (nextTitle.length > 0) ? nextTitle : nextId;
            if (displayName.length > 40) displayName = [[displayName substringToIndex:37] stringByAppendingString:@"..."];
            NSString *message = (remaining > 0)
                ? [NSString stringWithFormat:@"▶ %@ (%ld more)", displayName, (long)remaining]
                : [NSString stringWithFormat:@"▶ %@ (last)", displayName];
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:message]];
        }
    }

    // Navigate using YouTube's command system
    Class YTICommandClass = objc_getClass("YTICommand");
    if (YTICommandClass && [YTICommandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) {
        id cmd = [YTICommandClass watchNavigationEndpointWithVideoID:nextId];
        Class Handler = objc_getClass("YTCoWatchWatchEndpointWrapperCommandHandler");
        if (Handler) {
            id handler = [[Handler alloc] init];
            if ([handler respondsToSelector:@selector(sendOriginalCommandWithNavigationEndpoint:fromView:entry:sender:completionBlock:)]) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] Using YTCoWatchWatchEndpointWrapperCommandHandler");
                #endif
                [handler sendOriginalCommandWithNavigationEndpoint:cmd fromView:nil entry:nil sender:nil completionBlock:nil];
                return;
            }
        }
    }

    // Fallback to URL scheme
    #if DEBUG
    NSLog(@"[YTLocalQueue] Using URL scheme fallback");
    #endif
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"youtube://watch?v=%@", nextId]];
    Class UIUtils = objc_getClass("YTUIUtils");
    if (UIUtils && [UIUtils canOpenURL:url]) {
        [UIUtils openURL:url];
    }
}

// Forced navigation version - always uses navigation command, never native autonav
// Used for scrub-to-end and doubletap-to-end where native autonav won't work
static void ytlp_playNextFromQueueForced(void) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] === playNextFromQueueForced called ===");
    #endif

    // Set advance in progress flag
    ytlp_advanceInProgress = YES;
    ytlp_setState(YTLPStateTransitioning, @"playNextFromQueueForced");

    NSDictionary *nextItem = [[YTLPLocalQueueManager shared] popNextItem];
    NSString *nextId = nextItem[@"videoId"];
    NSString *nextTitle = nextItem[@"title"];

    if (nextId.length == 0) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] Queue is now empty");
        #endif
        ytlp_updateAutoplayState();
        ytlp_resetState(@"queue empty");

        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"✓ Queue complete"]];
        }
        return;
    }

    // Update tracking variables
    ytlp_lastQueueAdvanceTime = [[NSDate date] timeIntervalSince1970];
    ytlp_lastPlayedVideoId = nextId;
    ytlp_currentPlayingVideoId = nextId;

    [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:nextId title:nextTitle];

    #if DEBUG
    NSLog(@"[YTLocalQueue] Forced navigation to: %@", nextId);
    #endif

    // Show toast
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    if (HUD && HUDMsg) {
        NSInteger remaining = [[YTLPLocalQueueManager shared] allItems].count;
        NSString *displayName = (nextTitle.length > 0) ? nextTitle : nextId;
        if (displayName.length > 40) displayName = [[displayName substringToIndex:37] stringByAppendingString:@"..."];
        NSString *message = (remaining > 0)
            ? [NSString stringWithFormat:@"▶ %@ (%ld more)", displayName, (long)remaining]
            : [NSString stringWithFormat:@"▶ %@ (last)", displayName];
        [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:message]];
    }

    // Navigate using YouTube's command system (always - no background autonav)
    Class YTICommandClass = objc_getClass("YTICommand");
    if (YTICommandClass && [YTICommandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) {
        id cmd = [YTICommandClass watchNavigationEndpointWithVideoID:nextId];
        Class Handler = objc_getClass("YTCoWatchWatchEndpointWrapperCommandHandler");
        if (Handler) {
            id handler = [[Handler alloc] init];
            if ([handler respondsToSelector:@selector(sendOriginalCommandWithNavigationEndpoint:fromView:entry:sender:completionBlock:)]) {
                [handler sendOriginalCommandWithNavigationEndpoint:cmd fromView:nil entry:nil sender:nil completionBlock:nil];
                ytlp_advanceInProgress = NO;
                return;
            }
        }
    }

    // Fallback to URL scheme
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"youtube://watch?v=%@", nextId]];
    Class UIUtils = objc_getClass("YTUIUtils");
    if (UIUtils && [UIUtils canOpenURL:url]) {
        [UIUtils openURL:url];
    }
    ytlp_advanceInProgress = NO;
}

// Helper function to check if a string looks like a YouTube video ID
static BOOL ytlp_looksLikeVideoId(NSString *str) {
    if (!str || str.length != 11) return NO;
    
    // Exclude common false positives (class names, etc.)
    static NSSet *excludedStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excludedStrings = [NSSet setWithArray:@[
            @"YTVideoNode", @"ELMCellNode", @"ELMElement", @"ASTextNode",
            @"UIImageView", @"description", @"superclass_"
        ]];
    });
    if ([excludedStrings containsObject:str]) return NO;
    
    // Must contain at least one digit (real video IDs almost always do)
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([str rangeOfCharacterFromSet:digits].location == NSNotFound) return NO;
    
    NSCharacterSet *validChars = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    NSCharacterSet *strChars = [NSCharacterSet characterSetWithCharactersInString:str];
    return [validChars isSupersetOfSet:strChars];
}


// Collect ALL video IDs from an object into a mutable set
static void ytlp_collectAllVideoIds(id obj, int depth, NSMutableSet *collected, NSMutableSet *visited) {
    if (!obj || depth <= 0 || !collected) return;
    
    // Prevent infinite loops by tracking visited objects
    NSValue *objPtr = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([visited containsObject:objPtr]) return;
    [visited addObject:objPtr];
    
    // Get class name for logging and safety checks
    NSString *className = NSStringFromClass([obj class]);
    
    // Skip classes known to cause crashes or be irrelevant
    static NSSet *dangerousClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dangerousClasses = [NSSet setWithArray:@[
            @"CALayer", @"UIView", @"_ASDisplayView", @"ASDisplayNode",
            @"NSConcreteData", @"NSConcreteValue", @"__NSCFData",
            @"UIImage", @"UIColor", @"NSAttributedString",
            @"ELMElement", @"ELMContainerNode", @"ELMController",
            @"GPBMessage", @"GPBCodedInputStream", @"GPBUnknownFieldSet"
        ]];
    });
    if ([dangerousClasses containsObject:className]) {
        return;
    }
    // Also skip if class name contains certain patterns that are known to crash
    if ([className containsString:@"GPB"] || [className containsString:@"Protobuf"]) {
        return;
    }
    
    @try {
        // Special handling for YTVideoWithContextNode - look for specific paths
        if ([className containsString:@"VideoWithContext"] || [className containsString:@"VideoNode"] || 
            [className containsString:@"VideoRenderer"] || [className containsString:@"CellController"]) {
            // Get parentResponder (YTVideoElementCellController)
            id parentResponder = nil;
            @try {
                parentResponder = [obj valueForKey:@"parentResponder"];
            } @catch (__unused NSException *e) {}
            
            if (parentResponder) {
                // Scan ENTIRE class hierarchy of parentResponder
                Class currentPRClass = [parentResponder class];
                for (__unused int level = 0; level < 10 && currentPRClass && currentPRClass != [NSObject class]; level++) {
                    
                    unsigned int propCount = 0;
                    objc_property_t *props = class_copyPropertyList(currentPRClass, &propCount);
                    if (props && propCount > 0) {
                        NSMutableArray *propNames = [NSMutableArray array];
                        for (unsigned int i = 0; i < propCount; i++) {
                            const char *name = property_getName(props[i]);
                            if (name) [propNames addObject:[NSString stringWithUTF8String:name]];
                        }
                        free(props);
                        
                        for (NSString *propName in propNames) {
                            NSString *lowerProp = [propName lowercaseString];
                            // Skip UI/view related
                            if ([lowerProp containsString:@"view"] || [lowerProp containsString:@"layer"] ||
                                [lowerProp containsString:@"node"] || [lowerProp containsString:@"gesture"]) {
                                continue;
                            }
                            
                            @try {
                                id propVal = [parentResponder valueForKey:propName];
                                if (!propVal) continue;
                                
                                if ([propVal isKindOfClass:[NSString class]]) {
                                    NSString *strVal = (NSString *)propVal;
                                    if ([strVal length] == 11 && ytlp_looksLikeVideoId(strVal)) {
                                        [collected addObject:strVal];
                                    }
                                } else if ([lowerProp isEqualToString:@"entry"]) {
                                    // THIS IS THE KEY - entry contains YTIElementRenderer (protobuf)
                                    
                                    // Method 1: Use GPBMessage's textFormatForUnknownFieldData or just description
                                    // and look for watchEndpoint with videoId
                                    @try {
                                        // Get full description which includes all protobuf fields
                                        NSString *desc = [propVal debugDescription];
                                        if (!desc) desc = [propVal description];
                                        
                                        if (desc.length > 0) {
                                            // Look for videoId in thumbnail URL - most reliable pattern!
                                            // Format: https://i.ytimg.com/vi/VIDEO_ID/...
                                            NSArray *patterns = @[
                                                @"i\\.ytimg\\.com/vi/([a-zA-Z0-9_-]{11})/",  // THUMBNAIL URL - most reliable!
                                                @"videoId:\\s*\"([a-zA-Z0-9_-]{11})\"",
                                                @"video_id:\\s*\"([a-zA-Z0-9_-]{11})\"",
                                                @"\"videoId\":\\s*\"([a-zA-Z0-9_-]{11})\"",
                                                @"watchEndpoint\\s*\\{[^}]*videoId:\\s*\"([a-zA-Z0-9_-]{11})\""
                                            ];
                                            
                                            for (NSString *pattern in patterns) {
                                                NSRegularExpression *regex = [NSRegularExpression
                                                    regularExpressionWithPattern:pattern options:0 error:nil];
                                                NSArray *matches = [regex matchesInString:desc options:0 range:NSMakeRange(0, desc.length)];
                                                for (NSTextCheckingResult *match in matches) {
                                                    if (match.numberOfRanges > 1) {
                                                        NSString *vid = [desc substringWithRange:[match rangeAtIndex:1]];
                                                        if (ytlp_looksLikeVideoId(vid)) {
                                                            [collected addObject:vid];
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    } @catch (__unused NSException *e) {}
                                    
                                    // Method 2: Try GPBMessage field access
                                    @try {
                                        // List all fields using GPB introspection
                                        SEL fieldsSel = NSSelectorFromString(@"descriptor");
                                        if ([propVal respondsToSelector:fieldsSel]) {
                                            id descriptor = [propVal valueForKey:@"descriptor"];
                                            if (descriptor) {
                                                // Try to get fields
                                                SEL fieldsSel2 = NSSelectorFromString(@"fields");
                                                if ([descriptor respondsToSelector:fieldsSel2]) {
                                                    NSArray *fields = [descriptor valueForKey:@"fields"];
                                                    
                                                    for (id field in fields) {
                                                        @try {
                                                            NSString *fieldName = [field valueForKey:@"name"];
                                                            if (fieldName) {
                                                                // Try to get value for this field
                                                                @try {
                                                                    id fieldValue = [propVal valueForKey:fieldName];
                                                                    if ([fieldValue isKindOfClass:[NSString class]]) {
                                                                        NSString *strVal = (NSString *)fieldValue;
                                                                        if ([strVal length] == 11 && ytlp_looksLikeVideoId(strVal)) {
                                                                            [collected addObject:strVal];
                                                                        }
                                                                    }
                                                                } @catch (__unused NSException *e) {}
                                                            }
                                                        } @catch (__unused NSException *e) {}
                                                    }
                                                }
                                            }
                                        }
                                    } @catch (__unused NSException *e) {}
                                    
                                    // Method 3: Try known YouTube protobuf field numbers for video-related data
                                    // YouTube often uses extensions with high field numbers
                                    @try {
                                        // Unknown fields handling - no logging
                                    } @catch (__unused NSException *e) {}
                                }
                            } @catch (__unused NSException *e) {}
                        }
                    } else if (props) {
                        free(props);
                    }
                    
                    currentPRClass = class_getSuperclass(currentPRClass);
                }
            }
            
            // Also try ELMNodeController path carefully
            @try {
                id controller = [obj valueForKey:@"controller"];
                if (controller) {
                    // Try to get element data from controller
                    @try {
                        id elementData = [controller valueForKey:@"elementData"];
                        if (elementData) {
                            @try {
                                id vid = [elementData valueForKey:@"videoId"];
                                if ([vid isKindOfClass:[NSString class]] && [vid length] == 11 && ytlp_looksLikeVideoId(vid)) {
                                    [collected addObject:vid];
                                }
                            } @catch (__unused NSException *e) {}
                        }
                    } @catch (__unused NSException *e) {}
                    
                    // Try model/data paths
                    NSArray *ctrlPaths = @[@"model", @"data", @"videoData", @"contentData"];
                    for (NSString *path in ctrlPaths) {
                        @try {
                            id pathVal = [controller valueForKey:path];
                            if (pathVal) {
                                @try {
                                    id vid = [pathVal valueForKey:@"videoId"];
                                    if ([vid isKindOfClass:[NSString class]] && [vid length] == 11 && ytlp_looksLikeVideoId(vid)) {
                                        [collected addObject:vid];
                                    }
                                } @catch (__unused NSException *e) {}
                            }
                        } @catch (__unused NSException *e) {}
                    }
                }
            } @catch (__unused NSException *e) {}
        }
        
        // 1) Direct selectors
        if ([obj respondsToSelector:@selector(videoId)]) {
            @try {
                id s = [obj videoID];
                if ([s isKindOfClass:[NSString class]] && [s length] == 11 && ytlp_looksLikeVideoId(s)) {
                    [collected addObject:s];
                }
            } @catch (__unused NSException *e) {}
        }
        
        // 2) KVC direct - try multiple property names (with extra safety)
        NSArray *videoIdKeys = @[@"videoId", @"videoID"];
        for (NSString *key in videoIdKeys) {
            @try {
                if (![obj respondsToSelector:NSSelectorFromString(key)]) continue;
                id v = [obj valueForKey:key];
                if ([v isKindOfClass:[NSString class]] && [v length] == 11 && ytlp_looksLikeVideoId(v)) {
                    [collected addObject:v];
                }
            } @catch (__unused NSException *e) {}
        }

        // 3) Known nested keys to recurse through - prioritize renderer-specific paths
        NSArray<NSString *> *keys = @[
            // Renderer-specific (most likely to have the CELL's video)
            @"compactVideoRenderer", @"playlistPanelVideoRenderer", @"gridVideoRenderer",
            @"videoRenderer", @"reelItemRenderer", @"shortsLockupViewModel",
            @"playlistPanelVideoWrapperRenderer", @"compactLinkRenderer",
            // YTVideoWithContextNode specific
            @"videoWithContextRenderer", @"videoContext", @"contextRenderer",
            // Navigation endpoints (also cell-specific)
            @"navigationEndpoint", @"watchEndpoint", @"watchNavigationEndpoint",
            @"onTap", @"command", @"innertubeCommand",
            // Generic containers - but NOT model/viewModel which can crash
            @"renderer", @"elementRenderer", @"richItemRenderer",
            @"element", @"data", @"content"
            // NOTE: Deliberately NOT including currentVideo, activeVideo, singleVideo, playerResponse, model, viewModel
        ];
        for (NSString *k in keys) {
            @try {
                // Check if object responds to this key before trying to access
                SEL sel = NSSelectorFromString(k);
                if (![obj respondsToSelector:sel]) continue;
                
                id child = [obj valueForKey:k];
                if (child && ![dangerousClasses containsObject:NSStringFromClass([child class])]) {
                    ytlp_collectAllVideoIds(child, depth - 1, collected, visited);
                }
            } @catch (__unused NSException *e) {}
        }
        
        // 4) Arrays: scan items
        if ([obj isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)obj;
            NSUInteger limit = MIN(arr.count, 10);
            for (NSUInteger i = 0; i < limit; i++) {
                ytlp_collectAllVideoIds(arr[i], depth - 1, collected, visited);
            }
        }
        
        // 5) Dictionaries
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)obj;
            for (NSString *key in dict) {
                NSString *lowerKey = [key lowercaseString];
                if ([lowerKey containsString:@"video"] || [lowerKey containsString:@"renderer"]) {
                    ytlp_collectAllVideoIds(dict[key], depth - 1, collected, visited);
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

// Find the best video ID from an object, preferring one different from current
static NSString *ytlp_findBestVideoId(id obj, int depth, NSString *currentVideoId) {
    if (!obj) return nil;
    
    NSMutableSet *allIds = [NSMutableSet set];
    NSMutableSet *visited = [NSMutableSet set];
    ytlp_collectAllVideoIds(obj, depth, allIds, visited);
    
    if (allIds.count == 0) return nil;
    
    // First, try to find one that's different from current
    for (NSString *vid in allIds) {
        if (currentVideoId.length == 0 || ![vid isEqualToString:currentVideoId]) {
            return vid;
        }
    }
    
    // Fall back to any ID
    return [allIds anyObject];
}

// Legacy wrapper for compatibility
static NSString *ytlp_findVideoIdDeep(id obj, int depth) {
    return ytlp_findBestVideoId(obj, depth, nil);
}

static NSString *ytlp_getCurrentVideoId(void) {
    id pvc = ytlp_currentPlayerVC;
    if (pvc) {
        if ([pvc respondsToSelector:@selector(currentVideoID)]) {
            NSString *vid = [pvc currentVideoID];
            if ([vid isKindOfClass:[NSString class]] && vid.length > 0) return vid;
        }
        if ([pvc respondsToSelector:@selector(activeVideo)]) {
            id active = [pvc activeVideo];
            if (active && [active respondsToSelector:@selector(singleVideo)]) {
                id sv = [active singleVideo];
                if (sv && [sv respondsToSelector:@selector(videoId)]) {
                    NSString *vid = [sv videoID];
                    if ([vid isKindOfClass:[NSString class]] && vid.length > 0) return vid;
                }
            }
        }
    }
    return nil;
}

// Try to extract a video id from renderers, preferring one different from current.
static NSString *ytlp_findVideoIdInRenderers(NSArray *renderers, NSString *currentVideoId) {
    if (![renderers isKindOfClass:[NSArray class]] || renderers.count == 0) return nil;
    
    // Collect ALL video IDs from all renderers
    NSMutableSet *allIds = [NSMutableSet set];
    NSMutableSet *visited = [NSMutableSet set];
    
    for (id renderer in renderers) {
        ytlp_collectAllVideoIds(renderer, 5, allIds, visited);
    }
    
    // Pick one that's different from current
    for (NSString *vid in allIds) {
        if (currentVideoId.length == 0 || ![vid isEqualToString:currentVideoId]) {
            return vid;
        }
    }
    
    return [allIds anyObject];
}

// Resolve menu context video ID at tap time with multiple fallbacks.
static NSString *ytlp_resolveMenuVideoId(id action,
                                         NSArray *renderers,
                                         UIView *fromView,
                                         id entry,
                                         id menuController,
                                         NSString *currentVideoId) {
    // Collect ALL video IDs from all sources
    NSMutableSet *allIds = [NSMutableSet set];
    NSMutableSet *visited = [NSMutableSet set];
    
    // 1) Action object itself
    if (action) {
        ytlp_collectAllVideoIds(action, 6, allIds, visited);
    }
    
    // 2) Menu controller
    if (menuController) {
        ytlp_collectAllVideoIds(menuController, 5, allIds, visited);
    }
    
    // 3) Entry parameter
    if (entry) {
        ytlp_collectAllVideoIds(entry, 5, allIds, visited);
    }
    
    // 4) Renderers array
    if ([renderers isKindOfClass:[NSArray class]]) {
        for (id renderer in renderers) {
            ytlp_collectAllVideoIds(renderer, 5, allIds, visited);
        }
    }
    
    // 5) fromView - walk up the hierarchy and scan each level
    if (fromView) {
        UIView *currentView = fromView;
        for (int level = 0; level < 10 && currentView; level++) {
            ytlp_collectAllVideoIds(currentView, 4, allIds, visited);
            
            // Also try the node property specifically for ASCollectionViewCell
            @try {
                id node = [currentView valueForKey:@"node"];
                if (node) {
                    ytlp_collectAllVideoIds(node, 6, allIds, visited);
                }
            } @catch (__unused NSException *e) {}
            
            currentView = [currentView superview];
        }
    }
    
    // Pick the best one (not current video)
    NSString *resolved = nil;
    for (NSString *vid in allIds) {
        if (currentVideoId.length == 0 || ![vid isEqualToString:currentVideoId]) {
            resolved = vid;
            break;
        }
    }
    
    // Fallback to any ID if all match current
    if (!resolved && allIds.count > 0) {
        resolved = [allIds anyObject];
    }
    
    // 6) Recent menu context cache as last resort
    if (resolved.length == 0 || (currentVideoId.length > 0 && [resolved isEqualToString:currentVideoId])) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if ((now - ytlp_lastMenuContextTime) < 6.0 && ytlp_lastMenuContextVideoId.length > 0) {
            if (![ytlp_lastMenuContextVideoId isEqualToString:currentVideoId]) {
                resolved = ytlp_lastMenuContextVideoId;
            }
        }
    }
    
    return resolved;
}

// Improved video ID extraction with multiple fallbacks and title extraction
static void ytlp_extractVideoInfo(id entry, NSString **outVideoId, NSString **outTitle) {
    NSString *videoId = nil;
    NSString *title = nil;
    
    @try {
        if (entry) {
            // Try multiple ways to get videoId from entry
            if ([entry respondsToSelector:@selector(videoId)]) {
                videoId = [entry videoID];
            } else {
                videoId = [entry valueForKey:@"videoId"];
            }
            
            // Try deep search if not found
            if (videoId.length == 0) {
                videoId = ytlp_findVideoIdDeep(entry, 4);
            }
            
            // Try multiple approaches to get title
            if ([entry respondsToSelector:@selector(title)]) {
                id titleObj = [entry title];
                if ([titleObj respondsToSelector:@selector(text)]) {
                    title = [titleObj text];
                } else if ([titleObj isKindOfClass:[NSString class]]) {
                    title = titleObj;
                }
            }
            
            // Alternative title extraction methods
            if (title.length == 0) {
                NSArray *titleKeys = @[@"title", @"headline", @"videoTitle", @"name", @"displayName"];
                for (NSString *key in titleKeys) {
                    @try {
                        id titleValue = [entry valueForKey:key];
                        if ([titleValue isKindOfClass:[NSString class]] && [titleValue length] > 0) {
                            title = titleValue;
                            break;
                        } else if (titleValue && [titleValue respondsToSelector:@selector(text)]) {
                            NSString *extracted = [titleValue text];
                            if (extracted.length > 0) {
                                title = extracted;
                                break;
                            }
                        }
    } @catch (__unused NSException *e) {}
                }
            }
        }
    } @catch (__unused NSException *e) {}
    
    // Try to extract title from nested structures if still not found
    if (title.length == 0 && entry) {
        @try {
            // Try videoRenderer path
            id videoRenderer = [entry valueForKey:@"videoRenderer"];
            if (videoRenderer) {
                id titleObj = [videoRenderer valueForKey:@"title"];
                if (titleObj) {
                    SEL runsSel = NSSelectorFromString(@"runs");
                    if ([titleObj respondsToSelector:runsSel]) {
                        NSArray *runs = ((id (*)(id, SEL))objc_msgSend)(titleObj, runsSel);
                        if (runs.count > 0) {
                            id firstRun = runs[0];
                            if ([firstRun respondsToSelector:@selector(text)]) {
                                title = [firstRun text];
                            }
                        }
                    } else {
                        SEL simpleTextSel = NSSelectorFromString(@"simpleText");
                        if ([titleObj respondsToSelector:simpleTextSel]) {
                            title = ((id (*)(id, SEL))objc_msgSend)(titleObj, simpleTextSel);
                        }
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    }
    
    // Skip accessibilityLabel - it often picks up wrong labels like "Action menu"
    
    // Fallback to current player for both videoId and title
    if (videoId.length == 0) {
        videoId = ytlp_getCurrentVideoId();
        
        // Try to get title from current player
        if (title.length == 0 && ytlp_currentPlayerVC) {
            @try {
                id activeVideo = [ytlp_currentPlayerVC valueForKey:@"activeVideo"];
                if (activeVideo) {
                    id singleVideo = [activeVideo valueForKey:@"singleVideo"];
                    if (singleVideo) {
                        id video = [singleVideo valueForKey:@"video"];
                        if (video && [video respondsToSelector:@selector(title)]) {
                            title = [video title];
                        }
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }
    
    if (outVideoId) *outVideoId = videoId;
    if (outTitle) *outTitle = title;
}

// Capture video tap function
static void ytlp_captureVideoTap(__unused id view, NSString *videoId, NSString *title) {
    if (videoId.length > 0) {
        ytlp_lastTappedVideoId = [videoId copy];
        ytlp_lastTappedVideoTitle = [title copy];
        ytlp_lastTapTime = [[NSDate date] timeIntervalSince1970];
    }
}

// Hook UIButton actions to capture video taps
typedef void (*UIButtonSendActionsIMP)(id, SEL, NSUInteger, id);
static UIButtonSendActionsIMP origButtonSendActions = NULL;

// Hook collection view cell selection to capture target videos
typedef void (*CollectionViewCellSetSelectedIMP)(id, SEL, BOOL);
static CollectionViewCellSetSelectedIMP origCollectionViewCellSetSelected = NULL;

// Gesture recognizer approach disabled for now due to method signature issues

static void ytlp_buttonSendActions(id self, SEL _cmd, NSUInteger controlEvents, id event) {
    // Try to extract video info from button or its superview before the action
    @try {
        NSString *videoId = nil;
        NSString *title = nil;
        
        // Look in the button and its parent views for video information
        UIView *currentView = self;
        for (int level = 0; level < 10 && currentView; level++) {
            @try {
                // Try various video-related properties
                id renderer = [currentView valueForKey:@"renderer"];
                id videoData = [currentView valueForKey:@"videoData"];
                id entry = [currentView valueForKey:@"entry"];
                id data = [currentView valueForKey:@"data"];
                
                if (renderer) {
                    ytlp_extractVideoInfo(renderer, &videoId, &title);
                    if (videoId.length > 0) break;
                }
                if (videoData) {
                    ytlp_extractVideoInfo(videoData, &videoId, &title);
                    if (videoId.length > 0) break;
                }
                if (entry) {
                    ytlp_extractVideoInfo(entry, &videoId, &title);
                    if (videoId.length > 0) break;
                }
                if (data) {
                    ytlp_extractVideoInfo(data, &videoId, &title);
                    if (videoId.length > 0) break;
                }
            } @catch (__unused NSException *e) {}
            
            currentView = [currentView superview];
        }
        
        if (videoId.length > 0) {
            ytlp_captureVideoTap(self, videoId, title);
        }
    } @catch (__unused NSException *e) {}
    
    // Call original implementation
    if (origButtonSendActions) {
        origButtonSendActions(self, _cmd, controlEvents, event);
    }
}

// Collection view cell selection hook to capture video when user interacts with video list items
static void ytlp_collectionViewCellSetSelected(id self, SEL _cmd, BOOL selected) {
    @try {
        if (selected && [self isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
            NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
            
            // Extract video info from the selected cell's node
            @try {
                id node = [self valueForKey:@"node"];
                if (node) {
                    NSString *videoId = nil;
                    NSString *title = nil;
                    ytlp_extractVideoInfo(node, &videoId, &title);
                    
                    if (videoId.length > 0) {
                        BOOL isDifferent = ![videoId isEqualToString:currentVideoId];
                        if (isDifferent) {
                            ytlp_captureVideoTap(self, videoId, title);
                        }
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    } @catch (__unused NSException *e) {}
    
    // Call original implementation
    if (origCollectionViewCellSetSelected) {
        origCollectionViewCellSetSelected(self, _cmd, selected);
    }
}


// YTPlayerViewController hooks
typedef void (*PlayerViewDidAppearIMP)(id, SEL, BOOL);
static PlayerViewDidAppearIMP origPlayerViewDidAppear = NULL;

// Hook seekToTime: to detect when YouTube loops by seeking to 0
typedef void (*PlayerSeekToTimeIMP)(id, SEL, CGFloat);
static PlayerSeekToTimeIMP origPlayerSeekToTime = NULL;

// Forward declaration for forced navigation (skips background autonav)
static void ytlp_playNextFromQueueForced(void);

static void ytlp_playerSeekToTime(id self, SEL _cmd, CGFloat time) {
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        CGFloat totalTime = 0;

        if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            totalTime = [(id)self currentVideoTotalMediaTime];
        }

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        BOOL cooldownOk = (now - ytlp_lastQueueAdvanceTime >= 3.0);

        if (totalTime > 10.0 && cooldownOk) {
            // Case 1: Seeking TO the end (user scrubbed to end) - advance before loop
            // Use forced navigation since native autonav won't work mid-video
            if (time >= (totalTime - 1.0)) {
                ytlp_playNextFromQueueForced();
                return;
            }

            // Case 2: Seeking TO the start (Loop Event)
            // If we are seeking to ~0, and we were previously deep in the video,
            // AND we didn't just start playing (safety)
            if (time < 1.0 && ytlp_lastTimeChangePosition > (totalTime - 5.0)) {
                // This is likely a loop!
                // Intercept and play next.
                ytlp_playNextFromQueueForced();
                return;
            }
        }
    }

    // Execute normal seek
    if (origPlayerSeekToTime) origPlayerSeekToTime(self, _cmd, time);
}

// Also hook scrubToTime: (older method, but may still be used)
typedef void (*PlayerScrubToTimeIMP)(id, SEL, CGFloat);
static PlayerScrubToTimeIMP origPlayerScrubToTime = NULL;

static void ytlp_playerScrubToTime(id self, SEL _cmd, CGFloat time) {
    // Detect if scrubbing TO the end - advance queue before loop happens
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        CGFloat totalTime = 0;
        if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            totalTime = [(id)self currentVideoTotalMediaTime];
        }

        // If scrubbing to very near the end (within 1 second), advance queue instead
        // Use forced navigation since native autonav won't work mid-video
        if (totalTime > 10.0 && time >= (totalTime - 1.0)) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - ytlp_lastQueueAdvanceTime >= 3.0) {
                ytlp_playNextFromQueueForced();
                return; // Don't scrub to end
            }
        }
    }

    if (origPlayerScrubToTime) origPlayerScrubToTime(self, _cmd, time);
}

// Hook seekToTime:seekSource: (another common variant)
typedef void (*PlayerSeekToTimeSourceIMP)(id, SEL, CGFloat, int);
static PlayerSeekToTimeSourceIMP origPlayerSeekToTimeSource = NULL;

static void ytlp_playerSeekToTimeSource(id self, SEL _cmd, CGFloat time, int source) {
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        CGFloat totalTime = 0;
        if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            totalTime = [(id)self currentVideoTotalMediaTime];
        }

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        BOOL cooldownOk = (now - ytlp_lastQueueAdvanceTime >= 3.0);

        if (totalTime > 10.0 && cooldownOk) {
            // Seeking TO the end - advance queue
            if (time >= (totalTime - 1.0)) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] seekToTime:seekSource: detected seek to end");
                #endif
                ytlp_playNextFromQueueForced();
                return;
            }
            // Loop detection
            if (time < 1.0 && ytlp_lastTimeChangePosition > (totalTime - 5.0)) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] seekToTime:seekSource: detected loop");
                #endif
                ytlp_playNextFromQueueForced();
                return;
            }
        }
    }
    if (origPlayerSeekToTimeSource) origPlayerSeekToTimeSource(self, _cmd, time, source);
}

// Hook seekToTime:toleranceBefore:toleranceAfter:seekSource: (most detailed variant)
typedef void (*PlayerSeekToTimeToleranceSourceIMP)(id, SEL, CGFloat, CGFloat, CGFloat, int);
static PlayerSeekToTimeToleranceSourceIMP origPlayerSeekToTimeToleranceSource = NULL;

static void ytlp_playerSeekToTimeToleranceSource(id self, SEL _cmd, CGFloat time, CGFloat before, CGFloat after, int source) {
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        CGFloat totalTime = 0;
        if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            totalTime = [(id)self currentVideoTotalMediaTime];
        }

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        BOOL cooldownOk = (now - ytlp_lastQueueAdvanceTime >= 3.0);

        if (totalTime > 10.0 && cooldownOk) {
            if (time >= (totalTime - 1.0)) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] seekToTime:toleranceBefore:toleranceAfter:seekSource: detected seek to end");
                #endif
                ytlp_playNextFromQueueForced();
                return;
            }
            if (time < 1.0 && ytlp_lastTimeChangePosition > (totalTime - 5.0)) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] seekToTime:toleranceBefore:toleranceAfter:seekSource: detected loop");
                #endif
                ytlp_playNextFromQueueForced();
                return;
            }
        }
    }
    if (origPlayerSeekToTimeToleranceSource) origPlayerSeekToTimeToleranceSource(self, _cmd, time, before, after, source);
}

// ============================================================================
// TIME CHANGE MONITORING (Backup/Safety Net Layer)
// ============================================================================

// Hook singleVideo:currentVideoTimeDidChange: for time-based monitoring
// This is a BACKUP mechanism - primary detection should be through video end hooks
typedef void (*SingleVideoTimeDidChangeIMP)(id, SEL, id, YTSingleVideoTime *);
static SingleVideoTimeDidChangeIMP origSingleVideoTimeDidChange = NULL;
static SingleVideoTimeDidChangeIMP origPotentiallyMutatedSingleVideoTimeDidChange = NULL;

static void ytlp_handleVideoTimeChange(id self, YTSingleVideoTime *videoTime) {
    if (!YTLP_AutoAdvanceEnabled() || [[YTLPLocalQueueManager shared] isEmpty]) {
        // Reset state if auto-advance is disabled or queue is empty
        if (ytlp_advanceState != YTLPStateIdle) {
            ytlp_resetState(@"auto-advance disabled or queue empty");
        }
        return;
    }

    // Use the time object directly - it works in background/PiP
    CGFloat currentTime = videoTime.time;
    CGFloat totalTime = 0;

    // Try to get total time from the view controller
    if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        totalTime = [(id)self currentVideoTotalMediaTime];
    }

    // Safety check - ignore short/invalid videos
    if (totalTime < 5.0) return;

    // Update state based on playback position
    if (currentTime < 2.0 && ytlp_advanceState != YTLPStateIdle && ytlp_advanceState != YTLPStateTransitioning) {
        // Video just started or restarted - clear the consumed video ID
        ytlp_currentPlayingVideoId = nil;
        ytlp_resetState(@"video (re)started");
    } else if (currentTime >= (totalTime - 5.0)) {
        // Near end of video
        if (ytlp_advanceState == YTLPStatePlaying || ytlp_advanceState == YTLPStateIdle) {
            ytlp_setState(YTLPStateNearEnd, @"approaching end");
        }
    } else if (currentTime > 5.0 && currentTime < (totalTime - 5.0)) {
        // Middle of video - normal playback
        if (ytlp_advanceState != YTLPStatePlaying &&
            ytlp_advanceState != YTLPStateUserPaused &&
            ytlp_advanceState != YTLPStateTransitioning &&
            ytlp_advanceState != YTLPStateWaitingForLoad) {
            ytlp_setState(YTLPStatePlaying, @"normal playback");
        }
    }

    // End detection (BACKUP - primary should be videoDidFinish hooks)
    // Trigger at 0.3s remaining to catch edge cases
    if (currentTime >= (totalTime - 0.3) && ytlp_advanceState != YTLPStateEnded) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] Time-based end detection: %.1f/%.1f", currentTime, totalTime);
        #endif
        ytlp_endDetected = YES;
        ytlp_setState(YTLPStateEnded, @"time reached end");

        if (ytlp_shouldAllowQueueAdvance(@"time-based end detection")) {
            ytlp_playNextFromQueue();
        }
    }

    // BACKUP: Loop detection (RARE - only if user manually enabled loop or endscreen hooks failed)
    // If we jumped from late in video (> 80% or > 20s) back to start (< 2s), it's likely a loop
    // This is now a LOW PRIORITY backup since we intercept earlier with endscreen hooks
    if (ytlp_lastTimeChangePosition > MAX(totalTime * 0.8, 20.0) && currentTime < 2.0) {
        // Possible loop detected
        NSTimeInterval timeSinceLastAdvance = [[NSDate date] timeIntervalSince1970] - ytlp_lastQueueAdvanceTime;

        // Only treat as loop if:
        // 1. We're not already transitioning
        // 2. Video played for significant time (20+ seconds to avoid false positives)
        // 3. This isn't a new video starting
        // 4. IMPORTANTLY: Enough time passed (10s) so we don't trigger on first loop
        //    (Give endscreen/autonav hooks a chance to work first)
        if (ytlp_advanceState != YTLPStateTransitioning &&
            ytlp_advanceState != YTLPStateWaitingForLoad &&
            ytlp_advanceState != YTLPStateEnded && // Don't re-trigger if already marked ended
            timeSinceLastAdvance > 10.0) { // Increased from 5.0 to 10.0 - less aggressive

            #if DEBUG
            NSLog(@"[YTLocalQueue] ⚠️ Loop detected (backup): %.1f -> %.1f (this shouldn't happen often)", ytlp_lastTimeChangePosition, currentTime);
            #endif

            ytlp_endDetected = YES;
            ytlp_setState(YTLPStateEnded, @"loop detected (backup)");

            if (ytlp_shouldAllowQueueAdvance(@"loop interception (backup)")) {
                ytlp_playNextFromQueue();
            }
        }
    }

    // Update last position
    ytlp_lastTimeChangePosition = currentTime;
}

static void ytlp_singleVideoTimeDidChange(id self, SEL _cmd, id singleVideo, YTSingleVideoTime *videoTime) {
    if (origSingleVideoTimeDidChange) origSingleVideoTimeDidChange(self, _cmd, singleVideo, videoTime);
    ytlp_handleVideoTimeChange(self, videoTime);
}

static void ytlp_potentiallyMutatedSingleVideoTimeDidChange(id self, SEL _cmd, id singleVideo, YTSingleVideoTime *videoTime) {
    if (origPotentiallyMutatedSingleVideoTimeDidChange) origPotentiallyMutatedSingleVideoTimeDidChange(self, _cmd, singleVideo, videoTime);
    ytlp_handleVideoTimeChange(self, videoTime);
}

static void ytlp_playerViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (origPlayerViewDidAppear) origPlayerViewDidAppear(self, _cmd, animated);
    ytlp_currentPlayerVC = self;
    
    // Store reference in manager so LocalQueueViewController can access it
    [[YTLPLocalQueueManager shared] setCurrentPlayerViewController:self];
    
    // Start monitoring immediately when player appears
    // ytlp_startEndMonitoring();
    
    // Re-register remote commands to ensure we have control of the lock screen
    ytlp_setupRemoteCommands();
    
    // Update currently playing video for the Local Queue view
    // Try immediately and also after a short delay (video may not be loaded yet)
    void (^updateCurrentlyPlaying)(void) = ^{
        NSString *videoId = nil;
        NSString *title = nil;
        
        // Try currentVideoID first (most reliable)
        if ([self respondsToSelector:@selector(currentVideoID)]) {
            videoId = [self currentVideoID];
        }
        
        // Fallback to extraction
        if (videoId.length == 0) {
            ytlp_extractVideoInfo(self, &videoId, &title);
        }
        
        // Try to get title from activeVideo if we have video ID but no title
        if (videoId.length > 0 && title.length == 0) {
            @try {
                if ([self respondsToSelector:@selector(activeVideo)]) {
                    id activeVideo = [self activeVideo];
                    if (activeVideo && [activeVideo respondsToSelector:@selector(singleVideo)]) {
                        id singleVideo = [activeVideo singleVideo];
                        if (singleVideo && [singleVideo respondsToSelector:@selector(title)]) {
                            id titleObj = [singleVideo title];
                            if ([titleObj isKindOfClass:[NSString class]]) {
                                title = titleObj;
                            } else if ([titleObj respondsToSelector:@selector(text)]) {
                                title = [titleObj text];
                            }
                        }
                    }
                }
            } @catch (NSException *e) {
                // Ignore
            }
        }
        
        // If we couldn't get the title from extraction, try the queue manager
        if (videoId.length > 0 && title.length == 0) {
            title = [[YTLPLocalQueueManager shared] titleForVideoId:videoId];
        }
        
        if (videoId.length > 0) {
            [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:videoId title:title];
        }
    };
    
    // Try immediately
    updateCurrentlyPlaying();
    
    // Also try after a delay (video may load after viewDidAppear)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        updateCurrentlyPlaying();
    });
}

// Thumbnail button code removed - not working in current YouTube version

// YTMenuController hooks - Replace existing "Play next in queue" action
typedef NSMutableArray* (*MenuActionsForRenderersIMP)(id, SEL, NSMutableArray*, UIView*, id, BOOL, id);
static MenuActionsForRenderersIMP origMenuActionsForRenderers = NULL;

static NSMutableArray* ytlp_menuActionsForRenderers(id self, SEL _cmd, NSMutableArray *renderers, UIView *fromView, id entry, BOOL shouldLogItems, id firstResponder) {
    NSMutableArray *actions = origMenuActionsForRenderers ? origMenuActionsForRenderers(self, _cmd, renderers, fromView, entry, shouldLogItems, firstResponder) : [NSMutableArray array];
    
    NSString *menuContextVideoId = nil;
    NSString *menuContextTitle = nil;

    // Try to capture video ID from fromView when menu appears
    if (fromView) {
        NSString *videoId = nil;
        NSString *title = nil;
        
        // Look in fromView hierarchy for video info - focus on collection view cells
        UIView *currentView = fromView;
        for (int level = 0; level < 15 && currentView; level++) {
            // Special handling for collection view cells where video data is likely stored
            if ([currentView isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
                @try {
                    // Try AsyncDisplayKit/YouTube specific properties
                    NSArray *cellProperties = @[@"node", @"cellNode", @"displayNode", @"contentNode", 
                                              @"renderer", @"viewModel", @"model", @"data", 
                                              @"entry", @"content", @"videoId", @"video"];
                    
                    for (NSString *property in cellProperties) {
                        @try {
                            id value = [currentView valueForKey:property];
                            if (value) {
                                // Try to extract video info from this property
                                ytlp_extractVideoInfo(value, &videoId, &title);
                                if (videoId.length > 0) {
                                    ytlp_captureVideoTap(fromView, videoId, title);
                                    menuContextVideoId = videoId;
                                    menuContextTitle = title;
                                    break;
                                }
                                
                                // If it's a node/container, try nested properties
                                if ([property containsString:@"node"] || [property containsString:@"Node"]) {
                                    NSArray *nestedProps = @[@"renderer", @"viewModel", @"model", @"data", @"entry", @"videoId"];
                                    for (NSString *nested in nestedProps) {
                                        @try {
                                            id nestedValue = [value valueForKey:nested];
                                            if (nestedValue) {
                                                ytlp_extractVideoInfo(nestedValue, &videoId, &title);
                                                if (videoId.length > 0) {
                                                    ytlp_captureVideoTap(fromView, videoId, title);
                                                    menuContextVideoId = videoId;
                                                    menuContextTitle = title;
                                                    break;
                                                }
                                            }
                                        } @catch (__unused NSException *e) {}
                                    }
                                    if (videoId.length > 0) break;
                                }
                            }
                        } @catch (__unused NSException *e) {}
                    }
                    
                    if (videoId.length > 0) break;
                } @catch (__unused NSException *e) {}
            } else {
                // For non-cell views, try the original approach but with broader property search
                @try {
                    NSArray *properties = @[@"renderer", @"entry", @"videoData", @"data", @"model", @"viewModel"];
                    for (NSString *property in properties) {
                        @try {
                            id value = [currentView valueForKey:property];
                            if (value) {
                                ytlp_extractVideoInfo(value, &videoId, &title);
                                if (videoId.length > 0) {
                                    ytlp_captureVideoTap(fromView, videoId, title);
                                    menuContextVideoId = videoId;
                                    menuContextTitle = title;
                                    break;
                                }
                            }
                        } @catch (__unused NSException *e) {}
                    }
                    if (videoId.length > 0) break;
                } @catch (__unused NSException *e) {}
            }
            
            currentView = [currentView superview];
        }
    }
    
    @try {
        NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
        
        // Find and replace existing "Play next in queue" action
        NSUInteger queueIndex = NSNotFound;
        for (NSUInteger i = 0; i < actions.count; i++) {
            id act = actions[i];
            NSString *title = nil;
            @try {
                if ([act respondsToSelector:@selector(button)]) {
                    UIButton *btn = [act button];
                    if ([btn isKindOfClass:[UIButton class]]) title = btn.currentTitle;
                }
                if (title.length == 0) title = [act valueForKey:@"_title"];
            } @catch (__unused NSException *e) {}
            
            if (title.length > 0) {
                NSString *t = title.lowercaseString;
                if ([t containsString:@"play next in queue"]) { 
                    queueIndex = i; 
                    break; 
                }
            }
        }

        // Only replace if we found the existing action - don't add new ones
        if (queueIndex != NSNotFound && queueIndex < actions.count) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            BOOL hasRecentTap = (now - ytlp_lastTapTime) < 5.0; // 5 second window
            
            // Prefer captured video ID if available and recent, but avoid current if possible
            NSString *videoId = nil;
            NSString *title = nil;

            NSString *renderersVideoId = ytlp_findVideoIdInRenderers(renderers, currentVideoId);
            
            if (hasRecentTap && ytlp_lastTappedVideoId.length > 0) {
                videoId = ytlp_lastTappedVideoId;
                title = ytlp_lastTappedVideoTitle;
            } else {
                if (entry) {
                    ytlp_extractVideoInfo(entry, &videoId, &title);
                }
            }

            // If we only got the currently playing video, prefer menu context or renderers.
            if (currentVideoId.length > 0 && [videoId isEqualToString:currentVideoId]) {
                if (menuContextVideoId.length > 0 && ![menuContextVideoId isEqualToString:currentVideoId]) {
                    videoId = menuContextVideoId;
                    title = menuContextTitle;
                } else if (renderersVideoId.length > 0 && ![renderersVideoId isEqualToString:currentVideoId]) {
                    videoId = renderersVideoId;
                }
            }

            // Cache menu context for handler-time resolution.
            NSString *cacheCandidate = menuContextVideoId.length > 0 ? menuContextVideoId : renderersVideoId;
            if (cacheCandidate.length > 0) {
                ytlp_lastMenuContextVideoId = [cacheCandidate copy];
                ytlp_lastMenuContextTitle = [menuContextTitle copy];
                ytlp_lastMenuContextTime = [[NSDate date] timeIntervalSince1970];
            }
            
            id action = actions[queueIndex];
            void (^newHandler)(id) = ^(id a){
                
                NSString *currentVideoIdNow = ytlp_getCurrentVideoId();
                // Re-resolve at tap time to avoid stale/current-video captures.
                NSString *resolvedVideoId = ytlp_resolveMenuVideoId(a, renderers, fromView, entry, self, currentVideoIdNow);
                NSString *resolvedTitle = title; // Start with captured title
                
                if (resolvedVideoId.length == 0 || [resolvedVideoId isEqualToString:currentVideoIdNow]) {
                    // Fall back to precomputed value if it's not current, otherwise keep as last resort.
                    if (videoId.length > 0 && ![videoId isEqualToString:currentVideoIdNow]) {
                        resolvedVideoId = videoId;
                    } else {
                        resolvedVideoId = videoId;
                    }
                }
                
                // If we don't have a title, try to extract it from the entry or renderers
                if (resolvedTitle.length == 0 && entry) {
                    NSString *extractedId = nil;
                    NSString *extractedTitle = nil;
                    ytlp_extractVideoInfo(entry, &extractedId, &extractedTitle);
                    if (extractedTitle.length > 0) {
                        resolvedTitle = extractedTitle;
                    }
                }
                
                // Try renderers for title if still not found
                if (resolvedTitle.length == 0 && renderers.count > 0) {
                    for (id renderer in renderers) {
                        NSString *extractedId = nil;
                        NSString *extractedTitle = nil;
                        ytlp_extractVideoInfo(renderer, &extractedId, &extractedTitle);
                        if (extractedTitle.length > 0) {
                            resolvedTitle = extractedTitle;
                            break;
                        }
                    }
                }
                
                // Try menu context title as fallback
                if (resolvedTitle.length == 0 && ytlp_lastMenuContextTitle.length > 0) {
                    resolvedTitle = ytlp_lastMenuContextTitle;
                }
                
                // Try last tapped video title (might have been updated since block capture)
                if (resolvedTitle.length == 0 && ytlp_lastTappedVideoTitle.length > 0) {
                    // Only use if the video ID matches
                    if ([resolvedVideoId isEqualToString:ytlp_lastTappedVideoId]) {
                        resolvedTitle = ytlp_lastTappedVideoTitle;
                    }
                }

                if (resolvedVideoId.length > 0) {
                    // Add to queue immediately
                    [[YTLPLocalQueueManager shared] addVideoId:resolvedVideoId title:resolvedTitle];
                    
                    Class HUD = objc_getClass("GOOHUDManagerInternal");
                    Class HUDMsg = objc_getClass("YTHUDMessage");
                    
                    // If we have a title, show it immediately
                    if (resolvedTitle.length > 0) {
                        NSString *displayName = resolvedTitle;
                        if (displayName.length > 35) displayName = [[displayName substringToIndex:32] stringByAppendingString:@"..."];
                        if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"✅ Added: %@", displayName]]];
                    } else {
                        // Show "Adding..." toast and fetch title in background
                        if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"✅ Added to queue"]];
                        
                        // Fetch title from YouTube API and update the stored item
                        NSString *capturedVideoId = [resolvedVideoId copy];
                        ytlp_fetchTitleForVideoId(capturedVideoId, ^(NSString *fetchedTitle) {
                            if (fetchedTitle.length > 0) {
                                [[YTLPLocalQueueManager shared] updateTitleForVideoId:capturedVideoId title:fetchedTitle];
                            }
                        });
                    }
                } else {
                    Class HUD = objc_getClass("GOOHUDManagerInternal");
                    Class HUDMsg = objc_getClass("YTHUDMessage");
                    if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"❌ Failed to add video"]];
                }
            };

            if ([action respondsToSelector:@selector(setHandler:)]) {
                [action setHandler:newHandler];
            } else {
                [action setValue:[newHandler copy] forKey:@"_handler"];
            }
        }
    } @catch (__unused NSException *e) {}
    return actions;
}

// YTDefaultSheetController hooks - Replace existing actions, don't add new ones
typedef void (*DefaultSheetAddActionIMP)(id, SEL, id);
static DefaultSheetAddActionIMP origDefaultSheetAddAction = NULL;

static void ytlp_defaultSheetAddAction(id self, SEL _cmd, id action) {
    @try {
        NSString *identifier = nil;
        
        @try {
            identifier = [action valueForKey:@"_accessibilityIdentifier"];
            if (identifier.length == 0) identifier = [action valueForKey:@"accessibilityIdentifier"];
        } @catch (__unused NSException *e) {}

        // Avoid recursion on our own injected actions
        if ([identifier isKindOfClass:[NSString class]] && [identifier hasPrefix:@"ytlp_"]) {
            if (origDefaultSheetAddAction) origDefaultSheetAddAction(self, _cmd, action);
            return;
        }
    } @catch (__unused NSException *e) {}

    if (origDefaultSheetAddAction) origDefaultSheetAddAction(self, _cmd, action);
}

// YTAppDelegate hooks
typedef void (*AppDelegateDidBecomeActiveIMP)(id, SEL, UIApplication*);
static AppDelegateDidBecomeActiveIMP origAppDelegateDidBecomeActive = NULL;

static void ytlp_appDelegateDidBecomeActive(id self, SEL _cmd, UIApplication *application) {
    if (origAppDelegateDidBecomeActive) origAppDelegateDidBecomeActive(self, _cmd, application);
    
    // Refresh remote commands when app comes to foreground
    ytlp_setupRemoteCommands();
}

// YTSingleVideoController hooks
typedef void (*SingleVideoPlayerRateIMP)(id, SEL, float);
static SingleVideoPlayerRateIMP origSingleVideoPlayerRate = NULL;

static void ytlp_singleVideoPlayerRateDidChange(id self, SEL _cmd, float rate) {
    if (origSingleVideoPlayerRate) origSingleVideoPlayerRate(self, _cmd, rate);
    
    // When playback starts (rate > 0), update the currently playing video
    if (rate > 0.0f) {
        NSString *videoId = nil;
        NSString *title = nil;
        
        // Try to get video info from YTSingleVideoController
        @try {
            if ([self respondsToSelector:@selector(singleVideo)]) {
                id singleVideo = [self singleVideo];
                if (singleVideo) {
                    if ([singleVideo respondsToSelector:@selector(videoId)]) {
                        videoId = [singleVideo videoID];
                    }
                    if ([singleVideo respondsToSelector:@selector(title)]) {
                        id titleObj = [singleVideo title];
                        if ([titleObj isKindOfClass:[NSString class]]) {
                            title = titleObj;
                        } else if ([titleObj respondsToSelector:@selector(text)]) {
                            title = [titleObj text];
                        }
                    }
                }
            }
            
            // Fallback to videoData
            if (videoId.length == 0 && [self respondsToSelector:@selector(videoData)]) {
                id videoData = [self videoData];
                if (videoData && [videoData respondsToSelector:@selector(videoId)]) {
                    videoId = [videoData videoID];
                }
            }
        } @catch (__unused NSException *e) {}
        
        // If we still don't have a video ID, try from the current player VC
        if (videoId.length == 0 && ytlp_currentPlayerVC) {
            if ([ytlp_currentPlayerVC respondsToSelector:@selector(currentVideoID)]) {
                videoId = [ytlp_currentPlayerVC currentVideoID];
            }
        }
        
        // If we couldn't get the title, try from the queue manager
        if (videoId.length > 0 && title.length == 0) {
            title = [[YTLPLocalQueueManager shared] titleForVideoId:videoId];
        }
        
        if (videoId.length > 0) {
            [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:videoId title:title];
        }
    }
    
    // Since we've disabled YouTube's autoplay, we need to be more proactive about detecting video ends
    if (rate == 0.0f && ytlp_currentPlayerVC) {
        // No longer needed
    }
}

// YouTube Autoplay hooks - Override what plays next
typedef id (*AutoplayGetNextVideoIMP)(id, SEL);
static AutoplayGetNextVideoIMP origAutoplayGetNextVideo = NULL;

static id ytlp_autoplayGetNextVideo(id self, SEL _cmd) {
    // If auto-advance is enabled and we have items in queue, override
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        // Use peek to get ID, then construct command.
        NSArray *items = [[YTLPLocalQueueManager shared] allItems];
        if (items.count > 0) {
            NSDictionary *nextItem = items[0];
            NSString *nextId = nextItem[@"videoId"];
            
            if (nextId.length > 0) {
                // Create a video object for our queue item
                Class YTICommandClass = objc_getClass("YTICommand");
                if (YTICommandClass && [YTICommandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) {
                    id cmd = [YTICommandClass watchNavigationEndpointWithVideoID:nextId];
                    // IMPORTANT: Return this command to force YouTube to play OUR video next
                    return cmd;
                }
            }
        }
    }
    // Fall back to original autoplay
    return origAutoplayGetNextVideo ? origAutoplayGetNextVideo(self, _cmd) : nil;
}

// These old generic hooks are now replaced by specific YTAutoplayAutonavController hooks

// Video completion hook as main fallback approach (safer than hooking random methods)
typedef void (*VideoDidCompleteIMP)(id, SEL);
static VideoDidCompleteIMP origVideoDidComplete = NULL;

static void ytlp_videoDidComplete(id self, SEL _cmd) {
    if (origVideoDidComplete) origVideoDidComplete(self, _cmd);
    
    // Add a short delay then check if we should play from queue
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
            if (ytlp_shouldAllowQueueAdvance(@"video completed")) {
                ytlp_playNextFromQueue();
            }
        }
    });
}

// Hook for when video actually ends (not just pauses)
typedef void (*VideoDidFinishIMP)(id, SEL);
static VideoDidFinishIMP origVideoDidFinish = NULL;

static void ytlp_videoDidFinish(id self, SEL _cmd) {
    // Try to play next from queue if enabled, with safety check
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        // PREEMPTIVE: Play next immediately and SKIP original
        if (ytlp_shouldAllowQueueAdvance(@"video finished (preemptive)")) {
             ytlp_playNextFromQueue();
             return;
        }
    }
    
    if (origVideoDidFinish) origVideoDidFinish(self, _cmd);
}

// Hook MPRemoteCommandCenter to handle next track command
// typedef void (*AddTargetActionIMP)(id, SEL, id, SEL);
// static AddTargetActionIMP origAddTargetAction = NULL;

// typedef id (*AddTargetWithHandlerIMP)(id, SEL, id);
// static AddTargetWithHandlerIMP origAddTargetWithHandler = NULL;

// Unused hooks removed
/*
static void ytlp_handleNextTrack(id event) {
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
         ytlp_playNextFromQueue();
    }
}

static void ytlp_addTargetAction(id self, SEL _cmd, id target, SEL action) {
    if (origAddTargetAction) origAddTargetAction(self, _cmd, target, action);
}

static id ytlp_addTargetWithHandler(id self, SEL _cmd, id (^handler)(id)) {
    return origAddTargetWithHandler ? origAddTargetWithHandler(self, _cmd, handler) : nil;
}
*/

// Hook MPRemoteCommandCenter sharedCommandCenter to register our handler
static id ytlp_remoteCommandTarget = nil;

static void ytlp_setupRemoteCommands(void) {
    // Only proceed if main thread (safety)
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ytlp_setupRemoteCommands();
        });
        return;
    }

    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    MPRemoteCommand *nextCmd = [center nextTrackCommand];
    
    [nextCmd setEnabled:YES];
    
    // Remove previous target if we have one to avoid duplicates
    if (ytlp_remoteCommandTarget) {
        [nextCmd removeTarget:ytlp_remoteCommandTarget];
        ytlp_remoteCommandTarget = nil;
    }
    
    // Add new target
    ytlp_remoteCommandTarget = [nextCmd addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
            #if DEBUG
            NSLog(@"[YTLocalQueue] Remote next track command (lock screen/control center)");
            #endif

            // For background playback, use direct player transition to avoid waking screen
            if (ytlp_isAppInBackground()) {
                if (ytlp_playNextInBackground()) {
                    return MPRemoteCommandHandlerStatusSuccess;
                }
                // If background method failed, fall through to regular method
            }

            // Fallback: use regular playNextFromQueue (may wake screen but always works)
            ytlp_userInitiated = YES;
            ytlp_endDetected = YES;
            ytlp_playNextFromQueue();
            return MPRemoteCommandHandlerStatusSuccess;
        }
        return MPRemoteCommandHandlerStatusCommandFailed;
    }];
}

// ============================================================================
// YOUTUBE AUTONAV/AUTOPLAY INTERCEPTION (Primary Layer)
// ============================================================================

// CRITICAL STRATEGY CHANGE:
// Instead of forcing loop mode (which causes the loop problem), we intercept
// YouTube's autoplay/autonav system to inject our own next video.

typedef NSInteger (*AutonavLoopModeIMP)(id, SEL);
static AutonavLoopModeIMP origAutonavLoopMode = NULL;

typedef void (*AutonavPlayNextIMP)(id, SEL);
static AutonavPlayNextIMP origAutonavPlayNext = NULL;

typedef void (*AutonavPlayAutonavIMP)(id, SEL);
static AutonavPlayAutonavIMP origAutonavPlayAutonav = NULL;

typedef void (*AutonavPlayAutoplayIMP)(id, SEL);
static AutonavPlayAutoplayIMP origAutonavPlayAutoplay = NULL;

typedef id (*AutonavEndpointIMP)(id, SEL);
static AutonavEndpointIMP origAutonavEndpoint = NULL;

typedef id (*AutonavInitIMP)(id, SEL, id);
static AutonavInitIMP origAutonavInit = NULL;

// Note: AutoplayGetNextVideoIMP already defined earlier in the file

// DON'T force loop mode - let YouTube handle natural playback
static NSInteger ytlp_autonavLoopMode(id self, SEL _cmd) {
    // Return original loop mode - don't interfere
    return origAutonavLoopMode ? origAutonavLoopMode(self, _cmd) : 0;
}

// Helper to consume queue item and let YouTube's autonav handle the actual playback
// This avoids waking the screen by using YouTube's native background transition
static BOOL ytlp_consumeQueueForAutonav(void) {
    if (!YTLP_AutoAdvanceEnabled() || [[YTLPLocalQueueManager shared] isEmpty]) {
        return NO;
    }

    // Pop the next item from queue - autonavEndpoint will provide the video ID
    NSDictionary *nextItem = [[YTLPLocalQueueManager shared] popNextItem];
    NSString *nextId = nextItem[@"videoId"];
    NSString *nextTitle = nextItem[@"title"];

    if (nextId.length == 0) {
        return NO;
    }

    // Update tracking
    ytlp_lastQueueAdvanceTime = [[NSDate date] timeIntervalSince1970];
    ytlp_lastPlayedVideoId = nextId;
    ytlp_currentPlayingVideoId = nextId;
    [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:nextId title:nextTitle];

    #if DEBUG
    NSLog(@"[YTLocalQueue] Consumed queue item for autonav: %@", nextId);
    #endif

    return YES;
}

// Intercept playNext to inject queue video
static void ytlp_autonavPlayNext(id self, SEL _cmd) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] YTAutoplayAutonavController.playNext called");
    #endif

    // Consume queue item - autonavEndpoint will provide the video
    ytlp_consumeQueueForAutonav();

    // Always call original - let YouTube handle the actual transition
    // This keeps the screen off during background playback
    if (origAutonavPlayNext) origAutonavPlayNext(self, _cmd);
}

// Intercept playAutonav (auto-advance to next video)
static void ytlp_autonavPlayAutonav(id self, SEL _cmd) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] YTAutoplayAutonavController.playAutonav called");
    #endif

    // Consume queue item - autonavEndpoint will provide the video
    ytlp_consumeQueueForAutonav();

    // Always call original - let YouTube handle the actual transition
    if (origAutonavPlayAutonav) origAutonavPlayAutonav(self, _cmd);
}

// Intercept playAutoplay
static void ytlp_autonavPlayAutoplay(id self, SEL _cmd) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] YTAutoplayAutonavController.playAutoplay called");
    #endif

    // Consume queue item - autonavEndpoint will provide the video
    ytlp_consumeQueueForAutonav();

    // Always call original - let YouTube handle the actual transition
    if (origAutonavPlayAutoplay) origAutonavPlayAutoplay(self, _cmd);
}

// Helper to create queue endpoint
static id ytlp_createQueueEndpoint(NSString *videoId) {
    if (videoId.length == 0) return nil;

    Class YTICommandClass = objc_getClass("YTICommand");
    if (YTICommandClass && [YTICommandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) {
        return [YTICommandClass watchNavigationEndpointWithVideoID:videoId];
    }
    return nil;
}

// Get the video ID to use for endpoint hooks
static NSString *ytlp_getNextQueueVideoId(void) {
    if (!YTLP_AutoAdvanceEnabled()) return nil;

    // First priority: consumed video ID
    if (ytlp_currentPlayingVideoId.length > 0) {
        return ytlp_currentPlayingVideoId;
    }

    // Second priority: peek at queue
    if (![[YTLPLocalQueueManager shared] isEmpty]) {
        NSDictionary *nextItem = [[YTLPLocalQueueManager shared] peekNextItem];
        return nextItem[@"videoId"];
    }

    return nil;
}

// Intercept autonavEndpoint to return our queue endpoint
static id ytlp_autonavEndpoint(id self, SEL _cmd) {
    NSString *videoId = ytlp_getNextQueueVideoId();
    if (videoId) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] autonavEndpoint returning: %@", videoId);
        #endif
        id endpoint = ytlp_createQueueEndpoint(videoId);
        if (endpoint) return endpoint;
    }
    return origAutonavEndpoint ? origAutonavEndpoint(self, _cmd) : nil;
}

// Intercept nextEndpointForAutonav - this is what YouTube uses to get the next video
typedef id (*NextEndpointForAutonavIMP)(id, SEL);
static NextEndpointForAutonavIMP origNextEndpointForAutonav = NULL;

static id ytlp_nextEndpointForAutonav(id self, SEL _cmd) {
    NSString *videoId = ytlp_getNextQueueVideoId();
    if (videoId) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] nextEndpointForAutonav returning: %@", videoId);
        #endif
        id endpoint = ytlp_createQueueEndpoint(videoId);
        if (endpoint) return endpoint;
    }
    return origNextEndpointForAutonav ? origNextEndpointForAutonav(self, _cmd) : nil;
}

// Intercept autoplayEndpoint
typedef id (*AutoplayEndpointIMP)(id, SEL);
static AutoplayEndpointIMP origAutoplayEndpoint = NULL;

static id ytlp_autoplayEndpoint(id self, SEL _cmd) {
    NSString *videoId = ytlp_getNextQueueVideoId();
    if (videoId) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] autoplayEndpoint returning: %@", videoId);
        #endif
        id endpoint = ytlp_createQueueEndpoint(videoId);
        if (endpoint) return endpoint;
    }
    return origAutoplayEndpoint ? origAutoplayEndpoint(self, _cmd) : nil;
}

// Intercept nextEndpointForAutoplay
typedef id (*NextEndpointForAutoplayIMP)(id, SEL);
static NextEndpointForAutoplayIMP origNextEndpointForAutoplay = NULL;

static id ytlp_nextEndpointForAutoplay(id self, SEL _cmd) {
    NSString *videoId = ytlp_getNextQueueVideoId();
    if (videoId) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] nextEndpointForAutoplay returning: %@", videoId);
        #endif
        id endpoint = ytlp_createQueueEndpoint(videoId);
        if (endpoint) return endpoint;
    }
    return origNextEndpointForAutoplay ? origNextEndpointForAutoplay(self, _cmd) : nil;
}

// Store reference to autonav controller when initialized
static id ytlp_autonavInit(id self, SEL _cmd, id parentResponder) {
    id instance = origAutonavInit ? origAutonavInit(self, _cmd, parentResponder) : nil;
    if (instance) {
        ytlp_currentAutonavController = instance;
        #if DEBUG
        NSLog(@"[YTLocalQueue] YTAutoplayAutonavController initialized");
        #endif
    }
    return instance;
}

// ============================================================================
// ENDSCREEN CONTROLLER HOOKS (Show Countdown with QUEUE Video!)
// ============================================================================

// UPDATED STRATEGY: Let countdown show, but display QUEUE video (not YouTube's choice)
// The autonavEndpoint hook provides our queue video, so countdown shows correct video!

typedef void (*EndscreenVideoDidFinishIMP)(id, SEL);
static EndscreenVideoDidFinishIMP origEndscreenVideoDidFinish = NULL;

// Track video end for state management
static void ytlp_endscreenVideoDidFinish(id self, SEL _cmd) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] YTAutonavEndscreenController.videoDidFinish called");
    #endif

    // Mark that video ended
    ytlp_endDetected = YES;
    ytlp_setState(YTLPStateEnded, @"endscreen videoDidFinish");

    // Always call original - let YouTube show endscreen/countdown
    // The autonavEndpoint hook will provide our queue video for the countdown!
    if (origEndscreenVideoDidFinish) origEndscreenVideoDidFinish(self, _cmd);
}

static void ytlp_updateAutoplayState(void) {
    // This function can now be simpler - we don't need to force loop mode
    #if DEBUG
    NSLog(@"[YTLocalQueue] Update autoplay state (queue has %ld items)", (long)[[YTLPLocalQueueManager shared] allItems].count);
    #endif
    // Nothing to do - we intercept at the navigation point instead
}

// Removed legacy timer check
static void ytlp_startEndMonitoring(void) {} // Kept as stub called by ViewDidLoad
// static void ytlp_checkVideoEnd(NSTimer *timer) {}
// static void ytlp_stopEndMonitoring(void) {}

// YTMainAppVideoPlayerOverlayViewController hooks
typedef void (*OverlayViewDidLoadIMP)(id, SEL);
static OverlayViewDidLoadIMP origOverlayViewDidLoad = NULL;

// YTMainAppControlsOverlayView hooks for proper button integration
typedef NSMutableArray *(*TopControlsIMP)(id, SEL);
static TopControlsIMP origTopControls = NULL;
static TopControlsIMP origTopButtonControls = NULL;

typedef void (*SetTopOverlayVisibleIMP)(id, SEL, BOOL, BOOL);
static SetTopOverlayVisibleIMP origSetTopOverlayVisible = NULL;


// Associated object key for storing our buttons on the controls view
static const char *kYTLPOverlayButtonsKey = "ytlp_overlayButtons";

// Store our buttons in associated object dictionary
static NSMutableDictionary *ytlp_getOverlayButtons(id controls) {
    return objc_getAssociatedObject(controls, kYTLPOverlayButtonsKey);
}

static void ytlp_setOverlayButtons(id controls, NSMutableDictionary *buttons) {
    objc_setAssociatedObject(controls, kYTLPOverlayButtonsKey, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Create overlay buttons for a controls view
static void ytlp_createOverlayButtons(id controls, id target) {
    if (!controls || ytlp_getOverlayButtons(controls)) return;
    
    @try {
        Class ControlsClass = objc_getClass("YTMainAppControlsOverlayView");
        CGFloat padding = 0;
        if (ControlsClass && [ControlsClass respondsToSelector:@selector(topButtonAdditionalPadding)]) {
            padding = [ControlsClass topButtonAdditionalPadding];
        }
        
        SEL buttonSel = @selector(buttonWithImage:accessibilityLabel:verticalContentPadding:);
        if (![controls respondsToSelector:buttonSel]) return;
        
        NSMutableDictionary *overlayButtons = [NSMutableDictionary dictionary];
        
        // Create "Show Queue" button (if enabled)
        if (YTLP_ShowQueueButton()) {
            UIImage *queueImg = YTLPIconQueueList();
            id queueBtn = [controls buttonWithImage:queueImg accessibilityLabel:@"Local queue" verticalContentPadding:padding];
            [(UIView *)queueBtn setHidden:NO];
            [(UIView *)queueBtn setAlpha:0]; // Start invisible, will be shown by setTopOverlayVisible
            [queueBtn addTarget:target action:@selector(ytlp_showQueueTapped:) forControlEvents:UIControlEventTouchUpInside];
            overlayButtons[@"showQueue"] = queueBtn;
            
            // Add to container
            @try {
                id accessibilityContainer = [controls valueForKey:@"_topControlsAccessibilityContainerView"];
                if (accessibilityContainer) {
                    [accessibilityContainer addSubview:queueBtn];
                } else {
                    [controls addSubview:queueBtn];
                }
            } @catch (__unused NSException *e) {
                [controls addSubview:queueBtn];
            }
        }
        
        // Create "Next from Queue" button (if enabled)
        if (YTLP_ShowPlayNextButton()) {
            UIImage *nextImg = YTLPIconNext();
            id nextBtn = [controls buttonWithImage:nextImg accessibilityLabel:@"Next from queue" verticalContentPadding:padding];
            [(UIView *)nextBtn setHidden:NO];
            [(UIView *)nextBtn setAlpha:0]; // Start invisible, will be shown by setTopOverlayVisible
            [nextBtn addTarget:target action:@selector(ytlp_nextFromQueueTapped:) forControlEvents:UIControlEventTouchUpInside];
            overlayButtons[@"nextFromQueue"] = nextBtn;
            
            // Add to container
            @try {
                id accessibilityContainer = [controls valueForKey:@"_topControlsAccessibilityContainerView"];
                if (accessibilityContainer) {
                    [accessibilityContainer addSubview:nextBtn];
                } else {
                    [controls addSubview:nextBtn];
                }
            } @catch (__unused NSException *e) {
                [controls addSubview:nextBtn];
            }
        }
        
        ytlp_setOverlayButtons(controls, overlayButtons);
    } @catch (__unused NSException *e) {}
}

// Hook topControls/topButtonControls to insert our buttons into the controls array
static NSMutableArray *ytlp_topControls(id self, SEL _cmd) {
    NSMutableArray *controls = origTopControls ? origTopControls(self, _cmd) : [NSMutableArray array];
    
    NSDictionary *overlayButtons = ytlp_getOverlayButtons(self);
    if (overlayButtons) {
        id nextBtn = overlayButtons[@"nextFromQueue"];
        id queueBtn = overlayButtons[@"showQueue"];
        // Insert in order: Next, Queue (so Next appears first/leftmost)
        // Only insert if the button exists (which means the setting was enabled when created)
        if (queueBtn && YTLP_ShowQueueButton()) [controls insertObject:queueBtn atIndex:0];
        if (nextBtn && YTLP_ShowPlayNextButton()) [controls insertObject:nextBtn atIndex:0];
    }
    
    return controls;
}

static NSMutableArray *ytlp_topButtonControls(id self, SEL _cmd) {
    NSMutableArray *controls = origTopButtonControls ? origTopButtonControls(self, _cmd) : [NSMutableArray array];
    
    NSDictionary *overlayButtons = ytlp_getOverlayButtons(self);
    if (overlayButtons) {
        id nextBtn = overlayButtons[@"nextFromQueue"];
        id queueBtn = overlayButtons[@"showQueue"];
        // Insert in order: Next, Queue (so Next appears first/leftmost)
        // Only insert if the button exists (which means the setting was enabled when created)
        if (queueBtn && YTLP_ShowQueueButton()) [controls insertObject:queueBtn atIndex:0];
        if (nextBtn && YTLP_ShowPlayNextButton()) [controls insertObject:nextBtn atIndex:0];
    }
    
    return controls;
}

// Hook setTopOverlayVisible to control button visibility (alpha)
static void ytlp_setTopOverlayVisible(id self, SEL _cmd, BOOL visible, BOOL canceledState) {
    if (origSetTopOverlayVisible) origSetTopOverlayVisible(self, _cmd, visible, canceledState);
    
    CGFloat alpha = (canceledState || !visible) ? 0.0 : 1.0;
    
    NSDictionary *overlayButtons = ytlp_getOverlayButtons(self);
    if (overlayButtons) {
        for (UIView *button in [overlayButtons allValues]) {
            button.alpha = alpha;
        }
    }
}

static void ytlp_overlayViewDidLoad(id self, SEL _cmd) {
    if (origOverlayViewDidLoad) origOverlayViewDidLoad(self, _cmd);
    
    id overlayView = [self videoPlayerOverlayView];
    id controls = nil;
    
    @try {
        controls = [overlayView valueForKey:@"_controlsOverlayView"];
    } @catch (__unused NSException *e) {
        controls = [overlayView controlsOverlayView];
    }
    
    if (!controls) return;

    // Create our buttons now that we have the overlay view controller as target
    ytlp_createOverlayButtons(controls, self);
    
    // Trigger a layout update
    @try {
        [controls setNeedsLayout];
    } @catch (__unused NSException *e) {}
    
    // Start monitoring for video end immediately when overlay loads
    ytlp_startEndMonitoring();
}

static void ytlp_addToQueueTapped(id self, SEL _cmd, id sender) {
    id playerVC = [self valueForKey:@"_playerViewController"];
    NSString *videoId = nil;
    NSString *title = nil;
    ytlp_extractVideoInfo(playerVC, &videoId, &title);
    
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    if (videoId.length > 0) {
        [[YTLPLocalQueueManager shared] addVideoId:videoId title:title];
        
        if (title.length > 0) {
            NSString *displayName = title;
            if (displayName.length > 35) displayName = [[displayName substringToIndex:32] stringByAppendingString:@"..."];
            if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"✅ Added: %@", displayName]]];
        } else {
            // Show simple toast and fetch title in background
            if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"✅ Added to queue"]];
            
            NSString *capturedVideoId = [videoId copy];
            ytlp_fetchTitleForVideoId(capturedVideoId, ^(NSString *fetchedTitle) {
                if (fetchedTitle.length > 0) {
                    [[YTLPLocalQueueManager shared] updateTitleForVideoId:capturedVideoId title:fetchedTitle];
                }
            });
        }
    } else {
        if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"❌ Could not add video"]];
    }
}

static void ytlp_showQueueTapped(id self, SEL _cmd, id sender) {
    Class UIUtils = objc_getClass("YTUIUtils");
    UIViewController *top = UIUtils ? [UIUtils topViewControllerForPresenting] : nil;
    if (!top) return;
    YTLPLocalQueueViewController *vc = [[YTLPLocalQueueViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
}

static void ytlp_nextFromQueueTapped(id self, SEL _cmd, id sender) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] Next button tapped");
    #endif

    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");

    // Check if queue is empty
    if ([[YTLPLocalQueueManager shared] isEmpty]) {
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Queue is empty"]];
        }
        return;
    }

    // Set user-initiated flag for immediate response
    ytlp_userInitiated = YES;
    ytlp_endDetected = YES; // Treat as if video ended

    // Play next from queue
    ytlp_playNextFromQueue();
}

// ============================================================================
// NATIVE NEXT BUTTON HOOK (YTMainAppVideoPlayerOverlayViewController)
// ============================================================================

typedef void (*OverlayDidPressNextIMP)(id, SEL, id);
static OverlayDidPressNextIMP origOverlayDidPressNext = NULL;

static void ytlp_overlayDidPressNext(id self, SEL _cmd, id sender) {
    #if DEBUG
    NSLog(@"[YTLocalQueue] Native next button pressed (didPressNext:)");
    #endif

    // If queue has items and auto-advance is enabled, play from queue
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        #if DEBUG
        NSLog(@"[YTLocalQueue] Intercepting native next - playing from queue");
        #endif
        ytlp_userInitiated = YES;
        ytlp_endDetected = YES;
        ytlp_playNextFromQueue();
        return; // Don't call original
    }

    // Otherwise, call original
    if (origOverlayDidPressNext) {
        origOverlayDidPressNext(self, _cmd, sender);
    }
}

// Installation function
__attribute__((constructor)) static void YTLP_InstallTweakHooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attemptsRemaining = 20; // ~10s max with 0.5s intervals
        __block void (^ __weak weakTryInstall)(void);
        void (^tryInstall)(void);
        weakTryInstall = tryInstall = ^{
            BOOL allInstalled = YES;

            // Hook YTPlayerViewController
            Class PlayerVC = objc_getClass("YTPlayerViewController");
            if (PlayerVC) {
                Method m = class_getInstanceMethod(PlayerVC, @selector(viewDidAppear:));
                if (m && !origPlayerViewDidAppear) {
                    origPlayerViewDidAppear = (PlayerViewDidAppearIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_playerViewDidAppear);
                }
                
                // Hook seekToTime: to detect loop seeks (when YouTube seeks to 0)
                Method seekMethod = class_getInstanceMethod(PlayerVC, @selector(seekToTime:));
                if (seekMethod && !origPlayerSeekToTime) {
                    origPlayerSeekToTime = (PlayerSeekToTimeIMP)method_getImplementation(seekMethod);
                    method_setImplementation(seekMethod, (IMP)ytlp_playerSeekToTime);
                }
                
                // Hook singleVideo:currentVideoTimeDidChange: for reliable loop detection (like iSponsorBlock)
                Method timeChangeMethod = class_getInstanceMethod(PlayerVC, @selector(singleVideo:currentVideoTimeDidChange:));
                if (timeChangeMethod && !origSingleVideoTimeDidChange) {
                    origSingleVideoTimeDidChange = (SingleVideoTimeDidChangeIMP)method_getImplementation(timeChangeMethod);
                    method_setImplementation(timeChangeMethod, (IMP)ytlp_singleVideoTimeDidChange);
                }
                
                // Also hook potentiallyMutatedSingleVideo:currentVideoTimeDidChange: (alternate method)
                Method mutatedTimeChangeMethod = class_getInstanceMethod(PlayerVC, @selector(potentiallyMutatedSingleVideo:currentVideoTimeDidChange:));
                if (mutatedTimeChangeMethod && !origPotentiallyMutatedSingleVideoTimeDidChange) {
                    origPotentiallyMutatedSingleVideoTimeDidChange = (SingleVideoTimeDidChangeIMP)method_getImplementation(mutatedTimeChangeMethod);
                    method_setImplementation(mutatedTimeChangeMethod, (IMP)ytlp_potentiallyMutatedSingleVideoTimeDidChange);
                }
                
                // Hook scrubToTime: (older method but may still be used in some versions)
                Method scrubMethod = class_getInstanceMethod(PlayerVC, @selector(scrubToTime:));
                if (scrubMethod && !origPlayerScrubToTime) {
                    origPlayerScrubToTime = (PlayerScrubToTimeIMP)method_getImplementation(scrubMethod);
                    method_setImplementation(scrubMethod, (IMP)ytlp_playerScrubToTime);
                }

                // Hook seekToTime:seekSource: (used for double-tap seek)
                Method seekSourceMethod = class_getInstanceMethod(PlayerVC, @selector(seekToTime:seekSource:));
                if (seekSourceMethod && !origPlayerSeekToTimeSource) {
                    origPlayerSeekToTimeSource = (PlayerSeekToTimeSourceIMP)method_getImplementation(seekSourceMethod);
                    method_setImplementation(seekSourceMethod, (IMP)ytlp_playerSeekToTimeSource);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked seekToTime:seekSource:");
                    #endif
                }

                // Hook seekToTime:toleranceBefore:toleranceAfter:seekSource: (most detailed variant)
                Method seekToleranceMethod = class_getInstanceMethod(PlayerVC, @selector(seekToTime:toleranceBefore:toleranceAfter:seekSource:));
                if (seekToleranceMethod && !origPlayerSeekToTimeToleranceSource) {
                    origPlayerSeekToTimeToleranceSource = (PlayerSeekToTimeToleranceSourceIMP)method_getImplementation(seekToleranceMethod);
                    method_setImplementation(seekToleranceMethod, (IMP)ytlp_playerSeekToTimeToleranceSource);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked seekToTime:toleranceBefore:toleranceAfter:seekSource:");
                    #endif
                }

                if (!origPlayerViewDidAppear) allInstalled = NO;
            } else {
                allInstalled = NO;
            }

            // Hook YTMenuController - Replace existing "Play next in queue" action
            Class MenuController = objc_getClass("YTMenuController");
            if (MenuController) {
                Method m = class_getInstanceMethod(MenuController, @selector(actionsForRenderers:fromView:entry:shouldLogItems:firstResponder:));
                if (m && !origMenuActionsForRenderers) {
                    origMenuActionsForRenderers = (MenuActionsForRenderersIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_menuActionsForRenderers);
                }
            }

            // Hook YTDefaultSheetController - Replace existing actions
            Class DefaultSheetController = objc_getClass("YTDefaultSheetController");
            if (DefaultSheetController) {
                Method m = class_getInstanceMethod(DefaultSheetController, @selector(addAction:));
                if (m && !origDefaultSheetAddAction) {
                    origDefaultSheetAddAction = (DefaultSheetAddActionIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_defaultSheetAddAction);
                }
            }

            // Hook YTAppDelegate
            Class AppDelegate = objc_getClass("YTAppDelegate");
            if (AppDelegate) {
                Method m = class_getInstanceMethod(AppDelegate, @selector(applicationDidBecomeActive:));
                if (m && !origAppDelegateDidBecomeActive) {
                    origAppDelegateDidBecomeActive = (AppDelegateDidBecomeActiveIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_appDelegateDidBecomeActive);
                }
            }

            // Hook UIButton to capture video taps
            Class UIButtonClass = objc_getClass("UIButton");
            if (UIButtonClass) {
                Method m = class_getInstanceMethod(UIButtonClass, @selector(sendActionsForControlEvents:));
                if (m && !origButtonSendActions) {
                    origButtonSendActions = (UIButtonSendActionsIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_buttonSendActions);
                }
            }

            // Hook AsyncDisplayKit collection view cell selection to capture list interactions
            Class ASCollectionViewCellClass = NSClassFromString(@"_ASCollectionViewCell");
            if (ASCollectionViewCellClass) {
                Method m = class_getInstanceMethod(ASCollectionViewCellClass, @selector(setSelected:));
                if (m && !origCollectionViewCellSetSelected) {
                    origCollectionViewCellSetSelected = (CollectionViewCellSetSelectedIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_collectionViewCellSetSelected);
                }
            }


            // Hook YTSingleVideoController
            Class SingleVideoController = objc_getClass("YTSingleVideoController");
            if (SingleVideoController) {
                Method m = class_getInstanceMethod(SingleVideoController, @selector(playerRateDidChange:));
                if (m && !origSingleVideoPlayerRate) {
                    origSingleVideoPlayerRate = (SingleVideoPlayerRateIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_singleVideoPlayerRateDidChange);
                }
            }

            // Removed deprecated hooks for WatchEndpoint and ResponderEvent as they were too aggressive


            // Setup MPRemoteCommandCenter hook
            // Since we can't easily swizzle the singleton's commands directly safely without potential side effects,
            // we'll try to just add our target to the shared center's commands periodically or when app becomes active.
            // But doing it once here is a good start.
            ytlp_setupRemoteCommands();

            // Hook YTFullscreenEngagementOverlayController (Related Videos Grid)
            Class FullscreenEngagementClass = objc_getClass("YTFullscreenEngagementOverlayController");
            if (FullscreenEngagementClass) {
                Method m = class_getInstanceMethod(FullscreenEngagementClass, @selector(setRelatedVideosVisible:));
                const char *typeEncoding = method_getTypeEncoding(m);
                if (m) {
                    class_addMethod(FullscreenEngagementClass, @selector(ytlp_setRelatedVideosVisible:), method_getImplementation(m), typeEncoding);
                    method_setImplementation(m, imp_implementationWithBlock(^(id self, BOOL visible) {
                        // If queue acts, FORCE HIDDEN
                        if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
                            visible = NO;
                        }
                        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(ytlp_setRelatedVideosVisible:), visible);
                    }));
                }
            }

            // Hook YTCreatorEndscreenView (End Cards)
            Class CreatorEndscreenClass = objc_getClass("YTCreatorEndscreenView");
            if (CreatorEndscreenClass) {
                 Method m = class_getInstanceMethod(CreatorEndscreenClass, @selector(setHidden:));
                 const char *typeEncoding = method_getTypeEncoding(m);
                 if (m) {
                     class_addMethod(CreatorEndscreenClass, @selector(ytlp_setHidden:), method_getImplementation(m), typeEncoding);
                     method_setImplementation(m, imp_implementationWithBlock(^(id self, BOOL hidden) {
                         // If queue acts, FORCE HIDDEN (YES)
                         if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
                             hidden = YES;
                         }
                         ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(ytlp_setHidden:), hidden);
                     }));
                 }
            }

            // ================================================================
            // Hook YouTube Autoplay/Autonav Controller (Primary Interception)
            // ================================================================
            // NEW STRATEGY: Intercept navigation methods instead of forcing loop mode
            Class YTAutoplayAutonavControllerClass = objc_getClass("YTAutoplayAutonavController");
            if (YTAutoplayAutonavControllerClass) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] Installing YTAutoplayAutonavController hooks");
                #endif

                // Hook init to track controller instance
                Method initMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(initWithParentResponder:));
                if (initMethod && !origAutonavInit) {
                    origAutonavInit = (AutonavInitIMP)method_getImplementation(initMethod);
                    method_setImplementation(initMethod, (IMP)ytlp_autonavInit);
                }

                // Hook loopMode getter (but don't force it - just observe)
                Method loopModeMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(loopMode));
                if (loopModeMethod && !origAutonavLoopMode) {
                    origAutonavLoopMode = (AutonavLoopModeIMP)method_getImplementation(loopModeMethod);
                    method_setImplementation(loopModeMethod, (IMP)ytlp_autonavLoopMode);
                }

                // Hook playNext - PRIMARY HOOK for next button
                Method playNextMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(playNext));
                if (playNextMethod && !origAutonavPlayNext) {
                    origAutonavPlayNext = (AutonavPlayNextIMP)method_getImplementation(playNextMethod);
                    method_setImplementation(playNextMethod, (IMP)ytlp_autonavPlayNext);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked playNext");
                    #endif
                }

                // Hook playAutonav - PRIMARY HOOK for auto-advance at video end
                Method playAutonavMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(playAutonav));
                if (playAutonavMethod && !origAutonavPlayAutonav) {
                    origAutonavPlayAutonav = (AutonavPlayAutonavIMP)method_getImplementation(playAutonavMethod);
                    method_setImplementation(playAutonavMethod, (IMP)ytlp_autonavPlayAutonav);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked playAutonav");
                    #endif
                }

                // Hook playAutoplay - SECONDARY HOOK for autoplay
                Method playAutoplayMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(playAutoplay));
                if (playAutoplayMethod && !origAutonavPlayAutoplay) {
                    origAutonavPlayAutoplay = (AutonavPlayAutoplayIMP)method_getImplementation(playAutoplayMethod);
                    method_setImplementation(playAutoplayMethod, (IMP)ytlp_autonavPlayAutoplay);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked playAutoplay");
                    #endif
                }

                // Hook autonavEndpoint - Returns the next video endpoint
                Method autonavEndpointMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(autonavEndpoint));
                if (autonavEndpointMethod && !origAutonavEndpoint) {
                    origAutonavEndpoint = (AutonavEndpointIMP)method_getImplementation(autonavEndpointMethod);
                    method_setImplementation(autonavEndpointMethod, (IMP)ytlp_autonavEndpoint);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked autonavEndpoint");
                    #endif
                }

                // Hook nextEndpointForAutonav - YouTube uses this to get the actual next video
                Method nextEndpointForAutonavMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(nextEndpointForAutonav));
                if (nextEndpointForAutonavMethod && !origNextEndpointForAutonav) {
                    origNextEndpointForAutonav = (NextEndpointForAutonavIMP)method_getImplementation(nextEndpointForAutonavMethod);
                    method_setImplementation(nextEndpointForAutonavMethod, (IMP)ytlp_nextEndpointForAutonav);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked nextEndpointForAutonav");
                    #endif
                }

                // Hook autoplayEndpoint
                Method autoplayEndpointMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(autoplayEndpoint));
                if (autoplayEndpointMethod && !origAutoplayEndpoint) {
                    origAutoplayEndpoint = (AutoplayEndpointIMP)method_getImplementation(autoplayEndpointMethod);
                    method_setImplementation(autoplayEndpointMethod, (IMP)ytlp_autoplayEndpoint);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked autoplayEndpoint");
                    #endif
                }

                // Hook nextEndpointForAutoplay
                Method nextEndpointForAutoplayMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(nextEndpointForAutoplay));
                if (nextEndpointForAutoplayMethod && !origNextEndpointForAutoplay) {
                    origNextEndpointForAutoplay = (NextEndpointForAutoplayIMP)method_getImplementation(nextEndpointForAutoplayMethod);
                    method_setImplementation(nextEndpointForAutoplayMethod, (IMP)ytlp_nextEndpointForAutoplay);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked nextEndpointForAutoplay");
                    #endif
                }
            }

            // ================================================================
            // Hook YouTube Endscreen Controller (Show Countdown with Queue Video!)
            // ================================================================
            // Let countdown show, but display QUEUE video via autonavEndpoint hook
            Class YTAutonavEndscreenControllerClass = objc_getClass("YTAutonavEndscreenController");
            if (YTAutonavEndscreenControllerClass) {
                #if DEBUG
                NSLog(@"[YTLocalQueue] Installing YTAutonavEndscreenController hooks");
                #endif

                // Hook videoDidFinish - Track video end for state management
                Method videoDidFinishMethod = class_getInstanceMethod(YTAutonavEndscreenControllerClass, @selector(videoDidFinish));
                if (videoDidFinishMethod && !origEndscreenVideoDidFinish) {
                    origEndscreenVideoDidFinish = (EndscreenVideoDidFinishIMP)method_getImplementation(videoDidFinishMethod);
                    method_setImplementation(videoDidFinishMethod, (IMP)ytlp_endscreenVideoDidFinish);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked videoDidFinish (state tracking)");
                    #endif
                }
            }

            // Also try generic autoplay classes
            NSArray *autoplayClasses = @[
                @"YTAutoplayController",
                @"YTPlayerAutoplayController", 
                @"YTUpNextAutoplayController",
                @"YTAutoplayManager",
                @"YTWatchNextAutoplayController"
            ];
            
            for (NSString *className in autoplayClasses) {
                Class AutoplayClass = objc_getClass([className UTF8String]);
                if (AutoplayClass) {
                    unsigned int methodCount;
                    Method *methods = class_copyMethodList(AutoplayClass, &methodCount);
                    for (unsigned int i = 0; i < methodCount; i++) {
                        SEL selector = method_getName(methods[i]);
                        NSString *selectorName = NSStringFromSelector(selector);
                        
                        // Try to hook autoplayEndpoint method
                        if ([selectorName isEqualToString:@"autoplayEndpoint"] && !origAutoplayGetNextVideo) {
                            origAutoplayGetNextVideo = (AutoplayGetNextVideoIMP)method_getImplementation(methods[i]);
                            method_setImplementation(methods[i], (IMP)ytlp_autoplayGetNextVideo);
                        }
                    }
                    free(methods);
                }
            }

            // Hook video completion methods as additional fallbacks
            NSArray *videoControllerClasses = @[@"YTPlayerViewController", @"YTSingleVideoController", @"YTVideoController", @"YTWatchController"];
            NSArray *completionSelectors = @[@"videoDidComplete", @"didCompleteVideo", @"videoDidFinish", @"didFinishVideo", @"playbackDidFinish"];
            
            for (NSString *className in videoControllerClasses) {
                Class VideoClass = objc_getClass([className UTF8String]);
                if (VideoClass) {
                    for (NSString *selectorName in completionSelectors) {
                        SEL selector = NSSelectorFromString(selectorName);
                        Method m = class_getInstanceMethod(VideoClass, selector);
                        if (m) {
                            if ([selectorName containsString:@"Complete"]) {
                                if (!origVideoDidComplete) {
                                    origVideoDidComplete = (VideoDidCompleteIMP)method_getImplementation(m);
                                    method_setImplementation(m, (IMP)ytlp_videoDidComplete);
                                }
                            } else if ([selectorName containsString:@"Finish"]) {
                                if (!origVideoDidFinish) {
                                    origVideoDidFinish = (VideoDidFinishIMP)method_getImplementation(m);
                                    method_setImplementation(m, (IMP)ytlp_videoDidFinish);
                                }
                            }
                        }
                    }
                }
            }

            // Hook YTMainAppVideoPlayerOverlayViewController
            Class OverlayViewController = objc_getClass("YTMainAppVideoPlayerOverlayViewController");
            if (OverlayViewController) {
                Method m = class_getInstanceMethod(OverlayViewController, @selector(viewDidLoad));
                if (m && !origOverlayViewDidLoad) {
                    origOverlayViewDidLoad = (OverlayViewDidLoadIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_overlayViewDidLoad);
                }

                // Hook didPressNext: to intercept native next button
                Method didPressNextMethod = class_getInstanceMethod(OverlayViewController, @selector(didPressNext:));
                if (didPressNextMethod && !origOverlayDidPressNext) {
                    origOverlayDidPressNext = (OverlayDidPressNextIMP)method_getImplementation(didPressNextMethod);
                    method_setImplementation(didPressNextMethod, (IMP)ytlp_overlayDidPressNext);
                    #if DEBUG
                    NSLog(@"[YTLocalQueue] Hooked didPressNext: on overlay");
                    #endif
                }

                // Add target methods
                class_addMethod(OverlayViewController, @selector(ytlp_addToQueueTapped:), (IMP)ytlp_addToQueueTapped, "v@:@");
                class_addMethod(OverlayViewController, @selector(ytlp_showQueueTapped:), (IMP)ytlp_showQueueTapped, "v@:@");
                class_addMethod(OverlayViewController, @selector(ytlp_nextFromQueueTapped:), (IMP)ytlp_nextFromQueueTapped, "v@:@");
            }
            
            // Hook YTMainAppControlsOverlayView for proper button integration
            Class ControlsOverlayView = objc_getClass("YTMainAppControlsOverlayView");
            if (ControlsOverlayView) {
                // Hook topControls to insert our buttons
                Method topControlsMethod = class_getInstanceMethod(ControlsOverlayView, @selector(topControls));
                if (topControlsMethod && !origTopControls) {
                    origTopControls = (TopControlsIMP)method_getImplementation(topControlsMethod);
                    method_setImplementation(topControlsMethod, (IMP)ytlp_topControls);
                }
                
                // Hook topButtonControls (alternative method name)
                Method topButtonControlsMethod = class_getInstanceMethod(ControlsOverlayView, @selector(topButtonControls));
                if (topButtonControlsMethod && !origTopButtonControls) {
                    origTopButtonControls = (TopControlsIMP)method_getImplementation(topButtonControlsMethod);
                    method_setImplementation(topButtonControlsMethod, (IMP)ytlp_topButtonControls);
                }
                
                // Hook setTopOverlayVisible:isAutonavCanceledState: to control button visibility
                Method setVisibleMethod = class_getInstanceMethod(ControlsOverlayView, @selector(setTopOverlayVisible:isAutonavCanceledState:));
                if (setVisibleMethod && !origSetTopOverlayVisible) {
                    origSetTopOverlayVisible = (SetTopOverlayVisibleIMP)method_getImplementation(setVisibleMethod);
                    method_setImplementation(setVisibleMethod, (IMP)ytlp_setTopOverlayVisible);
                }
            }

            if (allInstalled) {
                return;
            }
            if (--attemptsRemaining <= 0) {
                return;
            }
            void (^strongTryInstall)(void) = weakTryInstall;
            if (strongTryInstall) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), strongTryInstall);
            }
        };
        tryInstall();
    });
}