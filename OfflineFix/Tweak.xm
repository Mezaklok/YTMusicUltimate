#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

@class YTMFixDownloadItem;
static NSString *const YTMFixCompletionDatesKey = @"YTMOfflineFixCompletionDates";
static YTMFixDownloadItem *YTMFixActiveDownloadItem;
static BOOL YTMFixQueuePaused;

typedef id (*YTMFixAncestorHelperType)(id object, id visited, NSUInteger depth);
static YTMFixAncestorHelperType YTMFixOriginalAncestorHelper;

#ifdef __cplusplus
extern "C" {
#endif
extern void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

static dispatch_queue_t YTMFixLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytmusicultimate.offlinefix.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void YTMFixLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (message.length == 0) return;

    dispatch_async(YTMFixLogQueue(), ^{
        NSURL *documentsURL = [[[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
        NSURL *directoryURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSURL *logURL = [directoryURL URLByAppendingPathComponent:@"YTMOfflineStabilityFix.queue.log"];
        NSString *oldContents = [NSString stringWithContentsOfURL:logURL
                                                           encoding:NSUTF8StringEncoding
                                                              error:nil] ?: @"";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [[NSDate date] descriptionWithLocale:nil], message];
        NSString *contents = [oldContents stringByAppendingString:line];
        if (contents.length > 262144) {
            contents = [contents substringFromIndex:(contents.length - 131072)];
        }
        [contents writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

static NSMutableDictionary<NSString *, NSNumber *> *YTMFixMutableCompletionDates(void) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:YTMFixCompletionDatesKey];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void YTMFixRecordCompletion(NSString *fileName) {
    if (fileName.length == 0) return;
    @synchronized ([NSUserDefaults standardUserDefaults]) {
        NSMutableDictionary *dates = YTMFixMutableCompletionDates();
        dates[fileName] = @([NSDate date].timeIntervalSince1970);
        [[NSUserDefaults standardUserDefaults] setObject:dates forKey:YTMFixCompletionDatesKey];
    }
}

static BOOL YTMFixClassIsSubclassOf(Class cls, Class parent) {
    if (cls == Nil || parent == Nil) return NO;
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        if (current == parent) return YES;
    }
    return NO;
}

// The installed YTMusicUltimate helper at offset 0xe10c recursively searches
// arbitrary objects and eventually sends -view after a loose respondsToSelector:
// check. Replace that one helper by address, rather than changing NSProxy
// globally, and only traverse concrete UIKit/Foundation container types.
static id YTMFixSafeAncestorHelper(id object, NSMutableSet *visited, NSUInteger depth) {
    if (object == nil || depth > 12) return nil;

    Class objectClass = object_getClass(object);
    if (objectClass == Nil) return nil;

    NSValue *marker = [NSValue valueWithPointer:(__bridge const void *)object];
    if (visited != nil && [visited containsObject:marker]) return nil;
    if (visited != nil) [visited addObject:marker];

    if (YTMFixClassIsSubclassOf(objectClass, [NSProxy class])) {
        YTMFixLog(@"safe ancestor skipped NSProxy depth=%lu", (unsigned long)depth);
        return nil;
    }
    if (YTMFixClassIsSubclassOf(objectClass, [UIViewController class])) {
        Method viewMethod = class_getInstanceMethod(objectClass, @selector(view));
        if (viewMethod != NULL) return object;
        YTMFixLog(@"safe ancestor skipped controller without view method depth=%lu",
                  (unsigned long)depth);
        return nil;
    }

    SEL rootSelector = @selector(rootViewController);
    if (YTMFixClassIsSubclassOf(objectClass, [UIWindow class])) {
        Method rootMethod = class_getInstanceMethod(objectClass, rootSelector);
        IMP rootImplementation = rootMethod ? method_getImplementation(rootMethod) : NULL;
        if (rootImplementation != NULL) {
            id root = ((id (*)(id, SEL))rootImplementation)(object, rootSelector);
            return YTMFixSafeAncestorHelper(root, visited, depth + 1);
        }
        return nil;
    }

    SEL responderSelector = @selector(nextResponder);
    if (YTMFixClassIsSubclassOf(objectClass, [UIView class])) {
        Method responderMethod = class_getInstanceMethod(objectClass, responderSelector);
        IMP responderImplementation = responderMethod ? method_getImplementation(responderMethod) : NULL;
        if (responderImplementation != NULL) {
            id responder = ((id (*)(id, SEL))responderImplementation)(object, responderSelector);
            return YTMFixSafeAncestorHelper(responder, visited, depth + 1);
        }
        return nil;
    }

    if (YTMFixClassIsSubclassOf(objectClass, [NSDictionary class])) {
        for (id value in [(NSDictionary *)object allValues]) {
            id result = YTMFixSafeAncestorHelper(value, visited, depth + 1);
            if (result != nil) return result;
        }
        return nil;
    }
    if (YTMFixClassIsSubclassOf(objectClass, [NSArray class]) ||
        YTMFixClassIsSubclassOf(objectClass, [NSSet class])) {
        for (id value in (id<NSFastEnumeration>)object) {
            id result = YTMFixSafeAncestorHelper(value, visited, depth + 1);
            if (result != nil) return result;
        }
    }
    return nil;
}

static void YTMFixInstallAncestorHelperHook(void) {
    static BOOL installed;
    if (installed) return;

    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *imageName = _dyld_get_image_name(index);
        if (imageName == NULL || strstr(imageName, "/YTMusicUltimate.dylib") == NULL) continue;

        uintptr_t targetAddress = (uintptr_t)_dyld_get_image_header(index) + 0xe10c;
        uint32_t signature = *(uint32_t *)targetAddress;
        uint32_t viewCallSignature = *(uint32_t *)(targetAddress + (0xebdc - 0xe10c));
        if (signature != 0xa9ba6ffc || viewCallSignature != 0xa94b2e94) {
            YTMFixLog(@"safe ancestor hook skipped signatures=%08x/%08x",
                      signature, viewCallSignature);
            return;
        }

        MSHookFunction((void *)targetAddress,
                       (void *)YTMFixSafeAncestorHelper,
                       (void **)&YTMFixOriginalAncestorHelper);
        installed = YES;
        YTMFixLog(@"safe ancestor helper installed offset=0xe10c");
        return;
    }
    YTMFixLog(@"safe ancestor helper target not found");
}

static NSDate *YTMFixCompletionDate(NSString *fileName, NSURL *downloadsURL) {
    @synchronized ([NSUserDefaults standardUserDefaults]) {
        NSNumber *timestamp = [[NSUserDefaults standardUserDefaults]
            dictionaryForKey:YTMFixCompletionDatesKey][fileName];
        if (timestamp != nil) return [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
    }

    NSString *path = [[downloadsURL URLByAppendingPathComponent:fileName] path];
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:nil];
    return attributes[NSFileModificationDate] ?: attributes[NSFileCreationDate] ?: [NSDate distantPast];
}

%hook YTMDownloadMetadata

+ (void)saveMetadataForFileName:(NSString *)fileName
                         videoId:(NSString *)videoId
                           title:(NSString *)title
                          author:(NSString *)author {
    YTMFixLog(@"metadata completion hook invoked");
    %orig;
    YTMFixRecordCompletion(fileName);
}

%end

%hook YTMDownloads

- (void)refreshAudioFiles {
    YTMFixLog(@"downloads refresh hook invoked");
    %orig;

    id downloadsController = (id)self;
    id selectedPlaylist = nil;
    @try {
        selectedPlaylist = [downloadsController valueForKey:@"selectedPlaylistFilter"];
    } @catch (__unused NSException *exception) {
    }
    if ([selectedPlaylist isKindOfClass:[NSString class]] && [selectedPlaylist length] > 0) return;

    NSArray<NSString *> *audioFiles = nil;
    @try {
        audioFiles = [downloadsController valueForKey:@"audioFiles"];
    } @catch (__unused NSException *exception) {
        return;
    }
    if (![audioFiles isKindOfClass:[NSArray class]] || audioFiles.count < 2) return;

    NSURL *documentsURL = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *downloadsURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
    NSArray *sorted = [audioFiles sortedArrayUsingComparator:^NSComparisonResult(NSString *first,
                                                                                  NSString *second) {
        NSDate *firstDate = YTMFixCompletionDate(first, downloadsURL);
        NSDate *secondDate = YTMFixCompletionDate(second, downloadsURL);
        NSComparisonResult result = [secondDate compare:firstDate];
        return result != NSOrderedSame ? result : [first localizedCaseInsensitiveCompare:second];
    }];

    @try {
        [downloadsController setValue:[sorted mutableCopy] forKey:@"audioFiles"];
    } @catch (__unused NSException *exception) {
    }
}

%end

@interface YTMFixDownloadItem : NSObject
@property(nonatomic, copy) NSString *videoId;
@property(nonatomic, copy) void (^start)(void);
@property(nonatomic, copy) void (^completion)(void);
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, assign) NSUInteger sequence;
@end

@implementation YTMFixDownloadItem
@end

static dispatch_queue_t YTMFixQueueStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytmusicultimate.offlinefix.queue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableArray<YTMFixDownloadItem *> *YTMFixDownloadQueue(void) {
    static NSMutableArray<YTMFixDownloadItem *> *items;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = [NSMutableArray array];
    });
    return items;
}

static NSMutableSet<NSString *> *YTMFixQueuedVideoIDs(void) {
    static NSMutableSet<NSString *> *videoIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoIDs = [NSMutableSet set];
    });
    return videoIDs;
}

static YTMFixDownloadItem *YTMFixActiveItem(void) {
    return YTMFixActiveDownloadItem;
}

static void YTMFixSetActiveItem(YTMFixDownloadItem *item) {
    YTMFixActiveDownloadItem = item;
}

static void YTMFixFinishItem(YTMFixDownloadItem *item, NSString *reason);
static dispatch_queue_t YTMFixQueueStateQueue(void);

static void YTMFixCancelActiveItem(void) {
    dispatch_async(YTMFixQueueStateQueue(), ^{
        YTMFixDownloadItem *item = YTMFixActiveItem();
        if (item == nil || item.finished) return;
        YTMFixLog(@"queue cancellation confirmed seq=%lu", (unsigned long)item.sequence);
        YTMFixFinishItem(item, @"cancelled");
    });
}

static void YTMFixStartNextItem(void) {
    if (YTMFixQueuePaused || YTMFixActiveItem() != nil || YTMFixDownloadQueue().count == 0) return;

    YTMFixDownloadItem *item = YTMFixDownloadQueue().firstObject;
    YTMFixSetActiveItem(item);
    YTMFixLog(@"queue start seq=%lu pending=%lu", (unsigned long)item.sequence,
              (unsigned long)YTMFixDownloadQueue().count);

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (item.start) item.start();
        } @catch (NSException *exception) {
            YTMFixLog(@"queue exception seq=%lu name=%@", (unsigned long)item.sequence, exception.name);
            YTMFixFinishItem(item, @"exception");
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * 60 * NSEC_PER_SEC)),
                       YTMFixQueueStateQueue(), ^{
            if (!item.finished) {
                // A watchdog is diagnostic only. Never signal completion or
                // start another item while the underlying download is alive.
                YTMFixQueuePaused = YES;
                YTMFixLog(@"queue paused seq=%lu reason=timeout; active download retained; no next track",
                          (unsigned long)item.sequence);
            }
        });
    });
}

static void YTMFixFinishItem(YTMFixDownloadItem *item, NSString *reason) {
    dispatch_async(YTMFixQueueStateQueue(), ^{
        if (item.finished) return;
        item.finished = YES;
        YTMFixQueuePaused = NO;
        if (YTMFixDownloadQueue().firstObject == item) {
            [YTMFixDownloadQueue() removeObjectAtIndex:0];
        } else {
            [YTMFixDownloadQueue() removeObject:item];
        }
        [YTMFixQueuedVideoIDs() removeObject:item.videoId];
        YTMFixLog(@"queue finish seq=%lu reason=%@ remaining=%lu",
                  (unsigned long)item.sequence, reason,
                  (unsigned long)YTMFixDownloadQueue().count);

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (item.completion) item.completion();
            } @catch (NSException *exception) {
                YTMFixLog(@"completion exception seq=%lu name=%@",
                          (unsigned long)item.sequence, exception.name);
            }
            dispatch_async(YTMFixQueueStateQueue(), ^{
                if (YTMFixActiveItem() == item) YTMFixSetActiveItem(nil);
                YTMFixStartNextItem();
            });
        });
    });
}

%hook FFMpegDownloader

- (void)cancelDownloading:(id)execution {
    %orig;
    YTMFixCancelActiveItem();
}

%end

%hook ELMTouchCommandPropertiesHandler

- (void)downloadTrackWithVideoId:(NSString *)videoId
                           title:(NSString *)title
                    playlistName:(NSString *)playlistName
                      completion:(void (^)(void))completion {
    if (videoId.length == 0) {
        %orig;
        return;
    }

    dispatch_async(YTMFixQueueStateQueue(), ^{
        if ([YTMFixQueuedVideoIDs() containsObject:videoId]) {
            YTMFixLog(@"queue duplicate idLength=%lu pending=%lu",
                      (unsigned long)videoId.length,
                      (unsigned long)YTMFixDownloadQueue().count);
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (completion) completion();
                } @catch (NSException *exception) {
                    YTMFixLog(@"duplicate completion exception name=%@", exception.name);
                }
            });
            return;
        }

        YTMFixDownloadItem *item = [YTMFixDownloadItem new];
        item.videoId = [videoId copy];
        item.sequence = YTMFixDownloadQueue().count + 1;
        item.completion = [completion copy];
        __weak YTMFixDownloadItem *weakItem = item;
        item.start = ^{
            YTMFixDownloadItem *strongItem = weakItem;
            if (!strongItem) return;
            void (^downloadCompletion)(void) = ^{
                YTMFixFinishItem(strongItem, @"completion");
            };
            %orig(videoId, title, playlistName, downloadCompletion);
        };
        [YTMFixQueuedVideoIDs() addObject:videoId];
        [YTMFixDownloadQueue() addObject:item];
        YTMFixLog(@"queue enqueue seq=%lu pending=%lu idLength=%lu",
                  (unsigned long)item.sequence,
                  (unsigned long)YTMFixDownloadQueue().count,
                  (unsigned long)videoId.length);
        YTMFixStartNextItem();
    });
}

%end

%ctor {
    YTMFixLog(@"overlay loaded");
    NSArray<NSString *> *classNames = @[
        @"YTMDownloadMetadata",
        @"YTMDownloads",
        @"ELMTouchCommandPropertiesHandler",
        @"FFMpegDownloader"
    ];
    for (NSString *className in classNames) {
        Class cls = objc_getClass(className.UTF8String);
        YTMFixLog(@"class %@ available=%@", className, cls ? @"yes" : @"no");
    }
    Class handlerClass = objc_getClass("ELMTouchCommandPropertiesHandler");
    BOOL hasBulkPath = handlerClass != Nil &&
        class_getInstanceMethod(handlerClass,
                                @selector(downloadTrackWithVideoId:title:playlistName:completion:)) != NULL;
    YTMFixLog(@"bulk hook selector available=%@", hasBulkPath ? @"yes" : @"no");
    dispatch_async(dispatch_get_main_queue(), ^{
        YTMFixInstallAncestorHelperHook();
    });
}


