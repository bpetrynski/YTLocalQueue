// Tweaks/YTLocalQueue/LocalQueueManager.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTLPLocalQueueManager : NSObject

+ (instancetype)shared;

- (NSArray<NSDictionary *> *)allItems; // { videoId, title }
- (void)addVideoId:(NSString *)videoId title:(nullable NSString *)title;
- (void)updateTitleForVideoId:(NSString *)videoId title:(NSString *)title;
- (void)removeItemAtIndex:(NSUInteger)index;
- (void)moveItemFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;
- (void)clear;
- (BOOL)isEmpty;
- (nullable NSString *)popNextVideoId;

@end

NS_ASSUME_NONNULL_END


