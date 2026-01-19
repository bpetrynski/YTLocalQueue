# YTLocalQueue

A YouTube tweak for creating and managing a local video queue that works with LiveContainer.

## Features

- Add videos to a local queue from context menus
- Auto-advance to the next video when the current video ends
- Background playback support - queue advances without waking the screen
- Lock screen/Control Center next button support
- Queue management interface to view, reorder, and remove videos
- Settings panel integration within YouTube's settings

## How It Works

This tweak is designed to run in environments like LiveContainer without relying on traditional jailbreak hooking libraries like Cydia Substrate. It works by using pure Objective-C runtime method swizzling.

### Adding to Queue

When you long-press a video and tap "Add to Local Queue", the tweak intercepts this action and extracts the video ID from the UI element. The video is then added to a local queue managed by the tweak.

### Auto-Advance

The tweak intercepts YouTube's native autonav/autoplay system:

1. **Endpoint Interception**: Hooks `nextEndpointForAutonav`, `nextEndpointForAutoplay`, `autonavEndpoint`, and `autoplayEndpoint` to return the next queue video instead of YouTube's recommendation
2. **Playback Hooks**: Hooks `playNext`, `playAutonav`, and `playAutoplay` to consume queue items when playback transitions
3. **Background Support**: Uses YouTube's native autonav mechanism for background playback, keeping the screen off
4. **Seek Detection**: Detects when user scrubs to the end of a video and advances the queue

### Lock Screen Controls

The tweak registers with `MPRemoteCommandCenter` to handle the next track button from the lock screen and Control Center. When pressed, it triggers YouTube's native autonav which uses the hooked endpoints to play from the queue.

## Building

### Requirements

You need YouTube headers. Place them in a `Headers/` directory:

```
Headers/
  YouTubeHeader/
    YTPlayerViewController.h
    YTAutoplayAutonavController.h
    ... (other headers)
```

Headers can be obtained from [theos/headers](https://github.com/theos/headers) or generated using class-dump.

### Build Command

```bash
make package THEOS_PACKAGE_SCHEME=rootless
```

The resulting dylib will be in the `packages/` directory.

## Usage

1. Build the dylib using the command above
2. Copy the resulting `.deb` file to your device
3. Extract the dylib from the `.deb` file
4. Load the dylib in LiveContainer
5. Access settings through YouTube Settings > Local Queue

## Settings

- **Auto advance**: Automatically play the next item from the local queue when a video ends
- **Open Local Queue**: View and manage your queue
- **Clear Local Queue**: Remove all items from the queue

## Known Issues

- Queue advances may not work correctly in all scenarios
- Some edge cases with video end detection may cause issues

## License

MIT
