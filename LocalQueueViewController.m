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
    self.clearButton = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clearQueue)];
    UIBarButtonItem *doneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissController)];
    self.navigationItem.leftBarButtonItem = self.clearButton;
    self.navigationItem.rightBarButtonItems = @[doneButton, self.editButtonItem];
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.rowHeight = 70;
    self.tableView.sectionHeaderHeight = 32;
    self.thumbnailCache = [NSMutableDictionary dictionary];
    self.tableView.separatorColor = [UIColor separatorColor];
}

- (void)dismissController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    NSIndexPath *selectedIndexPath = [self.tableView indexPathForSelectedRow];
    if (selectedIndexPath) {
        [self.tableView deselectRowAtIndexPath:selectedIndexPath animated:NO];
    }

    [self updateCurrentlyPlayingFromPlayer];
    [self.tableView reloadData];
}

- (void)updateCurrentlyPlayingFromPlayer {
    NSString *videoId = nil;
    NSString *title = nil;

    id playerVC = [[YTLPLocalQueueManager shared] currentPlayerViewController];

    if (!playerVC) {
        UIViewController *rootVC = nil;
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
            SEL currentVideoIDSel = NSSelectorFromString(@"currentVideoID");
            if ([playerVC respondsToSelector:currentVideoIDSel]) {
                videoId = ((id (*)(id, SEL))objc_msgSend)(playerVC, currentVideoIDSel);
            }

            SEL activeVideoSel = NSSelectorFromString(@"activeVideo");
            if (videoId.length > 0 && [playerVC respondsToSelector:activeVideoSel]) {
                id activeVideo = ((id (*)(id, SEL))objc_msgSend)(playerVC, activeVideoSel);
                SEL singleVideoSel = NSSelectorFromString(@"singleVideo");
                if (activeVideo && [activeVideo respondsToSelector:singleVideoSel]) {
                    id singleVideo = ((id (*)(id, SEL))objc_msgSend)(activeVideo, singleVideoSel);
                    if (singleVideo) {
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
        }
    }

    if (videoId.length > 0 && title.length == 0) {
        title = [[YTLPLocalQueueManager shared] titleForVideoId:videoId];
    }

    if (videoId.length > 0) {
        [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:videoId title:title];

        if (title.length == 0) {
            NSString *capturedVideoId = [videoId copy];
            [self fetchTitleForVideoId:capturedVideoId completion:^(NSString *fetchedTitle) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (fetchedTitle.length > 0) {
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

    Class PlayerVCClass = objc_getClass("YTPlayerViewController");
    if (PlayerVCClass && [viewController isKindOfClass:PlayerVCClass]) {
        return viewController;
    }

    if (viewController.presentedViewController) {
        id found = [self findPlayerViewControllerFrom:viewController.presentedViewController];
        if (found) return found;
    }

    for (UIViewController *child in viewController.childViewControllers) {
        id found = [self findPlayerViewControllerFrom:child];
        if (found) return found;
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        for (UIViewController *vc in nav.viewControllers) {
            id found = [self findPlayerViewControllerFrom:vc];
            if (found) return found;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)viewController;
        for (UIViewController *vc in tab.viewControllers) {
            id found = [self findPlayerViewControllerFrom:vc];
            if (found) return found;
        }
    }

    return nil;
}

- (void)clearQueue {
    NSInteger count = [[YTLPLocalQueueManager shared] allItems].count;
    [[YTLPLocalQueueManager shared] clear];
    [self.tableView reloadData];

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
    return 2;
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
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 4;
    }

    BOOL isNowPlaying = (indexPath.section == YTLPQueueSectionNowPlaying);

    // Reset cell state completely for reuse - BEFORE setting new values
    cell.selected = NO;
    cell.highlighted = NO;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    // Apply background and selection style based on section
    if (isNowPlaying) {
        cell.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.15];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryView = [self nowPlayingIndicator];
    } else {
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    NSDictionary *item;
    if (isNowPlaying) {
        item = [YTLPLocalQueueManager.shared currentlyPlayingItem];
    } else {
        item = [YTLPLocalQueueManager.shared allItems][indexPath.row];
    }

    NSString *title = item[@"title"] ?: @"";
    NSString *videoId = item[@"videoId"] ?: @"";
    NSString *channelName = item[@"channelName"] ?: @"";

    cell.textLabel.text = title.length > 0 ? title : @"Loading...";
    if (isNowPlaying) {
        cell.detailTextLabel.text = @"Playing now";
        cell.detailTextLabel.textColor = [UIColor systemRedColor];
    } else {
        cell.detailTextLabel.text = channelName.length > 0 ? channelName : @"";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    // Fetch metadata if title OR channel name is missing
    if (title.length == 0 || (!isNowPlaying && channelName.length == 0)) {
        NSString *capturedVideoId = [videoId copy];
        NSString *capturedTitle = [title copy];
        BOOL capturedIsNowPlaying = isNowPlaying;

        [self fetchMetadataForVideoId:capturedVideoId completion:^(NSString *fetchedTitle, NSString *fetchedChannel) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *finalTitle = (fetchedTitle.length > 0) ? fetchedTitle : capturedTitle;
                if (finalTitle.length > 0 || fetchedChannel.length > 0) {
                    if (capturedIsNowPlaying) {
                        [[YTLPLocalQueueManager shared] setCurrentlyPlayingVideoId:capturedVideoId title:finalTitle channelName:fetchedChannel];
                    } else {
                        [[YTLPLocalQueueManager shared] updateMetadataForVideoId:capturedVideoId title:finalTitle channelName:fetchedChannel];
                    }

                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.textLabel.text = finalTitle.length > 0 ? finalTitle : [NSString stringWithFormat:@"Video %@", capturedVideoId];
                        if (!capturedIsNowPlaying) {
                            updateCell.detailTextLabel.text = fetchedChannel ?: @"";
                        }
                    }
                } else {
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell && capturedTitle.length == 0) {
                        updateCell.textLabel.text = [NSString stringWithFormat:@"Video %@", capturedVideoId];
                    }
                }
            });
        }];
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

    return cell;
}

- (UIView *)nowPlayingIndicator {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];

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

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == YTLPQueueSectionUpNext) {
        return UITableViewCellEditingStyleDelete;
    }
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == YTLPQueueSectionUpNext;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == YTLPQueueSectionUpNext;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
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
    CGSize size = CGSizeMake(88, 50);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();

    [[UIColor colorWithWhite:0.15 alpha:1.0] setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));

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
    CGFloat aspectRatio = image.size.width / image.size.height;
    CGFloat targetAspectRatio = newSize.width / newSize.height;

    CGRect drawRect;
    if (aspectRatio > targetAspectRatio) {
        CGFloat drawHeight = newSize.height;
        CGFloat drawWidth = drawHeight * aspectRatio;
        CGFloat offsetX = (newSize.width - drawWidth) / 2;
        drawRect = CGRectMake(offsetX, 0, drawWidth, drawHeight);
    } else {
        CGFloat drawWidth = newSize.width;
        CGFloat drawHeight = drawWidth / aspectRatio;
        CGFloat offsetY = (newSize.height - drawHeight) / 2;
        drawRect = CGRectMake(0, offsetY, drawWidth, drawHeight);
    }

    UIGraphicsBeginImageContextWithOptions(newSize, YES, 0.0);
    [image drawInRect:drawRect];
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedImage;
}

- (void)fetchTitleForVideoId:(NSString *)videoId completion:(void (^)(NSString *title))completion {
    [self fetchMetadataForVideoId:videoId completion:^(NSString *title, NSString *channelName) {
        completion(title);
    }];
}

- (void)fetchMetadataForVideoId:(NSString *)videoId completion:(void (^)(NSString *title, NSString *channelName))completion {
    if (!videoId || videoId.length == 0) {
        completion(nil, nil);
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
                NSString *channelName = json[@"author_name"];
                completion(title, channelName);
                return;
            }
        }
        completion(nil, nil);
    }];

    [task resume];
}

@end
