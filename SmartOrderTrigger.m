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

@interface SmartOrderManager : NSObject
@property (nonatomic, assign) BOOL isAuthorized;
@property (nonatomic, assign) NSInteger triggerSecond;
@property (nonatomic, assign) BOOL isTriggered;
@property (nonatomic, strong) dispatch_source_t scanTimer;
@property (nonatomic, strong) dispatch_source_t syncTimer;
@end

@implementation SmartOrderManager

+ (void)load {
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
    });
    return instance;
}

// ==========================================
// QUẢN LÝ MÃ THIẾT BỊ VĨNH VIỄN BẰNG KEYCHAIN
// ==========================================
- (NSString *)getDeviceID {
    // 1. Kiểm tra mã đã từng lưu trong Keychain chưa
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
            return savedID; // Trả về mã cũ dù đã xóa app cài lại
        }
    }

    // 2. Nếu máy hoàn toàn mới (chưa có trong Keychain) -> Tạo mã 8 ký tự
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (!uuid) {
        uuid = [[NSUUID UUID] UUIDString];
    }
    NSString *newDeviceID = [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].uppercaseString;

    // 3. Khóa chặt mã này vào Keychain với cờ kSecAttrAccessibleAfterFirstUnlock (tồn tại vĩnh viễn)
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

    // Đồng bộ trạng thái với Google Sheets
    [self syncWithGoogleSheets];

    // Định kỳ 5 phút kiểm tra lại quyền 1 lần
    self.syncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.syncTimer, dispatch_walltime(NULL, 0), 300ull * NSEC_PER_SEC, 10ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.syncTimer, ^{
        [weakSelf syncWithGoogleSheets];
    });
    dispatch_resume(self.syncTimer);

    // Quét màn hình bắt giây
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
                                                       timeoutInterval:10.0];
    request.HTTPMethod = @"GET";

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
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

- (void)scanCurrentScreenFast {
    if (!self.isAuthorized) return;

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
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
