#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const YTMFixCompletionDatesKey = @"YTMOfflineFixCompletionDates";
static const void *YTMFixLastProgressTimeKey = &YTMFixLastProgressTimeKey;

static dispatch_semaphore_t YTMFixFFmpegSemaphore(void) {
    static dispatch_semaphore_t semaphore;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        semaphore = dispatch_semaphore_create(1);
    });
    return semaphore;
}

static NSMutableSet<NSString *> *YTMFixPendingVideoIDs(void) {
    static NSMutableSet<NSString *> *videoIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoIDs = [NSMutableSet set];
    });
    return videoIDs;
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
    %orig;
    YTMFixRecordCompletion(fileName);
}

%end

%hook YTMDownloads

- (void)refreshAudioFiles {
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

// The installed bulk downloader walks arbitrary playlist objects and may
// misclassify an NSProxy as a view controller before sending it -view.
// Returning nil keeps that defensive traversal from raising an uncaught
// unrecognized-selector exception; real UIViewController instances are not
// affected.
%hook NSProxy

- (id)view {
    return nil;
}

%end

%hook FFMpegDownloader

- (BOOL)downloadAudioSynchronous:(NSString *)audioURL {
    dispatch_semaphore_wait(YTMFixFFmpegSemaphore(), DISPATCH_TIME_FOREVER);
    BOOL success = NO;
    @try {
        success = %orig;
    } @finally {
        dispatch_semaphore_signal(YTMFixFFmpegSemaphore());
    }
    return success;
}

- (void)statisticsCallback:(id)statistics {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSNumber *lastValue = objc_getAssociatedObject(self, YTMFixLastProgressTimeKey);
    if (lastValue != nil && now - lastValue.doubleValue < 0.25) return;
    objc_setAssociatedObject(self, YTMFixLastProgressTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}

- (void)logCallback:(long)executionId :(int)level :(NSString *)message {
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

    @synchronized (YTMFixPendingVideoIDs()) {
        if ([YTMFixPendingVideoIDs() containsObject:videoId]) {
            if (completion) completion();
            return;
        }
        [YTMFixPendingVideoIDs() addObject:videoId];
    }

    void (^wrappedCompletion)(void) = ^{
        @synchronized (YTMFixPendingVideoIDs()) {
            [YTMFixPendingVideoIDs() removeObject:videoId];
        }
        if (completion) completion();
    };
    %orig(videoId, title, playlistName, wrappedCompletion);
}

%end

