// Tweaks/YTLocalQueue/Tweak.xm
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "Headers/YouTubeHeader/YTPlayerViewController.h"
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
#import "Headers/YouTubeHeader/YTIcon.h"
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
#import "AutoAdvanceController.h"
#import <objc/runtime.h>

// Associated-object keys used across this file (only needed if we add advanced thumbnail injection)

// Track last known player VC
static __weak YTPlayerViewController *ytlp_currentPlayerVC = nil;
static NSTimeInterval ytlp_lastQueueAdvanceTime = 0;
static NSString *ytlp_lastPlayedVideoId = nil;
static NSTimer *ytlp_endCheckTimer = nil;
static dispatch_source_t ytlp_dispatchTimer = nil;  // GCD timer for background/PiP
static CGFloat ytlp_lastKnownPosition = 0;
static CGFloat ytlp_lastKnownTotal = 0;

// Time change tracking for loop detection (from singleVideo:currentVideoTimeDidChange:)
static CGFloat ytlp_lastTimeChangePosition = 0;
static CGFloat ytlp_lastTimeChangeTotal = 0;
static CGFloat ytlp_maxPositionSeen = 0;  // Track max position to detect loops after scrubbing
static BOOL ytlp_playbackStarted = NO;    // TRUE once we've seen position > 1 second

// Store the last tapped video info for menu operations
static NSString *ytlp_lastTappedVideoId = nil;
static NSString *ytlp_lastTappedVideoTitle = nil;
static NSTimeInterval ytlp_lastTapTime = 0;
static NSString *ytlp_lastMenuContextVideoId = nil;
static NSString *ytlp_lastMenuContextTitle = nil;
static NSTimeInterval ytlp_lastMenuContextTime = 0;

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
static void ytlp_startEndMonitoring(void);
static void ytlp_stopEndMonitoring(void);
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

// Simple cooldown check for loop interceptions - the loop itself proves video ended
static BOOL ytlp_shouldAllowLoopIntercept(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // Only check cooldown - if YouTube is trying to loop, the video definitely ended
    return (now - ytlp_lastQueueAdvanceTime >= 3.0);
}

static BOOL ytlp_shouldAllowQueueAdvance(NSString *reason) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    
    // Check cooldown period (minimum 5 seconds between advances since we're using loop mode)
    if (now - ytlp_lastQueueAdvanceTime < 5.0) {
        return NO;
    }
    
    // Check if current video has played for at least 15 seconds OR is near the end
    if (ytlp_currentPlayerVC) {
        CGFloat currentTime = [ytlp_currentPlayerVC currentVideoMediaTime];
        CGFloat totalTime = [ytlp_currentPlayerVC currentVideoTotalMediaTime];
        
        // If we're near the end (within 5 seconds), always allow - video is about to end/loop
        BOOL nearEnd = (totalTime > 0 && currentTime >= (totalTime - 5.0));
        
        // If not near end and haven't played for at least 15 seconds, block
        // This prevents advancing when video just started
        if (!nearEnd && currentTime < 15.0) {
            return NO;
        }
        
        // If we're not near the end and video is still playing, block
        if (!nearEnd && totalTime > 0 && currentTime < (totalTime - 5.0)) {
            return NO;
        }
    }
    
    return YES;
}

static void ytlp_playNextFromQueue(void) {
    NSDictionary *nextItem = [[YTLPLocalQueueManager shared] popNextItem];
    NSString *nextId = nextItem[@"videoId"];
    NSString *nextTitle = nextItem[@"title"];
    
    if (nextId.length == 0) {
        // Queue is now empty, update autoplay state to re-enable YouTube's autoplay
        ytlp_updateAutoplayState();
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
    // IMPORTANT: Set lastPlayedVideoId to the NEXT video we're navigating to, not the current one.
    // This prevents the "same video" check from blocking when the loop fires again before navigation completes.
    ytlp_lastPlayedVideoId = nextId;
    
    // Update currently playing for the Local Queue view
    [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:nextId title:nextTitle];
    
    // Reset position tracking to prevent false loop detection on new video
    ytlp_lastKnownPosition = 0;
    ytlp_lastKnownTotal = 0;
    ytlp_lastTimeChangePosition = 0;
    ytlp_lastTimeChangeTotal = 0;
    ytlp_maxPositionSeen = 0;
    ytlp_playbackStarted = NO;
    
    // Schedule a check to detect navigation failure and re-add video to queue if needed
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (ytlp_currentPlayerVC) {
            NSString *currentVideoId = [ytlp_currentPlayerVC currentVideoID];
            // If we're still on the previous video (not the one we tried to navigate to),
            // navigation probably failed - re-add the video to the front of the queue
            if (previousVideoId && [currentVideoId isEqualToString:previousVideoId] && ![currentVideoId isEqualToString:nextId]) {
                [[YTLPLocalQueueManager shared] insertVideoId:nextId title:nextTitle atIndex:0];
                Class HUD = objc_getClass("GOOHUDManagerInternal");
                Class HUDMsg = objc_getClass("YTHUDMessage");
                if (HUD && HUDMsg) {
                    [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Navigation failed, video re-added to queue"]];
                }
            }
        }
    });
    
    // Show toast with video title or ID
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
    
    // Update autoplay state for the new video (in case queue becomes empty after this)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ytlp_updateAutoplayState();
    });
    
    // Restart monitoring for the new video (small delay for video to start loading)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ytlp_startEndMonitoring();
    });
    
    Class YTICommandClass = objc_getClass("YTICommand");
    if (YTICommandClass && [YTICommandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) {
        id cmd = [YTICommandClass watchNavigationEndpointWithVideoID:nextId];
        Class Handler = objc_getClass("YTCoWatchWatchEndpointWrapperCommandHandler");
        if (Handler) {
            id handler = [[Handler alloc] init];
            if ([handler respondsToSelector:@selector(sendOriginalCommandWithNavigationEndpoint:fromView:entry:sender:completionBlock:)]) {
                [handler sendOriginalCommandWithNavigationEndpoint:cmd fromView:nil entry:nil sender:nil completionBlock:nil];
                return;
            }
        }
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"youtube://watch?v=%@", nextId]];
    Class UIUtils = objc_getClass("YTUIUtils");
    if (UIUtils && [UIUtils canOpenURL:url]) { [UIUtils openURL:url]; }
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
                id s = [obj videoId];
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
                    NSString *vid = [sv videoId];
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
                videoId = [entry videoId];
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

static void ytlp_playerSeekToTime(id self, SEL _cmd, CGFloat time) {
    CGFloat totalTime = 0;
    if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        totalTime = [(id)self currentVideoTotalMediaTime];
    }
    
    // Forward to AutoAdvanceController
    [[YTLPAutoAdvanceController shared] handleSeekToTime:time totalTime:totalTime];
    
    // Execute normal seek
    if (origPlayerSeekToTime) origPlayerSeekToTime(self, _cmd, time);
}

// Also hook scrubToTime: (older method, but may still be used)
typedef void (*PlayerScrubToTimeIMP)(id, SEL, CGFloat);
static PlayerScrubToTimeIMP origPlayerScrubToTime = NULL;

static void ytlp_playerScrubToTime(id self, SEL _cmd, CGFloat time) {
    CGFloat totalTime = 0;
    if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        totalTime = [(id)self currentVideoTotalMediaTime];
    }
    
    // Forward to AutoAdvanceController
    [[YTLPAutoAdvanceController shared] handleSeekToTime:time totalTime:totalTime];
    
    if (origPlayerScrubToTime) origPlayerScrubToTime(self, _cmd, time);
}

// Hook singleVideo:currentVideoTimeDidChange: to detect loops (inspired by iSponsorBlock)
// This gets called every time the video position changes, much more reliable than a timer
typedef void (*SingleVideoTimeDidChangeIMP)(id, SEL, id, YTSingleVideoTime *);
static SingleVideoTimeDidChangeIMP origSingleVideoTimeDidChange = NULL;
static SingleVideoTimeDidChangeIMP origPotentiallyMutatedSingleVideoTimeDidChange = NULL;

static void ytlp_handleVideoTimeChange(id self, YTSingleVideoTime *videoTime) {
    CGFloat currentTime = videoTime.time;
    CGFloat totalTime = 0;
    
    if ([self respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        totalTime = [(id)self currentVideoTotalMediaTime];
    }
    
    // Forward to AutoAdvanceController
    [[YTLPAutoAdvanceController shared] handleTimeUpdate:currentTime totalTime:totalTime];
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
    
    // Start AutoAdvanceController monitoring
    [[YTLPAutoAdvanceController shared] startMonitoringWithPlayerViewController:self];
    
    // Also start legacy monitoring as backup
    ytlp_playbackStarted = NO;
    ytlp_startEndMonitoring();
    
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
                    ytlp_updateAutoplayState();
                    
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
                        videoId = [singleVideo videoId];
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
                    videoId = [videoData videoId];
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
    
    // Forward rate change to AutoAdvanceController
    [[YTLPAutoAdvanceController shared] handlePlaybackRateChange:rate];
}

// YouTube Autoplay hooks - Override what plays next
typedef id (*AutoplayGetNextVideoIMP)(id, SEL);
static AutoplayGetNextVideoIMP origAutoplayGetNextVideo = NULL;

static id ytlp_autoplayGetNextVideo(id self, SEL _cmd) {
    // If auto-advance is enabled and we have items in queue, override
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        NSDictionary *nextItem = [[YTLPLocalQueueManager shared] popNextItem];
        NSString *nextId = nextItem[@"videoId"];
        NSString *nextTitle = nextItem[@"title"];
        if (nextId.length > 0) {
            // Update tracking variables to prevent double-triggers
            ytlp_lastQueueAdvanceTime = [[NSDate date] timeIntervalSince1970];
            ytlp_lastPlayedVideoId = nextId;
            
            // Update currently playing for the Local Queue view
            [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:nextId title:nextTitle];
            
            // Create a video object for our queue item
            Class YTICommandClass = objc_getClass("YTICommand");
            if (YTICommandClass && [YTICommandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) {
                return [YTICommandClass watchNavigationEndpointWithVideoID:nextId];
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
    if (origVideoDidFinish) origVideoDidFinish(self, _cmd);
    
    // Try to play next from queue if enabled, with safety check
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (ytlp_shouldAllowQueueAdvance(@"video finished")) {
                ytlp_playNextFromQueue();
            }
        });
    }
}

// Hook YTAutoplayAutonavController - completely override autoplay like YouLoop does
typedef NSInteger (*AutonavLoopModeIMP)(id, SEL);
static AutonavLoopModeIMP origAutonavLoopMode = NULL;

static NSInteger ytlp_autonavLoopMode(id self, SEL _cmd) {
    // If we have items in local queue and auto-advance is enabled, force loop mode like YouLoop does
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        return 2; // Set to 2 (loop mode) to prevent ANY other video from playing - we'll handle advancement manually
    }
    return origAutonavLoopMode ? origAutonavLoopMode(self, _cmd) : 0;
}

// Hook setLoopMode to completely override YouTube's autoplay decisions (like YouLoop)
typedef void (*AutonavSetLoopModeIMP)(id, SEL, NSInteger);
static AutonavSetLoopModeIMP origAutonavSetLoopMode = NULL;

static void ytlp_autonavSetLoopMode(id self, SEL _cmd, NSInteger loopMode) {
    // If we have local queue items and auto-advance is enabled, completely override YouTube's decision (like YouLoop)
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        // Force loop mode to 2 like YouLoop does - this prevents ANY other video from playing
        if (origAutonavSetLoopMode) origAutonavSetLoopMode(self, _cmd, 2);
        return;
    }
    
    // Fall back to original setLoopMode with original parameter
    if (origAutonavSetLoopMode) origAutonavSetLoopMode(self, _cmd, loopMode);
}

// Hook methods that might be called when video tries to loop - intercept and play from queue instead
typedef void (*AutonavPerformNavigationIMP)(id, SEL);
static AutonavPerformNavigationIMP origAutonavPerformNavigation = NULL;

static void ytlp_autonavPerformNavigation(id self, SEL _cmd) {
    // If we have queue items and this is about to loop, play from queue instead
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        // Use simpler check - the loop itself proves video ended
        if (ytlp_shouldAllowLoopIntercept()) {
            ytlp_playNextFromQueue();
            return;
        }
    }
    
    // Fall back to original navigation (loop)
    if (origAutonavPerformNavigation) origAutonavPerformNavigation(self, _cmd);
}

// Hook navigation execution to intercept loop attempts
typedef void (*AutonavExecuteNavigationIMP)(id, SEL);
static AutonavExecuteNavigationIMP origAutonavExecuteNavigation = NULL;

static void ytlp_autonavExecuteNavigation(id self, SEL _cmd) {
    // If we have queue items and this would execute loop navigation, play from queue instead
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        // Use simpler check - the loop itself proves video ended
        if (ytlp_shouldAllowLoopIntercept()) {
            ytlp_playNextFromQueue();
            return;
        }
    }
    
    // Fall back to original execution (loop)
    if (origAutonavExecuteNavigation) origAutonavExecuteNavigation(self, _cmd);
}

// Hook YTCoWatchWatchEndpointWrapperCommandHandler to intercept next button navigation
typedef void (*SendOriginalCommandIMP)(id, SEL, id, id, id, id, id);
static SendOriginalCommandIMP origSendOriginalCommand = NULL;

static void ytlp_sendOriginalCommand(id self, SEL _cmd, id navigationEndpoint, id fromView, id entry, id sender, id completionBlock) {
    // Just pass through - this hook was too aggressive
    if (origSendOriginalCommand) {
        origSendOriginalCommand(self, _cmd, navigationEndpoint, fromView, entry, sender, completionBlock);
    }
}

// Hook YTCommandResponderEvent to intercept command dispatch (more fundamental interception)
typedef void (*ResponderEventSendIMP)(id, SEL);
static ResponderEventSendIMP origResponderEventSend = NULL;

static void ytlp_responderEventSend(id self, SEL _cmd) {
    // Just pass through - this hook was too aggressive
    if (origResponderEventSend) {
        origResponderEventSend(self, _cmd);
    }
}

// Hook init to disable autoplay from the start when we have queue items
typedef id (*AutonavInitIMP)(id, SEL, id);
static AutonavInitIMP origAutonavInit = NULL;

static id ytlp_autonavInit(id self, SEL _cmd, id parentResponder) {
    self = origAutonavInit ? origAutonavInit(self, _cmd, parentResponder) : nil;
    if (self) {
        // If we have queue items, immediately disable autoplay like YouLoop does
        if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
            // Force loop mode like YouLoop does to prevent any other video from playing
            if ([self respondsToSelector:@selector(setLoopMode:)]) {
                [(YTAutoplayAutonavController *)self setLoopMode:2];
            }
        }
    }
    return self;
}

// Function to update autoplay controller when queue state changes
static void ytlp_updateAutoplayState(void) {
    // Find the current autoplay controller and update its state
    Class YTMainAppVideoPlayerOverlayViewControllerClass = objc_getClass("YTMainAppVideoPlayerOverlayViewController");
    if (!YTMainAppVideoPlayerOverlayViewControllerClass) return;
    
    // Try to get the current overlay instance from the player
    if (ytlp_currentPlayerVC && [ytlp_currentPlayerVC respondsToSelector:@selector(activeVideoPlayerOverlay)]) {
        id overlay = [ytlp_currentPlayerVC activeVideoPlayerOverlay];
        if (overlay && [overlay isKindOfClass:YTMainAppVideoPlayerOverlayViewControllerClass]) {
            // Get the autoplay controller like YouLoop does
            if ([overlay respondsToSelector:@selector(valueForKey:)]) {
                id autonavController = [overlay valueForKey:@"_autonavController"];
                if (autonavController && [autonavController respondsToSelector:@selector(setLoopMode:)]) {
                    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
                        // Force loop mode like YouLoop does when we have queue items (prevents any other video from playing)
                        [(YTAutoplayAutonavController *)autonavController setLoopMode:2];
                    } else {
                        // Re-enable normal autoplay when queue is empty (mode 0 = no loop, autoplay enabled)
                        [(YTAutoplayAutonavController *)autonavController setLoopMode:0];
                    }
                }
            }
        }
    }
}

// Proactive video end monitoring - check every second if we're near end and intercept loop
static void ytlp_checkVideoEnd(NSTimer *timer) {
    if (!YTLP_AutoAdvanceEnabled() || [[YTLPLocalQueueManager shared] isEmpty] || !ytlp_currentPlayerVC) {
        return;
    }
    
    CGFloat total = [ytlp_currentPlayerVC currentVideoTotalMediaTime];
    CGFloat current = [ytlp_currentPlayerVC currentVideoMediaTime];
    
    // Track if playback ever started (position exceeded 1 second)
    if (current > 1.0) {
        ytlp_playbackStarted = YES;
    }
    
    // Reset playback flag if video changed (total time changed significantly)
    if (fabs(total - ytlp_lastKnownTotal) > 5.0) {
        ytlp_playbackStarted = (current > 1.0);
    }
    
    // SIMPLE LOOP DETECTION: If playback started and now position is near 0, it's a loop
    // This catches ALL loops including after scrubbing to end from any position
    BOOL nowAtStart = (current < 1.0);
    BOOL loopDetected = NO;
    
    if (nowAtStart && ytlp_playbackStarted && total > 10.0) {
        loopDetected = YES;
    }
    
    // Update tracking for next check
    ytlp_lastKnownPosition = current;
    ytlp_lastKnownTotal = total;
    
    // If loop detected, advance queue
    if (loopDetected) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - ytlp_lastQueueAdvanceTime >= 3.0) {
            ytlp_playbackStarted = NO;
            ytlp_stopEndMonitoring();
            ytlp_playNextFromQueue();
            return;
        }
    }
    
    // If we're within 1 second of the end, immediately play from queue to prevent loop
    if (total > 10.0 && current >= (total - 1.0)) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - ytlp_lastQueueAdvanceTime >= 3.0) {
            ytlp_playbackStarted = NO;
            ytlp_stopEndMonitoring();
            ytlp_playNextFromQueue();
        }
    }
}

static void ytlp_startEndMonitoring(void) {
    ytlp_stopEndMonitoring(); // Stop any existing timer
    
    // Initialize position tracking with current values (don't reset to 0)
    // This allows loop detection to work immediately
    if (ytlp_currentPlayerVC) {
        ytlp_lastKnownPosition = [ytlp_currentPlayerVC currentVideoMediaTime];
        ytlp_lastKnownTotal = [ytlp_currentPlayerVC currentVideoTotalMediaTime];
    } else {
        ytlp_lastKnownPosition = 0;
        ytlp_lastKnownTotal = 0;
    }
    
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        // Use GCD dispatch timer for reliable background/PiP execution
        dispatch_queue_t queue = dispatch_get_main_queue();
        ytlp_dispatchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        if (ytlp_dispatchTimer) {
            // Fire every 0.15 seconds (150ms)
            dispatch_source_set_timer(ytlp_dispatchTimer, 
                                       dispatch_time(DISPATCH_TIME_NOW, 0), 
                                       150 * NSEC_PER_MSEC, 
                                       50 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(ytlp_dispatchTimer, ^{
                ytlp_checkVideoEnd(nil);
            });
            dispatch_resume(ytlp_dispatchTimer);
        }
    }
}

static void ytlp_stopEndMonitoring(void) {
    if (ytlp_endCheckTimer) {
        [ytlp_endCheckTimer invalidate];
        ytlp_endCheckTimer = nil;
    }
    if (ytlp_dispatchTimer) {
        dispatch_source_cancel(ytlp_dispatchTimer);
        ytlp_dispatchTimer = nil;
    }
}

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
        ytlp_updateAutoplayState();
        
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
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    
    // Check if queue is empty
    if ([[YTLPLocalQueueManager shared] isEmpty]) {
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Queue is empty"]];
        }
        return;
    }
    
    // Play next from queue using new controller
    [[YTLPAutoAdvanceController shared] advanceToNextInQueue];
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

            // Hook YTCoWatchWatchEndpointWrapperCommandHandler (passthrough for now)
            Class CommandHandler = objc_getClass("YTCoWatchWatchEndpointWrapperCommandHandler");
            if (CommandHandler) {
                Method m = class_getInstanceMethod(CommandHandler, @selector(sendOriginalCommandWithNavigationEndpoint:fromView:entry:sender:completionBlock:));
                if (m && !origSendOriginalCommand) {
                    origSendOriginalCommand = (SendOriginalCommandIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_sendOriginalCommand);
                }
            }

            // Hook YTCommandResponderEvent to intercept command dispatch (for next button)
            Class ResponderEvent = objc_getClass("YTCommandResponderEvent");
            if (ResponderEvent) {
                Method m = class_getInstanceMethod(ResponderEvent, @selector(send));
                if (m && !origResponderEventSend) {
                    origResponderEventSend = (ResponderEventSendIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_responderEventSend);
                }
            }

            // Hook the real YouTube Autoplay Controller (found from YouLoop tweak)
            Class YTAutoplayAutonavControllerClass = objc_getClass("YTAutoplayAutonavController");
            if (YTAutoplayAutonavControllerClass) {
                // Hook loopMode getter to completely disable autoplay when we have queue items
                Method loopModeMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(loopMode));
                if (loopModeMethod && !origAutonavLoopMode) {
                    origAutonavLoopMode = (AutonavLoopModeIMP)method_getImplementation(loopModeMethod);
                    method_setImplementation(loopModeMethod, (IMP)ytlp_autonavLoopMode);
                }
                
                // Hook init to disable autoplay from the start (like YouLoop approach)
                Method initMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(initWithParentResponder:));
                if (initMethod && !origAutonavInit) {
                    origAutonavInit = (AutonavInitIMP)method_getImplementation(initMethod);
                    method_setImplementation(initMethod, (IMP)ytlp_autonavInit);
                }
                
                // Hook specific safe methods and try to find loop interception points
                unsigned int methodCount;
                Method *methods = class_copyMethodList(YTAutoplayAutonavControllerClass, &methodCount);
                
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL selector = method_getName(methods[i]);
                    NSString *selectorName = NSStringFromSelector(selector);
                    
                    // Hook setLoopMode
                    if ([selectorName isEqualToString:@"setLoopMode:"] && !origAutonavSetLoopMode) {
                        origAutonavSetLoopMode = (AutonavSetLoopModeIMP)method_getImplementation(methods[i]);
                        method_setImplementation(methods[i], (IMP)ytlp_autonavSetLoopMode);
                    }
                    
                    // Hook methods that might perform loop navigation
                    else if (([selectorName containsString:@"performNavigation"] || 
                              [selectorName containsString:@"navigate"] ||
                              [selectorName containsString:@"perform"]) && 
                             ![selectorName containsString:@"get"] &&
                             ![selectorName containsString:@"set"] &&
                             [selectorName hasSuffix:@""]) {
                        
                        if (!origAutonavPerformNavigation) {
                            origAutonavPerformNavigation = (AutonavPerformNavigationIMP)method_getImplementation(methods[i]);
                            method_setImplementation(methods[i], (IMP)ytlp_autonavPerformNavigation);
                        }
                    }
                    
                    // Hook methods that might execute navigation
                    else if (([selectorName containsString:@"execute"] || 
                              [selectorName containsString:@"advance"] ||
                              [selectorName containsString:@"next"]) && 
                             ![selectorName containsString:@"get"] &&
                             ![selectorName containsString:@"set"] &&
                             [selectorName hasSuffix:@""]) {
                        
                        if (!origAutonavExecuteNavigation) {
                            origAutonavExecuteNavigation = (AutonavExecuteNavigationIMP)method_getImplementation(methods[i]);
                            method_setImplementation(methods[i], (IMP)ytlp_autonavExecuteNavigation);
                        }
                    }
                }
                
                free(methods);
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