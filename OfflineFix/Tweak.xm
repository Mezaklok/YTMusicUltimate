#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdarg.h>

@class YTMFixDownloadItem;
static NSString *const YTMFixCompletionDatesKey = @"YTMOfflineFixCompletionDates";
static NSString *const YTMFixBuildMarker = @"Offline Stability Fix: V6 · build-time helper patch";
static YTMFixDownloadItem *YTMFixActiveDownloadItem;
static BOOL YTMFixQueuePaused;

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

// The existing YTMusicUltimate preferences screen is the least invasive
// place to expose the loaded overlay version. It leaves all settings and
// playback UI untouched while making an update immediately identifiable.
%hook YTMUltimateSettingsController

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *originalFooter = %orig;
    if (section != 3) return originalFooter;
    if (originalFooter.length == 0) return YTMFixBuildMarker;
    return [originalFooter stringByAppendingFormat:@"\n%@", YTMFixBuildMarker];
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
}


