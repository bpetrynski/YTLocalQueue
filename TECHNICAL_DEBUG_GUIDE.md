# YTLocalQueue Technical Debugging Guide

This document describes the debugging process used to find video IDs in YouTube's iOS app hierarchy. It serves as a reference for future tweak development.

## The Problem

When implementing context menu actions (like "Play Next in Queue"), the challenge is extracting the correct video ID from the tapped video cell, not the currently playing video.

YouTube's iOS app uses:
- **AsyncDisplayKit (Texture)** for UI rendering (`ASDisplayNode`, `_ASDisplayView`)
- **Protocol Buffers (GPB)** for data serialization
- **Element-based architecture** (`ELM*` classes)
- **Complex view hierarchies** with multiple levels of controllers

## Key Classes in the Hierarchy

When a user long-presses on a video thumbnail, the view hierarchy looks like:

```
_ASDisplayView (level 0)
└── _ASDisplayView (level 1)
    └── _ASDisplayView (level 2)
        └── _ASDisplayView (level 3)
            └── UIView (level 4)
                └── _ASCollectionViewCell (level 5)
                    └── YTVideoWithContextNode ← The key node!
                        └── YTAsyncCollectionView
                            └── YTWatchNextView
                                └── ...
```

### Important Classes

| Class | Description |
|-------|-------------|
| `YTVideoWithContextNode` | ASDisplayNode subclass representing a video cell |
| `YTVideoElementCellController` | Controller for the video cell element |
| `YTCellController` | Base controller class with `entry` property |
| `YTIElementRenderer` | Protobuf message containing video data |
| `ELMNodeController` | Element framework node controller |

## The Solution Path

### Step 1: Accessing the Node from the View

```objc
// Get the node from _ASCollectionViewCell
id node = nil;
if ([view respondsToSelector:@selector(node)]) {
    node = [view valueForKey:@"node"];
}
```

### Step 2: Finding the Cell Controller

The video data is stored in the `parentResponder` chain:

```objc
// YTVideoWithContextNode -> parentResponder -> YTVideoElementCellController
id parentResponder = [node valueForKey:@"parentResponder"];
// Class: YTVideoElementCellController
```

### Step 3: Accessing the Entry (Protobuf Data)

The `entry` property contains the protobuf data:

```objc
// YTVideoElementCellController inherits from YTCellController
// YTCellController has the 'entry' property
id entry = [parentResponder valueForKey:@"entry"];
// Class: YTIElementRenderer (a GPBMessage subclass)
```

### Step 4: Extracting Video ID from Protobuf

The `YTIElementRenderer` is a Protocol Buffer message. The video ID is NOT directly accessible as a property - it's embedded in the binary protobuf data.

**Key Discovery:** The video ID appears in thumbnail URLs within the protobuf description:

```
https://i.ytimg.com/vi/VIDEO_ID_HERE/hqdefault.jpg
```

Extract using regex:

```objc
NSString *desc = [entry description];
NSRegularExpression *regex = [NSRegularExpression
    regularExpressionWithPattern:@"i\\.ytimg\\.com/vi/([a-zA-Z0-9_-]{11})/"
    options:0 error:nil];
NSTextCheckingResult *match = [regex firstMatchInString:desc 
    options:0 range:NSMakeRange(0, desc.length)];
if (match.numberOfRanges > 1) {
    NSString *videoId = [desc substringWithRange:[match rangeAtIndex:1]];
}
```

## Debugging Techniques

### 1. File-Based Logging

iOS privacy features hide NSLog values with `<private>`. Use file-based logging:

```objc
static NSString *debugLogPath = nil;

static void debugLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    // Get Documents directory
    if (!debugLogPath) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        debugLogPath = [paths.firstObject 
            stringByAppendingPathComponent:@"debug.log"];
    }
    
    // Append to file
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:debugLogPath];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:debugLogPath 
            contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:debugLogPath];
    }
    [handle seekToEndOfFile];
    [handle writeData:[[message stringByAppendingString:@"\n"] 
        dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}
```

### 2. Debug Video ID Search Mode

Create a settings option to set a specific video ID to search for, then scan all objects and log where that ID is found:

```objc
static void deepSearchForVideoId(id obj, NSString *targetVideoId, 
    NSString *currentPath, int depth, NSMutableSet *visited) {
    
    if (!obj || depth <= 0) return;
    
    // Prevent infinite loops
    NSValue *objPtr = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([visited containsObject:objPtr]) return;
    [visited addObject:objPtr];
    
    NSString *className = NSStringFromClass([obj class]);
    
    // For protobuf classes, check description
    if ([className hasPrefix:@"YTI"] || [className hasPrefix:@"GPB"]) {
        NSString *desc = [obj description];
        if ([desc containsString:targetVideoId]) {
            NSLog(@"*** FOUND at path: %@", currentPath);
            NSLog(@"Class: %@", className);
            // Log context around the ID
        }
        return;
    }
    
    // Recursively check known safe properties
    NSArray *safeProps = @[@"entry", @"model", @"parentResponder", @"controller"];
    for (NSString *prop in safeProps) {
        if ([obj respondsToSelector:NSSelectorFromString(prop)]) {
            id val = [obj valueForKey:prop];
            NSString *newPath = [NSString stringWithFormat:@"%@.%@", currentPath, prop];
            deepSearchForVideoId(val, targetVideoId, newPath, depth - 1, visited);
        }
    }
}
```

### 3. Dangerous Classes to Avoid

These classes will crash if you try to enumerate their properties:

```objc
static NSSet *dangerousClasses = [NSSet setWithArray:@[
    // Core Animation / UI
    @"CALayer", @"UIView", @"UIViewController", @"UIColor", @"UIImage",
    
    // AsyncDisplayKit
    @"ASDisplayNode", @"_ASDisplayView", @"ASTextNode", @"ASImageNode",
    
    // Element framework
    @"ELMElement", @"ELMContainerElement", @"ELMTextElement",
    
    // Protobuf internals
    @"GPBDescriptor", @"GPBFieldDescriptor", @"GPBExtensionDescriptor"
]];
```

Also skip by prefix:
- `CA*` - Core Animation
- `UI*` - UIKit
- `_UI*` - Private UIKit
- `AS*` - AsyncDisplayKit
- `ELM*` - Element framework
- `GPB*` - Protocol Buffers (except for checking description)

### 4. Video ID Validation

Not every 11-character string is a video ID:

```objc
static BOOL looksLikeVideoId(NSString *str) {
    if (!str || str.length != 11) return NO;
    
    // Exclude known false positives
    static NSSet *excluded = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excluded = [NSSet setWithArray:@[
            @"YTVideoNode", @"ELMCellNode", @"ELMElement", @"ASTextNode"
        ]];
    });
    if ([excluded containsObject:str]) return NO;
    
    // Must contain at least one digit
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([str rangeOfCharacterFromSet:digits].location == NSNotFound) return NO;
    
    // Only valid characters
    NSCharacterSet *valid = [NSCharacterSet 
        characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    NSCharacterSet *strChars = [NSCharacterSet characterSetWithCharactersInString:str];
    return [valid isSupersetOfSet:strChars];
}
```

## Complete Property Path

The final working path to get the video ID from a tapped video cell:

```
View Hierarchy:
_ASCollectionViewCell
    ↓ .node
YTVideoWithContextNode
    ↓ .parentResponder
YTVideoElementCellController (inherits from YTCellController)
    ↓ .entry
YTIElementRenderer (GPBMessage)
    ↓ .description (regex match thumbnail URL)
Video ID: extracted from "i.ytimg.com/vi/VIDEO_ID/"
```

## Regex Patterns for Video ID Extraction

In order of reliability:

1. **Thumbnail URL** (most reliable):
   ```regex
   i\.ytimg\.com/vi/([a-zA-Z0-9_-]{11})/
   ```

2. **videoId field** (if directly accessible):
   ```regex
   videoId:\s*"([a-zA-Z0-9_-]{11})"
   ```

3. **Watch endpoint**:
   ```regex
   watchEndpoint\s*\{[^}]*videoId:\s*"([a-zA-Z0-9_-]{11})"
   ```

## Lessons Learned

1. **Don't trust property introspection** - Many YouTube/Texture classes crash when you try to enumerate properties via runtime

2. **Use targeted property access** - Only access known safe properties like `entry`, `model`, `parentResponder`

3. **File-based logging is essential** - iOS hides dynamic values in logs

4. **Protobuf data is opaque** - You can't directly access nested protobuf fields; parse the description string instead

5. **Thumbnail URLs are reliable** - YouTube embeds video IDs in thumbnail URLs, which appear in protobuf descriptions

6. **Debug mode with specific search** - Let users paste a video URL and search for that specific ID to find the exact path

## Tools Used

- **Theos** - Build system for iOS tweaks
- **NSLog + file logging** - Debugging output
- **Objective-C runtime** - `class_copyPropertyList`, `objc_msgSend`
- **Regex** - Pattern matching in protobuf descriptions
- **KVC** - `valueForKey:` for property access

## Queue Progression & Autoplay Interception

### The Challenge

To automatically play the next video from the local queue, we must override YouTube's native autoplay system. YouTube uses a sophisticated autoplay controller that decides what to play next based on recommendations, playlists, etc.

### The YTAutoplayAutonavController

YouTube's autoplay is managed by `YTAutoplayAutonavController`. Key methods:

| Method | Purpose |
|--------|---------|
| `loopMode` | Returns current loop mode (0=off, 1=one, 2=all) |
| `setLoopMode:` | Sets loop mode |
| `initWithParentResponder:` | Initializes the controller |

### The Loop Mode Trick

To prevent YouTube from playing recommended videos, we force loop mode = 2:

```objc
// When we have queue items, force loop mode
if (hasQueueItems && autoAdvanceEnabled) {
    [autonavController setLoopMode:2];
}
```

This makes YouTube loop the current video instead of playing recommendations. We then detect the loop and play from our queue instead.

### Loop Detection Problem

**Issue:** When loop mode is active and the video ends, YouTube may just seek back to position 0 without calling any navigation methods. Our hooks on `performNavigation` or `executeNavigation` may never fire.

**Solution:** Use position-based loop detection:

```objc
static CGFloat lastKnownPosition = 0;
static CGFloat lastKnownTotal = 0;

static void checkVideoEnd(void) {
    CGFloat current = [playerVC currentVideoMediaTime];
    CGFloat total = [playerVC currentVideoTotalMediaTime];
    
    // Detect loop: position jumped from near-end to near-start
    BOOL wasNearEnd = lastKnownPosition >= (lastKnownTotal - 10.0);
    BOOL nowNearStart = current < 5.0;
    
    if (wasNearEnd && nowNearStart && fabs(total - lastKnownTotal) < 1.0) {
        // Loop detected! Advance queue
        playNextFromQueue();
    }
    
    lastKnownPosition = current;
    lastKnownTotal = total;
}
```

### The lastPlayedVideoId Bug

**Bug:** Originally, `lastPlayedVideoId` was set to the current video (the one that just finished):

```objc
// WRONG - causes looping
lastPlayedVideoId = [playerVC currentVideoID]; // Video A
```

Then the "same video" check would block:
1. Video A ends, we pop Video B and navigate
2. Navigation doesn't complete instantly
3. Loop fires again, `currentVideoID` is still A
4. Check: `currentVideoID (A) == lastPlayedVideoId (A)` → BLOCKED!
5. Video A loops forever

**Fix:** Set `lastPlayedVideoId` to the NEXT video (the one we're navigating to):

```objc
// CORRECT
lastPlayedVideoId = nextId; // Video B (where we're going)
```

Now when Video B ends:
- `currentVideoID` = B
- `lastPlayedVideoId` = B  
- They match, but that's expected - it means we successfully navigated

### Double-Tap Skip Issue

**Issue:** When user double-taps to skip forward to near the end:
1. Video ends quickly
2. Loop happens before our timer detects we're near end
3. Position resets to 0
4. Our `currentTime < 15.0` check blocks the advance

**Fix:** Create a simpler check for loop interceptions:

```objc
// For loop interceptions, only check cooldown
// The loop itself proves the video ended
static BOOL shouldAllowLoopIntercept(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return (now - lastQueueAdvanceTime >= 3.0);
}
```

### Navigation Failure Recovery

Navigation is fire-and-forget - we can't know if it succeeded. Add a recovery mechanism:

```objc
// After attempting navigation, check if it worked
dispatch_after(8.0 seconds, ^{
    NSString *currentVideoId = [playerVC currentVideoID];
    
    // If still on previous video (not the one we navigated to)
    if ([currentVideoId isEqualToString:previousVideoId]) {
        // Navigation failed - re-add video to front of queue
        [queueManager insertVideoId:nextId title:nextTitle atIndex:0];
    }
});
```

### Timer Configuration

Run the end-check timer frequently for responsive loop detection:

```objc
// Check every 0.5s for faster loop detection
[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^{
    checkVideoEnd();
}];
```

### Key Classes for Autoplay

| Class | Purpose |
|-------|---------|
| `YTAutoplayAutonavController` | Main autoplay controller |
| `YTMainAppVideoPlayerOverlayViewController` | Has `_autonavController` property |
| `YTPlayerViewController` | Player with `currentVideoID`, `currentVideoMediaTime` |

### Accessing the Autoplay Controller

```objc
id overlay = [playerVC activeVideoPlayerOverlay];
if ([overlay isKindOfClass:YTMainAppVideoPlayerOverlayViewControllerClass]) {
    id autonavController = [overlay valueForKey:@"_autonavController"];
    if ([autonavController respondsToSelector:@selector(setLoopMode:)]) {
        [autonavController setLoopMode:2]; // Force loop
    }
}
```

## Currently Playing Tracking

### UI Enhancement: Now Playing Section

The queue UI can show a "Now Playing" section separate from "Up Next":

```objc
// In LocalQueueManager
@property NSDictionary *currentlyPlayingItem;

- (void)setCurrentlyPlayingVideoId:(NSString *)videoId title:(NSString *)title {
    _currentlyPlayingItem = @{ @"videoId": videoId, @"title": title ?: @"" };
}
```

Update this when advancing the queue:

```objc
static void playNextFromQueue(void) {
    NSDictionary *item = [queueManager popNextItem];
    
    // Track as currently playing
    [queueManager setCurrentlyPlayingVideoId:item[@"videoId"] 
                                       title:item[@"title"]];
    
    // Navigate to video...
}
```

## Future Improvements

- Cache the video ID extraction logic for performance
- Handle edge cases (shorts, live streams, premieres)
- Consider hooking deeper into YouTube's action handlers instead of parsing protobufs
- Add skip controls for queue navigation
- Persist currently playing state across app restarts
