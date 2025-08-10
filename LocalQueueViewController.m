// Tweaks/YTLocalQueue/LocalQueueViewController.m
#import "LocalQueueViewController.h"
#import <objc/runtime.h>
#import "LocalQueueManager.h"
#import "../YouTubeHeader/YTUIUtils.h"
#import "../YouTubeHeader/YTICommand.h"
#import "../YouTubeHeader/YTCoWatchWatchEndpointWrapperCommandHandler.h"

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
    self.tableView.rowHeight = 80; // Increase row height for thumbnails
    self.thumbnailCache = [NSMutableDictionary dictionary];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (void)toggleEditing { [self setEditing:!self.isEditing animated:YES]; }
- (void)clearQueue { [[YTLPLocalQueueManager shared] clear]; [self.tableView reloadData]; }

#pragma mark - DataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [YTLPLocalQueueManager.shared allItems].count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"queueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.numberOfLines = 1;
    }
    
    NSDictionary *item = [YTLPLocalQueueManager.shared allItems][indexPath.row];
    NSString *title = item[@"title"] ?: @"";
    NSString *videoId = item[@"videoId"] ?: @"";
    
    // Configure text - show actual title or try to fetch it
    if (title.length > 0 && ![title isEqualToString:@""]) {
        cell.textLabel.text = title;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@", videoId];
    } else {
        // Try to fetch title from YouTube if we don't have it
        cell.textLabel.text = @"Loading title...";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@", videoId];
        [self fetchTitleForVideoId:videoId completion:^(NSString *fetchedTitle) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (fetchedTitle && fetchedTitle.length > 0) {
                    // Update the stored item with the title
                    [[YTLPLocalQueueManager shared] updateTitleForVideoId:videoId title:fetchedTitle];
                    // Update cell if it's still visible
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.textLabel.text = fetchedTitle;
                        updateCell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@", videoId];
                    }
                } else {
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.textLabel.text = [NSString stringWithFormat:@"Video %@", videoId];
                        updateCell.detailTextLabel.text = @"No title available";
                    }
                }
            });
        }];
    }
    
    // Configure thumbnail with proper sizing
    UIImage *cachedThumbnail = self.thumbnailCache[videoId];
    if (cachedThumbnail) {
        cell.imageView.image = cachedThumbnail;
    } else {
        // Set placeholder image with proper size
        cell.imageView.image = [self placeholderImage];
        // Load thumbnail asynchronously
        [self loadThumbnailForVideoId:videoId completion:^(UIImage *thumbnail) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (thumbnail) {
                    self.thumbnailCache[videoId] = thumbnail;
                    // Update cell if it's still visible
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.imageView.image = thumbnail;
                        [updateCell setNeedsLayout];
                    }
                }
            });
        }];
    }
    
    cell.showsReorderControl = YES;
    
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath { [[YTLPLocalQueueManager shared] moveItemFromIndex:sourceIndexPath.row toIndex:destinationIndexPath.row]; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath { if (editingStyle == UITableViewCellEditingStyleDelete) { [[YTLPLocalQueueManager shared] removeItemAtIndex:indexPath.row]; [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic]; } }

#pragma mark - Delegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
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
    if (UIUtils && [UIUtils canOpenURL:url]) { [UIUtils openURL:url]; }
}

#pragma mark - Thumbnail Methods

- (UIImage *)placeholderImage {
    // Create a simple placeholder image
    CGSize size = CGSizeMake(120, 90);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Draw background
    [[UIColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1.0] setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));
    
    // Draw play icon
    [[UIColor colorWithRed:0.6 green:0.6 blue:0.6 alpha:1.0] setFill];
    CGFloat centerX = size.width / 2;
    CGFloat centerY = size.height / 2;
    CGFloat triangleSize = 20;
    
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
    
    // YouTube thumbnail URL patterns
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
                // Resize image to fit cell
                UIImage *resizedImage = [self resizeImage:image toSize:CGSizeMake(120, 90)];
                completion(resizedImage);
                return;
            }
        }
        
        // Try next URL if current one failed
        [self loadThumbnailFromURLs:urls currentIndex:index + 1 completion:completion];
    }];
    
    [task resume];
}

- (UIImage *)resizeImage:(UIImage *)image toSize:(CGSize)newSize {
    // Calculate the aspect ratio to maintain proper proportions
    CGFloat aspectRatio = image.size.width / image.size.height;
    CGFloat targetAspectRatio = newSize.width / newSize.height;
    
    CGSize drawSize;
    if (aspectRatio > targetAspectRatio) {
        // Image is wider than target
        drawSize = CGSizeMake(newSize.width, newSize.width / aspectRatio);
    } else {
        // Image is taller than target
        drawSize = CGSizeMake(newSize.height * aspectRatio, newSize.height);
    }
    
    // Center the image in the target size
    CGFloat offsetX = (newSize.width - drawSize.width) / 2;
    CGFloat offsetY = (newSize.height - drawSize.height) / 2;
    
    UIGraphicsBeginImageContextWithOptions(newSize, YES, 0.0);
    
    // Fill background with light gray
    [[UIColor colorWithRed:0.95 green:0.95 blue:0.95 alpha:1.0] setFill];
    CGContextFillRect(UIGraphicsGetCurrentContext(), CGRectMake(0, 0, newSize.width, newSize.height));
    
    // Draw the image centered
    [image drawInRect:CGRectMake(offsetX, offsetY, drawSize.width, drawSize.height)];
    
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedImage;
}

- (void)fetchTitleForVideoId:(NSString *)videoId completion:(void (^)(NSString *title))completion {
    if (!videoId || videoId.length == 0) {
        completion(nil);
        return;
    }
    
    // Use YouTube's oembed API to get video title
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


