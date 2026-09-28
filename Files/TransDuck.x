#import "Headers.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "TransDuckVoices.h"

extern void TDShowTranslationPreferences(UINavigationController *navigation, NSString *language, NSString *domain);

// All player and UI state stays on the main queue. Network callbacks return there.
static NSString *const TDBaseURL = @"https://yd.transduck.com";
static CGFloat TDPlaybackRate(YTPlayerViewController *player) {
    id overlay = player.activeVideoPlayerOverlay;
    if (![overlay respondsToSelector:@selector(currentPlaybackRate)]) return 1;
    CGFloat rate = [(YTMainAppVideoPlayerOverlayViewController *)overlay currentPlaybackRate];
    return isfinite(rate) && rate > 0 ? MIN(2, MAX(0.5, rate)) : 1;
}
static CGFloat TDSpeechStretch(AVAudioPlayer *audio, NSDictionary *cue, CGFloat playbackRate) {
    CGFloat cueDuration = [cue[@"end"] doubleValue] - [cue[@"start"] doubleValue];
    if (!isfinite(cueDuration) || cueDuration <= 0 || !isfinite(audio.duration)) return 1;
    return MIN(MAX(1, audio.duration / cueDuration), 2 / MAX(0.5, playbackRate));
}
static AVPlayer *TDPlayerInLayer(CALayer *layer) {
    if ([layer isKindOfClass:AVPlayerLayer.class] && ((AVPlayerLayer *)layer).player) return ((AVPlayerLayer *)layer).player;
    for (CALayer *child in layer.sublayers) {
        AVPlayer *player = TDPlayerInLayer(child);
        if (player) return player;
    }
    return nil;
}
static void TDLogPlayerObjects(id object, int depth, int *budget) {
    if (!object || depth < 0 || *budget <= 0) return;
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(object), &count);
    for (unsigned i = 0; i < count && *budget > 0; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') continue;
        id value = object_getIvar(object, ivars[i]);
        if (!value) continue;
        NSString *kind = NSStringFromClass([value class]);
        NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
        if (![kind localizedCaseInsensitiveContainsString:@"player"] &&
            ![kind localizedCaseInsensitiveContainsString:@"audio"] &&
            ![kind localizedCaseInsensitiveContainsString:@"render"] &&
            ![name localizedCaseInsensitiveContainsString:@"player"] &&
            ![name localizedCaseInsensitiveContainsString:@"audio"]) continue;
        (*budget)--;
        os_log(OS_LOG_DEFAULT, "[TransDuckAudioGraph] parent=%{public}s ivar=%{public}s class=%{public}s", NSStringFromClass([object class]).UTF8String, name.UTF8String, kind.UTF8String);
        if (depth > 0) TDLogPlayerObjects(value, depth - 1, budget);
    }
    free(ivars);
}
static NSArray<NSDictionary *> *TDModels(void) {
    return @[
        @{ @"name": @"Google", @"id": @"google" },
        @{ @"name": @"Gemini Flash Lite", @"id": @"gemini-3.5-flash-lite" },
        @{ @"name": @"DeepSeek Flash", @"id": @"deepseek-v4-flash" },
        @{ @"name": @"GPT Sol", @"id": @"gpt-5.6-sol" },
        @{ @"name": @"GPT Luna", @"id": @"gpt-5.6-luna" },
        @{ @"name": @"GPT Terra", @"id": @"gpt-5.6-terra" },
        @{ @"name": @"Claude Opus", @"id": @"claude-opus-5" },
        @{ @"name": @"Claude Sonnet", @"id": @"claude-sonnet-5" },
        @{ @"name": @"Claude Haiku", @"id": @"claude-haiku-4-5-20251001" }
    ];
}
static NSArray<NSDictionary *> *TDLanguages(void) {
    static NSArray<NSDictionary *> *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *byCode = [NSMutableDictionary dictionary];
        for (NSDictionary *voice in TDVoiceCatalog()) {
            NSArray *parts = [voice[@"id"] componentsSeparatedByString:@"-"];
            if (parts.count < 3) continue;
            NSString *code = [NSString stringWithFormat:@"%@-%@", parts[0], parts[1]];
            NSString *name = [[NSLocale currentLocale] localizedStringForLocaleIdentifier:code] ?: code;
            byCode[code] = @{ @"id":code, @"name":[NSString stringWithFormat:@"%@ · %@", name, code] };
        }
        NSMutableArray *all = [byCode.allValues mutableCopy];
        [all sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
        NSDictionary *vietnamese = byCode[@"vi-VN"];
        [all removeObject:vietnamese];
        if (vietnamese) [all insertObject:vietnamese atIndex:0];
        languages = all;
    });
    return languages;
}

@interface TDPanel : UIViewController
@property (nonatomic, weak) YTPlayerViewController *player;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *modelButton;
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UIButton *languageButton;
@property (nonatomic, strong) UIButton *domainButton;
@property (nonatomic, strong) NSArray<NSDictionary *> *domains;
@property (nonatomic, strong) UISlider *speechVolumeSlider;
@property (nonatomic, strong) UISlider *originalVolumeSlider;
@property (nonatomic, strong) UISwitch *speechSwitch;
@property (nonatomic, strong) UISwitch *bilingualSwitch;
@property (nonatomic, strong) UISwitch *captionSwitch;
@property (nonatomic, strong) UISwitch *rulesSwitch;
@property (nonatomic, strong) UISwitch *muteSwitch;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *summaryButton;
@property (nonatomic, strong) UISlider *subtitleSizeSlider;
@property (nonatomic, strong) UIButton *captionPositionButton;
@property (nonatomic, strong) UIButton *captionColorButton;
@property (nonatomic, strong) UISlider *captionOpacitySlider;
@property (nonatomic, strong) UISwitch *originalFirstSwitch;
@property (nonatomic, strong) UIActivityIndicatorView *activity;
@property (nonatomic) BOOL awaitingSession;
- (void)persistSettings;
- (void)refreshActivity;
- (void)speechVolumeChanged;
- (void)originalVolumeChanged;
@end

@interface TDVoicePicker : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) void (^selection)(NSDictionary *);
@property (nonatomic, strong) NSArray<NSDictionary *> *filtered;
@property (nonatomic, strong) NSArray<NSDictionary *> *options;
@property (nonatomic, copy) NSString *pickerTitle;
@end

@interface TDSummaryPanel : UITableViewController
@property (nonatomic, weak) YTPlayerViewController *player;
@property (nonatomic, copy) NSString *targetLanguage;
@property (nonatomic, strong) NSDictionary *summary;
@property (nonatomic, strong) NSArray<NSDictionary *> *summaryRows;
@property (nonatomic, strong) UILabel *stateLabel;
@end

@interface TDSubtitleEditor : UIViewController
@property (nonatomic, weak) YTPlayerViewController *player;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@interface TDManager : NSObject
@property (nonatomic, weak) YTPlayerViewController *player;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *cues;
@property (nonatomic, strong) NSArray<NSNumber *> *prefixMaxEnd;
@property (nonatomic, strong) NSCache<NSString *, NSData *> *audioCache;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UIActivityIndicatorView *playerActivity;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, copy) NSString *voice;
@property (nonatomic, copy) NSString *targetLanguage;
@property (nonatomic, copy) NSString *domain;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) void (^statusChanged)(NSString *);
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSInteger activeIndex;
@property (nonatomic) CGFloat previousTime;
@property (nonatomic) BOOL advancing;
@property (nonatomic) BOOL speech;
@property (nonatomic) BOOL bilingual;
@property (nonatomic) BOOL showCaptions;
@property (nonatomic) float subtitleSize;
@property (nonatomic) BOOL translationRulesEnabled;
@property (nonatomic) BOOL muteOriginal;
@property (nonatomic) BOOL originalMuted;
@property (nonatomic) BOOL originalMuteCaptured;
@property (nonatomic, weak) YTSingleVideoController *mutedVideo;
@property (nonatomic) BOOL preparing;
@property (nonatomic) BOOL resumeAfterPrepare;
@property (nonatomic) BOOL bufferingSeek;
@property (nonatomic) BOOL resumeAfterSeek;
@property (nonatomic) NSInteger bufferedCueIndex;
@property (nonatomic) float speechVolume;
@property (nonatomic) float originalVolume;
@property (nonatomic, weak) AVPlayer *volumePlayer;
@property (nonatomic) float previousOriginalVolume;
@property (nonatomic) BOOL loggedMissingOriginalPlayer;
@property (nonatomic) NSUInteger translatedCount;
@property (nonatomic) NSUInteger synthesizedCount;
@property (nonatomic) NSUInteger translationInFlight;
@property (nonatomic) BOOL translationComplete;
@property (nonatomic) NSUInteger synthesisInFlight;
@property (nonatomic) BOOL startedPlayback;
@property (nonatomic) NSUInteger initialCueIndex;
@property (nonatomic, strong) NSMutableSet<NSString *> *downloads;
@property (nonatomic, strong) NSMutableArray<NSValue *> *translationRanges;
@property (nonatomic, strong) NSMutableArray<NSValue *> *speechRanges;
+ (instancetype)shared;
- (void)login:(NSString *)email password:(NSString *)password completion:(void (^)(NSError *))completion;
- (void)checkSession:(void (^)(BOOL))completion;
- (void)startForPlayer:(YTPlayerViewController *)player model:(NSString *)model voice:(NSString *)voice targetLanguage:(NSString *)targetLanguage domain:(NSString *)domain speech:(BOOL)speech bilingual:(BOOL)bilingual showCaptions:(BOOL)showCaptions subtitleSize:(float)subtitleSize translationRulesEnabled:(BOOL)translationRulesEnabled muteOriginal:(BOOL)muteOriginal originalVolume:(float)originalVolume speechVolume:(float)speechVolume resumeAfterPrepare:(BOOL)resumeAfterPrepare;
- (void)stop;
- (void)summaryForPlayer:(YTPlayerViewController *)player targetLanguage:(NSString *)targetLanguage completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)fetchCaptionsForVideo:(NSString *)videoID player:(YTPlayerViewController *)player completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion;
- (void)fetchNativeCaptionsForVideo:(NSString *)videoID player:(YTPlayerViewController *)player completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion;
- (void)fetchNativeCaptionTrackAtIndex:(NSUInteger)index tracks:(NSArray<YTICaptionTrackEntry *> *)tracks videoID:(NSString *)videoID player:(YTPlayerViewController *)player completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion;
- (void)saveSubtitle:(NSString *)srt videoID:(NSString *)videoID completion:(void (^)(NSError *))completion;
- (void)fetchDomains:(void (^)(NSArray<NSDictionary *> *))completion;
- (void)attachCaptionToPlayerView;
- (void)applyOriginalVolume;
- (void)translateNext:(NSUInteger)generation;
- (void)translatedRange:(NSRange)range generation:(NSUInteger)generation;
- (NSRange)takeNearestRangeFrom:(NSMutableArray<NSValue *> *)ranges;
- (void)releaseInitialBuffer;
- (BOOL)cueReadyAtIndex:(NSInteger)index;
- (void)showPlayerActivity:(BOOL)show;
- (void)releaseSeekBufferIfReady;
@end

@implementation TDManager
+ (instancetype)shared {
    static TDManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [TDManager new]; });
    return manager;
}
- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        config.HTTPShouldSetCookies = YES;
        config.timeoutIntervalForRequest = 75;
        _session = [NSURLSession sessionWithConfiguration:config];
        _audioCache = [NSCache new];
        _audioCache.totalCostLimit = 24 * 1024 * 1024;
        _downloads = [NSMutableSet set];
        _activeIndex = -1;
    }
    return self;
}
- (void)setStatus:(NSString *)status {
    _status = [status copy];
    if (self.statusChanged) self.statusChanged(status);
}
- (void)request:(NSString *)path method:(NSString *)method body:(id)body completion:(void (^)(id, NSError *))completion {
    NSURL *url = [NSURL URLWithString:[TDBaseURL stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    if (body) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSError *error = networkError;
        id json = nil;
        if (!error && (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode < 200 || http.statusCode >= 300)) {
            error = [NSError errorWithDomain:@"TransDuck" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"TransDuck HTTP %ld", (long)http.statusCode]}];
        }
        if (!error && data.length) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, error); });
    }] resume];
}
- (void)checkSession:(void (^)(BOOL))completion {
    [self request:@"/api/v2/membership/getPopupInfo" method:@"GET" body:nil completion:^(id json, NSError *error) {
        completion(!error && [json isKindOfClass:NSDictionary.class] && [json[@"exists"] boolValue]);
    }];
}
- (void)login:(NSString *)email password:(NSString *)password completion:(void (^)(NSError *))completion {
    NSURL *url = [NSURL URLWithString:[TDBaseURL stringByAppendingString:@"/login"]];
    NSURLComponents *form = [NSURLComponents new];
    form.queryItems = @[[NSURLQueryItem queryItemWithName:@"username" value:email], [NSURLQueryItem queryItemWithName:@"password" value:password]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [form.percentEncodedQuery dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [[self.session dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || http.statusCode < 200 || http.statusCode >= 300) {
                completion(error ?: [NSError errorWithDomain:@"TransDuck" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey:@"Đăng nhập thất bại."}]);
                return;
            }
            [self checkSession:^(BOOL signedIn) {
                completion(signedIn ? nil : [NSError errorWithDomain:@"TransDuck" code:401 userInfo:@{NSLocalizedDescriptionKey:@"Email hoặc mật khẩu không đúng."}]);
            }];
        });
    }] resume];
}
- (void)stop {
    YTPlayerViewController *resumePlayer = self.player;
    NSString *resumeVideoID = self.videoID;
    BOOL resume = self.resumeAfterPrepare;
    self.resumeAfterPrepare = NO;
    self.generation++;
    [self.timer invalidate];
    self.timer = nil;
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    [self.playerActivity stopAnimating];
    [self.playerActivity removeFromSuperview];
    self.playerActivity = nil;
    self.bufferingSeek = NO;
    self.resumeAfterSeek = NO;
    self.bufferedCueIndex = -1;
    if (self.volumePlayer) self.volumePlayer.volume = self.previousOriginalVolume;
    self.volumePlayer = nil;
    if (self.originalMuteCaptured && self.mutedVideo) [self.mutedVideo setMuted:self.originalMuted];
    self.originalMuteCaptured = NO;
    self.mutedVideo = nil;
    [self.captionLabel removeFromSuperview];
    self.captionLabel = nil;
    self.cues = nil;
    self.prefixMaxEnd = nil;
    self.translationRanges = nil;
    self.speechRanges = nil;
    [self.downloads removeAllObjects];
    self.activeIndex = -1;
    self.preparing = NO;
    self.translatedCount = 0;
    self.synthesizedCount = 0;
    self.translationInFlight = 0;
    self.translationComplete = NO;
    self.synthesisInFlight = 0;
    self.startedPlayback = NO;
    self.initialCueIndex = 0;
    self.videoID = nil;
    self.player = nil;
    self.status = @"Đã dừng.";
    if (resume && [resumePlayer.currentVideoID isEqualToString:resumeVideoID]) [resumePlayer play];
}
- (void)fail:(NSString *)message generation:(NSUInteger)generation {
    if (generation != self.generation) return;
    self.resumeAfterPrepare = NO;
    self.resumeAfterSeek = NO;
    [self stop];
    self.status = message;
}
- (void)startForPlayer:(YTPlayerViewController *)player model:(NSString *)model voice:(NSString *)voice targetLanguage:(NSString *)targetLanguage domain:(NSString *)domain speech:(BOOL)speech bilingual:(BOOL)bilingual showCaptions:(BOOL)showCaptions subtitleSize:(float)subtitleSize translationRulesEnabled:(BOOL)translationRulesEnabled muteOriginal:(BOOL)muteOriginal originalVolume:(float)originalVolume speechVolume:(float)speechVolume resumeAfterPrepare:(BOOL)resumeAfterPrepare {
    self.resumeAfterPrepare = NO;
    [self stop];
    NSString *videoID = player.currentVideoID;
    if (!videoID.length || player.isPlayingAd) {
        self.status = @"Hãy mở một video trước.";
        if (resumeAfterPrepare) [player play];
        return;
    }
    self.player = player;
    self.videoID = videoID;
    self.resumeAfterPrepare = resumeAfterPrepare;
    self.model = model;
    self.voice = voice;
    self.targetLanguage = targetLanguage;
    self.domain = domain;
    self.speech = speech;
    self.speechVolume = MIN(1, MAX(0, speechVolume));
    self.originalVolume = MIN(1, MAX(0, originalVolume));
    self.loggedMissingOriginalPlayer = NO;
    self.bilingual = bilingual;
    self.showCaptions = showCaptions;
    self.subtitleSize = MIN(36, MAX(16, subtitleSize));
    self.translationRulesEnabled = translationRulesEnabled;
    self.muteOriginal = muteOriginal;
    self.preparing = YES;
    [self showPlayerActivity:YES];
    NSUInteger generation = self.generation;
    self.status = @"Đang tải phụ đề…";
    [self fetchCaptionsForVideo:videoID player:player completion:^(NSArray<NSMutableDictionary *> *cues, NSError *error) {
        if (generation != self.generation) return;
        if (![self.player.currentVideoID isEqualToString:videoID]) { [self stop]; return; }
        if (error || !cues.count) { [self fail:error.localizedDescription ?: @"Video chưa có phụ đề khả dụng trên TransDuck." generation:generation]; return; }
        self.cues = [cues mutableCopy];
        NSMutableArray<NSNumber *> *maxEnds = [NSMutableArray arrayWithCapacity:cues.count];
        double latestEnd = 0;
        for (NSDictionary *cue in cues) {
            latestEnd = MAX(latestEnd, [cue[@"end"] doubleValue]);
            [maxEnds addObject:@(latestEnd)];
        }
        self.prefixMaxEnd = maxEnds;
        CGFloat initialTime = player.currentVideoMediaTime;
        if (!isfinite(initialTime) || initialTime < 0) initialTime = 0;
        for (NSUInteger i = 1; i < cues.count && [cues[i][@"start"] doubleValue] <= initialTime; i++) self.initialCueIndex = i;
        NSUInteger batchSize = [self.model isEqualToString:@"google"] ? 50 : 10;
        self.translationRanges = [NSMutableArray array];
        self.speechRanges = [NSMutableArray array];
        for (NSUInteger offset = 0; offset < cues.count; offset += batchSize) {
            [self.translationRanges addObject:[NSValue valueWithRange:NSMakeRange(offset, MIN(batchSize, cues.count - offset))]];
        }
        self.status = [NSString stringWithFormat:@"Đang dịch %lu câu…", (unsigned long)cues.count];
        for (NSUInteger i = 0; i < 3; i++) [self translateNext:generation];
    }];
}
- (void)fetchCaptionsForVideo:(NSString *)videoID player:(YTPlayerViewController *)player completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion {
    NSURLComponents *userParts = [NSURLComponents componentsWithString:[TDBaseURL stringByAppendingString:@"/api/v2/subtitle/getUserSubtitleList"]];
    userParts.queryItems = @[[NSURLQueryItem queryItemWithName:@"videoId" value:videoID]];
    NSString *userPath = [userParts.URL.absoluteString substringFromIndex:TDBaseURL.length];
    [self request:userPath method:@"GET" body:nil completion:^(id json, __unused NSError *error) {
        NSArray *saved = [json isKindOfClass:NSDictionary.class] ? json[@"subtitles"] : nil;
        NSArray *parsed = [self parseCaptionItems:saved];
        if (parsed.count) { completion(parsed, nil); return; }
        [self fetchOriginalCaptionsForVideo:videoID player:player completion:completion];
    }];
}
- (void)fetchOriginalCaptionsForVideo:(NSString *)videoID player:(YTPlayerViewController *)player completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion {
    NSURLComponents *parts = [NSURLComponents componentsWithString:[TDBaseURL stringByAppendingString:@"/api/v2/subtitle/getYoutubeSubtitleList"]];
    parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"videoId" value:videoID], [NSURLQueryItem queryItemWithName:@"version" value:@"1.0"]];
    NSString *path = [parts.URL.absoluteString substringFromIndex:TDBaseURL.length];
    [self request:path method:@"GET" body:nil completion:^(id json, NSError *error) {
        NSArray *parsed = !error && [json isKindOfClass:NSArray.class] ? [self parseCaptionItems:json] : @[];
        if (parsed.count) { completion(parsed, nil); return; }
        [self fetchNativeCaptionsForVideo:videoID player:player completion:completion];
    }];
}
- (NSArray<NSMutableDictionary *> *)parseCaptionItems:(NSArray *)items {
    if (![items isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *cues = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *timing = item[@"$"];
        NSString *text = item[@"_"];
        double start = [timing[@"start"] doubleValue], duration = [timing[@"dur"] doubleValue];
        if (![text isKindOfClass:NSString.class] || !text.length || !isfinite(start) || !isfinite(duration) || duration <= 0 || start < 0 || !isfinite(start + duration)) continue;
        [cues addObject:[@{@"text":text, @"start":@(start), @"end":@(start + duration)} mutableCopy]];
    }
    [cues sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"start"] compare:b[@"start"]]; }];
    for (NSUInteger i = 0; i < cues.count; i++) cues[i][@"index"] = @(i);
    return cues;
}
- (NSArray<NSMutableDictionary *> *)parseNativeCaptionJSON:(NSData *)data {
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *events = [payload isKindOfClass:NSDictionary.class] ? payload[@"events"] : nil;
    if (![events isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSMutableDictionary *> *cues = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:NSDictionary.class]) continue;
        double start = [event[@"tStartMs"] doubleValue] / 1000.0;
        double duration = [event[@"dDurationMs"] doubleValue] / 1000.0;
        NSArray *segments = event[@"segs"];
        if (![segments isKindOfClass:NSArray.class] || !isfinite(start) || !isfinite(duration) || start < 0 || duration <= 0) continue;
        NSMutableString *text = [NSMutableString string];
        for (NSDictionary *segment in segments) {
            NSString *part = [segment isKindOfClass:NSDictionary.class] ? segment[@"utf8"] : nil;
            if ([part isKindOfClass:NSString.class]) [text appendString:part];
        }
        NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [cues addObject:[@{@"text":clean, @"start":@(start), @"end":@(start + duration)} mutableCopy]];
    }
    [cues sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"start"] compare:b[@"start"]]; }];
    for (NSUInteger i = 0; i < cues.count; i++) cues[i][@"index"] = @(i);
    return cues;
}
- (void)fetchNativeCaptionsForVideo:(NSString *)videoID player:(YTPlayerViewController *)player completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion {
    if (![player.currentVideoID isEqualToString:videoID]) { completion(nil, [NSError errorWithDomain:@"TransDuck" code:409 userInfo:@{NSLocalizedDescriptionKey:@"Video đã thay đổi."}]); return; }
    YTPlayerResponse *response = [player respondsToSelector:@selector(contentPlayerResponse)] ? player.contentPlayerResponse : nil;
    NSArray *available = response.playerData.captions.playerCaptionsTracklistRenderer.captionTracksArray;
    if (!available.count) available = player.playerResponse.playerData.captions.playerCaptionsTracklistRenderer.captionTracksArray;
    NSLog(@"[TransDuckCaptions] video=%@ nativeTracks=%lu", videoID, (unsigned long)available.count);
    if (![available isKindOfClass:NSArray.class] || !available.count) { completion(nil, [NSError errorWithDomain:@"TransDuck" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Video chưa có phụ đề khả dụng trong trình phát YouTube."}]); return; }
    NSString *activeVSS = player.activeVideo.activeCaptionTrack.VSSID;
    NSMutableArray<YTICaptionTrackEntry *> *tracks = [NSMutableArray array];
    for (YTICaptionTrackEntry *track in available) if ([track.vssId isEqualToString:activeVSS]) [tracks addObject:track];
    for (YTICaptionTrackEntry *track in available) if (![tracks containsObject:track]) [tracks addObject:track];
    [self fetchNativeCaptionTrackAtIndex:0 tracks:tracks videoID:videoID player:player completion:completion];
}
- (void)fetchNativeCaptionTrackAtIndex:(NSUInteger)index tracks:(NSArray<YTICaptionTrackEntry *> *)tracks videoID:(NSString *)videoID player:(YTPlayerViewController *)player completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion {
    if (index >= tracks.count) { NSLog(@"[TransDuckCaptions] all native tracks failed video=%@", videoID); completion(nil, [NSError errorWithDomain:@"TransDuck" code:404 userInfo:@{NSLocalizedDescriptionKey:@"YouTube có track phụ đề nhưng không tải được nội dung."}]); return; }
    NSString *baseURL = tracks[index].baseURL;
    NSURLComponents *parts = [NSURLComponents componentsWithString:baseURL];
    NSString *host = parts.host.lowercaseString;
    if (![parts.scheme.lowercaseString isEqualToString:@"https"] || !([host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"])) {
        [self fetchNativeCaptionTrackAtIndex:index + 1 tracks:tracks videoID:videoID player:player completion:completion];
        return;
    }
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in parts.queryItems) if (![item.name isEqualToString:@"fmt"]) [items addObject:item];
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    parts.queryItems = items;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:parts.URL];
    request.timeoutInterval = 20;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSArray *cues = !error && [http isKindOfClass:NSHTTPURLResponse.class] && http.statusCode == 200 && data.length ? [self parseNativeCaptionJSON:data] : @[];
        if (!cues.count) NSLog(@"[TransDuckCaptions] track=%lu http=%ld bytes=%lu error=%@", (unsigned long)index, (long)http.statusCode, (unsigned long)data.length, error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cues.count) completion(cues, nil);
            else [self fetchNativeCaptionTrackAtIndex:index + 1 tracks:tracks videoID:videoID player:player completion:completion];
        });
    }] resume];
}
- (void)saveSubtitle:(NSString *)srt videoID:(NSString *)videoID completion:(void (^)(NSError *))completion {
    [self request:@"/api/v2/subtitle/saveUserSubtitle" method:@"POST" body:@{@"videoId":videoID, @"srt":srt} completion:^(id json, NSError *error) {
        if (error) { completion(error); return; }
        NSDictionary *payload = [json isKindOfClass:NSDictionary.class] ? json : nil;
        if ([payload[@"success"] boolValue]) { completion(nil); return; }
        completion([NSError errorWithDomain:@"TransDuck" code:422 userInfo:@{NSLocalizedDescriptionKey:payload[@"message"] ?: @"Không lưu được phụ đề."}]);
    }];
}
- (void)fetchDomains:(void (^)(NSArray<NSDictionary *> *))completion {
    [self request:@"/api/v2/translate-preference/domains" method:@"GET" body:nil completion:^(id json, NSError *error) {
        NSArray *data = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        if (error || ![data isKindOfClass:NSArray.class]) { completion(@[@{@"name":@"General", @"id":@"general"}]); return; }
        NSMutableArray *domains = [NSMutableArray array];
        for (NSDictionary *item in data) {
            NSString *code = [item[@"code"] isKindOfClass:NSString.class] ? item[@"code"] : nil;
            NSString *name = [item[@"labelEn"] isKindOfClass:NSString.class] ? item[@"labelEn"] : code;
            if (code.length) [domains addObject:@{@"name":name ?: code, @"id":code}];
        }
        completion(domains.count ? domains : @[@{@"name":@"General", @"id":@"general"}]);
    }];
}
- (void)summaryForPlayer:(YTPlayerViewController *)player targetLanguage:(NSString *)targetLanguage completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *videoID = player.currentVideoID;
    if (!videoID.length) { completion(nil, [NSError errorWithDomain:@"TransDuck" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Hãy mở video trước."}]); return; }
    [self fetchCaptionsForVideo:videoID player:player completion:^(NSArray<NSMutableDictionary *> *cues, NSError *error) {
        if (error || !cues.count) { completion(nil, error ?: [NSError errorWithDomain:@"TransDuck" code:404 userInfo:@{NSLocalizedDescriptionKey:@"Video chưa có phụ đề để tóm tắt."}]); return; }
        NSMutableArray *subtitles = [NSMutableArray arrayWithCapacity:cues.count];
        for (NSDictionary *cue in cues) [subtitles addObject:@{@"text":cue[@"text"], @"start":cue[@"start"], @"end":cue[@"end"]}];
        [self request:@"/api/v2/summary/generate" method:@"POST" body:@{@"videoId":videoID, @"subtitles":subtitles, @"targetLanguage":targetLanguage ?: @"vi-VN"} completion:^(id json, NSError *requestError) {
            NSDictionary *payload = [json isKindOfClass:NSDictionary.class] ? json : nil;
            NSDictionary *data = [payload[@"data"] isKindOfClass:NSDictionary.class] ? payload[@"data"] : nil;
            if (requestError || ![payload[@"success"] boolValue] || ![data[@"summary"] isKindOfClass:NSString.class]) {
                completion(nil, requestError ?: [NSError errorWithDomain:@"TransDuck" code:422 userInfo:@{NSLocalizedDescriptionKey:payload[@"errorMessage"] ?: @"Không tạo được tóm tắt."}]);
                return;
            }
            completion(data, nil);
        }];
    }];
}
- (NSRange)takeNearestRangeFrom:(NSMutableArray<NSValue *> *)ranges {
    CGFloat time = self.player.currentVideoMediaTime;
    if (!isfinite(time) || time < 0) time = 0;
    NSInteger low = 0, high = (NSInteger)self.cues.count;
    while (low < high) {
        NSInteger middle = low + (high - low) / 2;
        if ([self.cues[(NSUInteger)middle][@"start"] doubleValue] <= time) low = middle + 1;
        else high = middle;
    }
    NSInteger target = MAX(0, low - 1);
    NSUInteger best = 0;
    NSInteger bestDistance = NSIntegerMax;
    for (NSUInteger i = 0; i < ranges.count; i++) {
        NSRange range = ranges[i].rangeValue;
        NSInteger first = (NSInteger)range.location;
        NSInteger last = (NSInteger)NSMaxRange(range) - 1;
        NSInteger distance = target < first ? first - target : (target > last ? target - last : 0);
        if (distance < bestDistance) { best = i; bestDistance = distance; }
    }
    NSRange selected = ranges[best].rangeValue;
    [ranges removeObjectAtIndex:best];
    return selected;
}
- (void)translateNext:(NSUInteger)generation {
    if (generation != self.generation) return;
    if (![self.player.currentVideoID isEqualToString:self.videoID]) { [self stop]; return; }
    if (self.translationInFlight >= 3) return;
    if (!self.translationRanges.count) {
        if (!self.translationInFlight) { self.translationComplete = YES; [self finishIfReady]; }
        return;
    }
    NSRange range = [self takeNearestRangeFrom:self.translationRanges];
    self.translationInFlight++;
    NSUInteger offset = range.location;
    NSArray *batch = [self.cues subarrayWithRange:range];
    if ([self.model isEqualToString:@"google"]) {
        NSURLComponents *parts = [NSURLComponents componentsWithString:[TDBaseURL stringByAppendingString:@"/api/v2/translateAll"]];
        parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"language" value:@"auto"], [NSURLQueryItem queryItemWithName:@"to" value:self.targetLanguage], [NSURLQueryItem queryItemWithName:@"videoId" value:self.videoID], [NSURLQueryItem queryItemWithName:@"platform" value:@"pc"]];
        NSString *path = [parts.URL.absoluteString substringFromIndex:TDBaseURL.length];
        NSMutableArray *texts = [NSMutableArray array];
        for (NSDictionary *cue in batch) [texts addObject:cue[@"text"]];
        [self request:path method:@"POST" body:texts completion:^(id json, NSError *error) {
            if (generation != self.generation) return;
            NSArray *results = [json isKindOfClass:NSDictionary.class] ? json[@"translations"] : nil;
            if (error || results.count != batch.count) { [self fail:error.localizedDescription ?: @"Bản dịch không đầy đủ." generation:generation]; return; }
            for (NSUInteger i = 0; i < batch.count; i++) {
                NSString *text = [results[i] isKindOfClass:NSDictionary.class] ? results[i][@"text"] : nil;
                self.cues[offset + i][@"translated"] = text.length ? text : batch[i][@"text"];
            }
            [self translatedRange:range generation:generation];
        }];
        return;
    }
    NSMutableArray *subtitles = [NSMutableArray array];
    for (NSDictionary *cue in batch) {
        [subtitles addObject:@{@"index":cue[@"index"], @"text":cue[@"text"], @"googleTranslation":cue[@"text"], @"start":cue[@"start"], @"end":cue[@"end"]}];
    }
    NSDictionary *body = @{@"videoId":self.videoID, @"title":self.videoID, @"model":self.model, @"toLanguage":self.targetLanguage, @"domain":self.domain ?: @"general", @"translationRulesEnabled":@(self.translationRulesEnabled), @"skipTranslation":@NO, @"subtitles":subtitles};
    [self request:@"/api/v2/ai-translate/translate" method:@"POST" body:body completion:^(id json, NSError *error) {
        if (generation != self.generation) return;
        NSArray *results = [json isKindOfClass:NSDictionary.class] ? json[@"subtitleTranslateResults"] : nil;
        if (error || results.count != batch.count) { [self fail:error.localizedDescription ?: @"Bản dịch không đầy đủ." generation:generation]; return; }
        for (NSUInteger i = 0; i < batch.count; i++) {
            NSString *text = [results[i] isKindOfClass:NSDictionary.class] ? results[i][@"translateResult"] : nil;
            self.cues[offset + i][@"translated"] = text.length ? text : batch[i][@"text"];
        }
        [self translatedRange:range generation:generation];
    }];
}
- (void)translatedRange:(NSRange)range generation:(NSUInteger)generation {
    if (generation != self.generation) return;
    if (![self.player.currentVideoID isEqualToString:self.videoID]) { [self stop]; return; }
    self.translationInFlight--;
    self.translatedCount += range.length;
    if (!self.startedPlayback) { self.startedPlayback = YES; [self beginPlayback:generation]; }
    if (self.speech) {
        for (NSUInteger offset = range.location; offset < NSMaxRange(range); offset += 10) {
            [self.speechRanges addObject:[NSValue valueWithRange:NSMakeRange(offset, MIN(10, NSMaxRange(range) - offset))]];
        }
        [self synthesizeAvailable:generation];
        [self synthesizeAvailable:generation];
    } else if (NSLocationInRange(self.initialCueIndex, range)) [self releaseInitialBuffer];
    self.status = [NSString stringWithFormat:@"Đã dịch %lu/%lu câu%@", (unsigned long)self.translatedCount, (unsigned long)self.cues.count, self.speech ? @" · đang chuẩn bị giọng…" : @""];
    if (self.preparing) [self releaseInitialBuffer];
    [self releaseSeekBufferIfReady];
    [self translateNext:generation];
}
- (void)finishIfReady {
    if (!self.translationComplete) return;
    if (self.speech && (self.synthesisInFlight || self.synthesizedCount < self.cues.count)) return;
    if (self.preparing && self.speech) {
        NSString *url = self.cues[self.initialCueIndex][@"audioURL"];
        if (url.length && ![self.audioCache objectForKey:url]) {
            [self loadAudioAtIndex:(NSInteger)self.initialCueIndex];
            return;
        }
    }
    [self releaseInitialBuffer];
    self.status = self.speech ? @"Phụ đề và lồng tiếng đã sẵn sàng." : @"Phụ đề đã sẵn sàng.";
}
- (void)releaseInitialBuffer {
    if (!self.preparing) return;
    CGFloat time = self.player.currentVideoMediaTime;
    NSInteger index = (NSInteger)self.initialCueIndex;
    if (isfinite(time) && time >= 0) {
        NSInteger low = 0, high = (NSInteger)self.cues.count;
        while (low < high) {
            NSInteger middle = low + (high - low) / 2;
            if ([self.cues[(NSUInteger)middle][@"start"] doubleValue] <= time) low = middle + 1;
            else high = middle;
        }
        index = MAX(0, low - 1);
    }
    self.initialCueIndex = (NSUInteger)index;
    if (![self cueReadyAtIndex:index]) {
        [self prefetchNearIndex:index];
        return;
    }
    self.preparing = NO;
    BOOL resume = self.resumeAfterPrepare;
    self.resumeAfterPrepare = NO;
    self.status = @"Đoạn đầu đã sẵn sàng · đang chuẩn bị phần còn lại…";
    [self showPlayerActivity:NO];
    if (resume && [self.player.currentVideoID isEqualToString:self.videoID]) [self.player play];
}
- (BOOL)cueReadyAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.cues.count) return YES;
    NSDictionary *cue = self.cues[(NSUInteger)index];
    if (![cue[@"translated"] isKindOfClass:NSString.class]) return NO;
    if (!self.speech) return YES;
    NSString *url = cue[@"audioURL"];
    return url.length && [self.audioCache objectForKey:url] != nil;
}
- (void)showPlayerActivity:(BOOL)show {
    if (!show) { [self.playerActivity stopAnimating]; self.playerActivity.hidden = YES; return; }
    UIView *view = self.player.playerView;
    if (!view) return;
    if (!self.playerActivity) {
        self.playerActivity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        self.playerActivity.translatesAutoresizingMaskIntoConstraints = NO;
        self.playerActivity.color = UIColor.whiteColor;
        self.playerActivity.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
        self.playerActivity.layer.cornerRadius = 16;
    }
    if (self.playerActivity.superview != view) {
        [self.playerActivity removeFromSuperview];
        [view addSubview:self.playerActivity];
        [NSLayoutConstraint activateConstraints:@[[self.playerActivity.centerXAnchor constraintEqualToAnchor:view.centerXAnchor], [self.playerActivity.centerYAnchor constraintEqualToAnchor:view.centerYAnchor], [self.playerActivity.widthAnchor constraintEqualToConstant:64], [self.playerActivity.heightAnchor constraintEqualToConstant:64]]];
    }
    self.playerActivity.hidden = NO;
    [self.playerActivity startAnimating];
}
- (void)releaseSeekBufferIfReady {
    if (!self.bufferingSeek || ![self cueReadyAtIndex:self.bufferedCueIndex]) return;
    self.bufferingSeek = NO;
    [self showPlayerActivity:NO];
    BOOL resume = self.resumeAfterSeek;
    self.resumeAfterSeek = NO;
    self.previousTime = -1;
    if (resume && [self.player.currentVideoID isEqualToString:self.videoID]) [self.player play];
}
- (void)synthesizeAvailable:(NSUInteger)generation {
    if (generation != self.generation || self.synthesisInFlight >= 2 || !self.speech) return;
    if (![self.player.currentVideoID isEqualToString:self.videoID]) { [self stop]; return; }
    if (!self.speechRanges.count) { [self finishIfReady]; return; }
    self.synthesisInFlight++;
    NSRange range = [self takeNearestRangeFrom:self.speechRanges];
    NSUInteger offset = range.location;
    NSArray *batch = [self.cues subarrayWithRange:range];
    NSMutableArray *subtitles = [NSMutableArray array];
    for (NSDictionary *cue in batch) [subtitles addObject:@{@"index":cue[@"index"], @"text":cue[@"translated"], @"start":cue[@"start"], @"end":cue[@"end"]}];
    NSDictionary *body = @{@"subtitles":subtitles, @"config":@{@"model":self.model, @"voice":self.voice, @"voiceType":@"azure", @"toLanguage":self.targetLanguage, @"skipTranslation":@YES}, @"videoDetails":@{@"videoId":self.videoID, @"title":self.videoID, @"subtitleLevel":@2}, @"v2Version":@YES};
    [self request:@"/api/v2/dubbing/generateDubbing" method:@"POST" body:body completion:^(id json, NSError *error) {
        if (generation != self.generation) return;
        NSArray *results = [json isKindOfClass:NSDictionary.class] ? json[@"subtitleDubbingResults"] : nil;
        self.synthesisInFlight--;
        if (error || results.count != batch.count) {
            self.speech = NO;
            [self.speechRanges removeAllObjects];
            if (self.originalMuteCaptured && self.mutedVideo) [self.mutedVideo setMuted:self.originalMuted];
            self.originalMuteCaptured = NO;
            self.mutedVideo = nil;
            if (self.cues[self.initialCueIndex][@"translated"]) [self releaseInitialBuffer];
            [self finishIfReady];
            self.status = error.localizedDescription ?: @"TTS không đầy đủ; phụ đề vẫn hoạt động.";
            return;
        }
        for (NSUInteger i = 0; i < batch.count; i++) {
            id value = [results[i] isKindOfClass:NSDictionary.class] ? results[i][@"ttsUrl"] : nil;
            NSString *url = [value isKindOfClass:NSString.class] ? value : nil;
            if ([url hasPrefix:@"https://"] && ![url.lastPathComponent.lowercaseString containsString:@"empty_audio"]) self.cues[offset + i][@"audioURL"] = url;
            else if ([self.cues[offset + i][@"translated"] length]) {
                [self fail:@"Một câu TTS chưa tạo được giọng. Hãy thử lại." generation:generation];
                return;
            }
        }
        if (self.activeIndex >= (NSInteger)offset && self.activeIndex < (NSInteger)NSMaxRange(range) && !self.audioPlayer) self.activeIndex = -1;
        CGFloat now = self.player.currentVideoMediaTime;
        NSInteger current = 0;
        while (current + 1 < (NSInteger)self.cues.count && [self.cues[(NSUInteger)(current + 1)][@"start"] doubleValue] <= now) current++;
        [self prefetchNearIndex:current];
        self.synthesizedCount += range.length;
        if (NSLocationInRange(self.initialCueIndex, range)) {
            NSString *initialURL = self.cues[self.initialCueIndex][@"audioURL"];
            if (initialURL.length) {
                if ([self.audioCache objectForKey:initialURL]) [self releaseInitialBuffer];
                else [self loadAudioAtIndex:(NSInteger)self.initialCueIndex];
            } else [self releaseInitialBuffer];
        }
        [self releaseSeekBufferIfReady];
        [self synthesizeAvailable:generation];
    }];
}
- (void)beginPlayback:(NSUInteger)generation {
    if (generation != self.generation) return;
    if (![self.player.currentVideoID isEqualToString:self.videoID]) { [self stop]; return; }
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    CGFloat opacity = [defaults objectForKey:@"TDCaptionOpacity"] ? [defaults floatForKey:@"TDCaptionOpacity"] : 0.68;
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:MIN(0.9, MAX(0, opacity))];
    NSString *color = [defaults stringForKey:@"TDCaptionColor"] ?: @"white";
    NSDictionary *colors = @{@"white":UIColor.whiteColor, @"yellow":UIColor.systemYellowColor, @"cyan":UIColor.cyanColor, @"green":UIColor.systemGreenColor};
    label.textColor = colors[color] ?: UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:self.subtitleSize weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 3;
    label.layer.cornerRadius = 8;
    label.clipsToBounds = YES;
    label.hidden = YES;
    self.captionLabel = label;
    [self attachCaptionToPlayerView];
    self.previousTime = -1;
    [self applyOriginalVolume];
    if (self.speech && self.muteOriginal && self.player.activeVideo) {
        self.mutedVideo = self.player.activeVideo;
        self.originalMuted = self.mutedVideo.isMuted;
        self.originalMuteCaptured = YES;
        [self.mutedVideo setMuted:YES];
    }
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)applyOriginalVolume {
    if (!self.speech || !self.player.playerView) return;
    AVPlayer *player = TDPlayerInLayer(self.player.playerView.layer);
    if (!player) {
        if (!self.loggedMissingOriginalPlayer) {
            NSLog(@"[TransDuckAudio] original AVPlayer layer unavailable");
            int budget = 30;
            TDLogPlayerObjects(self.player.activeVideo, 2, &budget);
            self.loggedMissingOriginalPlayer = YES;
        }
        return;
    }
    if (player != self.volumePlayer) {
        if (self.volumePlayer) self.volumePlayer.volume = self.previousOriginalVolume;
        self.volumePlayer = player;
        self.previousOriginalVolume = player.volume;
        NSLog(@"[TransDuckAudio] original AVPlayer found; separate volume enabled");
    }
    player.volume = self.muteOriginal ? 0 : self.originalVolume;
}
- (void)attachCaptionToPlayerView {
    UIView *view = self.player.playerView;
    UILabel *label = self.captionLabel;
    if (!view || !label || label.superview == view) return;
    [label removeFromSuperview];
    [view addSubview:label];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *position = [defaults stringForKey:@"TDCaptionPosition"] ?: @"bottom";
    NSLayoutConstraint *vertical = [position isEqualToString:@"top"] ? [label.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:46] : ([position isEqualToString:@"middle"] ? [label.centerYAnchor constraintEqualToAnchor:view.centerYAnchor] : [label.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-46]);
    [NSLayoutConstraint activateConstraints:@[[label.centerXAnchor constraintEqualToAnchor:view.centerXAnchor], vertical, [label.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor multiplier:0.86]]];
}
- (void)tick {
    YTPlayerViewController *player = self.player;
    if (!player || ![player.currentVideoID isEqualToString:self.videoID]) { [self stop]; return; }
    [self attachCaptionToPlayerView];
    [self applyOriginalVolume];
    CGFloat time = player.currentVideoMediaTime;
    if (player.isPlayingAd || !isfinite(time) || time < 0) {
        self.captionLabel.hidden = YES;
        [self.audioPlayer pause];
        self.previousTime = -1;
        return;
    }
    BOOL jumped = self.previousTime >= 0 && fabs(time - self.previousTime) > MAX(0.55, 0.4 * TDPlaybackRate(player));
    BOOL advancing = self.previousTime < 0 || fabs(time - self.previousTime) > 0.015;
    self.advancing = advancing;
    self.previousTime = time;
    // Find the latest cue that has started, then inspect only cues whose
    // prefix contains an interval that might still cover this time.
    NSInteger low = 0, high = (NSInteger)self.cues.count;
    while (low < high) {
        NSInteger middle = low + (high - low) / 2;
        if ([self.cues[(NSUInteger)middle][@"start"] doubleValue] <= time) low = middle + 1;
        else high = middle;
    }
    NSInteger next = low, found = -1;
    for (NSInteger i = next - 1; i >= 0 && [self.prefixMaxEnd[(NSUInteger)i] doubleValue] > time; i--) {
        if ([self.cues[(NSUInteger)i][@"end"] doubleValue] > time) { found = i; break; }
    }
    NSInteger target = found >= 0 ? found : (next < (NSInteger)self.cues.count && [self.cues[(NSUInteger)next][@"start"] doubleValue] - time < 2 ? next : -1);
    if (self.preparing) {
        if (target >= 0) self.initialCueIndex = (NSUInteger)target;
        [self releaseInitialBuffer];
        if (self.preparing) { [self showPlayerActivity:YES]; return; }
    }
    if (jumped && target >= 0 && ![self cueReadyAtIndex:target]) {
        self.bufferingSeek = YES;
        self.bufferedCueIndex = target;
        self.resumeAfterSeek = player.playerState == 3;
        if (self.resumeAfterSeek) [player pause];
        [self.audioPlayer stop];
        self.audioPlayer = nil;
        self.activeIndex = -1;
        [self prefetchNearIndex:target];
        [self showPlayerActivity:YES];
        self.status = @"Đang xử lý đoạn vừa tua…";
    }
    if (self.bufferingSeek) {
        if (target >= 0 && target != self.bufferedCueIndex) self.bufferedCueIndex = target;
        [self releaseSeekBufferIfReady];
        if (self.bufferingSeek) { [self showPlayerActivity:YES]; return; }
    }
    self.captionLabel.hidden = !self.showCaptions || found < 0;
    if (found >= 0) {
        NSDictionary *cue = self.cues[(NSUInteger)found];
        NSString *translated = cue[@"translated"] ?: cue[@"text"];
        BOOL originalFirst = [NSUserDefaults.standardUserDefaults boolForKey:@"TDOriginalFirst"];
        NSString *display = self.bilingual && cue[@"translated"] ? (originalFirst ? [NSString stringWithFormat:@"%@\n%@", cue[@"text"], translated] : [NSString stringWithFormat:@"%@\n%@", translated, cue[@"text"]]) : translated;
        if (![self.captionLabel.text isEqualToString:display]) self.captionLabel.text = display;
    }
    if (!advancing) { [self.audioPlayer pause]; return; }
    // A synthesized phrase can be longer than its caption interval. Let it
    // finish, then play the next phrase instead of cutting off the last words.
    if (self.audioPlayer && found != self.activeIndex && !jumped && self.audioPlayer.currentTime < self.audioPlayer.duration - 0.05) {
        self.audioPlayer.rate = TDPlaybackRate(player) * TDSpeechStretch(self.audioPlayer, self.cues[(NSUInteger)self.activeIndex], TDPlaybackRate(player));
        if (!self.audioPlayer.isPlaying) [self.audioPlayer play];
        return;
    }
    if (found == self.activeIndex) {
        if (found < 0) [self prefetchNearIndex:next];
        if (self.audioPlayer && found >= 0) {
            NSDictionary *cue = self.cues[(NSUInteger)found];
            CGFloat playbackRate = TDPlaybackRate(player);
            CGFloat stretch = TDSpeechStretch(self.audioPlayer, cue, playbackRate);
            CGFloat offset = MAX(0, time - [cue[@"start"] doubleValue]) * stretch;
            if (fabs(self.audioPlayer.currentTime - offset) > 0.4) self.audioPlayer.currentTime = MIN(offset, self.audioPlayer.duration);
            self.audioPlayer.rate = stretch * playbackRate;
            if (!self.audioPlayer.isPlaying) [self.audioPlayer play];
        }
        return;
    }
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    NSInteger audioTarget = found;
    if (!jumped && self.activeIndex >= 0 && found > self.activeIndex + 1) audioTarget = self.activeIndex + 1;
    self.activeIndex = audioTarget;
    [self prefetchNearIndex:audioTarget >= 0 ? audioTarget : next];
    if (audioTarget < 0 || !self.speech) return;
    NSString *urlString = self.cues[(NSUInteger)audioTarget][@"audioURL"];
    if (!urlString) return;
    NSData *cached = [self.audioCache objectForKey:urlString];
    if (cached) { [self playData:cached index:audioTarget time:time]; return; }
    [self loadAudioAtIndex:audioTarget];
}
- (void)prefetchNearIndex:(NSInteger)index {
    if (!self.speech || !self.cues.count) return;
    for (NSInteger i = MAX(0, index); i < MIN((NSInteger)self.cues.count, index + 4); i++) [self loadAudioAtIndex:i];
}
- (void)loadAudioAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.cues.count) return;
    NSString *urlString = self.cues[(NSUInteger)index][@"audioURL"];
    if (!urlString || [self.audioCache objectForKey:urlString] || [self.downloads containsObject:urlString]) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (![url.scheme isEqualToString:@"https"]) return;
    [self.downloads addObject:urlString];
    NSUInteger generation = self.generation;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 12;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            [self.downloads removeObject:urlString];
            if (error || ![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode != 200 || ![http.URL.scheme isEqualToString:@"https"] || data.length < 1000) {
                if ((self.preparing && index == (NSInteger)self.initialCueIndex) || (self.bufferingSeek && index == self.bufferedCueIndex)) [self fail:@"Không tải được giọng lồng tiếng cho đoạn đang chờ. Hãy thử lại." generation:generation];
                return;
            }
            [self.audioCache setObject:data forKey:urlString cost:data.length];
            if (self.preparing && index == (NSInteger)self.initialCueIndex) [self releaseInitialBuffer];
            if (self.bufferingSeek && index == self.bufferedCueIndex) [self releaseSeekBufferIfReady];
            if (self.activeIndex == index && self.player && !self.audioPlayer) [self playData:data index:index time:self.player.currentVideoMediaTime];
        });
    }] resume];
}
- (void)playData:(NSData *)data index:(NSInteger)index time:(CGFloat)time {
    NSUInteger generation = self.generation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        AVAudioPlayer *audio = [[AVAudioPlayer alloc] initWithData:data error:&error];
        if (!audio || error) return;
    audio.enableRate = YES;
        [audio prepareToPlay];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation || self.activeIndex != index || !self.player) return;
            CGFloat now = self.player.currentVideoMediaTime;
            NSDictionary *cue = self.cues[(NSUInteger)index];
            if (now < [cue[@"start"] doubleValue]) return;
            CGFloat playbackRate = TDPlaybackRate(self.player);
            CGFloat stretch = TDSpeechStretch(audio, cue, playbackRate);
            audio.currentTime = now >= [cue[@"end"] doubleValue] ? 0 : MIN(MAX(0, now - [cue[@"start"] doubleValue]) * stretch, audio.duration);
            audio.rate = stretch * playbackRate;
            audio.volume = self.speechVolume;
            self.audioPlayer = audio;
            BOOL started = self.advancing && [audio play];
            os_log(OS_LOG_DEFAULT, "[TransDuckVoice] cue=%ld duration=%.2f interval=%.2f volume=%.2f started=%d", (long)index, audio.duration, [cue[@"end"] doubleValue] - [cue[@"start"] doubleValue], audio.volume, started);
        });
    });
}
@end

@implementation TDVoicePicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.pickerTitle ?: @"Giọng Azure";
    self.filtered = self.options ?: TDVoiceCatalog();
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchResultsUpdater = self;
    search.searchBar.placeholder = @"Tìm ngôn ngữ hoặc giọng";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.tableView.rowHeight = 52;
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *term = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!term.length) self.filtered = self.options ?: TDVoiceCatalog();
    else self.filtered = [(self.options ?: TDVoiceCatalog()) filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *voice, __unused NSDictionary *bindings) {
        return [voice[@"name"] localizedCaseInsensitiveContainsString:term] || [voice[@"id"] localizedCaseInsensitiveContainsString:term];
    }]];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return self.filtered.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"voice"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"voice"];
    NSDictionary *voice = self.filtered[(NSUInteger)indexPath.row];
    cell.textLabel.text = voice[@"name"];
    cell.detailTextLabel.text = voice[@"id"];
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", voice[@"name"], voice[@"id"]];
    return cell;
}
- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selection) self.selection(self.filtered[(NSUInteger)indexPath.row]);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@implementation TDSummaryPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tóm tắt video";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Tạo lại" style:UIBarButtonItemStylePlain target:self action:@selector(loadSummary)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    self.stateLabel = [UILabel new];
    self.stateLabel.text = @"Đang tạo tóm tắt…";
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.numberOfLines = 0;
    self.tableView.backgroundView = self.stateLabel;
    [self loadSummary];
}
- (void)loadSummary {
    self.stateLabel.text = @"Đang tạo tóm tắt…";
    self.summary = nil;
    [self.tableView reloadData];
    NSString *videoID = self.player.currentVideoID;
    __weak typeof(self) weakSelf = self;
    [[TDManager shared] summaryForPlayer:self.player targetLanguage:self.targetLanguage completion:^(NSDictionary *summary, NSError *error) {
        if (!weakSelf || ![weakSelf.player.currentVideoID isEqualToString:videoID]) return;
        weakSelf.summary = summary;
        NSMutableArray *rows = [NSMutableArray array];
        NSArray *highlights = [summary[@"highlights"] isKindOfClass:NSArray.class] ? summary[@"highlights"] : @[];
        for (NSDictionary *highlight in highlights) {
            if (![highlight isKindOfClass:NSDictionary.class]) continue;
            [rows addObject:@{@"text":highlight[@"title"] ?: @"", @"timestamp":highlight[@"timestamp"] ?: @0, @"detail":@NO}];
            NSArray *details = [highlight[@"details"] isKindOfClass:NSArray.class] ? highlight[@"details"] : @[];
            for (NSDictionary *detail in details) if ([detail isKindOfClass:NSDictionary.class]) [rows addObject:@{@"text":detail[@"text"] ?: @"", @"timestamp":detail[@"timestamp"] ?: @0, @"detail":@YES}];
        }
        weakSelf.summaryRows = rows;
        weakSelf.stateLabel.text = error.localizedDescription ?: @"";
        weakSelf.tableView.backgroundView = summary ? nil : weakSelf.stateLabel;
        [weakSelf.tableView reloadData];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.summary ? 2 : 0; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return self.summaryRows.count;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"Tóm tắt" : @"Các ý chính · chạm để tua"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"summary"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"summary"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.section == 0) {
        cell.textLabel.text = self.summary[@"summary"];
        cell.detailTextLabel.text = @"Chạm để sao chép";
    } else {
        NSDictionary *item = self.summaryRows[(NSUInteger)indexPath.row];
        NSTimeInterval seconds = [item[@"timestamp"] doubleValue];
        NSString *text = [item[@"text"] isKindOfClass:NSString.class] ? item[@"text"] : @"";
        cell.textLabel.text = [item[@"detail"] boolValue] ? [@"    " stringByAppendingString:text] : text;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)(seconds / 60), (long)((NSInteger)seconds % 60)];
    }
    return cell;
}
- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UIPasteboard.generalPasteboard.string = self.summary[@"summary"];
        return;
    }
    NSDictionary *item = self.summaryRows[(NSUInteger)indexPath.row];
    [self.player seekToTime:[item[@"timestamp"] doubleValue]];
}
@end

static NSString *TDSRTTime(NSTimeInterval seconds) {
    long long milliseconds = llround(MAX(0, seconds) * 1000);
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld,%03lld", milliseconds / 3600000, (milliseconds / 60000) % 60, (milliseconds / 1000) % 60, milliseconds % 1000];
}

@implementation TDSubtitleEditor
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chỉnh sửa phụ đề";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.text = @"Đang tải phụ đề…";
    self.textView.editable = NO;
    [self.view addSubview:self.textView];
    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"Sửa nội dung và mốc thời gian SRT, rồi lưu để dùng cho lần lồng tiếng kế tiếp.";
    [self.view addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [self.textView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:12],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16]
    ]];
    if (@available(iOS 15.0, *)) [[self.textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor] setActive:YES];
    else [[self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor] setActive:YES];
    NSString *videoID = self.player.currentVideoID;
    self.videoID = videoID;
    __weak typeof(self) weakSelf = self;
    [[TDManager shared] fetchCaptionsForVideo:videoID player:self.player completion:^(NSArray<NSDictionary *> *cues, NSError *error) {
        if (!weakSelf || ![weakSelf.player.currentVideoID isEqualToString:videoID]) return;
        if (error || !cues.count) { weakSelf.statusLabel.text = error.localizedDescription ?: @"Video chưa có phụ đề."; weakSelf.textView.text = @""; return; }
        NSMutableArray *blocks = [NSMutableArray arrayWithCapacity:cues.count];
        for (NSUInteger i = 0; i < cues.count; i++) {
            NSDictionary *cue = cues[i];
            [blocks addObject:[NSString stringWithFormat:@"%lu\n%@ --> %@\n%@", (unsigned long)i + 1, TDSRTTime([cue[@"start"] doubleValue]), TDSRTTime([cue[@"end"] doubleValue]), cue[@"text"]]];
        }
        weakSelf.textView.text = [blocks componentsJoinedByString:@"\n\n"];
        weakSelf.textView.editable = YES;
    }];
}
- (BOOL)validateSRT:(NSString *)srt {
    NSArray *blocks = [[srt stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n\n"];
    NSRegularExpression *timing = [NSRegularExpression regularExpressionWithPattern:@"^([0-9]{2,}):([0-5][0-9]):([0-5][0-9]),([0-9]{3}) --> ([0-9]{2,}):([0-5][0-9]):([0-5][0-9]),([0-9]{3})$" options:0 error:nil];
    if (!blocks.count) return NO;
    NSUInteger count = 0;
    for (NSString *block in blocks) {
        NSString *trimmed = [block stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!trimmed.length) continue;
        NSArray *lines = [trimmed componentsSeparatedByString:@"\n"];
        if (lines.count < 3 || [lines[0] integerValue] != (NSInteger)count + 1) return NO;
        NSString *timeLine = [lines[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSTextCheckingResult *match = [timing firstMatchInString:timeLine options:0 range:NSMakeRange(0, timeLine.length)];
        if (!match) return NO;
        double values[8];
        for (NSUInteger i = 0; i < 8; i++) values[i] = [[timeLine substringWithRange:[match rangeAtIndex:i + 1]] doubleValue];
        double start = values[0] * 3600 + values[1] * 60 + values[2] + values[3] / 1000;
        double end = values[4] * 3600 + values[5] * 60 + values[6] + values[7] / 1000;
        if (end <= start || ![[[lines subarrayWithRange:NSMakeRange(2, lines.count - 2)] componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return NO;
        count++;
    }
    return count > 0;
}
- (void)save {
    if (!self.textView.editable) return;
    if (![self.player.currentVideoID isEqualToString:self.videoID]) { self.statusLabel.text = @"Video đã thay đổi. Mở lại trình chỉnh sửa để tránh lưu nhầm."; return; }
    NSString *srt = self.textView.text;
    if (![self validateSRT:srt]) { self.statusLabel.text = @"SRT không hợp lệ: kiểm tra số thứ tự, thời gian và nội dung."; return; }
    NSString *videoID = self.videoID;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.statusLabel.text = @"Đang lưu…";
    [[TDManager shared] saveSubtitle:srt videoID:videoID completion:^(NSError *error) {
        self.navigationItem.rightBarButtonItem.enabled = YES;
        self.statusLabel.text = error.localizedDescription ?: @"Đã lưu. Bản phụ đề này sẽ dùng cho lần dịch và lồng tiếng tiếp theo.";
    }];
}
@end

@implementation TDPanel
- (UIButton *)menuButton:(NSString *)title options:(NSArray<NSDictionary *> *)options action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (UIView *)row:(NSString *)title control:(UIView *)control {
    UILabel *name = [self label:title];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    [name setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    if ([control isKindOfClass:UIButton.class]) {
        [control setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [control.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor multiplier:0.58].active = YES;
    } else {
        [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }
    return row;
}
- (UILabel *)label:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    return label;
}
- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [self label:text];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TransDuck";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor], [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24], [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor], [stack.widthAnchor constraintLessThanOrEqualToConstant:500], [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    UILabel *info = [self label:@"Dịch phụ đề và lồng tiếng Việt ngay trong trình phát YouTube."];
    info.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:info];
    UIButton *login = [UIButton buttonWithType:UIButtonTypeSystem];
    [login setTitle:@"Đăng nhập TransDuck" forState:UIControlStateNormal];
    [login addTarget:self action:@selector(login) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:login];
    [stack addArrangedSubview:[self sectionLabel:@"Bản dịch"]];
    self.modelButton = [self menuButton:@"Gemini Flash Lite" options:TDModels() action:@selector(selectModel)];
    [stack addArrangedSubview:[self row:@"Mô hình dịch" control:self.modelButton]];
    self.domainButton = [self menuButton:@"General" options:@[] action:@selector(selectDomain)];
    self.domains = @[@{@"name":@"General", @"id":@"general"}];
    [stack addArrangedSubview:[self row:@"Lĩnh vực dịch" control:self.domainButton]];
    self.languageButton = [self menuButton:@"Tiếng Việt · vi-VN" options:TDLanguages() action:@selector(selectLanguage)];
    [stack addArrangedSubview:[self row:@"Ngôn ngữ đích" control:self.languageButton]];
    self.voiceButton = [self menuButton:@"vi-VN · HoaiMy" options:@[] action:@selector(selectVoice)];
    [stack addArrangedSubview:[self row:@"Giọng Azure" control:self.voiceButton]];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *savedModel = [defaults stringForKey:@"TDModel"];
    for (NSDictionary *item in TDModels()) if ([item[@"id"] isEqualToString:savedModel]) { [self.modelButton setTitle:item[@"name"] forState:UIControlStateNormal]; self.modelButton.accessibilityValue = savedModel; break; }
    NSString *savedVoice = [defaults stringForKey:@"TDVoice"];
    for (NSDictionary *item in TDVoiceCatalog()) if ([item[@"id"] isEqualToString:savedVoice]) { [self.voiceButton setTitle:item[@"name"] forState:UIControlStateNormal]; self.voiceButton.accessibilityValue = savedVoice; break; }
    NSString *savedLanguage = [defaults stringForKey:@"TDLanguage"];
    for (NSDictionary *item in TDLanguages()) if ([item[@"id"] isEqualToString:savedLanguage]) { [self.languageButton setTitle:item[@"name"] forState:UIControlStateNormal]; self.languageButton.accessibilityValue = savedLanguage; break; }
    NSString *voicePrefix = [(self.languageButton.accessibilityValue ?: @"vi-VN") stringByAppendingString:@"-"];
    if (![self.voiceButton.accessibilityValue hasPrefix:voicePrefix]) {
        for (NSDictionary *voice in TDVoiceCatalog()) if ([voice[@"id"] hasPrefix:voicePrefix]) {
            [self.voiceButton setTitle:voice[@"name"] forState:UIControlStateNormal];
            self.voiceButton.accessibilityValue = voice[@"id"];
            break;
        }
    }
    self.speechSwitch = [UISwitch new]; self.speechSwitch.on = [defaults objectForKey:@"TDSpeech"] ? [defaults boolForKey:@"TDSpeech"] : YES;
    [stack addArrangedSubview:[self row:@"Lồng tiếng" control:self.speechSwitch]];
    self.bilingualSwitch = [UISwitch new]; self.bilingualSwitch.on = [defaults boolForKey:@"TDBilingual"];
    [stack addArrangedSubview:[self row:@"Phụ đề song ngữ" control:self.bilingualSwitch]];
    self.rulesSwitch = [UISwitch new]; self.rulesSwitch.on = [defaults boolForKey:@"TDTranslationRules"];
    [stack addArrangedSubview:[self row:@"Áp dụng bảng thuật ngữ và quy tắc dịch" control:self.rulesSwitch]];
    [stack addArrangedSubview:[self sectionLabel:@"Phụ đề"]];
    self.captionSwitch = [UISwitch new]; self.captionSwitch.on = [defaults objectForKey:@"TDShowCaptions"] ? [defaults boolForKey:@"TDShowCaptions"] : YES;
    [stack addArrangedSubview:[self row:@"Hiện phụ đề" control:self.captionSwitch]];
    self.subtitleSizeSlider = [UISlider new];
    self.subtitleSizeSlider.minimumValue = 16;
    self.subtitleSizeSlider.maximumValue = 36;
    self.subtitleSizeSlider.value = [defaults objectForKey:@"TDSubtitleSize"] ? [defaults floatForKey:@"TDSubtitleSize"] : 22;
    [stack addArrangedSubview:[self label:@"Cỡ chữ phụ đề"]];
    [stack addArrangedSubview:self.subtitleSizeSlider];
    self.captionPositionButton = [self menuButton:@"Dưới" options:@[] action:@selector(selectCaptionPosition)];
    NSArray *positions = @[@{@"name":@"Trên", @"id":@"top"}, @{@"name":@"Giữa", @"id":@"middle"}, @{@"name":@"Dưới", @"id":@"bottom"}];
    for (NSDictionary *item in positions) if ([item[@"id"] isEqualToString:[defaults stringForKey:@"TDCaptionPosition"]]) { [self.captionPositionButton setTitle:item[@"name"] forState:UIControlStateNormal]; self.captionPositionButton.accessibilityValue = item[@"id"]; }
    [stack addArrangedSubview:[self row:@"Vị trí phụ đề" control:self.captionPositionButton]];
    self.captionColorButton = [self menuButton:@"Trắng" options:@[] action:@selector(selectCaptionColor)];
    NSArray *colors = @[@{@"name":@"Trắng", @"id":@"white"}, @{@"name":@"Vàng", @"id":@"yellow"}, @{@"name":@"Xanh lam", @"id":@"cyan"}, @{@"name":@"Xanh lá", @"id":@"green"}];
    for (NSDictionary *item in colors) if ([item[@"id"] isEqualToString:[defaults stringForKey:@"TDCaptionColor"]]) { [self.captionColorButton setTitle:item[@"name"] forState:UIControlStateNormal]; self.captionColorButton.accessibilityValue = item[@"id"]; }
    [stack addArrangedSubview:[self row:@"Màu chữ" control:self.captionColorButton]];
    self.captionOpacitySlider = [UISlider new];
    self.captionOpacitySlider.minimumValue = 0;
    self.captionOpacitySlider.maximumValue = 0.9;
    self.captionOpacitySlider.value = [defaults objectForKey:@"TDCaptionOpacity"] ? [defaults floatForKey:@"TDCaptionOpacity"] : 0.68;
    [stack addArrangedSubview:[self label:@"Độ mờ nền phụ đề"]];
    [stack addArrangedSubview:self.captionOpacitySlider];
    self.originalFirstSwitch = [UISwitch new];
    self.originalFirstSwitch.on = [defaults boolForKey:@"TDOriginalFirst"];
    [stack addArrangedSubview:[self row:@"Bản gốc ở trên" control:self.originalFirstSwitch]];
    [stack addArrangedSubview:[self sectionLabel:@"Lồng tiếng"]];
    self.muteSwitch = [UISwitch new]; self.muteSwitch.on = [defaults boolForKey:@"TDMuteOriginal"];
    [stack addArrangedSubview:[self row:@"Tắt tiếng video gốc" control:self.muteSwitch]];
    self.originalVolumeSlider = [UISlider new];
    self.originalVolumeSlider.minimumValue = 0;
    self.originalVolumeSlider.maximumValue = 1;
    self.originalVolumeSlider.value = [defaults objectForKey:@"TDOriginalVolume"] ? [defaults floatForKey:@"TDOriginalVolume"] : 0.35;
    [stack addArrangedSubview:[self label:@"Âm lượng video gốc"]];
    [stack addArrangedSubview:self.originalVolumeSlider];
    [stack addArrangedSubview:[self label:@"Giữ tiếng gốc ở mức thấp để nghe rõ giọng lồng tiếng. Tắt tiếng gốc sẽ ưu tiên hơn thanh âm lượng này."]];
    self.speechVolumeSlider = [UISlider new];
    self.speechVolumeSlider.minimumValue = 0;
    self.speechVolumeSlider.maximumValue = 1;
    self.speechVolumeSlider.value = [defaults objectForKey:@"TDSpeechVolume"] ? [defaults floatForKey:@"TDSpeechVolume"] : 1;
    [stack addArrangedSubview:[self label:@"Âm lượng lồng tiếng"]];
    [stack addArrangedSubview:self.speechVolumeSlider];
    for (UIControl *control in @[self.speechSwitch, self.bilingualSwitch, self.rulesSwitch, self.captionSwitch, self.subtitleSizeSlider, self.captionOpacitySlider, self.originalFirstSwitch, self.muteSwitch]) {
        [control addTarget:self action:@selector(persistSettings) forControlEvents:UIControlEventValueChanged];
    }
    [self.speechVolumeSlider addTarget:self action:@selector(speechVolumeChanged) forControlEvents:UIControlEventValueChanged];
    [self.originalVolumeSlider addTarget:self action:@selector(originalVolumeChanged) forControlEvents:UIControlEventValueChanged];
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startButton setTitle:@"Dịch và phát" forState:UIControlStateNormal];
    self.startButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.startButton addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.startButton];
    self.activity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.activity.hidesWhenStopped = YES;
    [stack addArrangedSubview:self.activity];
    self.summaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.summaryButton setTitle:@"Tóm tắt video" forState:UIControlStateNormal];
    [self.summaryButton addTarget:self action:@selector(showSummary) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.summaryButton];
    UIButton *editSubtitles = [UIButton buttonWithType:UIButtonTypeSystem];
    [editSubtitles setTitle:@"Chỉnh sửa phụ đề" forState:UIControlStateNormal];
    [editSubtitles addTarget:self action:@selector(showSubtitleEditor) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:editSubtitles];
    UIButton *preferences = [UIButton buttonWithType:UIButtonTypeSystem];
    [preferences setTitle:@"Bảng thuật ngữ và quy tắc thay thế" forState:UIControlStateNormal];
    [preferences addTarget:self action:@selector(showTranslationPreferences) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:preferences];
    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    [stop setTitle:@"Dừng TransDuck" forState:UIControlStateNormal];
    [stop addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:stop];
    self.statusLabel = [self label:[TDManager shared].status ?: @"Sẵn sàng."];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.statusLabel];
    __weak typeof(self) weakSelf = self;
    [TDManager shared].statusChanged = ^(NSString *status) { weakSelf.statusLabel.text = status; [weakSelf refreshActivity]; };
    [[TDManager shared] checkSession:^(BOOL signedIn) { if (signedIn) [login setTitle:@"Đã đăng nhập · đổi tài khoản" forState:UIControlStateNormal]; }];
    [[TDManager shared] fetchDomains:^(NSArray<NSDictionary *> *domains) {
        weakSelf.domains = domains;
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"TDDomain"];
        for (NSDictionary *domain in domains) if ([domain[@"id"] isEqualToString:saved]) {
            [weakSelf.domainButton setTitle:domain[@"name"] forState:UIControlStateNormal];
            weakSelf.domainButton.accessibilityValue = saved;
            break;
        }
    }];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)login {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đăng nhập TransDuck" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Email"; field.keyboardType = UIKeyboardTypeEmailAddress; field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.textContentType = UITextContentTypeUsername; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Mật khẩu"; field.secureTextEntry = YES; field.textContentType = UITextContentTypePassword; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đăng nhập" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *email = [alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *password = alert.textFields[1].text;
        alert.textFields[1].text = @"";
        if (!email.length || !password.length) { self.statusLabel.text = @"Nhập email và mật khẩu."; return; }
        self.statusLabel.text = @"Đang đăng nhập…";
        [[TDManager shared] login:email password:password completion:^(NSError *error) { self.statusLabel.text = error ? error.localizedDescription : @"Đã đăng nhập."; }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)selectModel { [self choose:@"Mô hình dịch" options:TDModels() button:self.modelButton]; }
- (void)selectCaptionPosition { [self choose:@"Vị trí phụ đề" options:@[@{@"name":@"Trên", @"id":@"top"}, @{@"name":@"Giữa", @"id":@"middle"}, @{@"name":@"Dưới", @"id":@"bottom"}] button:self.captionPositionButton]; }
- (void)selectCaptionColor { [self choose:@"Màu chữ" options:@[@{@"name":@"Trắng", @"id":@"white"}, @{@"name":@"Vàng", @"id":@"yellow"}, @{@"name":@"Xanh lam", @"id":@"cyan"}, @{@"name":@"Xanh lá", @"id":@"green"}] button:self.captionColorButton]; }
- (void)selectDomain { [self choose:@"Lĩnh vực dịch" options:self.domains button:self.domainButton]; }
- (void)selectVoice {
    TDVoicePicker *picker = [TDVoicePicker new];
    __weak typeof(self) weakSelf = self;
    picker.selection = ^(NSDictionary *voice) {
        [weakSelf.voiceButton setTitle:voice[@"name"] forState:UIControlStateNormal];
        weakSelf.voiceButton.accessibilityValue = voice[@"id"];
        NSArray *parts = [voice[@"id"] componentsSeparatedByString:@"-"];
        if (parts.count >= 3) {
            NSString *locale = [NSString stringWithFormat:@"%@-%@", parts[0], parts[1]];
            for (NSDictionary *language in TDLanguages()) if ([language[@"id"] isEqualToString:locale]) {
                [weakSelf.languageButton setTitle:language[@"name"] forState:UIControlStateNormal];
                weakSelf.languageButton.accessibilityValue = locale;
                break;
            }
        }
        [weakSelf persistSettings];
    };
    [self.navigationController pushViewController:picker animated:YES];
}
- (void)selectLanguage {
    TDVoicePicker *picker = [TDVoicePicker new];
    picker.options = TDLanguages();
    picker.pickerTitle = @"Ngôn ngữ đích";
    __weak typeof(self) weakSelf = self;
    picker.selection = ^(NSDictionary *language) {
        [weakSelf.languageButton setTitle:language[@"name"] forState:UIControlStateNormal];
        weakSelf.languageButton.accessibilityValue = language[@"id"];
        NSString *voicePrefix = [language[@"id"] stringByAppendingString:@"-"];
        if (![weakSelf.voiceButton.accessibilityValue hasPrefix:voicePrefix]) {
            for (NSDictionary *voice in TDVoiceCatalog()) {
                if ([voice[@"id"] hasPrefix:voicePrefix]) {
                    [weakSelf.voiceButton setTitle:voice[@"name"] forState:UIControlStateNormal];
                    weakSelf.voiceButton.accessibilityValue = voice[@"id"];
                    break;
                }
            }
        }
        [weakSelf persistSettings];
    };
    [self.navigationController pushViewController:picker animated:YES];
}
- (void)choose:(NSString *)title options:(NSArray<NSDictionary *> *)options button:(UIButton *)button {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *option in options) [sheet addAction:[UIAlertAction actionWithTitle:option[@"name"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [button setTitle:option[@"name"] forState:UIControlStateNormal]; button.accessibilityValue = option[@"id"]; [self persistSettings]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = button;
    sheet.popoverPresentationController.sourceRect = button.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)persistSettings {
    NSString *model = self.modelButton.accessibilityValue ?: @"gemini-3.5-flash-lite";
    NSString *voice = self.voiceButton.accessibilityValue ?: @"vi-VN-HoaiMyNeural";
    NSString *language = self.languageButton.accessibilityValue ?: @"vi-VN";
    NSString *domain = self.domainButton.accessibilityValue ?: @"general";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:model forKey:@"TDModel"];
    [defaults setObject:voice forKey:@"TDVoice"];
    [defaults setObject:language forKey:@"TDLanguage"];
    [defaults setObject:domain forKey:@"TDDomain"];
    [defaults setBool:self.speechSwitch.on forKey:@"TDSpeech"];
    [defaults setBool:self.bilingualSwitch.on forKey:@"TDBilingual"];
    [defaults setBool:self.rulesSwitch.on forKey:@"TDTranslationRules"];
    [defaults setBool:self.captionSwitch.on forKey:@"TDShowCaptions"];
    [defaults setFloat:self.subtitleSizeSlider.value forKey:@"TDSubtitleSize"];
    [defaults setObject:self.captionPositionButton.accessibilityValue ?: @"bottom" forKey:@"TDCaptionPosition"];
    [defaults setObject:self.captionColorButton.accessibilityValue ?: @"white" forKey:@"TDCaptionColor"];
    [defaults setFloat:self.captionOpacitySlider.value forKey:@"TDCaptionOpacity"];
    [defaults setBool:self.originalFirstSwitch.on forKey:@"TDOriginalFirst"];
    [defaults setBool:self.muteSwitch.on forKey:@"TDMuteOriginal"];
    [defaults setFloat:self.originalVolumeSlider.value forKey:@"TDOriginalVolume"];
    [defaults setFloat:self.speechVolumeSlider.value forKey:@"TDSpeechVolume"];
}
- (void)refreshActivity {
    BOOL busy = self.awaitingSession || [TDManager shared].preparing;
    if (busy) [self.activity startAnimating];
    else [self.activity stopAnimating];
    self.startButton.enabled = !busy;
}
- (void)speechVolumeChanged {
    [self persistSettings];
    TDManager *manager = [TDManager shared];
    manager.speechVolume = self.speechVolumeSlider.value;
    manager.audioPlayer.volume = manager.speechVolume;
    os_log(OS_LOG_DEFAULT, "[TransDuckVoice] slider=%.2f active=%d", manager.speechVolume, manager.audioPlayer != nil);
}
- (void)originalVolumeChanged {
    [self persistSettings];
    TDManager *manager = [TDManager shared];
    manager.originalVolume = self.originalVolumeSlider.value;
    [manager applyOriginalVolume];
}
- (void)start {
    if (!self.player.currentVideoID.length) { self.statusLabel.text = @"Hãy mở video trước."; return; }
    [self persistSettings];
    NSString *model = self.modelButton.accessibilityValue ?: @"gemini-3.5-flash-lite";
    NSString *voice = self.voiceButton.accessibilityValue ?: @"vi-VN-HoaiMyNeural";
    NSString *language = self.languageButton.accessibilityValue ?: @"vi-VN";
    NSString *domain = self.domainButton.accessibilityValue ?: @"general";
    NSString *requestedVideoID = self.player.currentVideoID;
    BOOL shouldResume = self.player.playerState == 3;
    if (shouldResume) [self.player pause];
    self.awaitingSession = YES;
    self.statusLabel.text = @"Đang kiểm tra tài khoản…";
    [self refreshActivity];
    [[TDManager shared] checkSession:^(BOOL signedIn) {
        self.awaitingSession = NO;
        if (!signedIn || ![self.player.currentVideoID isEqualToString:requestedVideoID]) {
            if (shouldResume && [self.player.currentVideoID isEqualToString:requestedVideoID]) [self.player play];
            self.statusLabel.text = signedIn ? @"Video đã thay đổi." : @"Đăng nhập TransDuck trước khi dịch.";
            [self refreshActivity];
            return;
        }
        [[TDManager shared] startForPlayer:self.player model:model voice:voice targetLanguage:language domain:domain speech:self.speechSwitch.on bilingual:self.bilingualSwitch.on showCaptions:self.captionSwitch.on subtitleSize:self.subtitleSizeSlider.value translationRulesEnabled:self.rulesSwitch.on muteOriginal:self.muteSwitch.on originalVolume:self.originalVolumeSlider.value speechVolume:self.speechVolumeSlider.value resumeAfterPrepare:shouldResume];
        [self refreshActivity];
    }];
}
- (void)showSummary {
    TDSummaryPanel *panel = [TDSummaryPanel new];
    panel.player = self.player;
    panel.targetLanguage = self.languageButton.accessibilityValue ?: @"vi-VN";
    [self.navigationController pushViewController:panel animated:YES];
}
- (void)showSubtitleEditor {
    TDSubtitleEditor *editor = [TDSubtitleEditor new];
    editor.player = self.player;
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)showTranslationPreferences {
    TDShowTranslationPreferences(self.navigationController, self.languageButton.accessibilityValue ?: @"vi-VN", self.domainButton.accessibilityValue ?: @"general");
}
- (void)stop { [[TDManager shared] stop]; }
@end

%ctor {
    YMOverlayButtonSpec *button = [YMOverlayButtonSpec new];
    button.identifier = @"transduck.dubbing";
    button.symbolName = @"waveform.badge.mic";
    button.settingsSymbolName = @"waveform.badge.mic";
    button.displayName = @"TransDuck";
    button.tintColor = UIColor.whiteColor;
    button.sortOrder = 200;
    button.isVisible = ^BOOL(YTPlayerViewController *player) { return player.currentVideoID.length > 0 && YMIsOverlayButtonEnabled(@"transduck.dubbing"); };
    button.onTap = ^(YTPlayerViewController *player, __unused YTQTMButton *source) {
        TDPanel *panel = [TDPanel new];
        panel.player = player;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [player presentViewController:nav animated:YES completion:nil];
    };
    YMRegisterOverlayButton(button);
}
