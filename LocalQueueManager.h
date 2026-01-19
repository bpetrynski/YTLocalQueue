// Tweaks/YTLocalQueue/LocalQueueManager.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTLPLocalQueueManager : NSObject

+ (instancetype)shared;

// Queue items
- (NSArray<NSDictionary *> *)allItems; // { videoId, title, channelName }
- (void)addVideoId:(NSString *)videoId title:(nullable NSString *)title channelName:(nullable NSString *)channelName;
- (void)addVideoId:(NSString *)videoId title:(nullable NSString *)title; // Legacy, no channel name
- (void)updateMetadataForVideoId:(NSString *)videoId title:(NSString *)title channelName:(nullable NSString *)channelName;
- (void)updateTitleForVideoId:(NSString *)videoId title:(NSString *)title; // Legacy, no channel name
- (void)removeItemAtIndex:(NSUInteger)index;
- (void)moveItemFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;
- (void)clear;
- (BOOL)isEmpty;
- (nullable NSString *)popNextVideoId;
- (nullable NSDictionary *)popNextItem; // Returns full item with videoId and title
- (nullable NSDictionary *)peekNextItem; // Returns next item WITHOUT removing it
- (nullable NSString *)titleForVideoId:(NSString *)videoId;
- (void)insertVideoId:(NSString *)videoId title:(nullable NSString *)title atIndex:(NSUInteger)index;
- (void)insertVideoId:(NSString *)videoId title:(nullable NSString *)title channelName:(nullable NSString *)channelName atIndex:(NSUInteger)index;

// Currently playing tracking
- (void)setCurrentlyPlayingVideoId:(nullable NSString *)videoId title:(nullable NSString *)title channelName:(nullable NSString *)channelName;
- (void)setCurrentlyPlayingVideoId:(nullable NSString *)videoId title:(nullable NSString *)title; // Legacy
- (nullable NSDictionary *)currentlyPlayingItem; // { videoId, title } or nil

// Player reference (for fetching current video when queue view opens)
- (void)setCurrentPlayerViewController:(nullable id)playerVC;
- (nullable id)currentPlayerViewController;

@end

NS_ASSUME_NONNULL_END


