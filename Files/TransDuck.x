#import "Headers.h"
#import <AVFoundation/AVFoundation.h>

// All player and UI state stays on the main queue. Network callbacks return there.
static NSString *const TDBaseURL = @"https://yd.transduck.com";
static NSArray<NSDictionary *> *TDModels(void) {
    return @[
        @{ @"name": @"Google", @"id": @"google" },
        @{ @"name": @"Gemini Flash Lite", @"id": @"gemini-3.5-flash-lite" },
        @{ @"name": @"DeepSeek Flash", @"id": @"deepseek-v4-flash" },
        @{ @"name": @"GPT Sol", @"id": @"gpt-5.6-sol" },
        @{ @"name": @"GPT Luna", @"id": @"gpt-5.6-luna" },
        @{ @"name": @"Claude Opus", @"id": @"claude-opus-5" },
        @{ @"name": @"Claude Sonnet", @"id": @"claude-sonnet-5" },
        @{ @"name": @"Claude Haiku", @"id": @"claude-haiku-4-5-20251001" }
    ];
}

@interface TDPanel : UIViewController
@property (nonatomic, weak) YTPlayerViewController *player;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *modelButton;
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UISwitch *speechSwitch;
@property (nonatomic, strong) UISwitch *bilingualSwitch;
@property (nonatomic, strong) UISwitch *muteSwitch;
@property (nonatomic, strong) UIButton *startButton;
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
+ (instancetype)shared;
- (void)login:(NSString *)email password:(NSString *)password completion:(void (^)(NSError *))completion;
- (void)checkSession:(void (^)(BOOL))completion;
- (void)startForPlayer:(YTPlayerViewController *)player model:(NSString *)model voice:(NSString *)voice speech:(BOOL)speech bilingual:(BOOL)bilingual muteOriginal:(BOOL)muteOriginal;
- (void)stop;
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
- (void)startForPlayer:(YTPlayerViewController *)player model:(NSString *)model voice:(NSString *)voice speech:(BOOL)speech bilingual:(BOOL)bilingual muteOriginal:(BOOL)muteOriginal {
    [self stop];
    NSString *videoID = player.currentVideoID;
    if (!videoID.length || player.isPlayingAd) { self.status = @"Hãy mở một video trước."; return; }
    self.player = player;
    self.videoID = videoID;
    self.model = model;
    self.voice = voice;
    self.speech = speech;
    self.bilingual = bilingual;
    self.muteOriginal = muteOriginal;
    self.preparing = YES;
    NSUInteger generation = self.generation;
    self.status = @"Đang tải phụ đề…";
    NSURLComponents *parts = [NSURLComponents componentsWithString:[TDBaseURL stringByAppendingString:@"/api/v2/subtitle/getYoutubeSubtitleList"]];
    parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"videoId" value:videoID], [NSURLQueryItem queryItemWithName:@"version" value:@"1.0"]];
    NSString *path = [parts.URL.absoluteString substringFromIndex:TDBaseURL.length];
    [self request:path method:@"GET" body:nil completion:^(id json, NSError *error) {
        if (generation != self.generation) return;
        if (error || ![json isKindOfClass:NSArray.class]) { [self fail:error.localizedDescription ?: @"Không đọc được phụ đề." generation:generation]; return; }
        NSMutableArray *cues = [NSMutableArray array];
        for (NSDictionary *item in json) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *timing = item[@"$"];
            NSString *text = item[@"_"];
            double start = [timing[@"start"] doubleValue], duration = [timing[@"dur"] doubleValue];
            if (![text isKindOfClass:NSString.class] || !text.length || duration <= 0 || start < 0) continue;
            [cues addObject:[@{@"index":@(cues.count), @"text":text, @"start":@(start), @"end":@(start + duration)} mutableCopy]];
        }
        if (!cues.count) { [self fail:@"Video chưa có phụ đề khả dụng trên TransDuck." generation:generation]; return; }
        self.cues = cues;
        self.status = [NSString stringWithFormat:@"Đang dịch %lu câu…", (unsigned long)cues.count];
        [self translateFrom:0 generation:generation];
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
        parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"language" value:@"auto"], [NSURLQueryItem queryItemWithName:@"to" value:@"vi-VN"], [NSURLQueryItem queryItemWithName:@"videoId" value:self.videoID], [NSURLQueryItem queryItemWithName:@"platform" value:@"pc"]];
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
    NSDictionary *body = @{@"videoId":self.videoID, @"title":self.videoID, @"model":self.model, @"toLanguage":@"vi-VN", @"domain":@"general", @"translationRulesEnabled":@NO, @"skipTranslation":@NO, @"subtitles":subtitles};
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
    NSDictionary *body = @{@"subtitles":subtitles, @"config":@{@"model":self.model, @"voice":self.voice, @"voiceType":@"azure", @"toLanguage":@"vi-VN", @"skipTranslation":@YES}, @"videoDetails":@{@"videoId":self.videoID, @"title":self.videoID, @"subtitleLevel":@2}, @"v2Version":@YES};
    [self request:@"/api/v2/dubbing/generateDubbing" method:@"POST" body:body completion:^(id json, NSError *error) {
        if (generation != self.generation) return;
        NSArray *results = [json isKindOfClass:NSDictionary.class] ? json[@"subtitleDubbingResults"] : nil;
        if (error || results.count != batch.count) { self.preparing = NO; self.status = error.localizedDescription ?: @"TTS không đầy đủ; phụ đề vẫn hoạt động."; return; }
        for (NSUInteger i = 0; i < batch.count; i++) {
            NSString *url = [results[i] isKindOfClass:NSDictionary.class] ? results[i][@"ttsUrl"] : nil;
            if ([url hasPrefix:@"https://"] && ![url.lastPathComponent.lowercaseString containsString:@"empty_audio"]) self.cues[offset + i][@"audioURL"] = url;
        }
        if (self.activeIndex >= (NSInteger)offset && self.activeIndex < (NSInteger)NSMaxRange(range) && !self.audioPlayer) self.activeIndex = -1;
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
    NSInteger found = -1;
    for (NSUInteger i = 0; i < self.cues.count; i++) {
        NSDictionary *cue = self.cues[i];
        if (time >= [cue[@"start"] doubleValue] && time < [cue[@"end"] doubleValue]) { found = (NSInteger)i; break; }
        if (time < [cue[@"start"] doubleValue]) break;
    }
    self.captionLabel.hidden = found < 0;
    if (found >= 0) {
        NSDictionary *cue = self.cues[(NSUInteger)found];
        NSString *translated = cue[@"translated"] ?: @"";
        self.captionLabel.text = self.bilingual ? [NSString stringWithFormat:@"%@\n%@", translated, cue[@"text"]] : translated;
    }
    if (!advancing) { [self.audioPlayer pause]; return; }
    if (found == self.activeIndex) {
        if (self.audioPlayer && found >= 0) {
            CGFloat offset = MAX(0, time - [self.cues[(NSUInteger)found][@"start"] doubleValue]);
            if (fabs(self.audioPlayer.currentTime - offset) > 0.4) self.audioPlayer.currentTime = MIN(offset, self.audioPlayer.duration);
            if (!self.audioPlayer.isPlaying) [self.audioPlayer play];
        }
        return;
    }
    [self.audioPlayer stop];
    self.audioPlayer = nil;
    self.activeIndex = found;
    if (found < 0 || !self.speech) return;
    NSString *urlString = self.cues[(NSUInteger)found][@"audioURL"];
    if (!urlString) return;
    NSUInteger generation = self.generation;
    NSInteger requestedIndex = found;
    NSData *cached = [self.audioCache objectForKey:urlString];
    if (cached) { [self playData:cached index:found time:time]; return; }
    NSURL *url = [NSURL URLWithString:urlString];
    if (![url.scheme isEqualToString:@"https"]) return;
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error || ![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode != 200 || ![http.URL.scheme isEqualToString:@"https"] || data.length < 1000) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            [self.audioCache setObject:data forKey:urlString cost:data.length];
            if (self.activeIndex == requestedIndex && self.player) [self playData:data index:requestedIndex time:self.player.currentVideoMediaTime];
        });
    }] resume];
}
- (void)playData:(NSData *)data index:(NSInteger)index time:(CGFloat)time {
    NSError *error = nil;
    AVAudioPlayer *audio = [[AVAudioPlayer alloc] initWithData:data error:&error];
    if (!audio || error) return;
    audio.enableRate = YES;
    audio.currentTime = MIN(MAX(0, time - [self.cues[(NSUInteger)index][@"start"] doubleValue]), audio.duration);
    [audio prepareToPlay];
    self.audioPlayer = audio;
    [audio play];
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
    self.voiceButton = [self menuButton:@"Hoài My" options:@[] action:@selector(selectVoice)];
    [stack addArrangedSubview:[self row:@"Giọng Azure" control:self.voiceButton]];
    self.speechSwitch = [UISwitch new]; self.speechSwitch.on = YES;
    [stack addArrangedSubview:[self row:@"Lồng tiếng" control:self.speechSwitch]];
    self.bilingualSwitch = [UISwitch new];
    [stack addArrangedSubview:[self row:@"Phụ đề song ngữ" control:self.bilingualSwitch]];
    self.muteSwitch = [UISwitch new];
    [stack addArrangedSubview:[self row:@"Tắt tiếng video gốc" control:self.muteSwitch]];
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startButton setTitle:@"Dịch và phát" forState:UIControlStateNormal];
    self.startButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.startButton addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.startButton];
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
- (void)selectVoice { [self choose:@"Giọng Azure" options:@[@{@"name":@"Hoài My", @"id":@"vi-VN-HoaiMyNeural"}, @{@"name":@"Nam Minh", @"id":@"vi-VN-NamMinhNeural"}] button:self.voiceButton]; }
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
    [[TDManager shared] checkSession:^(BOOL signedIn) {
        if (!signedIn) { self.statusLabel.text = @"Đăng nhập TransDuck trước khi dịch."; return; }
        [[TDManager shared] startForPlayer:self.player model:model voice:voice speech:self.speechSwitch.on bilingual:self.bilingualSwitch.on muteOriginal:self.muteSwitch.on];
    }];
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
