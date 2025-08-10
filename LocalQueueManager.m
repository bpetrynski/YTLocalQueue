// Tweaks/YTLocalQueue/LocalQueueManager.m
#import "LocalQueueManager.h"

static NSString *const kYTLPLocalQueueStorageKey = @"ytlp_local_queue_items";

@implementation YTLPLocalQueueManager {
    dispatch_queue_t _syncQueue;
    NSMutableArray<NSDictionary *> *_items;
}

+ (instancetype)shared {
    static YTLPLocalQueueManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] initPrivate]; });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _syncQueue = dispatch_queue_create("ytlp.localqueue.sync", DISPATCH_QUEUE_SERIAL);
        NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:kYTLPLocalQueueStorageKey];
        _items = [saved isKindOfClass:[NSArray class]] ? [saved mutableCopy] : [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSDictionary *> *)allItems { __block NSArray *s; dispatch_sync(_syncQueue, ^{ s = [_items copy]; }); return s; }
- (BOOL)isEmpty { __block BOOL e = YES; dispatch_sync(_syncQueue, ^{ e = _items.count == 0; }); return e; }

- (void)addVideoId:(NSString *)videoId title:(NSString *)title {
    if (videoId.length == 0) return;
    NSDictionary *entry = @{ @"videoId": videoId, @"title": title ?: @"" };
    dispatch_async(_syncQueue, ^{ [_items addObject:entry]; [self persist]; });
}

- (void)updateTitleForVideoId:(NSString *)videoId title:(NSString *)title {
    if (videoId.length == 0 || title.length == 0) return;
    dispatch_async(_syncQueue, ^{
        for (NSUInteger i = 0; i < _items.count; i++) {
            NSDictionary *item = _items[i];
            if ([item[@"videoId"] isEqualToString:videoId]) {
                NSMutableDictionary *updatedItem = [item mutableCopy];
                updatedItem[@"title"] = title;
                _items[i] = [updatedItem copy];
                [self persist];
                break;
            }
        }
    });
}

- (void)removeItemAtIndex:(NSUInteger)index {
    dispatch_async(_syncQueue, ^{ if (index < _items.count) { [_items removeObjectAtIndex:index]; [self persist]; } });
}

- (void)moveItemFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    dispatch_async(_syncQueue, ^{
        if (fromIndex >= _items.count || toIndex >= _items.count) return;
        NSDictionary *obj = _items[fromIndex];
        [_items removeObjectAtIndex:fromIndex];
        [_items insertObject:obj atIndex:toIndex];
        [self persist];
    });
}

- (void)clear { dispatch_async(_syncQueue, ^{ [_items removeAllObjects]; [self persist]; }); }

- (NSString *)popNextVideoId {
    __block NSString *next = nil;
    dispatch_sync(_syncQueue, ^{
        if (_items.count > 0) { next = _items.firstObject[@"videoId"]; [_items removeObjectAtIndex:0]; [self persist]; }
    });
    return next;
}

- (void)persist {
    [[NSUserDefaults standardUserDefaults] setObject:[_items copy] forKey:kYTLPLocalQueueStorageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end


