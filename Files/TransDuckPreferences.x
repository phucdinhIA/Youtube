#import "Headers.h"

// Translation preferences share TransDuck's cookie jar with the native player client.
@interface TDTranslationPreferencesPanel : UITableViewController
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *domain;
@property (nonatomic, strong) UISegmentedControl *mode;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation TDTranslationPreferencesPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Quy tắc dịch";
    self.mode = [[UISegmentedControl alloc] initWithItems:@[@"Thuật ngữ", @"Thay thế"]];
    self.mode.selectedSegmentIndex = 0;
    [self.mode addTarget:self action:@selector(reloadRules) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.mode;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addRule)];
    self.tableView.rowHeight = 62;
    self.messageLabel = [UILabel new];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.textColor = UIColor.secondaryLabelColor;
    self.tableView.backgroundView = self.messageLabel;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
    config.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    config.HTTPShouldSetCookies = YES;
    config.timeoutIntervalForRequest = 30;
    self.session = [NSURLSession sessionWithConfiguration:config];
    [self reloadRules];
}
- (BOOL)isGlossary { return self.mode.selectedSegmentIndex == 0; }
- (NSString *)resource { return [self isGlossary] ? @"glossary" : @"replacement"; }
- (void)request:(NSString *)method path:(NSString *)path body:(NSDictionary *)body completion:(void (^)(id, NSError *))completion {
    NSURL *url = [NSURL URLWithString:[@"https://yd.transduck.com" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    if (body) {
        NSError *encodingError = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodingError];
        if (encodingError) { completion(nil, encodingError); return; }
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSError *error = networkError;
        if (!error && (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode < 200 || http.statusCode >= 300)) {
            error = [NSError errorWithDomain:@"TransDuck" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"TransDuck HTTP %ld", (long)http.statusCode]}];
        }
        id json = nil;
        if (!error && data.length) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [json isKindOfClass:NSDictionary.class] && [json[@"code"] integerValue] != 0) {
            NSString *message = [json[@"message"] isKindOfClass:NSString.class] ? json[@"message"] : @"Không lưu được quy tắc.";
            error = [NSError errorWithDomain:@"TransDuck" code:422 userInfo:@{NSLocalizedDescriptionKey:message}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, error); });
    }] resume];
}
- (void)reloadRules {
    self.items = @[];
    [self.tableView reloadData];
    self.messageLabel.text = @"Đang tải quy tắc…";
    NSString *resource = self.resource;
    [self request:@"GET" path:[@"/api/v2/translate-preference/" stringByAppendingString:resource] body:nil completion:^(id json, NSError *error) {
        if (![resource isEqualToString:self.resource]) return;
        NSArray *data = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        if (error || ![data isKindOfClass:NSArray.class]) { self.messageLabel.text = error.localizedDescription ?: @"Không tải được quy tắc."; return; }
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *item in data) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            if (![item[@"domain"] isEqualToString:self.domain]) continue;
            if ([self isGlossary] && ![item[@"toLanguage"] isEqualToString:self.language]) continue;
            [filtered addObject:item];
        }
        self.items = filtered;
        self.messageLabel.text = filtered.count ? @"" : @"Chưa có quy tắc trong lĩnh vực và ngôn ngữ này.";
        [self.tableView reloadData];
    }];
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section { return self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"rule"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"rule"];
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    NSString *source = [self isGlossary] ? item[@"sourceTerm"] : item[@"findText"];
    NSString *target = [self isGlossary] ? item[@"targetTerm"] : item[@"replaceText"];
    cell.textLabel.text = [source isKindOfClass:NSString.class] ? source : @"";
    cell.detailTextLabel.text = [target isKindOfClass:NSString.class] ? [@"→ " stringByAppendingString:target] : @"";
    UISwitch *toggle = [UISwitch new];
    toggle.tag = indexPath.row;
    toggle.on = [item[@"enabled"] boolValue];
    [toggle addTarget:self action:@selector(toggleRule:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}
- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self showEditorForItem:self.items[(NSUInteger)indexPath.row]];
}
- (void)addRule { [self showEditorForItem:nil]; }
- (NSDictionary *)bodyWithSource:(NSString *)source target:(NSString *)target enabled:(BOOL)enabled {
    if ([self isGlossary]) return @{@"domain":self.domain, @"toLanguage":self.language, @"sourceTerm":source, @"targetTerm":target, @"enabled":@(enabled)};
    return @{@"domain":self.domain, @"findText":source, @"replaceText":target, @"enabled":@(enabled)};
}
- (void)showEditorForItem:(NSDictionary *)item {
    NSString *source = [self isGlossary] ? item[@"sourceTerm"] : item[@"findText"];
    NSString *target = [self isGlossary] ? item[@"targetTerm"] : item[@"replaceText"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:item ? @"Sửa quy tắc" : @"Thêm quy tắc" message:[NSString stringWithFormat:@"%@ · %@", self.domain, self.language] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = [self isGlossary] ? @"Thuật ngữ gốc" : @"Văn bản cần thay"; field.text = source; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = [self isGlossary] ? @"Thuật ngữ đích" : @"Văn bản thay thế"; field.text = target; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *from = [alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *to = [alert.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!from.length || !to.length) { self.messageLabel.text = @"Hai trường không được trống."; return; }
        NSDictionary *body = [self bodyWithSource:from target:to enabled:item ? [item[@"enabled"] boolValue] : YES];
        NSString *path = [@"/api/v2/translate-preference/" stringByAppendingString:self.resource];
        if (item[@"id"]) path = [path stringByAppendingFormat:@"/%@", item[@"id"]];
        [self request:item ? @"PUT" : @"POST" path:path body:body completion:^(__unused id json, NSError *error) {
            if (error) self.messageLabel.text = error.localizedDescription;
            else [self reloadRules];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)toggleRule:(UISwitch *)toggle {
    if (toggle.tag < 0 || toggle.tag >= (NSInteger)self.items.count) return;
    NSDictionary *item = self.items[(NSUInteger)toggle.tag];
    NSString *source = [self isGlossary] ? item[@"sourceTerm"] : item[@"findText"];
    NSString *target = [self isGlossary] ? item[@"targetTerm"] : item[@"replaceText"];
    if (![source isKindOfClass:NSString.class] || ![target isKindOfClass:NSString.class] || !item[@"id"]) { toggle.on = !toggle.on; return; }
    toggle.enabled = NO;
    NSString *path = [NSString stringWithFormat:@"/api/v2/translate-preference/%@/%@", self.resource, item[@"id"]];
    [self request:@"PUT" path:path body:[self bodyWithSource:source target:target enabled:toggle.on] completion:^(__unused id json, NSError *error) {
        toggle.enabled = YES;
        if (error) { toggle.on = !toggle.on; self.messageLabel.text = error.localizedDescription; }
        else [self reloadRules];
    }];
}
- (void)tableView:(__unused UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    if (!item[@"id"]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xóa quy tắc?" message:@"Quy tắc này sẽ bị xóa khỏi tài khoản TransDuck." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xóa" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSString *path = [NSString stringWithFormat:@"/api/v2/translate-preference/%@/%@", self.resource, item[@"id"]];
        [self request:@"DELETE" path:path body:nil completion:^(__unused id json, NSError *error) {
            if (error) self.messageLabel.text = error.localizedDescription;
            else [self reloadRules];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

void TDShowTranslationPreferences(UINavigationController *navigation, NSString *language, NSString *domain) {
    TDTranslationPreferencesPanel *panel = [TDTranslationPreferencesPanel new];
    panel.language = language;
    panel.domain = domain;
    [navigation pushViewController:panel animated:YES];
}
