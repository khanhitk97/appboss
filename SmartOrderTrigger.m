#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

// ==========================================
// CẤU HÌNH API GOOGLE SHEETS MỚI NHẤT
// ==========================================
#define GOOGLE_SHEET_API_URL @"https://script.google.com/macros/s/AKfycbxhrz4aZ5eaDNMzyLk4lejznQNoipIE7VN7qOLmy0TNxjddHaNzKmWjxIubgIrbiKhh/exec"

@interface SmartOrderManager : NSObject
@property (nonatomic, assign) BOOL isAuthorized;
@property (nonatomic, assign) NSInteger triggerSecond;
@property (nonatomic, assign) BOOL isTriggered;
@property (nonatomic, strong) dispatch_source_t scanTimer;
@property (nonatomic, strong) dispatch_source_t syncTimer;
@end

@implementation SmartOrderManager

+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SmartOrderManager sharedInstance] startService];
    });
}

+ (instancetype)sharedInstance {
    static SmartOrderManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SmartOrderManager alloc] init];
        instance.isAuthorized = NO;
        instance.triggerSecond = 3;
        instance.isTriggered = NO;
    });
    return instance;
}

+ (UIWindow *)findActiveWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (NSString *)getDeviceID {
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (!uuid) return @"UNKNOWN0";
    return [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].uppercaseString;
}

- (void)startService {
    set_speed_factor(1.0f);

    // Gửi ngay khi mở app
    [self syncWithGoogleSheets];

    // Lặp lại mỗi 3 phút để cập nhật trạng thái mới nhất từ Sheets
    self.syncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.syncTimer, dispatch_walltime(NULL, 0), 180ull * NSEC_PER_SEC, 10ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.syncTimer, ^{
        [weakSelf syncWithGoogleSheets];
    });
    dispatch_resume(self.syncTimer);

    // Quét màn hình bắt đúng mốc giây
    self.scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.scanTimer, dispatch_walltime(NULL, 0), 400ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.scanTimer, ^{
        [weakSelf scanCurrentScreenFast];
    });
    dispatch_resume(self.scanTimer);
}

- (void)syncWithGoogleSheets {
    NSString *deviceID = [self getDeviceID];
    NSString *urlStr = [NSString stringWithFormat:@"%@?device_id=%@", GOOGLE_SHEET_API_URL, deviceID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    [request setHTTPMethod:@"GET"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (!error && data) {
            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (!jsonErr && [json isKindOfClass:[NSDictionary class]]) {
                BOOL active = [json[@"is_active"] boolValue];
                NSInteger sec = [json[@"trigger_second"] integerValue];

                dispatch_async(dispatch_get_main_queue(), ^{
                    self.isAuthorized = active;
                    if (sec > 0) self.triggerSecond = sec;
                    if (!active) set_speed_factor(1.0f);
                });
            }
        }
    }];
    [task resume];
}

- (void)scanCurrentScreenFast {
    if (!self.isAuthorized) return;

    UIWindow *window = [SmartOrderManager findActiveWindow];
    if (!window) return;

    BOOL foundTargetSecond = NO;
    BOOL foundOrderScreen = NO;

    [self fastSearch:window currentDepth:0 maxDepth:8 foundTarget:&foundTargetSecond foundOrder:&foundOrderScreen];

    if (foundTargetSecond && !self.isTriggered) {
        self.isTriggered = YES;
        set_speed_factor(5.0f);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set_speed_factor(1.0f);
        });
    }

    if (!foundOrderScreen) {
        self.isTriggered = NO;
    }
}

- (void)fastSearch:(UIView *)view currentDepth:(NSInteger)depth maxDepth:(NSInteger)maxDepth foundTarget:(BOOL *)foundTarget foundOrder:(BOOL *)foundOrder {
    if (!view || view.isHidden || view.alpha < 0.1 || depth > maxDepth) return;

    NSString *matchPattern1 = [NSString stringWithFormat:@"sau %ld giây", (long)self.triggerSecond];
    NSString *matchPattern2 = [NSString stringWithFormat:@"%ld giây", (long)self.triggerSecond];

    if ([view isKindOfClass:[UILabel class]]) {
        NSString *txt = [(UILabel *)view text];
        if (txt.length > 5) {
            if ([txt containsString:@"được nhận đơn sau"]) {
                *foundOrder = YES;
                if ([txt containsString:matchPattern1] || [txt containsString:matchPattern2]) {
                    *foundTarget = YES;
                    return;
                }
            } else if ([txt containsString:@"Vuốt để nhận đơn"]) {
                *foundOrder = YES;
            }
        }
    } else {
        NSString *acc = view.accessibilityLabel;
        if (acc.length > 5) {
            if ([acc containsString:@"được nhận đơn sau"]) {
                *foundOrder = YES;
                if ([acc containsString:matchPattern1] || [acc containsString:matchPattern2]) {
                    *foundTarget = YES;
                    return;
                }
            } else if ([acc containsString:@"Vuốt để nhận đơn"]) {
                *foundOrder = YES;
            }
        }
    }

    for (UIView *sub in [view.subviews reverseObjectEnumerator]) {
        [self fastSearch:sub currentDepth:depth + 1 maxDepth:maxDepth foundTarget:foundTarget foundOrder:foundOrder];
        if (*foundTarget) break;
    }
}

@end
