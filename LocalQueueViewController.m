// Tweaks/YTLocalQueue/LocalQueueViewController.m
#import "LocalQueueViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "LocalQueueManager.h"
#import "Headers/YouTubeHeader/YTUIUtils.h"
#import "Headers/YouTubeHeader/YTICommand.h"
#import "Headers/YouTubeHeader/YTCoWatchWatchEndpointWrapperCommandHandler.h"
#import "Headers/YouTubeHeader/GOOHUDManagerInternal.h"
#import "Headers/YouTubeHeader/YTHUDMessage.h"

@interface YTICommand (YTLocalQueue)
+ (id)watchNavigationEndpointWithVideoID:(NSString *)videoId;
@end

typedef NS_ENUM(NSInteger, YTLPQueueSection) {
    YTLPQueueSectionNowPlaying = 0,
    YTLPQueueSectionUpNext = 1
};

@interface YTLPLocalQueueViewController ()
@property (nonatomic, strong) UIBarButtonItem *clearButton;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *thumbnailCache;
@end

@implementation YTLPLocalQueueViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Local Queue";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemEdit target:self action:@selector(toggleEditing)];
    self.clearButton = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clearQueue)];
    self.navigationItem.leftBarButtonItem = self.clearButton;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.rowHeight = 70; // Reduced height for better thumbnail fit
    self.tableView.sectionHeaderHeight = 32;
    self.thumbnailCache = [NSMutableDictionary dictionary];
    
    // Use dark separator for dark mode compatibility
    self.tableView.separatorColor = [UIColor separatorColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // Actively fetch the currently playing video from the player
    [self updateCurrentlyPlayingFromPlayer];
    
    [self.tableView reloadData];
}

- (void)updateCurrentlyPlayingFromPlayer {
    // Try to get the current video from the player
    NSString *videoId = nil;
    NSString *title = nil;
    
    // First, try the stored player reference from the manager
    id playerVC = [[YTLPLocalQueueManager shared] currentPlayerViewController];
    
    // If no stored reference, search the view hierarchy
    if (!playerVC) {
        UIViewController *rootVC = nil;
        // Get key window in a way that works with scenes
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        rootVC = window.rootViewController;
                        break;
                    }
                }
            }
            if (rootVC) break;
        }
        if (rootVC) {
            playerVC = [self findPlayerViewControllerFrom:rootVC];
        }
    }
    
    if (playerVC) {
        @try {
            // Get video ID using performSelector
            SEL currentVideoIDSel = NSSelectorFromString(@"currentVideoID");
            if ([playerVC respondsToSelector:currentVideoIDSel]) {
                videoId = ((id (*)(id, SEL))objc_msgSend)(playerVC, currentVideoIDSel);
            }
            
            // Try to get title from activeVideo
            SEL activeVideoSel = NSSelectorFromString(@"activeVideo");
            if (videoId.length > 0 && [playerVC respondsToSelector:activeVideoSel]) {
                id activeVideo = ((id (*)(id, SEL))objc_msgSend)(playerVC, activeVideoSel);
                SEL singleVideoSel = NSSelectorFromString(@"singleVideo");
                if (activeVideo && [activeVideo respondsToSelector:singleVideoSel]) {
                    id singleVideo = ((id (*)(id, SEL))objc_msgSend)(activeVideo, singleVideoSel);
                    if (singleVideo) {
                        // Try title property
                        SEL titleSel = NSSelectorFromString(@"title");
                        if ([singleVideo respondsToSelector:titleSel]) {
                            id titleObj = ((id (*)(id, SEL))objc_msgSend)(singleVideo, titleSel);
                            if ([titleObj isKindOfClass:[NSString class]]) {
                                title = titleObj;
                            } else {
                                SEL textSel = NSSelectorFromString(@"text");
                                if ([titleObj respondsToSelector:textSel]) {
                                    title = ((id (*)(id, SEL))objc_msgSend)(titleObj, textSel);
                                }
                            }
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            // Ignore
        }
    }
    
    // Try to get title from queue manager if we have video ID but no title
    if (videoId.length > 0 && title.length == 0) {
        title = [[YTLPLocalQueueManager shared] titleForVideoId:videoId];
    }
    
    // Update the manager if we found a video
    if (videoId.length > 0) {
        [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:videoId title:title];
        
        // If we still don't have a title, fetch it asynchronously
        if (title.length == 0) {
            NSString *capturedVideoId = [videoId copy];
            [self fetchTitleForVideoId:capturedVideoId completion:^(NSString *fetchedTitle) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (fetchedTitle.length > 0) {
                        // Update the currently playing item with the fetched title
                        NSDictionary *currentItem = [[YTLPLocalQueueManager shared] currentlyPlayingItem];
                        if (currentItem && [currentItem[@"videoId"] isEqualToString:capturedVideoId]) {
                            [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:capturedVideoId title:fetchedTitle];
                            [self.tableView reloadData];
                        }
                    }
                });
            }];
        }
    }
}

- (id)findPlayerViewControllerFrom:(UIViewController *)viewController {
    if (!viewController) return nil;
    
    // Check if this is a player view controller
    Class PlayerVCClass = objc_getClass("YTPlayerViewController");
    if (PlayerVCClass && [viewController isKindOfClass:PlayerVCClass]) {
        return viewController;
    }
    
    // Check presented view controller
    if (viewController.presentedViewController) {
        id found = [self findPlayerViewControllerFrom:viewController.presentedViewController];
        if (found) return found;
    }
    
    // Check child view controllers
    for (UIViewController *child in viewController.childViewControllers) {
        id found = [self findPlayerViewControllerFrom:child];
        if (found) return found;
    }
    
    // Check navigation controller's view controllers
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        for (UIViewController *vc in nav.viewControllers) {
            id found = [self findPlayerViewControllerFrom:vc];
            if (found) return found;
        }
    }
    
    // Check tab bar controller's view controllers
    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)viewController;
        for (UIViewController *vc in tab.viewControllers) {
            id found = [self findPlayerViewControllerFrom:vc];
            if (found) return found;
        }
    }
    
    return nil;
}

- (void)toggleEditing {
    [self setEditing:!self.isEditing animated:YES];
}

- (void)clearQueue {
    NSInteger count = [[YTLPLocalQueueManager shared] allItems].count;
    [[YTLPLocalQueueManager shared] clear];
    [self.tableView reloadData];
    
    // Show confirmation toast
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    if (HUD && HUDMsg) {
        NSString *message = (count > 0)
            ? [NSString stringWithFormat:@"Cleared %ld video%@", (long)count, count == 1 ? @"" : @"s"]
            : @"Queue is empty";
        id hudInstance = ((id (*)(id, SEL))objc_msgSend)(HUD, sel_getUid("sharedInstance"));
        id hudMsg = ((id (*)(id, SEL, id))objc_msgSend)(HUDMsg, sel_getUid("messageWithText:"), message);
        if (hudInstance && hudMsg) {
            ((void (*)(id, SEL, id))objc_msgSend)(hudInstance, sel_getUid("showMessageMainThread:"), hudMsg);
        }
    }
}

#pragma mark - DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // Now Playing + Up Next
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == YTLPQueueSectionNowPlaying) {
        return [YTLPLocalQueueManager.shared currentlyPlayingItem] ? 1 : 0;
    } else {
        return [YTLPLocalQueueManager.shared allItems].count;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == YTLPQueueSectionNowPlaying) {
        return [YTLPLocalQueueManager.shared currentlyPlayingItem] ? @"Now Playing" : nil;
    } else {
        return [YTLPLocalQueueManager.shared allItems].count > 0 ? @"Up Next" : nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"queueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.numberOfLines = 2;
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.detailTextLabel.numberOfLines = 1;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        
        // Configure imageView for proper thumbnail display
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 4;
    }
    
    // Reset cell state for reuse
    cell.selected = NO;
    cell.highlighted = NO;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    
    NSDictionary *item;
    BOOL isNowPlaying = (indexPath.section == YTLPQueueSectionNowPlaying);
    
    if (isNowPlaying) {
        item = [YTLPLocalQueueManager.shared currentlyPlayingItem];
    } else {
        item = [YTLPLocalQueueManager.shared allItems][indexPath.row];
    }
    
    NSString *title = item[@"title"] ?: @"";
    NSString *videoId = item[@"videoId"] ?: @"";
    
    // Configure text
    if (title.length > 0) {
        cell.textLabel.text = title;
        if (isNowPlaying) {
            cell.detailTextLabel.text = @"▶ Playing now";
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.detailTextLabel.text = videoId;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
    } else {
        cell.textLabel.text = @"Loading...";
        cell.detailTextLabel.text = videoId;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        
        NSString *capturedVideoId = [videoId copy];
        BOOL capturedIsNowPlaying = isNowPlaying;
        
        [self fetchTitleForVideoId:capturedVideoId completion:^(NSString *fetchedTitle) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (fetchedTitle && fetchedTitle.length > 0) {
                    // Update the appropriate item based on section
                    if (capturedIsNowPlaying) {
                        [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:capturedVideoId title:fetchedTitle];
                    } else {
                        [[YTLPLocalQueueManager shared] updateTitleForVideoId:capturedVideoId title:fetchedTitle];
                    }
                    
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.textLabel.text = fetchedTitle;
                        if (capturedIsNowPlaying) {
                            updateCell.detailTextLabel.text = @"▶ Playing now";
                            updateCell.detailTextLabel.textColor = [UIColor systemRedColor];
                        }
                    }
                } else {
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.textLabel.text = [NSString stringWithFormat:@"Video %@", capturedVideoId];
                    }
                }
            });
        }];
    }
    
    // Add playing indicator for now playing section
    if (isNowPlaying) {
        cell.accessoryView = [self nowPlayingIndicator];
        cell.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.08];
        cell.selectionStyle = UITableViewCellSelectionStyleNone; // Can't tap now playing
    } else {
        cell.accessoryView = nil;
        cell.backgroundColor = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    
    // Configure thumbnail
    UIImage *cachedThumbnail = self.thumbnailCache[videoId];
    if (cachedThumbnail) {
        cell.imageView.image = cachedThumbnail;
    } else {
        cell.imageView.image = [self placeholderImage];
        [self loadThumbnailForVideoId:videoId completion:^(UIImage *thumbnail) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (thumbnail) {
                    self.thumbnailCache[videoId] = thumbnail;
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.imageView.image = thumbnail;
                        [updateCell setNeedsLayout];
                    }
                }
            });
        }];
    }
    
    cell.showsReorderControl = !isNowPlaying;
    
    return cell;
}

- (UIView *)nowPlayingIndicator {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    
    // Create equalizer-style bars
    CGFloat barWidth = 3;
    CGFloat spacing = 2;
    CGFloat heights[] = {12, 18, 10, 16};
    UIColor *barColor = [UIColor systemRedColor];
    
    for (int i = 0; i < 4; i++) {
        UIView *bar = [[UIView alloc] init];
        bar.backgroundColor = barColor;
        bar.layer.cornerRadius = barWidth / 2;
        
        CGFloat x = i * (barWidth + spacing);
        CGFloat height = heights[i];
        CGFloat y = (24 - height) / 2;
        bar.frame = CGRectMake(x, y, barWidth, height);
        
        [container addSubview:bar];
    }
    
    return container;
}

#pragma mark - Editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    // Can't edit now playing section
    return indexPath.section == YTLPQueueSectionUpNext;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == YTLPQueueSectionUpNext;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    // Keep moves within Up Next section only
    if (proposedDestinationIndexPath.section != YTLPQueueSectionUpNext) {
        return [NSIndexPath indexPathForRow:0 inSection:YTLPQueueSectionUpNext];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    [[YTLPLocalQueueManager shared] moveItemFromIndex:sourceIndexPath.row toIndex:destinationIndexPath.row];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == YTLPQueueSectionUpNext) {
        [[YTLPLocalQueueManager shared] removeItemAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

#pragma mark - Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // Don't allow tapping currently playing video
    if (indexPath.section == YTLPQueueSectionNowPlaying) {
        return;
    }
    
    NSDictionary *item = [YTLPLocalQueueManager.shared allItems][indexPath.row];
    NSString *videoId = item[@"videoId"];
    if (videoId.length == 0) return;
    
    Class YTICommandClass = objc_getClass("YTICommand");
    if (YTICommandClass && [YTICommandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) {
        id command = [YTICommandClass watchNavigationEndpointWithVideoID:videoId];
        Class Handler = objc_getClass("YTCoWatchWatchEndpointWrapperCommandHandler");
        if (Handler) {
            id handler = [[Handler alloc] init];
            if ([handler respondsToSelector:@selector(sendOriginalCommandWithNavigationEndpoint:fromView:entry:sender:completionBlock:)]) {
                [handler sendOriginalCommandWithNavigationEndpoint:command fromView:nil entry:nil sender:nil completionBlock:nil];
                return;
            }
        }
    }
    
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"youtube://watch?v=%@", videoId]];
    Class UIUtils = objc_getClass("YTUIUtils");
    if (UIUtils && [UIUtils canOpenURL:url]) {
        [UIUtils openURL:url];
    }
}

#pragma mark - Thumbnail Methods

- (UIImage *)placeholderImage {
    CGSize size = CGSizeMake(88, 50); // 16:9 aspect ratio
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Dark background that works in both light and dark mode
    [[UIColor colorWithWhite:0.15 alpha:1.0] setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));
    
    // Draw play icon
    [[UIColor colorWithWhite:0.4 alpha:1.0] setFill];
    CGFloat centerX = size.width / 2;
    CGFloat centerY = size.height / 2;
    CGFloat triangleSize = 14;
    
    CGMutablePathRef trianglePath = CGPathCreateMutable();
    CGPathMoveToPoint(trianglePath, NULL, centerX - triangleSize/2, centerY - triangleSize/2);
    CGPathAddLineToPoint(trianglePath, NULL, centerX + triangleSize/2, centerY);
    CGPathAddLineToPoint(trianglePath, NULL, centerX - triangleSize/2, centerY + triangleSize/2);
    CGPathCloseSubpath(trianglePath);
    
    CGContextAddPath(context, trianglePath);
    CGContextFillPath(context);
    CGPathRelease(trianglePath);
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return image;
}

- (void)loadThumbnailForVideoId:(NSString *)videoId completion:(void (^)(UIImage *thumbnail))completion {
    if (!videoId || videoId.length == 0) {
        completion(nil);
        return;
    }
    
    NSArray *thumbnailURLs = @[
        [NSString stringWithFormat:@"https://img.youtube.com/vi/%@/mqdefault.jpg", videoId],
        [NSString stringWithFormat:@"https://img.youtube.com/vi/%@/hqdefault.jpg", videoId],
        [NSString stringWithFormat:@"https://img.youtube.com/vi/%@/default.jpg", videoId]
    ];
    
    [self loadThumbnailFromURLs:thumbnailURLs currentIndex:0 completion:completion];
}

- (void)loadThumbnailFromURLs:(NSArray<NSString *> *)urls currentIndex:(NSUInteger)index completion:(void (^)(UIImage *thumbnail))completion {
    if (index >= urls.count) {
        completion(nil);
        return;
    }
    
    NSString *urlString = urls[index];
    NSURL *url = [NSURL URLWithString:urlString];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            UIImage *image = [UIImage imageWithData:data];
            if (image) {
                UIImage *resizedImage = [self resizeImage:image toSize:CGSizeMake(88, 50)];
                completion(resizedImage);
                return;
            }
        }
        [self loadThumbnailFromURLs:urls currentIndex:index + 1 completion:completion];
    }];
    
    [task resume];
}

- (UIImage *)resizeImage:(UIImage *)image toSize:(CGSize)newSize {
    // Use aspect fill and clip - no letterboxing/pillarboxing
    CGFloat aspectRatio = image.size.width / image.size.height;
    CGFloat targetAspectRatio = newSize.width / newSize.height;
    
    CGRect drawRect;
    if (aspectRatio > targetAspectRatio) {
        // Image is wider - crop sides
        CGFloat drawHeight = newSize.height;
        CGFloat drawWidth = drawHeight * aspectRatio;
        CGFloat offsetX = (newSize.width - drawWidth) / 2;
        drawRect = CGRectMake(offsetX, 0, drawWidth, drawHeight);
    } else {
        // Image is taller - crop top/bottom
        CGFloat drawWidth = newSize.width;
        CGFloat drawHeight = drawWidth / aspectRatio;
        CGFloat offsetY = (newSize.height - drawHeight) / 2;
        drawRect = CGRectMake(0, offsetY, drawWidth, drawHeight);
    }
    
    UIGraphicsBeginImageContextWithOptions(newSize, YES, 0.0);
    
    // No background fill needed - image fills entire rect
    [image drawInRect:drawRect];
    
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedImage;
}

- (void)fetchTitleForVideoId:(NSString *)videoId completion:(void (^)(NSString *title))completion {
    if (!videoId || videoId.length == 0) {
        completion(nil);
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
                completion(title);
                return;
            }
        }
        completion(nil);
    }];
    
    [task resume];
}

@end
