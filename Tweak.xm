// Tweaks/YTLocalQueue/Tweak.xm
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../YouTubeHeader/YTPlayerViewController.h"
#import "../YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h"
#import "../YouTubeHeader/YTMainAppVideoPlayerOverlayView.h"
#import "../YouTubeHeader/YTMainAppControlsOverlayView.h"
#import "../YouTubeHeader/YTQTMButton.h"
#import "../YouTubeHeader/YTUIUtils.h"
#import "../YouTubeHeader/YTICommand.h"
#import "../YouTubeHeader/YTCoWatchWatchEndpointWrapperCommandHandler.h"
#import "../YouTubeHeader/GOOHUDManagerInternal.h"
#import "../YouTubeHeader/YTAppDelegate.h"
#import "../YouTubeHeader/YTIMenuRenderer.h"
#import "../YouTubeHeader/YTIMenuItemSupportedRenderers.h"
#import "../YouTubeHeader/YTIMenuNavigationItemRenderer.h"
#import "../YouTubeHeader/YTIButtonRenderer.h"
#import "../YouTubeHeader/YTIcon.h"
#import "../YouTubeHeader/YTIMenuItemSupportedRenderersElementRendererCompatibilityOptionsExtension.h"
#import "../YouTubeHeader/YTIMenuConditionalServiceItemRenderer.h"
#import "../YouTubeHeader/YTActionSheetAction.h"
#import "../YouTubeHeader/YTActionSheetController.h"
#import "../YouTubeHeader/YTActionSheetDialogViewController.h"
#import "../YouTubeHeader/YTDefaultSheetController.h"
#import "../YouTubeHeader/GOODialogView.h"
#import "../YouTubeHeader/GOODialogViewAction.h"
#import "../YouTubeHeader/QTMIcon.h"
#import "../YouTubeHeader/YTUIResources.h"
#import "../YouTubeHeader/YTVideoCellController.h"
#import "../YouTubeHeader/YTCollectionViewCell.h"

#import "LocalQueueManager.h"
#import "LocalQueueViewController.h"
#import <objc/runtime.h>

// Associated-object keys used across this file (only needed if we add advanced thumbnail injection)

// Track last known player VC
static __weak YTPlayerViewController *ytlp_currentPlayerVC = nil;
static BOOL ytlp_didShowLaunchAlert = NO;
static NSTimeInterval ytlp_lastQueueAdvanceTime = 0;
static NSString *ytlp_lastPlayedVideoId = nil;
static NSTimer *ytlp_endCheckTimer = nil;

// Store the last tapped video info for menu operations
static NSString *ytlp_lastTappedVideoId = nil;
static NSString *ytlp_lastTappedVideoTitle = nil;
static NSTimeInterval ytlp_lastTapTime = 0;

static BOOL YTLP_AutoAdvanceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ytlp_queue_auto_advance_enabled"];
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

// Simple icons
static UIImage *YTLPIconAddToQueue(void) {
    UIImage *img = [UIImage systemImageNamed:@"text.badge.plus"]; if (img) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(20, 20), NO, 0);
    [[UIColor whiteColor] setStroke]; UIBezierPath *p = [UIBezierPath bezierPathWithRect:CGRectMake(2, 9, 16, 2)]; [p stroke];
    p = [UIBezierPath bezierPathWithRect:CGRectMake(9, 2, 2, 16)]; [p stroke]; UIImage *out = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); return out;
}

static UIImage *YTLPIconQueueList(void) {
    UIImage *img = [UIImage systemImageNamed:@"list.bullet"]; if (img) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(20, 20), NO, 0);
    [[UIColor whiteColor] setFill];
    UIBezierPath *p = [UIBezierPath bezierPathWithRect:CGRectMake(3, 4, 14, 2)]; [p fill];
    p = [UIBezierPath bezierPathWithRect:CGRectMake(3, 9, 14, 2)]; [p fill];
    p = [UIBezierPath bezierPathWithRect:CGRectMake(3, 14, 14, 2)]; [p fill];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); return out;
}

// Debug helper: present a quick alert to confirm load
static void ytlp_presentDebugAlert(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = nil;
        // Try YTUIUtils if available
        Class UIUtils = objc_getClass("YTUIUtils");
        SEL selTop = sel_getUid("topViewControllerForPresenting");
        if (UIUtils && class_respondsToSelector(object_getClass((id)UIUtils), selTop)) {
            top = ((id (*)(id, SEL))objc_msgSend)(UIUtils, selTop);
        }
        // Fallback: walk key window scenes
        if (!top) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *win in scene.windows) {
                    if (win.isKeyWindow) { top = win.rootViewController; break; }
                }
                if (top) break;
            }
        }
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"YTLocalQueue"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void ytlp_presentLaunchAlert(void) {
    if (ytlp_didShowLaunchAlert) return;
    ytlp_didShowLaunchAlert = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ytlp_presentDebugAlert(@"YTLocalQueue Loaded - Debug: tweak is active");
    });
}

static BOOL ytlp_shouldAllowQueueAdvance(NSString *reason) {
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    
    // Check cooldown period (minimum 5 seconds between advances since we're using loop mode)
    if (now - ytlp_lastQueueAdvanceTime < 5.0) {
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Queue advance blocked: too soon (%.1fs)", now - ytlp_lastQueueAdvanceTime]]];
        }
        return NO;
    }
    
    // Check if current video has played for at least 15 seconds
    if (ytlp_currentPlayerVC) {
        CGFloat currentTime = [ytlp_currentPlayerVC currentVideoMediaTime];
        CGFloat totalTime = [ytlp_currentPlayerVC currentVideoTotalMediaTime];
        
        if (currentTime < 15.0) {
            if (HUD && HUDMsg) {
                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Queue advance blocked: video too short (%.1fs)", currentTime]]];
            }
            return NO;
        }
        
        // Since we're forcing loop mode, be more aggressive about detecting video end (within 5 seconds)
        if (totalTime > 0 && currentTime < (totalTime - 5.0)) {
            if (HUD && HUDMsg) {
                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Queue advance blocked: not near end (%.1f/%.1f)", currentTime, totalTime]]];
            }
            return NO;
        }
        
        // Check if we're trying to advance on the same video multiple times
        NSString *currentVideoId = [ytlp_currentPlayerVC currentVideoID];
        if (currentVideoId && [currentVideoId isEqualToString:ytlp_lastPlayedVideoId]) {
            if (HUD && HUDMsg) {
                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Queue advance blocked: same video"]];
            }
            return NO;
        }
    }
    
    if (HUD && HUDMsg) {
        [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Queue advance allowed: %@", reason]]];
    }
    
    return YES;
}

static void ytlp_playNextFromQueue(void) {
    NSString *nextId = [[YTLPLocalQueueManager shared] popNextVideoId];
    if (nextId.length == 0) {
        // Queue is now empty, update autoplay state to re-enable YouTube's autoplay
        ytlp_updateAutoplayState();
        return;
    }
    
    // Update tracking variables
    ytlp_lastQueueAdvanceTime = [[NSDate date] timeIntervalSince1970];
    ytlp_lastPlayedVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
    
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    if (HUD && HUDMsg) {
        [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Playing next from local queue"]];
    }
    
    // Update autoplay state for the new video (in case queue becomes empty after this)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ytlp_updateAutoplayState();
    });
    
    // Restart monitoring for the new video
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

// Improved video ID resolution logic
static NSString *ytlp_findVideoIdDeep(id obj, int depth) {
    if (!obj || depth <= 0) return nil;
    @try {
        // 1) Direct selectors
        if ([obj respondsToSelector:@selector(videoId)]) {
            id s = [obj videoId];
            if ([s isKindOfClass:[NSString class]] && [s length] > 0) return s;
        }
        if ([obj respondsToSelector:@selector(currentVideoID)]) {
            id s = [obj currentVideoID];
            if ([s isKindOfClass:[NSString class]] && [s length] > 0) return s;
        }
        // 2) KVC direct
        id v = nil;
        @try { v = [obj valueForKey:@"videoId"]; if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v; } @catch (__unused NSException *e) {}
        @try { v = [obj valueForKey:@"videoID"]; if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v; } @catch (__unused NSException *e) {}

        // 3) Known nested keys to recurse through
        NSArray<NSString *> *keys = @[
            @"navigationEndpoint", @"watchEndpoint", @"watchNavigationEndpoint",
            @"videoEndpoint", @"playlistVideoRenderer", @"compactVideoRenderer",
            @"richItemRenderer", @"elementRenderer", @"renderer",
            @"element", @"data", @"content", @"singleVideo", @"activeVideo",
            @"currentVideo", @"playerResponse", @"videoDetails"
        ];
        for (NSString *k in keys) {
            id child = nil; @try { child = [obj valueForKey:k]; } @catch (__unused NSException *e) {}
            if (child) {
                NSString *found = ytlp_findVideoIdDeep(child, depth - 1);
                if (found.length > 0) return found;
            }
        }
        // 4) Arrays: scan a few items
        if ([obj isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)obj; NSUInteger limit = MIN(arr.count, 5);
            for (NSUInteger i = 0; i < limit; i++) {
                NSString *found = ytlp_findVideoIdDeep(arr[i], depth - 1);
                if (found.length > 0) return found;
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
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

// Helper function to check if a string looks like a YouTube video ID
static BOOL ytlp_looksLikeVideoId(NSString *str) {
    if (!str || str.length != 11) return NO;
    
    NSCharacterSet *validChars = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    NSCharacterSet *strChars = [NSCharacterSet characterSetWithCharactersInString:str];
    return [validChars isSupersetOfSet:strChars];
}

// Comprehensive video ID scanner - logs ALL video IDs found in an object
static void ytlp_scanForVideoIds(id obj, NSString *location, NSString *currentVideoId) {
    if (!obj) return;
    
    @try {
        // Get all properties of the object
        unsigned int count;
        objc_property_t *properties = class_copyPropertyList([obj class], &count);
        
        for (unsigned int i = 0; i < count; i++) {
            const char *propertyName = property_getName(properties[i]);
            NSString *propName = [NSString stringWithUTF8String:propertyName];
            
            @try {
                id value = [obj valueForKey:propName];
                if ([value isKindOfClass:[NSString class]]) {
                    NSString *strValue = (NSString *)value;
                    if (ytlp_looksLikeVideoId(strValue)) {
                        BOOL isDifferent = ![strValue isEqualToString:currentVideoId];
                        NSLog(@"[YTLocalQueue] 🔍 FOUND VIDEO ID: %@ in %@.%@ (different=%@)", 
                              strValue, location, propName, isDifferent ? @"YES" : @"NO");
                    }
                }
            } @catch (NSException *e) {
                // Ignore exceptions when scanning properties
            }
        }
        
        if (properties) free(properties);
        
        // Note: Method scanning disabled to avoid compiler warnings
        // Property scanning above should be sufficient for video ID discovery
        
    } @catch (NSException *e) {
        NSLog(@"[YTLocalQueue] Exception scanning %@: %@", location, e.reason);
    }
}

// Forward declarations
static void ytlp_findAndTriggerCopyLink(void);
static void ytlp_searchViewHierarchy(UIView *view, SEL unused);

// Capture video tap function
static void ytlp_captureVideoTap(id view, NSString *videoId, NSString *title) {
    if (videoId.length > 0) {
        ytlp_lastTappedVideoId = [videoId copy];
        ytlp_lastTappedVideoTitle = [title copy];
        ytlp_lastTapTime = [[NSDate date] timeIntervalSince1970];
        
        NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
        NSLog(@"[YTLocalQueue] CAPTURED VIDEO TAP: videoId=%@, title=%@, view=%@", 
              videoId, title ?: @"nil", NSStringFromClass([view class]));
        NSLog(@"[YTLocalQueue] Current video: %@, captured is different: %@", 
              currentVideoId ?: @"nil", ![videoId isEqualToString:currentVideoId] ? @"YES" : @"NO");
    }
}

// Hook UIButton actions to capture video taps
typedef void (*UIButtonSendActionsIMP)(id, SEL, NSUInteger, id);
static UIButtonSendActionsIMP origButtonSendActions = NULL;

// Hook collection view cell selection to capture target videos
typedef void (*CollectionViewCellSetSelectedIMP)(id, SEL, BOOL);
static CollectionViewCellSetSelectedIMP origCollectionViewCellSetSelected = NULL;

// Hook share functionality to capture video ID from share URLs
typedef void (*ShareHandlerIMP)(id, SEL, id);
static ShareHandlerIMP origShareHandler = NULL;

// Hook URL generation for sharing
typedef NSURL* (*ShareURLGeneratorIMP)(id, SEL);
static ShareURLGeneratorIMP origShareURLGenerator = NULL;

// Hook pasteboard for copy link functionality
typedef void (*PasteboardSetStringIMP)(id, SEL, NSString*);
static PasteboardSetStringIMP origPasteboardSetString = NULL;

typedef void (*PasteboardSetURLIMP)(id, SEL, NSURL*);
static PasteboardSetURLIMP origPasteboardSetURL = NULL;

// Gesture recognizer approach disabled for now due to method signature issues

static void ytlp_buttonSendActions(id self, SEL _cmd, NSUInteger controlEvents, id event) {
    NSLog(@"[YTLocalQueue] BUTTON TAP: %@ (events: %lu)", NSStringFromClass([self class]), (unsigned long)controlEvents);
    
    // Try to extract video info from button or its superview before the action
    @try {
        NSString *videoId = nil;
        NSString *title = nil;
        
        // Look in the button and its parent views for video information
        UIView *currentView = self;
        for (int level = 0; level < 10 && currentView; level++) {
            NSLog(@"[YTLocalQueue] Checking level %d: %@", level, NSStringFromClass([currentView class]));
            @try {
                // Try various video-related properties
                id renderer = [currentView valueForKey:@"renderer"];
                id videoData = [currentView valueForKey:@"videoData"];
                id entry = [currentView valueForKey:@"entry"];
                id data = [currentView valueForKey:@"data"];
                
                if (renderer) {
                    NSLog(@"[YTLocalQueue] Found renderer at level %d: %@", level, NSStringFromClass([renderer class]));
                    ytlp_extractVideoInfo(renderer, &videoId, &title);
                    if (videoId.length > 0) {
                        NSLog(@"[YTLocalQueue] Button tap found video in renderer at level %d: %@", level, videoId);
                        break;
                    }
                }
                if (videoData) {
                    NSLog(@"[YTLocalQueue] Found videoData at level %d: %@", level, NSStringFromClass([videoData class]));
                    ytlp_extractVideoInfo(videoData, &videoId, &title);
                    if (videoId.length > 0) {
                        NSLog(@"[YTLocalQueue] Button tap found video in videoData at level %d: %@", level, videoId);
                        break;
                    }
                }
                if (entry) {
                    NSLog(@"[YTLocalQueue] Found entry at level %d: %@", level, NSStringFromClass([entry class]));
                    ytlp_extractVideoInfo(entry, &videoId, &title);
                    if (videoId.length > 0) {
                        NSLog(@"[YTLocalQueue] Button tap found video in entry at level %d: %@", level, videoId);
                        break;
                    }
                }
                if (data) {
                    NSLog(@"[YTLocalQueue] Found data at level %d: %@", level, NSStringFromClass([data class]));
                    ytlp_extractVideoInfo(data, &videoId, &title);
                    if (videoId.length > 0) {
                        NSLog(@"[YTLocalQueue] Button tap found video in data at level %d: %@", level, videoId);
                        break;
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"[YTLocalQueue] Exception at level %d: %@", level, e.reason);
            }
            
            currentView = [currentView superview];
        }
        
        if (videoId.length > 0) {
            ytlp_captureVideoTap(self, videoId, title);
        } else {
            NSLog(@"[YTLocalQueue] No video ID found in button hierarchy");
        }
    } @catch (NSException *e) {
        NSLog(@"[YTLocalQueue] Exception in button tap capture: %@", e.reason);
    }
    
    // Call original implementation
    if (origButtonSendActions) {
        origButtonSendActions(self, _cmd, controlEvents, event);
    }
}

// Collection view cell selection hook to capture video when user interacts with video list items
static void ytlp_collectionViewCellSetSelected(id self, SEL _cmd, BOOL selected) {
    @try {
        if (selected && [self isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
            NSLog(@"[YTLocalQueue] ===== COLLECTION CELL SELECTED =====");
            NSLog(@"[YTLocalQueue] Selected cell: %@", NSStringFromClass([self class]));
            NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
            
            // COMPREHENSIVE VIDEO ID SCAN of the entire selected cell
            ytlp_scanForVideoIds(self, @"SelectedCell", currentVideoId);
            
            // Extract video info from the selected cell's node
            @try {
                id node = [self valueForKey:@"node"];
                if (node) {
                    NSLog(@"[YTLocalQueue] Cell node: %@", NSStringFromClass([node class]));
                    
                    // COMPREHENSIVE VIDEO ID SCAN of the node
                    ytlp_scanForVideoIds(node, @"SelectedCell.node", currentVideoId);
                    
        NSString *videoId = nil;
                    NSString *title = nil;
                    ytlp_extractVideoInfo(node, &videoId, &title);
                    
                    if (videoId.length > 0) {
                        BOOL isDifferent = ![videoId isEqualToString:currentVideoId];
                        
                        NSLog(@"[YTLocalQueue] CELL video=%@, current=%@, different=%@", 
                              videoId, currentVideoId ?: @"nil", isDifferent ? @"YES" : @"NO");
                        
                        if (isDifferent) {
                            NSLog(@"[YTLocalQueue] ✅ CAPTURING different video from cell: %@", videoId);
                            ytlp_captureVideoTap(self, videoId, title);
                        } else {
                            NSLog(@"[YTLocalQueue] ⚠️ Cell video matches current - ignoring");
                        }
                    } else {
                        NSLog(@"[YTLocalQueue] No video ID in cell node");
                    }
                } else {
                    NSLog(@"[YTLocalQueue] No node in selected cell");
                }
            } @catch (NSException *e) {
                NSLog(@"[YTLocalQueue] Exception in cell analysis: %@", e.reason);
            }
            
            NSLog(@"[YTLocalQueue] ===== END CELL SELECTION =====");
        }
    } @catch (NSException *e) {
        NSLog(@"[YTLocalQueue] Exception in cell selection: %@", e.reason);
    }
    
    // Call original implementation
    if (origCollectionViewCellSetSelected) {
        origCollectionViewCellSetSelected(self, _cmd, selected);
    }
}

// Extract video ID from YouTube URLs
static NSString* ytlp_extractVideoIdFromURL(NSURL *url) {
    if (!url) return nil;
    
    NSString *urlString = [url absoluteString];
    NSLog(@"[YTLocalQueue] 🔗 SHARE URL: %@", urlString);
    
    // Look for various YouTube URL patterns
    NSArray *patterns = @[
        @"(?:youtu\\.be/|youtube\\.com/watch\\?v=|youtube\\.com/embed/)([a-zA-Z0-9_-]{11})",
        @"[?&]v=([a-zA-Z0-9_-]{11})",
        @"/([a-zA-Z0-9_-]{11})(?:[?&#]|$)"
    ];
    
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)];
        
        if (match && match.numberOfRanges > 1) {
            NSString *videoId = [urlString substringWithRange:[match rangeAtIndex:1]];
            if (ytlp_looksLikeVideoId(videoId)) {
                NSLog(@"[YTLocalQueue] ✅ EXTRACTED VIDEO ID from URL: %@", videoId);
                return videoId;
            }
        }
    }
    
    return nil;
}

// Automatically extract video ID by triggering share workflow
static NSString* ytlp_extractVideoIdFromAutoShare(id menuController, NSMutableArray *actions, UIView *fromView) {
    NSLog(@"[YTLocalQueue] 🤖 STARTING AUTOMATIC SHARE EXTRACTION");
    
    @try {
        // Step 1: Find the "Share" action in the current menu
        id shareAction = nil;
        
        for (NSUInteger i = 0; i < actions.count; i++) {
            id action = actions[i];
            NSString *title = nil;
            
            @try {
                if ([action respondsToSelector:@selector(button)]) {
                    UIButton *btn = [action button];
                    if ([btn isKindOfClass:[UIButton class]]) title = btn.currentTitle;
                }
                if (title.length == 0) title = [action valueForKey:@"_title"];
    } @catch (__unused NSException *e) {}
            
            if (title && [title.lowercaseString containsString:@"share"]) {
                shareAction = action;
                NSLog(@"[YTLocalQueue] 🤖 Found Share action at index %lu: '%@'", (unsigned long)i, title);
                break;
            }
        }
        
        if (!shareAction) {
            NSLog(@"[YTLocalQueue] 🤖 No Share action found in menu");
            return nil;
        }
        
        // Step 2: Store current pasteboard content to restore later
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        NSString *originalContent = pasteboard.string;
        NSLog(@"[YTLocalQueue] 🤖 Stored original pasteboard: %@", originalContent ?: @"nil");
        
        // Step 3: Clear pasteboard to detect new content
        pasteboard.string = @"";
        
        // Step 4: Programmatically trigger the share action
        NSLog(@"[YTLocalQueue] 🤖 Triggering Share action...");
        
        @try {
            // Get the action's handler
            void (^handler)(id) = nil;
            if ([shareAction respondsToSelector:@selector(handler)]) {
                handler = [shareAction handler];
            } else {
                handler = [shareAction valueForKey:@"_handler"];
            }
            
            if (handler) {
                NSLog(@"[YTLocalQueue] 🤖 Executing Share handler...");
                handler(shareAction);
                
                // Wait a moment for the share sheet to appear
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSLog(@"[YTLocalQueue] 🤖 Looking for Copy Link in share sheet...");
                    
                    // Step 5: Try to find and trigger "Copy link" in the share sheet
                    ytlp_findAndTriggerCopyLink();
                    
                    // Step 6: Wait for copy operation and check pasteboard
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSString *newContent = pasteboard.string;
                        NSLog(@"[YTLocalQueue] 🤖 New pasteboard content: %@", newContent ?: @"nil");
                        
    NSString *videoId = nil;
                        if (newContent && [newContent containsString:@"youtu"]) {
                            NSURL *url = [NSURL URLWithString:newContent];
                            videoId = ytlp_extractVideoIdFromURL(url);
                            
                            if (videoId) {
                                NSLog(@"[YTLocalQueue] 🤖 ✅ AUTO-EXTRACTED VIDEO ID: %@", videoId);
                                
                                // Store the captured video ID for immediate use
                                ytlp_lastTappedVideoId = [videoId copy];
                                ytlp_lastTappedVideoTitle = nil;
                                ytlp_lastTapTime = [[NSDate date] timeIntervalSince1970];
                            }
                        }
                        
                        // Restore original pasteboard content
                        if (originalContent) {
                            pasteboard.string = originalContent;
                            NSLog(@"[YTLocalQueue] 🤖 Restored original pasteboard");
                        }
                    });
                });
            } else {
                NSLog(@"[YTLocalQueue] 🤖 No handler found for Share action");
            }
        } @catch (NSException *e) {
            NSLog(@"[YTLocalQueue] 🤖 Exception triggering Share: %@", e.reason);
        }
        
    } @catch (NSException *e) {
        NSLog(@"[YTLocalQueue] 🤖 Exception in auto share extraction: %@", e.reason);
    }
    
    // Return nil for now since this is async - the video ID will be captured via ytlp_lastTappedVideoId
    return nil;
}

// Helper method to find and trigger Copy Link in share sheet
static void ytlp_findAndTriggerCopyLink() {
    NSLog(@"[YTLocalQueue] 🔗 Searching for Copy Link button...");
    
    @try {
        // Get the top window
        UIWindow *topWindow = nil;
        for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
            if (window.isKeyWindow) {
                topWindow = window;
                break;
            }
        }
        
        if (!topWindow) {
            NSLog(@"[YTLocalQueue] 🔗 No top window found");
            return;
        }
        
        // Recursively search for Copy Link button
        ytlp_searchViewHierarchy(topWindow.rootViewController.view, NULL);
        
    } @catch (NSException *e) {
        NSLog(@"[YTLocalQueue] 🔗 Exception searching for Copy Link: %@", e.reason);
    }
}

// Recursively search view hierarchy for Copy Link button
static void ytlp_searchViewHierarchy(UIView *view, SEL unused) {
    if (!view) return;
    
        @try {
        // Check if this view is a button with "Copy" text
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)view;
            NSString *title = button.currentTitle;
            
            if (title && ([title.lowercaseString containsString:@"copy"] && [title.lowercaseString containsString:@"link"])) {
                NSLog(@"[YTLocalQueue] 🔗 ✅ Found Copy Link button: %@", title);
                
                // Trigger the button
                dispatch_async(dispatch_get_main_queue(), ^{
                    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
                    NSLog(@"[YTLocalQueue] 🔗 Triggered Copy Link button");
                });
            return;
            }
        }
        
        // Check subviews
        for (UIView *subview in view.subviews) {
            ytlp_searchViewHierarchy(subview, unused);
        }
        
    } @catch (NSException *e) {
        // Ignore exceptions in view traversal
    }
}

// Hook share URL generation
static NSURL* ytlp_shareURLGenerator(id self, SEL _cmd) {
    NSLog(@"[YTLocalQueue] 🔗 SHARE URL GENERATOR called on: %@", NSStringFromClass([self class]));
    
    NSURL *url = origShareURLGenerator ? origShareURLGenerator(self, _cmd) : nil;
    
    if (url) {
        NSString *videoId = ytlp_extractVideoIdFromURL(url);
        if (videoId) {
            NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
            BOOL isDifferent = ![videoId isEqualToString:currentVideoId];
            
            NSLog(@"[YTLocalQueue] 🔗 SHARE CAPTURED: videoId=%@, current=%@, different=%@", 
                  videoId, currentVideoId ?: @"nil", isDifferent ? @"YES" : @"NO");
            
            if (isDifferent) {
                NSLog(@"[YTLocalQueue] ✅ CAPTURING video ID from share URL: %@", videoId);
                ytlp_captureVideoTap(self, videoId, nil);
            }
        }
    }
    
    return url;
}

// Hook share action handling
static void ytlp_shareHandler(id self, SEL _cmd, id shareItem) {
    NSLog(@"[YTLocalQueue] 🔗 SHARE HANDLER called on: %@ with item: %@", 
          NSStringFromClass([self class]), NSStringFromClass([shareItem class]));
    
    // Scan the share item for video IDs
    NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
    ytlp_scanForVideoIds(shareItem, @"ShareItem", currentVideoId);
    
    // Look for URL properties in the share item
                @try {
        NSArray *urlProperties = @[@"URL", @"url", @"shareURL", @"link"];
        for (NSString *prop in urlProperties) {
            @try {
                id urlValue = [shareItem valueForKey:prop];
                if ([urlValue isKindOfClass:[NSURL class]]) {
                    NSString *videoId = ytlp_extractVideoIdFromURL((NSURL *)urlValue);
                    if (videoId) {
                        BOOL isDifferent = ![videoId isEqualToString:currentVideoId];
                        NSLog(@"[YTLocalQueue] 🔗 SHARE ITEM URL: videoId=%@, different=%@", videoId, isDifferent ? @"YES" : @"NO");
                        if (isDifferent) {
                            ytlp_captureVideoTap(shareItem, videoId, nil);
                        }
                    }
                } else if ([urlValue isKindOfClass:[NSString class]]) {
                    NSURL *url = [NSURL URLWithString:(NSString *)urlValue];
                    NSString *videoId = ytlp_extractVideoIdFromURL(url);
                    if (videoId) {
                        BOOL isDifferent = ![videoId isEqualToString:currentVideoId];
                        NSLog(@"[YTLocalQueue] 🔗 SHARE ITEM STRING: videoId=%@, different=%@", videoId, isDifferent ? @"YES" : @"NO");
                        if (isDifferent) {
                            ytlp_captureVideoTap(shareItem, videoId, nil);
                        }
                    }
                }
            } @catch (NSException *e) {
                // Ignore exceptions
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[YTLocalQueue] Exception scanning share item: %@", e.reason);
    }
    
    // Call original implementation
    if (origShareHandler) {
        origShareHandler(self, _cmd, shareItem);
    }
}

// Hook pasteboard string setting to catch copied YouTube URLs
static void ytlp_pasteboardSetString(id self, SEL _cmd, NSString *string) {
    NSLog(@"[YTLocalQueue] 📋 PASTEBOARD STRING: %@", string);
    
    if (string && [string containsString:@"youtu"]) {
        NSURL *url = [NSURL URLWithString:string];
        NSString *videoId = ytlp_extractVideoIdFromURL(url);
        if (videoId) {
            NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
            BOOL isDifferent = ![videoId isEqualToString:currentVideoId];
            NSLog(@"[YTLocalQueue] 📋 PASTEBOARD CAPTURED: videoId=%@, different=%@", videoId, isDifferent ? @"YES" : @"NO");
            if (isDifferent) {
                NSLog(@"[YTLocalQueue] ✅ CAPTURING video ID from copy link: %@", videoId);
                ytlp_captureVideoTap(self, videoId, nil);
            }
        }
    }
    
    // Call original implementation
    if (origPasteboardSetString) {
        origPasteboardSetString(self, _cmd, string);
    }
}

// Hook pasteboard URL setting
static void ytlp_pasteboardSetURL(id self, SEL _cmd, NSURL *url) {
    NSLog(@"[YTLocalQueue] 📋 PASTEBOARD URL: %@", url);
    
    NSString *videoId = ytlp_extractVideoIdFromURL(url);
    if (videoId) {
        NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
        BOOL isDifferent = ![videoId isEqualToString:currentVideoId];
        NSLog(@"[YTLocalQueue] 📋 PASTEBOARD URL CAPTURED: videoId=%@, different=%@", videoId, isDifferent ? @"YES" : @"NO");
        if (isDifferent) {
            NSLog(@"[YTLocalQueue] ✅ CAPTURING video ID from copy URL: %@", videoId);
            ytlp_captureVideoTap(self, videoId, nil);
        }
    }
    
    // Call original implementation
    if (origPasteboardSetURL) {
        origPasteboardSetURL(self, _cmd, url);
    }
}

// YTPlayerViewController hooks
typedef void (*PlayerViewDidAppearIMP)(id, SEL, BOOL);
static PlayerViewDidAppearIMP origPlayerViewDidAppear = NULL;

static void ytlp_playerViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (origPlayerViewDidAppear) origPlayerViewDidAppear(self, _cmd, animated);
    ytlp_currentPlayerVC = self; 
    ytlp_presentLaunchAlert(); 
}

// Thumbnail button code removed - not working in current YouTube version

// YTMenuController hooks - Replace existing "Play next in queue" action
typedef NSMutableArray* (*MenuActionsForRenderersIMP)(id, SEL, NSMutableArray*, UIView*, id, BOOL, id);
static MenuActionsForRenderersIMP origMenuActionsForRenderers = NULL;

static NSMutableArray* ytlp_menuActionsForRenderers(id self, SEL _cmd, NSMutableArray *renderers, UIView *fromView, id entry, BOOL shouldLogItems, id firstResponder) {
    NSLog(@"[YTLocalQueue] HOOK CALLED: menuActionsForRenderers");
    NSMutableArray *actions = origMenuActionsForRenderers ? origMenuActionsForRenderers(self, _cmd, renderers, fromView, entry, shouldLogItems, firstResponder) : [NSMutableArray array];
    NSLog(@"[YTLocalQueue] Found %lu actions in menu", (unsigned long)actions.count);
    
    // Try to capture video ID from fromView when menu appears
    NSLog(@"[YTLocalQueue] Checking fromView parameter: %@", fromView ? NSStringFromClass([fromView class]) : @"nil");
    if (fromView) {
        NSLog(@"[YTLocalQueue] ===== ATTEMPTING FROMVIEW VIDEO CAPTURE =====");
    NSString *videoId = nil;
        NSString *title = nil;
        
        // Look in fromView hierarchy for video info - focus on collection view cells
        UIView *currentView = fromView;
        for (int level = 0; level < 15 && currentView; level++) {
            NSLog(@"[YTLocalQueue] fromView level %d: %@", level, NSStringFromClass([currentView class]));
            
            // Special handling for collection view cells where video data is likely stored
            if ([currentView isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
                NSLog(@"[YTLocalQueue] FOUND COLLECTION VIEW CELL at level %d - examining properties", level);
                NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
                
                // COMPREHENSIVE VIDEO ID SCAN of the cell
                ytlp_scanForVideoIds(currentView, [NSString stringWithFormat:@"Cell-Level%d", level], currentVideoId);
                
                @try {
                    // Try AsyncDisplayKit/YouTube specific properties
                    NSArray *cellProperties = @[@"node", @"cellNode", @"displayNode", @"contentNode", 
                                              @"renderer", @"viewModel", @"model", @"data", 
                                              @"entry", @"content", @"videoId", @"video"];
                    
                    for (NSString *property in cellProperties) {
                        @try {
                            id value = [currentView valueForKey:property];
                            if (value) {
                                NSLog(@"[YTLocalQueue] Cell has property '%@': %@", property, NSStringFromClass([value class]));
                                
                                // COMPREHENSIVE VIDEO ID SCAN of the property value
                                ytlp_scanForVideoIds(value, [NSString stringWithFormat:@"Cell-Level%d.%@", level, property], currentVideoId);
                                
                                // Try to extract video info from this property
                                ytlp_extractVideoInfo(value, &videoId, &title);
                if (videoId.length > 0) {
                                    NSLog(@"[YTLocalQueue] SUCCESS: Found video ID in cell property '%@': %@", property, videoId);
                                    ytlp_captureVideoTap(fromView, videoId, title);
                                    break;
                                }
                                
                                // If it's a node/container, try nested properties
                                if ([property containsString:@"node"] || [property containsString:@"Node"]) {
                                    NSArray *nestedProps = @[@"renderer", @"viewModel", @"model", @"data", @"entry", @"videoId"];
                                    for (NSString *nested in nestedProps) {
                                        @try {
                                            id nestedValue = [value valueForKey:nested];
                                            if (nestedValue) {
                                                NSLog(@"[YTLocalQueue] Node has nested property '%@': %@", nested, NSStringFromClass([nestedValue class]));
                                                
                                                // COMPREHENSIVE VIDEO ID SCAN of nested value
                                                ytlp_scanForVideoIds(nestedValue, [NSString stringWithFormat:@"Cell-Level%d.%@.%@", level, property, nested], currentVideoId);
                                                
                                                ytlp_extractVideoInfo(nestedValue, &videoId, &title);
    if (videoId.length > 0) {
                                                    NSLog(@"[YTLocalQueue] SUCCESS: Found video ID in nested property '%@.%@': %@", property, nested, videoId);
                                                    ytlp_captureVideoTap(fromView, videoId, title);
                                                    break;
                                                }
                                            }
                                        } @catch (NSException *e) {
                                            // Ignore exceptions when probing nested properties
                                        }
                                    }
                                    if (videoId.length > 0) break;
                                }
                            }
                        } @catch (NSException *e) {
                            // Ignore exceptions when probing properties
                        }
                    }
                    
                    if (videoId.length > 0) break;
                } @catch (NSException *e) {
                    NSLog(@"[YTLocalQueue] Exception examining collection view cell: %@", e.reason);
                }
            } else {
                // For non-cell views, try the original approach but with broader property search
            @try {
                    NSArray *properties = @[@"renderer", @"entry", @"videoData", @"data", @"model", @"viewModel"];
                    for (NSString *property in properties) {
                        @try {
                            id value = [currentView valueForKey:property];
                            if (value) {
                                NSLog(@"[YTLocalQueue] Level %d (%@) has property '%@': %@", level, NSStringFromClass([currentView class]), property, NSStringFromClass([value class]));
                                ytlp_extractVideoInfo(value, &videoId, &title);
                                if (videoId.length > 0) {
                                    NSLog(@"[YTLocalQueue] fromView found video in %@ at level %d: %@", property, level, videoId);
                                    ytlp_captureVideoTap(fromView, videoId, title);
                                    break;
                                }
                            }
                        } @catch (NSException *e) {
                            // Ignore exceptions when probing
                        }
                    }
                    if (videoId.length > 0) break;
                } @catch (NSException *e) {
                    NSLog(@"[YTLocalQueue] Exception at fromView level %d: %@", level, e.reason);
                }
            }
            
            currentView = [currentView superview];
        }
        
        if (videoId.length == 0) {
            NSLog(@"[YTLocalQueue] fromView video capture failed - no video ID found after checking %d levels", 15);
        }
        NSLog(@"[YTLocalQueue] ===== END FROMVIEW CAPTURE =====");
    } else {
        NSLog(@"[YTLocalQueue] No fromView to analyze for video capture");
    }
    
    @try {
        NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
        
        // COMPREHENSIVE VIDEO ID SCAN of renderers array
        NSLog(@"[YTLocalQueue] ===== SCANNING RENDERERS ARRAY =====");
        for (NSUInteger i = 0; i < renderers.count; i++) {
            id renderer = renderers[i];
            if (renderer) {
                NSLog(@"[YTLocalQueue] Renderer[%lu]: %@", (unsigned long)i, NSStringFromClass([renderer class]));
                ytlp_scanForVideoIds(renderer, [NSString stringWithFormat:@"Renderer[%lu]", (unsigned long)i], currentVideoId);
            }
        }
        
        // COMPREHENSIVE VIDEO ID SCAN of entry parameter
        NSLog(@"[YTLocalQueue] ===== SCANNING ENTRY PARAMETER =====");
        if (entry) {
            NSLog(@"[YTLocalQueue] Entry: %@", NSStringFromClass([entry class]));
            ytlp_scanForVideoIds(entry, @"Entry", currentVideoId);
        }
        
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

            NSLog(@"[YTLocalQueue] Menu action %lu: '%@'", (unsigned long)i, title ?: @"nil");
            
            if (title.length > 0) {
                NSString *t = title.lowercaseString;
                if ([t containsString:@"play next in queue"]) { 
                    queueIndex = i; 
                    NSLog(@"[YTLocalQueue] ✅ FOUND Play next in queue at index %lu", (unsigned long)i);
                    break; 
                }
            }
        }

        // Only replace if we found the existing action - don't add new ones
        if (queueIndex != NSNotFound && queueIndex < actions.count) {
            NSLog(@"[YTLocalQueue] REPLACING Play next in queue action at index %lu", (unsigned long)queueIndex);
            
            NSString *currentVideoId = ytlp_currentPlayerVC ? [ytlp_currentPlayerVC currentVideoID] : nil;
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            BOOL hasRecentTap = (now - ytlp_lastTapTime) < 5.0; // 5 second window
            
            NSLog(@"[YTLocalQueue] ===== VIDEO SOURCE ANALYSIS =====");
            NSLog(@"[YTLocalQueue] Currently playing: %@", currentVideoId ?: @"nil");
            NSLog(@"[YTLocalQueue] Last tapped video: %@ (time: %.1fs ago)", ytlp_lastTappedVideoId ?: @"nil", now - ytlp_lastTapTime);
            NSLog(@"[YTLocalQueue] Has recent tap: %@", hasRecentTap ? @"YES" : @"NO");
            
            // Use captured video ID if available and recent
                NSString *videoId = nil;
            NSString *title = nil;
            
            if (hasRecentTap && ytlp_lastTappedVideoId.length > 0) {
                videoId = ytlp_lastTappedVideoId;
                title = ytlp_lastTappedVideoTitle;
                NSLog(@"[YTLocalQueue] ✅ USING captured video ID: %@", videoId);
                NSLog(@"[YTLocalQueue] Matches current video: %@", [videoId isEqualToString:currentVideoId] ? @"YES" : @"NO");
                            } else {
                    NSLog(@"[YTLocalQueue] ⚠️ No recent video tap captured, trying automatic share extraction");
                    
                    // Automatically trigger share workflow to get the correct video ID
                    videoId = ytlp_extractVideoIdFromAutoShare(self, actions, fromView);
                    
                    if (!videoId && entry) {
                        ytlp_extractVideoInfo(entry, &videoId, &title);
                        NSLog(@"[YTLocalQueue] Final fallback from entry: %@", videoId ?: @"nil");
                    }
                }
            
            NSLog(@"[YTLocalQueue] ===== FINAL RESULT =====");
            NSLog(@"[YTLocalQueue] Selected videoId: %@", videoId ?: @"nil");
            NSLog(@"[YTLocalQueue] Selected title: %@", title ?: @"nil");
            NSLog(@"[YTLocalQueue] Source: %@", hasRecentTap ? @"captured tap" : @"menu context");
            NSLog(@"[YTLocalQueue] ===============================");
            
            id action = actions[queueIndex];
            void (^newHandler)(id) = ^(id a){
                NSLog(@"[YTLocalQueue] MENU HANDLER EXECUTED: Play next in queue tapped!");
                
                if (videoId.length > 0) {
                    NSLog(@"[YTLocalQueue] Adding to queue: videoId=%@, title=%@", videoId, title ?: @"No title");
                    [[YTLPLocalQueueManager shared] addVideoId:videoId title:title];
                    // Update autoplay state since we added a video to queue
                    ytlp_updateAutoplayState();
                    Class HUD = objc_getClass("GOOHUDManagerInternal");
                    Class HUDMsg = objc_getClass("YTHUDMessage");
                    if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"✅ Added: %@", title ?: [videoId substringToIndex:MIN(8, videoId.length)]]]];
                } else {
                    NSLog(@"[YTLocalQueue] FAILED: No video ID to add");
                    Class HUD = objc_getClass("GOOHUDManagerInternal");
                    Class HUDMsg = objc_getClass("YTHUDMessage");
                    if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"❌ Failed to resolve video id"]];
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
    NSLog(@"[YTLocalQueue] HOOK CALLED: defaultSheetAddAction");
    
                @try {
        NSString *title = nil;
        NSString *identifier = nil;
        
        // Try multiple ways to extract title
        @try {
            // Try the methods that work in menuActionsForRenderers
                if ([action respondsToSelector:@selector(button)]) {
                    UIButton *btn = [action button];
                if ([btn isKindOfClass:[UIButton class]]) title = btn.currentTitle;
            }
            if (title.length == 0) title = [action valueForKey:@"_title"];
            if (title.length == 0) title = [action valueForKey:@"title"];
            
            identifier = [action valueForKey:@"_accessibilityIdentifier"];
            if (identifier.length == 0) identifier = [action valueForKey:@"accessibilityIdentifier"];
                } @catch (__unused NSException *e) {}

        NSLog(@"[YTLocalQueue] Action title: '%@', identifier: '%@', class: %@", title ?: @"nil", identifier ?: @"nil", [action class]);

        // Avoid recursion on our own injected actions
        if ([identifier isKindOfClass:[NSString class]] && [identifier hasPrefix:@"ytlp_"]) {
            NSLog(@"[YTLocalQueue] Skipping our own action");
            if (origDefaultSheetAddAction) origDefaultSheetAddAction(self, _cmd, action);
            return;
        }

        BOOL looksLikeQueueNext = NO;
        if ([title isKindOfClass:[NSString class]]) {
            NSString *t = title.lowercaseString;
            NSLog(@"[YTLocalQueue] Checking title: '%@' (lowercase: '%@')", title, t);
            if ([t containsString:@"play next"] && [t containsString:@"queue"]) {
                looksLikeQueueNext = YES;
                NSLog(@"[YTLocalQueue] ✅ MATCH: This looks like Play next in queue!");
            } else if ([t containsString:@"queue"]) {
                NSLog(@"[YTLocalQueue] Contains 'queue' but not 'play next'");
            } else if ([t containsString:@"play"]) {
                NSLog(@"[YTLocalQueue] Contains 'play' but not 'queue'");
            } else {
                NSLog(@"[YTLocalQueue] No match for queue/play keywords");
            }
        } else {
            NSLog(@"[YTLocalQueue] Title is not a string, type: %@", [title class]);
        }
        if (looksLikeQueueNext) {
            NSLog(@"[YTLocalQueue] defaultSheetAddAction: Found Play next in queue action, but video extraction is handled in menuActionsForRenderers");
            Class HUD = objc_getClass("GOOHUDManagerInternal");
            Class HUDMsg = objc_getClass("YTHUDMessage");
            if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"ℹ️ Play next handled in menu"]];
        }
                } @catch (__unused NSException *e) {}

    if (origDefaultSheetAddAction) origDefaultSheetAddAction(self, _cmd, action);
}

// YTAppDelegate hooks
typedef void (*AppDelegateDidBecomeActiveIMP)(id, SEL, UIApplication*);
static AppDelegateDidBecomeActiveIMP origAppDelegateDidBecomeActive = NULL;

static void ytlp_appDelegateDidBecomeActive(id self, SEL _cmd, UIApplication *application) {
    if (origAppDelegateDidBecomeActive) origAppDelegateDidBecomeActive(self, _cmd, application);
    ytlp_presentLaunchAlert(); 
}

// YTSingleVideoController hooks
typedef void (*SingleVideoPlayerRateIMP)(id, SEL, float);
static SingleVideoPlayerRateIMP origSingleVideoPlayerRate = NULL;

static void ytlp_singleVideoPlayerRateDidChange(id self, SEL _cmd, float rate) {
    if (origSingleVideoPlayerRate) origSingleVideoPlayerRate(self, _cmd, rate);
    
    // Since we've disabled YouTube's autoplay, we need to be more proactive about detecting video ends
    if (rate == 0.0f && ytlp_currentPlayerVC) {
        // Check immediately if we're at the end
        CGFloat total = [ytlp_currentPlayerVC currentVideoTotalMediaTime];
        CGFloat current = [ytlp_currentPlayerVC currentVideoMediaTime];
        
        // Since we're forcing loop mode, we need to be more aggressive about detecting video end
        if (total > 0 && current >= (total - 3.0)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
                    if (ytlp_shouldAllowQueueAdvance(@"video stopped near end (loop mode)")) {
                        ytlp_playNextFromQueue();
                    }
                }
            });
        } else {
            // For mid-video pauses, wait longer and be more strict
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
                    if (ytlp_shouldAllowQueueAdvance(@"video paused (loop mode active)")) {
                        ytlp_playNextFromQueue();
                    }
                }
            });
        }
    }
}

// YouTube Autoplay hooks - Override what plays next
typedef id (*AutoplayGetNextVideoIMP)(id, SEL);
static AutoplayGetNextVideoIMP origAutoplayGetNextVideo = NULL;

static id ytlp_autoplayGetNextVideo(id self, SEL _cmd) {
    // If auto-advance is enabled and we have items in queue, override
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        NSString *nextId = [[YTLPLocalQueueManager shared] popNextVideoId];
        if (nextId.length > 0) {
                Class HUD = objc_getClass("GOOHUDManagerInternal");
                Class HUDMsg = objc_getClass("YTHUDMessage");
            if (HUD && HUDMsg) {
                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Redirecting autoplay to local queue"]];
            }
            
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
        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Overriding setLoopMode:%ld -> 2 (force loop to prevent autoplay)", (long)loopMode]]];
        }
        
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
        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Intercepted loop navigation, playing from queue instead"]];
        }
        
        if (ytlp_shouldAllowQueueAdvance(@"loop navigation intercepted")) {
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
        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Intercepted loop execution, playing from queue instead"]];
        }
        
        if (ytlp_shouldAllowQueueAdvance(@"loop execution intercepted")) {
            ytlp_playNextFromQueue();
            return;
        }
    }
    
    // Fall back to original execution (loop)
    if (origAutonavExecuteNavigation) origAutonavExecuteNavigation(self, _cmd);
}

// Hook init to disable autoplay from the start when we have queue items
typedef id (*AutonavInitIMP)(id, SEL, id);
static AutonavInitIMP origAutonavInit = NULL;

static id ytlp_autonavInit(id self, SEL _cmd, id parentResponder) {
    self = origAutonavInit ? origAutonavInit(self, _cmd, parentResponder) : nil;
    if (self) {
        // If we have queue items, immediately disable autoplay like YouLoop does
        if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
            Class HUD = objc_getClass("GOOHUDManagerInternal");
            Class HUDMsg = objc_getClass("YTHUDMessage");
            if (HUD && HUDMsg) {
                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"YTAutoplayAutonavController init: disabling autoplay for local queue"]];
            }
            
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
                        Class HUD = objc_getClass("GOOHUDManagerInternal");
                        Class HUDMsg = objc_getClass("YTHUDMessage");
                        if (HUD && HUDMsg) {
                            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Updated autoplay: forced loop mode to prevent other videos"]];
                        }
                    } else {
                        // Re-enable normal autoplay when queue is empty (mode 0 = no loop, autoplay enabled)
                        [(YTAutoplayAutonavController *)autonavController setLoopMode:0];
                        Class HUD = objc_getClass("GOOHUDManagerInternal");
                        Class HUDMsg = objc_getClass("YTHUDMessage");
                        if (HUD && HUDMsg) {
                            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Updated autoplay: re-enabled normal autoplay (no queue items)"]];
                        }
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
    
    // If we're within 3 seconds of the end, immediately play from queue to prevent loop
    if (total > 10.0 && current >= (total - 3.0)) {
        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Proactive end detected: %.1f/%.1f", current, total]]];
        }
        
        if (ytlp_shouldAllowQueueAdvance(@"proactive end monitoring")) {
            ytlp_stopEndMonitoring(); // Stop timer before playing next
            ytlp_playNextFromQueue();
        }
    }
}

static void ytlp_startEndMonitoring(void) {
    ytlp_stopEndMonitoring(); // Stop any existing timer
    
    if (YTLP_AutoAdvanceEnabled() && ![[YTLPLocalQueueManager shared] isEmpty]) {
        // Use a block-based timer
        ytlp_endCheckTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            ytlp_checkVideoEnd(timer);
        }];
        
        Class HUD = objc_getClass("GOOHUDManagerInternal");
        Class HUDMsg = objc_getClass("YTHUDMessage");
        if (HUD && HUDMsg) {
            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Started proactive video end monitoring"]];
        }
    }
}

static void ytlp_stopEndMonitoring(void) {
    if (ytlp_endCheckTimer) {
        [ytlp_endCheckTimer invalidate];
        ytlp_endCheckTimer = nil;
    }
}

// YTMainAppVideoPlayerOverlayViewController hooks
typedef void (*OverlayViewDidLoadIMP)(id, SEL);
static OverlayViewDidLoadIMP origOverlayViewDidLoad = NULL;

static void ytlp_overlayViewDidLoad(id self, SEL _cmd) {
    if (origOverlayViewDidLoad) origOverlayViewDidLoad(self, _cmd);
    
    id overlayView = [self videoPlayerOverlayView];
    id controls = [overlayView controlsOverlayView];
    if (!controls) return;

    @try {
        Class ControlsClass = objc_getClass("YTMainAppControlsOverlayView");
        CGFloat padding = 0;
        if (ControlsClass && [ControlsClass respondsToSelector:@selector(topButtonAdditionalPadding)]) {
            padding = [ControlsClass topButtonAdditionalPadding];
        }
        
        SEL buttonSel = @selector(buttonWithImage:accessibilityLabel:verticalContentPadding:);
        if ([controls respondsToSelector:buttonSel]) {
            UIImage *addImg = YTLPIconAddToQueue();
            id addBtn = [controls buttonWithImage:addImg accessibilityLabel:@"Add to local queue" verticalContentPadding:padding];
        [addBtn addTarget:self action:@selector(ytlp_addToQueueTapped:) forControlEvents:UIControlEventTouchUpInside];
        [controls addSubview:addBtn];
            
            UIImage *queueImg = YTLPIconQueueList();
            id queueBtn = [controls buttonWithImage:queueImg accessibilityLabel:@"Local queue" verticalContentPadding:padding];
        [queueBtn addTarget:self action:@selector(ytlp_showQueueTapped:) forControlEvents:UIControlEventTouchUpInside];
        [controls addSubview:queueBtn];
        }
    } @catch (__unused NSException *e) {}
    
    // Start monitoring for video end when overlay loads (indicates new video starting)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ytlp_startEndMonitoring();
    });
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
        // Update autoplay state since we added a video to queue
        ytlp_updateAutoplayState();
        if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Added to local queue"]];
    } else {
        if (HUD && HUDMsg) [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Unable to get video ID"]];
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
                    NSLog(@"[YTLocalQueue] Hooked UIButton sendActionsForControlEvents to capture video taps");
                }
            }

            // Hook AsyncDisplayKit collection view cell selection to capture list interactions
            Class ASCollectionViewCellClass = NSClassFromString(@"_ASCollectionViewCell");
            if (ASCollectionViewCellClass) {
                Method m = class_getInstanceMethod(ASCollectionViewCellClass, @selector(setSelected:));
                if (m && !origCollectionViewCellSetSelected) {
                    origCollectionViewCellSetSelected = (CollectionViewCellSetSelectedIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_collectionViewCellSetSelected);
                    NSLog(@"[YTLocalQueue] Hooked _ASCollectionViewCell setSelected to capture list interactions");
                }
            }

            // Hook share functionality to capture video IDs from share URLs
            NSArray *shareClasses = @[@"YTSharePanelController", @"YTShareService", @"YTShareItemService", 
                                     @"YTVideoShareItemProvider", @"YTShareUtils", @"YTCopyLinkShareItemProvider"];
            
            for (NSString *className in shareClasses) {
                Class shareClass = objc_getClass([className UTF8String]);
                if (shareClass) {
                    NSLog(@"[YTLocalQueue] Found share class: %@", className);
                    
                    // Try to hook various share-related methods
                    NSArray *selectors = @[@"shareURL", @"generateShareURL", @"copyLinkURL", @"videoURL", 
                                          @"shareWithItem:", @"handleShareAction:", @"presentShareSheet:"];
                    
                    for (NSString *selName in selectors) {
                        SEL selector = NSSelectorFromString(selName);
                        Method method = class_getInstanceMethod(shareClass, selector);
                        
                        if (method) {
                            NSLog(@"[YTLocalQueue] Found share method: %@.%@", className, selName);
                            
                            // Hook URL generation methods
                            if ([selName containsString:@"URL"] || [selName containsString:@"url"]) {
                                if (!origShareURLGenerator) {
                                    origShareURLGenerator = (ShareURLGeneratorIMP)method_getImplementation(method);
                                    method_setImplementation(method, (IMP)ytlp_shareURLGenerator);
                                    NSLog(@"[YTLocalQueue] ✅ Hooked %@.%@ for URL generation", className, selName);
                                }
                            }
                            // Hook action handling methods
                            else if ([selName containsString:@"share"] || [selName containsString:@"Share"]) {
                                if (!origShareHandler) {
                                    origShareHandler = (ShareHandlerIMP)method_getImplementation(method);
                                    method_setImplementation(method, (IMP)ytlp_shareHandler);
                                    NSLog(@"[YTLocalQueue] ✅ Hooked %@.%@ for share handling", className, selName);
                                }
                            }
                        }
                    }
                }
            }

            // Hook UIPasteboard to catch "Copy link" actions
            Class pasteboardClass = objc_getClass("UIPasteboard");
            if (pasteboardClass) {
                Method setStringMethod = class_getInstanceMethod(pasteboardClass, @selector(setString:));
                Method setURLMethod = class_getInstanceMethod(pasteboardClass, @selector(setURL:));
                
                if (setStringMethod && !origPasteboardSetString) {
                    origPasteboardSetString = (PasteboardSetStringIMP)method_getImplementation(setStringMethod);
                    method_setImplementation(setStringMethod, (IMP)ytlp_pasteboardSetString);
                    NSLog(@"[YTLocalQueue] ✅ Hooked UIPasteboard setString to capture copy link");
                }
                
                if (setURLMethod && !origPasteboardSetURL) {
                    origPasteboardSetURL = (PasteboardSetURLIMP)method_getImplementation(setURLMethod);
                    method_setImplementation(setURLMethod, (IMP)ytlp_pasteboardSetURL);
                    NSLog(@"[YTLocalQueue] ✅ Hooked UIPasteboard setURL to capture copy link");
                }
            }

            // Skip UITapGestureRecognizer hook for now - causing exceptions
            // Focus on UIButton and fromView capture instead
            NSLog(@"[YTLocalQueue] Skipping UITapGestureRecognizer hook - using fromView and UIButton capture instead");

            // Hook YTSingleVideoController
            Class SingleVideoController = objc_getClass("YTSingleVideoController");
            if (SingleVideoController) {
                Method m = class_getInstanceMethod(SingleVideoController, @selector(playerRateDidChange:));
                if (m && !origSingleVideoPlayerRate) {
                    origSingleVideoPlayerRate = (SingleVideoPlayerRateIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_singleVideoPlayerRateDidChange);
                }
            }

            // Hook the real YouTube Autoplay Controller (found from YouLoop tweak)
            Class YTAutoplayAutonavControllerClass = objc_getClass("YTAutoplayAutonavController");
            if (YTAutoplayAutonavControllerClass) {
                Class HUD = objc_getClass("GOOHUDManagerInternal");
                Class HUDMsg = objc_getClass("YTHUDMessage");
                if (HUD && HUDMsg) {
                    [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Found YTAutoplayAutonavController, installing hooks"]];
                }
                
                // Hook loopMode getter to completely disable autoplay when we have queue items
                Method loopModeMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(loopMode));
                if (loopModeMethod && !origAutonavLoopMode) {
                    origAutonavLoopMode = (AutonavLoopModeIMP)method_getImplementation(loopModeMethod);
                    method_setImplementation(loopModeMethod, (IMP)ytlp_autonavLoopMode);
                    if (HUD && HUDMsg) {
                        [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Hooked YTAutoplayAutonavController::loopMode"]];
                    }
                }
                
                // Hook init to disable autoplay from the start (like YouLoop approach)
                Method initMethod = class_getInstanceMethod(YTAutoplayAutonavControllerClass, @selector(initWithParentResponder:));
                if (initMethod && !origAutonavInit) {
                    origAutonavInit = (AutonavInitIMP)method_getImplementation(initMethod);
                    method_setImplementation(initMethod, (IMP)ytlp_autonavInit);
                    if (HUD && HUDMsg) {
                        [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Hooked YTAutoplayAutonavController::initWithParentResponder:"]];
                    }
                }
                
                // Hook specific safe methods and try to find loop interception points
                unsigned int methodCount;
                Method *methods = class_copyMethodList(YTAutoplayAutonavControllerClass, &methodCount);
                NSMutableString *methodNames = [NSMutableString stringWithString:@"YTAutoplayAutonavController methods: "];
                
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL selector = method_getName(methods[i]);
                    NSString *selectorName = NSStringFromSelector(selector);
                    [methodNames appendFormat:@"%@, ", selectorName];
                    
                    // Hook setLoopMode
                    if ([selectorName isEqualToString:@"setLoopMode:"] && !origAutonavSetLoopMode) {
                        origAutonavSetLoopMode = (AutonavSetLoopModeIMP)method_getImplementation(methods[i]);
                        method_setImplementation(methods[i], (IMP)ytlp_autonavSetLoopMode);
                        if (HUD && HUDMsg) {
                            [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"Hooked YTAutoplayAutonavController::setLoopMode:"]];
                        }
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
                            if (HUD && HUDMsg) {
                                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Hooked loop navigation: %@", selectorName]]];
                            }
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
                            if (HUD && HUDMsg) {
                                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Hooked loop execution: %@", selectorName]]];
                            }
                        }
                    }
                }
                
                if (HUD && HUDMsg) {
                    // Only show first 200 characters to avoid too long messages
                    NSString *truncatedNames = methodNames.length > 200 ? 
                        [[methodNames substringToIndex:200] stringByAppendingString:@"..."] : methodNames;
                    [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:truncatedNames]];
                }
                
                free(methods);
            } else {
                Class HUD = objc_getClass("GOOHUDManagerInternal");
                Class HUDMsg = objc_getClass("YTHUDMessage");
                if (HUD && HUDMsg) {
                    [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:@"YTAutoplayAutonavController NOT found"]];
                }
            }
            
            // Skip YTAutonavEndscreenController hooking for now - too risky with unknown method signatures
            
            // Also try generic autoplay classes with debug info
            NSArray *autoplayClasses = @[
                @"YTAutoplayController",
                @"YTPlayerAutoplayController", 
                @"YTUpNextAutoplayController",
                @"YTAutoplayManager",
                @"YTWatchNextAutoplayController"
            ];
            
            NSMutableString *foundClasses = [NSMutableString stringWithString:@"Found autoplay classes: "];
            for (NSString *className in autoplayClasses) {
                Class AutoplayClass = objc_getClass([className UTF8String]);
                if (AutoplayClass) {
                    [foundClasses appendFormat:@"%@, ", className];
                    
                    // List methods for debugging
                    unsigned int methodCount;
                    Method *methods = class_copyMethodList(AutoplayClass, &methodCount);
                    for (unsigned int i = 0; i < methodCount; i++) {
                        SEL selector = method_getName(methods[i]);
                        NSString *selectorName = NSStringFromSelector(selector);
                        
                        // Try to hook autoplayEndpoint method
                        if ([selectorName isEqualToString:@"autoplayEndpoint"] && !origAutoplayGetNextVideo) {
                            origAutoplayGetNextVideo = (AutoplayGetNextVideoIMP)method_getImplementation(methods[i]);
                            method_setImplementation(methods[i], (IMP)ytlp_autoplayGetNextVideo);
                            Class HUD = objc_getClass("GOOHUDManagerInternal");
                            Class HUDMsg = objc_getClass("YTHUDMessage");
                            if (HUD && HUDMsg) {
                                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:[NSString stringWithFormat:@"Hooked %@::%@", className, selectorName]]];
                            }
                        }
                    }
                    free(methods);
                }
            }
            
            Class HUD = objc_getClass("GOOHUDManagerInternal");
            Class HUDMsg = objc_getClass("YTHUDMessage");
            if (HUD && HUDMsg) {
                [[HUD sharedInstance] showMessageMainThread:[HUDMsg messageWithText:foundClasses]];
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
            }

            if (allInstalled) {
                NSLog(@"YTLocalQueue: Tweak hooks installed successfully");
                return;
            }
            if (--attemptsRemaining <= 0) {
                NSLog(@"YTLocalQueue: Tweak target classes not found (timed out)");
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