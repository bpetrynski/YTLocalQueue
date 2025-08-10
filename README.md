# YTLocalQueue

A YouTube tweak for creating and managing a local video queue that works with LiveContainer.

## Features

- Add videos to a local queue from context menus.
- Auto-advance to the next video when the current video ends.
- A queue management interface to view, reorder, and remove videos.
- Settings panel integration within YouTube's settings.

## How It Works

This tweak is designed to run in environments like LiveContainer without relying on traditional jailbreak hooking libraries like Cydia Substrate. It works by using pure Objective-C runtime method swizzling.

### Adding to Queue
When you long-press a video and tap "Play next in queue," the tweak intercepts this action. Instead of using YouTube's native queue, it performs a complex analysis of the tapped UI element and its associated data to find the video's unique ID. This ID is then added to a local queue managed by the tweak.

### Auto-Advance
To automatically play the next video, `YTLocalQueue` has to overcome YouTube's own autoplay system. It achieves this using a clever trick:
1.  **Disabling Native Autoplay**: When the local queue is active, the tweak forces the YouTube player into "loop" mode. This effectively disables YouTube's default autoplay, preventing it from playing recommended videos after the current one finishes.
2.  **Manual End Detection**: With native autoplay disabled, the tweak starts a timer that continuously monitors the playback time of the current video.
3.  **Playing the Next Video**: When the timer detects that the video is about to end, it retrieves the next video from the local queue and programmatically starts playback.

This entire process is managed carefully to feel seamless, but its complexity leads to some of the known issues listed below.

## Building

To build the dylib for LiveContainer (rootless):

```bash
make package THEOS_PACKAGE_SCHEME=rootless
```

The resulting dylib will be in the `packages/` directory.

## Usage

1.  Build the dylib using the command above.
2.  Copy the resulting `.deb` file to your device.
3.  Extract the dylib from the `.deb` file.
4.  Load the dylib in LiveContainer.
5.  Access settings through YouTube Settings > Local Queue.

## Settings

- **Auto advance**: Automatically play the next item from the local queue when a video ends.
- **Open Local Queue**: View and manage your queue.
- **Clear Local Queue**: Remove all items from the queue.

## Known Issues

- **"Play next in queue" can be unreliable**: Sometimes, when you select "Play next in queue" on a video thumbnail, the tweak fails to identify the *selected* video. As a fallback, it adds the *currently playing* video to the queue instead. This is a high-priority issue to be fixed.
- **Auto-advance doesn't work with screen off**: The auto-advance feature relies on a timer that may not run reliably when the app is backgrounded or the screen is locked. This means the queue will not advance to the next video if you are not actively watching.
- **Basic UI**: The user interface for the queue and player buttons is functional but very basic. The visual design and user experience could be significantly improved.

## Future Improvements

- Rework the video ID detection logic to be more reliable.
- Implement a more robust background-compatible method for auto-advance.
- Redesign the queue management UI for a better user experience.
- Make it work with languages other than English
- Make it work with YouTube Premium