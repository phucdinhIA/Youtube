#import "Headers.h"
#import <AVFoundation/AVFoundation.h>
#import "TransDuckVoices.h"

// All player and UI state stays on the main queue. Network callbacks return there.
static NSString *const TDBaseURL = @"https://yd.transduck.com";
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
@property (nonatomic, strong) UISlider *speechVolumeSlider;
@property (nonatomic, strong) UISwitch *speechSwitch;
@property (nonatomic, strong) UISwitch *bilingualSwitch;
@property (nonatomic, strong) UISwitch *muteSwitch;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *summaryButton;
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
@property (nonatomic, strong) NSCache<NSString *, NSData *> *audioCache;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, copy) NSString *voice;
@property (nonatomic, copy) NSString *targetLanguage;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) void (^statusChanged)(NSString *);
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSInteger activeIndex;
@property (nonatomic) CGFloat previousTime;
@property (nonatomic) BOOL speech;
@property (nonatomic) BOOL bilingual;
@property (nonatomic) BOOL muteOriginal;
@property (nonatomic) BOOL originalMuted;
@property (nonatomic) BOOL originalMuteCaptured;
@property (nonatomic) BOOL preparing;
@property (nonatomic) float speechVolume;
@property (nonatomic, strong) NSMutableSet<NSString *> *downloads;
+ (instancetype)shared;
- (void)login:(NSString *)email password:(NSString *)password completion:(void (^)(NSError *))completion;
- (void)checkSession:(void (^)(BOOL))completion;
- (void)startForPlayer:(YTPlayerViewController *)player model:(NSString *)model voice:(NSString *)voice targetLanguage:(NSString *)targetLanguage speech:(BOOL)speech bilingual:(BOOL)bilingual muteOriginal:(BOOL)muteOriginal speechVolume:(float)speechVolume;
- (void)stop;
- (void)summaryForPlayer:(YTPlayerViewController *)player targetLanguage:(NSString *)targetLanguage completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)fetchCaptionsForVideo:(NSString *)videoID completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion;
- (void)saveSubtitle:(NSString *)srt videoID:(NSString *)videoID completion:(void (^)(NSError *))completion;
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
    self.generation++;
    [self.timer invalidate];
    self.timer = nil;
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    if (self.originalMuteCaptured && self.player.activeVideo) [self.player.activeVideo setMuted:self.originalMuted];
    self.originalMuteCaptured = NO;
    [self.captionLabel removeFromSuperview];
    self.captionLabel = nil;
    self.cues = nil;
    [self.downloads removeAllObjects];
    self.activeIndex = -1;
    self.preparing = NO;
    self.videoID = nil;
    self.player = nil;
    self.status = @"Đã dừng.";
}
- (void)fail:(NSString *)message generation:(NSUInteger)generation {
    if (generation != self.generation) return;
    [self stop];
    self.status = message;
}
- (void)startForPlayer:(YTPlayerViewController *)player model:(NSString *)model voice:(NSString *)voice targetLanguage:(NSString *)targetLanguage speech:(BOOL)speech bilingual:(BOOL)bilingual muteOriginal:(BOOL)muteOriginal speechVolume:(float)speechVolume {
    [self stop];
    NSString *videoID = player.currentVideoID;
    if (!videoID.length || player.isPlayingAd) { self.status = @"Hãy mở một video trước."; return; }
    self.player = player;
    self.videoID = videoID;
    self.model = model;
    self.voice = voice;
    self.targetLanguage = targetLanguage;
    self.speech = speech;
    self.speechVolume = MIN(1, MAX(0, speechVolume));
    self.bilingual = bilingual;
    self.muteOriginal = muteOriginal;
    self.preparing = YES;
    NSUInteger generation = self.generation;
    self.status = @"Đang tải phụ đề…";
    [self fetchCaptionsForVideo:videoID completion:^(NSArray<NSMutableDictionary *> *cues, NSError *error) {
        if (generation != self.generation) return;
        if (error || !cues.count) { [self fail:error.localizedDescription ?: @"Video chưa có phụ đề khả dụng trên TransDuck." generation:generation]; return; }
        self.cues = [cues mutableCopy];
        self.status = [NSString stringWithFormat:@"Đang dịch %lu câu…", (unsigned long)cues.count];
        [self translateFrom:0 generation:generation];
    }];
}
- (void)fetchCaptionsForVideo:(NSString *)videoID completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion {
    NSURLComponents *userParts = [NSURLComponents componentsWithString:[TDBaseURL stringByAppendingString:@"/api/v2/subtitle/getUserSubtitleList"]];
    userParts.queryItems = @[[NSURLQueryItem queryItemWithName:@"videoId" value:videoID]];
    NSString *userPath = [userParts.URL.absoluteString substringFromIndex:TDBaseURL.length];
    [self request:userPath method:@"GET" body:nil completion:^(id json, __unused NSError *error) {
        NSArray *saved = [json isKindOfClass:NSDictionary.class] ? json[@"subtitles"] : nil;
        NSArray *parsed = [self parseCaptionItems:saved];
        if (parsed.count) { completion(parsed, nil); return; }
        [self fetchOriginalCaptionsForVideo:videoID completion:completion];
    }];
}
- (void)fetchOriginalCaptionsForVideo:(NSString *)videoID completion:(void (^)(NSArray<NSMutableDictionary *> *, NSError *))completion {
    NSURLComponents *parts = [NSURLComponents componentsWithString:[TDBaseURL stringByAppendingString:@"/api/v2/subtitle/getYoutubeSubtitleList"]];
    parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"videoId" value:videoID], [NSURLQueryItem queryItemWithName:@"version" value:@"1.0"]];
    NSString *path = [parts.URL.absoluteString substringFromIndex:TDBaseURL.length];
    [self request:path method:@"GET" body:nil completion:^(id json, NSError *error) {
        if (error || ![json isKindOfClass:NSArray.class]) { completion(nil, error ?: [NSError errorWithDomain:@"TransDuck" code:422 userInfo:@{NSLocalizedDescriptionKey:@"Không đọc được phụ đề."}]); return; }
        completion([self parseCaptionItems:json], nil);
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
        if (![text isKindOfClass:NSString.class] || !text.length || duration <= 0 || start < 0) continue;
        [cues addObject:[@{@"text":text, @"start":@(start), @"end":@(start + duration)} mutableCopy]];
    }
    [cues sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"start"] compare:b[@"start"]]; }];
    for (NSUInteger i = 0; i < cues.count; i++) cues[i][@"index"] = @(i);
    return cues;
}
- (void)saveSubtitle:(NSString *)srt videoID:(NSString *)videoID completion:(void (^)(NSError *))completion {
    [self request:@"/api/v2/subtitle/saveUserSubtitle" method:@"POST" body:@{@"videoId":videoID, @"srt":srt} completion:^(id json, NSError *error) {
        if (error) { completion(error); return; }
        NSDictionary *payload = [json isKindOfClass:NSDictionary.class] ? json : nil;
        if ([payload[@"success"] boolValue]) { completion(nil); return; }
        completion([NSError errorWithDomain:@"TransDuck" code:422 userInfo:@{NSLocalizedDescriptionKey:payload[@"message"] ?: @"Không lưu được phụ đề."}]);
    }];
}
- (void)summaryForPlayer:(YTPlayerViewController *)player targetLanguage:(NSString *)targetLanguage completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *videoID = player.currentVideoID;
    if (!videoID.length) { completion(nil, [NSError errorWithDomain:@"TransDuck" code:400 userInfo:@{NSLocalizedDescriptionKey:@"Hãy mở video trước."}]); return; }
    [self fetchCaptionsForVideo:videoID completion:^(NSArray<NSMutableDictionary *> *cues, NSError *error) {
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
- (void)translateFrom:(NSUInteger)offset generation:(NSUInteger)generation {
    if (generation != self.generation) return;
    if (offset >= self.cues.count) {
        [self beginPlayback:generation];
        if (self.speech) {
            self.status = [NSString stringWithFormat:@"Đang tạo giọng %@…", self.voice];
            [self synthesizeFrom:0 generation:generation];
        } else { self.preparing = NO; self.status = @"Phụ đề tiếng Việt đã sẵn sàng."; }
        return;
    }
    NSRange range = NSMakeRange(offset, MIN([self.model isEqualToString:@"google"] ? 50 : 10, self.cues.count - offset));
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
            [self translateFrom:NSMaxRange(range) generation:generation];
        }];
        return;
    }
    NSMutableArray *subtitles = [NSMutableArray array];
    for (NSDictionary *cue in batch) {
        [subtitles addObject:@{@"index":cue[@"index"], @"text":cue[@"text"], @"googleTranslation":cue[@"text"], @"start":cue[@"start"], @"end":cue[@"end"]}];
    }
    NSDictionary *body = @{@"videoId":self.videoID, @"title":self.videoID, @"model":self.model, @"toLanguage":self.targetLanguage, @"domain":@"general", @"translationRulesEnabled":@NO, @"skipTranslation":@NO, @"subtitles":subtitles};
    [self request:@"/api/v2/ai-translate/translate" method:@"POST" body:body completion:^(id json, NSError *error) {
        if (generation != self.generation) return;
        NSArray *results = [json isKindOfClass:NSDictionary.class] ? json[@"subtitleTranslateResults"] : nil;
        if (error || results.count != batch.count) { [self fail:error.localizedDescription ?: @"Bản dịch không đầy đủ." generation:generation]; return; }
        for (NSUInteger i = 0; i < batch.count; i++) {
            NSString *text = [results[i] isKindOfClass:NSDictionary.class] ? results[i][@"translateResult"] : nil;
            self.cues[offset + i][@"translated"] = text.length ? text : batch[i][@"text"];
        }
        [self translateFrom:NSMaxRange(range) generation:generation];
    }];
}
- (void)synthesizeFrom:(NSUInteger)offset generation:(NSUInteger)generation {
    if (generation != self.generation) return;
    if (offset >= self.cues.count) { self.preparing = NO; self.status = @"Phụ đề và lồng tiếng đã sẵn sàng."; return; }
    NSRange range = NSMakeRange(offset, MIN(10, self.cues.count - offset));
    NSArray *batch = [self.cues subarrayWithRange:range];
    NSMutableArray *subtitles = [NSMutableArray array];
    for (NSDictionary *cue in batch) [subtitles addObject:@{@"index":cue[@"index"], @"text":cue[@"translated"], @"start":cue[@"start"], @"end":cue[@"end"]}];
    NSDictionary *body = @{@"subtitles":subtitles, @"config":@{@"model":self.model, @"voice":self.voice, @"voiceType":@"azure", @"toLanguage":self.targetLanguage, @"skipTranslation":@YES}, @"videoDetails":@{@"videoId":self.videoID, @"title":self.videoID, @"subtitleLevel":@2}, @"v2Version":@YES};
    [self request:@"/api/v2/dubbing/generateDubbing" method:@"POST" body:body completion:^(id json, NSError *error) {
        if (generation != self.generation) return;
        NSArray *results = [json isKindOfClass:NSDictionary.class] ? json[@"subtitleDubbingResults"] : nil;
        if (error || results.count != batch.count) { self.preparing = NO; self.status = error.localizedDescription ?: @"TTS không đầy đủ; phụ đề vẫn hoạt động."; return; }
        for (NSUInteger i = 0; i < batch.count; i++) {
            NSString *url = [results[i] isKindOfClass:NSDictionary.class] ? results[i][@"ttsUrl"] : nil;
            if ([url hasPrefix:@"https://"] && ![url.lastPathComponent.lowercaseString containsString:@"empty_audio"]) self.cues[offset + i][@"audioURL"] = url;
        }
        if (self.activeIndex >= (NSInteger)offset && self.activeIndex < (NSInteger)NSMaxRange(range) && !self.audioPlayer) self.activeIndex = -1;
        [self prefetchNearIndex:MAX(0, self.activeIndex)];
        [self synthesizeFrom:NSMaxRange(range) generation:generation];
    }];
}
- (void)beginPlayback:(NSUInteger)generation {
    if (generation != self.generation || !self.player.playerView) return;
    UIView *view = self.player.playerView;
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.68];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 3;
    label.layer.cornerRadius = 8;
    label.clipsToBounds = YES;
    label.hidden = YES;
    [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-46],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor multiplier:0.86]
    ]];
    self.captionLabel = label;
    self.previousTime = -1;
    if (self.speech && self.muteOriginal && self.player.activeVideo) {
        self.originalMuted = self.player.activeVideo.isMuted;
        self.originalMuteCaptured = YES;
        [self.player.activeVideo setMuted:YES];
    }
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)tick {
    YTPlayerViewController *player = self.player;
    if (!player || ![player.currentVideoID isEqualToString:self.videoID]) { [self stop]; return; }
    CGFloat time = player.currentVideoMediaTime;
    BOOL advancing = self.previousTime < 0 || fabs(time - self.previousTime) > 0.015;
    self.previousTime = time;
    NSInteger low = 0, high = (NSInteger)self.cues.count - 1, found = -1;
    while (low <= high) {
        NSInteger middle = low + (high - low) / 2;
        NSDictionary *cue = self.cues[(NSUInteger)middle];
        if (time < [cue[@"start"] doubleValue]) high = middle - 1;
        else if (time >= [cue[@"end"] doubleValue]) low = middle + 1;
        else { found = middle; break; }
    }
    if (found != self.activeIndex) {
        self.captionLabel.hidden = found < 0;
        if (found >= 0) {
            NSDictionary *cue = self.cues[(NSUInteger)found];
            NSString *translated = cue[@"translated"] ?: @"";
            self.captionLabel.text = self.bilingual ? [NSString stringWithFormat:@"%@\n%@", translated, cue[@"text"]] : translated;
        }
    }
    if (!advancing) { [self.audioPlayer pause]; return; }
    if (found == self.activeIndex) {
        if (self.audioPlayer && found >= 0) {
            CGFloat offset = MAX(0, time - [self.cues[(NSUInteger)found][@"start"] doubleValue]);
            if (fabs(self.audioPlayer.currentTime - offset) > 0.4) self.audioPlayer.currentTime = MIN(offset, self.audioPlayer.duration);
            CGFloat rate = [(YTMainAppVideoPlayerOverlayViewController *)player.activeVideoPlayerOverlay currentPlaybackRate];
            self.audioPlayer.rate = MIN(2, MAX(0.5, rate > 0 ? rate : 1));
            if (!self.audioPlayer.isPlaying) [self.audioPlayer play];
        }
        return;
    }
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    self.activeIndex = found;
    [self prefetchNearIndex:MAX(0, found)];
    if (found < 0 || !self.speech) return;
    NSString *urlString = self.cues[(NSUInteger)found][@"audioURL"];
    if (!urlString) return;
    NSData *cached = [self.audioCache objectForKey:urlString];
    if (cached) { [self playData:cached index:found time:time]; return; }
    [self loadAudioAtIndex:found];
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
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            [self.downloads removeObject:urlString];
            if (error || ![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode != 200 || ![http.URL.scheme isEqualToString:@"https"] || data.length < 1000) return;
            [self.audioCache setObject:data forKey:urlString cost:data.length];
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
            if (now < [cue[@"start"] doubleValue] || now >= [cue[@"end"] doubleValue]) return;
            audio.currentTime = MIN(MAX(0, now - [cue[@"start"] doubleValue]), audio.duration);
            CGFloat rate = [(YTMainAppVideoPlayerOverlayViewController *)self.player.activeVideoPlayerOverlay currentPlaybackRate];
            audio.rate = MIN(2, MAX(0.5, rate > 0 ? rate : 1));
            audio.volume = self.speechVolume;
            self.audioPlayer = audio;
            if (fabs(now - self.previousTime) > 0.015) [audio play];
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
        weakSelf.stateLabel.text = error.localizedDescription ?: @"";
        weakSelf.tableView.backgroundView = summary ? nil : weakSelf.stateLabel;
        [weakSelf.tableView reloadData];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.summary ? 2 : 0; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    NSArray *highlights = [self.summary[@"highlights"] isKindOfClass:NSArray.class] ? self.summary[@"highlights"] : @[];
    return highlights.count;
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
        NSDictionary *item = self.summary[@"highlights"][(NSUInteger)indexPath.row];
        NSTimeInterval seconds = [item[@"timestamp"] doubleValue];
        cell.textLabel.text = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)(seconds / 60), (long)((NSInteger)seconds % 60)];
    }
    return cell;
}
- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UIPasteboard.generalPasteboard.string = self.summary[@"summary"];
        return;
    }
    NSDictionary *item = self.summary[@"highlights"][(NSUInteger)indexPath.row];
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
    [[TDManager shared] fetchCaptionsForVideo:videoID completion:^(NSArray<NSDictionary *> *cues, NSError *error) {
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
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = title;
    return button;
}
- (UIView *)row:(NSString *)title control:(UIView *)control {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:title], control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return row;
}
- (UILabel *)label:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
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
    self.modelButton = [self menuButton:@"Gemini Flash Lite" options:TDModels() action:@selector(selectModel)];
    [stack addArrangedSubview:[self row:@"Mô hình dịch" control:self.modelButton]];
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
    self.speechSwitch = [UISwitch new]; self.speechSwitch.on = [defaults objectForKey:@"TDSpeech"] ? [defaults boolForKey:@"TDSpeech"] : YES;
    [stack addArrangedSubview:[self row:@"Lồng tiếng" control:self.speechSwitch]];
    self.bilingualSwitch = [UISwitch new]; self.bilingualSwitch.on = [defaults boolForKey:@"TDBilingual"];
    [stack addArrangedSubview:[self row:@"Phụ đề song ngữ" control:self.bilingualSwitch]];
    self.muteSwitch = [UISwitch new]; self.muteSwitch.on = [defaults boolForKey:@"TDMuteOriginal"];
    [stack addArrangedSubview:[self row:@"Tắt tiếng video gốc" control:self.muteSwitch]];
    [stack addArrangedSubview:[self label:@"Giữ tiếng gốc bật mặc định. Có thể tắt nếu chỉ muốn nghe giọng lồng tiếng."]];
    self.speechVolumeSlider = [UISlider new];
    self.speechVolumeSlider.minimumValue = 0;
    self.speechVolumeSlider.maximumValue = 1;
    self.speechVolumeSlider.value = [defaults objectForKey:@"TDSpeechVolume"] ? [defaults floatForKey:@"TDSpeechVolume"] : 1;
    [stack addArrangedSubview:[self label:@"Âm lượng lồng tiếng"]];
    [stack addArrangedSubview:self.speechVolumeSlider];
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startButton setTitle:@"Dịch và phát" forState:UIControlStateNormal];
    self.startButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.startButton addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.startButton];
    self.summaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.summaryButton setTitle:@"Tóm tắt video" forState:UIControlStateNormal];
    [self.summaryButton addTarget:self action:@selector(showSummary) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.summaryButton];
    UIButton *editSubtitles = [UIButton buttonWithType:UIButtonTypeSystem];
    [editSubtitles setTitle:@"Chỉnh sửa phụ đề" forState:UIControlStateNormal];
    [editSubtitles addTarget:self action:@selector(showSubtitleEditor) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:editSubtitles];
    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    [stop setTitle:@"Dừng TransDuck" forState:UIControlStateNormal];
    [stop addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:stop];
    self.statusLabel = [self label:[TDManager shared].status ?: @"Sẵn sàng."];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.statusLabel];
    __weak typeof(self) weakSelf = self;
    [TDManager shared].statusChanged = ^(NSString *status) { weakSelf.statusLabel.text = status; weakSelf.startButton.enabled = ![TDManager shared].preparing; };
    [[TDManager shared] checkSession:^(BOOL signedIn) { if (signedIn) [login setTitle:@"Đã đăng nhập · đổi tài khoản" forState:UIControlStateNormal]; }];
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
- (void)selectVoice {
    TDVoicePicker *picker = [TDVoicePicker new];
    __weak typeof(self) weakSelf = self;
    picker.selection = ^(NSDictionary *voice) {
        [weakSelf.voiceButton setTitle:voice[@"name"] forState:UIControlStateNormal];
        weakSelf.voiceButton.accessibilityValue = voice[@"id"];
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
    };
    [self.navigationController pushViewController:picker animated:YES];
}
- (void)choose:(NSString *)title options:(NSArray<NSDictionary *> *)options button:(UIButton *)button {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *option in options) [sheet addAction:[UIAlertAction actionWithTitle:option[@"name"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [button setTitle:option[@"name"] forState:UIControlStateNormal]; button.accessibilityValue = option[@"id"]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = button;
    sheet.popoverPresentationController.sourceRect = button.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)start {
    NSString *model = self.modelButton.accessibilityValue ?: @"gemini-3.5-flash-lite";
    NSString *voice = self.voiceButton.accessibilityValue ?: @"vi-VN-HoaiMyNeural";
    NSString *language = self.languageButton.accessibilityValue ?: @"vi-VN";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:model forKey:@"TDModel"];
    [defaults setObject:voice forKey:@"TDVoice"];
    [defaults setObject:language forKey:@"TDLanguage"];
    [defaults setBool:self.speechSwitch.on forKey:@"TDSpeech"];
    [defaults setBool:self.bilingualSwitch.on forKey:@"TDBilingual"];
    [defaults setBool:self.muteSwitch.on forKey:@"TDMuteOriginal"];
    [defaults setFloat:self.speechVolumeSlider.value forKey:@"TDSpeechVolume"];
    [[TDManager shared] checkSession:^(BOOL signedIn) {
        if (!signedIn) { self.statusLabel.text = @"Đăng nhập TransDuck trước khi dịch."; return; }
        [[TDManager shared] startForPlayer:self.player model:model voice:voice targetLanguage:language speech:self.speechSwitch.on bilingual:self.bilingualSwitch.on muteOriginal:self.muteSwitch.on speechVolume:self.speechVolumeSlider.value];
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
