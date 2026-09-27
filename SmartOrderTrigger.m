#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

// ==========================================
// CẤU HÌNH API GOOGLE SHEETS
// ==========================================
#define GOOGLE_SHEET_API_URL @"https://script.google.com/macros/s/AKfycbxJ9hbctimNO5x23W5YT06SLunhJcUKIdkEzd652nhICuxGmugziDna5GEYkwQgqZEJ/exec"
#define KEYCHAIN_SERVICE @"com.speedhack.device.service"
#define KEYCHAIN_ACCOUNT @"PermanentDeviceID"

@interface SmartOrderManager : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, assign) BOOL isAuthorized;
@property (nonatomic, assign) NSInteger triggerSecond;
@property (nonatomic, assign) BOOL isTriggered;
@property (nonatomic, strong) dispatch_source_t scanTimer;
@property (nonatomic, strong) dispatch_source_t syncTimer;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation SmartOrderManager

+ (void)load {
    // Chờ 2 giây sau khi app nạp xong môi trường mạng
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

        // Cấu hình NSURLSession tự động theo đuôi chuyển hướng (Redirect 302 của Google)
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        config.timeoutIntervalForRequest = 15.0;
        config.timeoutIntervalForResource = 30.0;
        instance.session = [NSURLSession sessionWithConfiguration:config delegate:instance delegateQueue:nil];
    });
    return instance;
}

// ==========================================
// LẤY CỬA SỔ CHUẨN TRÊN IOS 13+
// ==========================================
+ (UIWindow *)findActiveWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) {
                        return w;
                    }
                }
            }
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

// ==========================================
// QUẢN LÝ MÃ THIẾT BỊ VĨNH VIỄN BẰNG KEYCHAIN
// ==========================================
- (NSString *)getDeviceID {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KEYCHAIN_SERVICE,
        (__bridge id)kSecAttrAccount: KEYCHAIN_ACCOUNT,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef dataTypeRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &dataTypeRef);
    if (status == errSecSuccess) {
        NSData *data = (__bridge_transfer NSData *)dataTypeRef;
        NSString *savedID = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (savedID && savedID.length == 8) {
            return savedID;
        }
    }

    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (!uuid) {
        uuid = [[NSUUID UUID] UUIDString];
    }
    NSString *newDeviceID = [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].uppercaseString;

    NSData *dataToStore = [newDeviceID dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KEYCHAIN_SERVICE,
        (__bridge id)kSecAttrAccount: KEYCHAIN_ACCOUNT,
        (__bridge id)kSecValueData: dataToStore,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
    };
    SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);

    return newDeviceID;
}

- (void)startService {
    set_speed_factor(1.0f);

    // 1. Gửi request đầu tiên ngay khi mở app
    [self syncWithGoogleSheets];

    // 2. Định kỳ mỗi 3 phút đồng bộ lại 1 lần
    self.syncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.syncTimer, dispatch_walltime(NULL, 0), 180ull * NSEC_PER_SEC, 10ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.syncTimer, ^{
        [weakSelf syncWithGoogleSheets];
    });
    dispatch_resume(self.syncTimer);

    // 3. Quét màn hình canh giây
    self.scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.scanTimer, dispatch_walltime(NULL, 0), 400ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.scanTimer, ^{
        [weakSelf scanCurrentScreenFast];
    });
    dispatch_resume(self.scanTimer);
}

// Xử lý chuyển hướng HTTP 302 chuẩn từ Google Apps Script
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    completionHandler(request);
}

// Gửi ID về Google Sheets
- (void)syncWithGoogleSheets {
    NSString *deviceID = [self getDeviceID];
    NSString *encodedID = [deviceID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"%@?device_id=%@", GOOGLE_SHEET_API_URL, encodedID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                       timeoutInterval:15.0];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (!error && data) {
            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (!jsonErr && [json isKindOfClass:[NSDictionary class]]) {
                BOOL active = [json[@"is_active"] boolValue];
                NSInteger sec = [json[@"trigger_second"] integerValue];

                dispatch_async(dispatch_get_main_queue(), ^{
                    self.isAuthorized = active;
                    if (sec > 0) {
                        self.triggerSecond = sec;
                    }
                    if (!active) {
                        set_speed_factor(1.0f);
                    }
                });
            }
        }
    }];
    [task resume];
}

// Quét màn hình bắt đúng giây
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
