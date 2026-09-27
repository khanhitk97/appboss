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
// CẤU HÌNH API GOOGLE SHEETS ĐÃ TÍCH HỢP URL
// ==========================================
#define GOOGLE_SHEET_API_URL @"https://script.google.com/macros/s/AKfycbxJ9hbctimNO5x23W5YT06SLunhJcUKIdkEzd652nhICuxGmugziDna5GEYkwQgqZEJ/exec"

@interface SmartOrderManager : NSObject
@property (nonatomic, assign) BOOL isAuthorized;      // Quyền hoạt động xác thực từ Google Sheets
@property (nonatomic, assign) NSInteger triggerSecond;// Mốc giây bứt tốc cấu hình từ Sheets
@property (nonatomic, assign) BOOL isTriggered;
@property (nonatomic, strong) dispatch_source_t scanTimer;
@property (nonatomic, strong) dispatch_source_t syncTimer;
@end

@implementation SmartOrderManager

+ (void)load {
    // Trì hoãn 2 giây để app khởi tạo xong giao diện và kết nối mạng
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
        instance.triggerSecond = 3; // Mặc định là 3 giây nếu chưa đồng bộ xong
        instance.isTriggered = NO;
    });
    return instance;
}

- (NSString *)getDeviceID {
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (!uuid) return @"UNKNOWN0";
    return [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].uppercaseString;
}

- (void)startService {
    // Luôn đưa tốc độ về chuẩn x1.0 khi khởi động
    set_speed_factor(1.0f);

    // 1. Kiểm tra trạng thái ngay lần đầu mở app
    [self syncWithGoogleSheets];

    // 2. Chạy Timer đồng bộ ngầm định kỳ mỗi 5 phút một lần để cập nhật trạng thái mới nhất từ Sheets
    self.syncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.syncTimer, dispatch_walltime(NULL, 0), 300ull * NSEC_PER_SEC, 10ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.syncTimer, ^{
        [weakSelf syncWithGoogleSheets];
    });
    dispatch_resume(self.syncTimer);

    // 3. Chạy Timer quét màn hình (chu kỳ 400ms - cực nhẹ, không nghẽn CPU)
    self.scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.scanTimer, dispatch_walltime(NULL, 0), 400ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.scanTimer, ^{
        [weakSelf scanCurrentScreenFast];
    });
    dispatch_resume(self.scanTimer);
}

// Gửi Device_ID về Google Sheets và nhận trạng thái
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
                        set_speed_factor(1.0f); // Nếu bị LOCKED hoặc hết hạn, cưỡng chế về x1.0
                    }
                });
            }
        }
    }];
    [task resume];
}

// Quét giao diện nhẹ nhàng
- (void)scanCurrentScreenFast {
    // Nếu chưa được cấp quyền trên Google Sheets thì không can thiệp
    if (!self.isAuthorized) return;

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    BOOL foundTargetSecond = NO;
    BOOL foundOrderScreen = NO;

    [self fastSearch:window currentDepth:0 maxDepth:8 foundTarget:&foundTargetSecond foundOrder:&foundOrderScreen];

    // PHÁT HIỆN ĐÚNG MỐC GIÂY ĐƯỢC CHỈ ĐỊNH TỪ GOOGLE SHEETS
    if (foundTargetSecond && !self.isTriggered) {
        self.isTriggered = YES;

        // 1. Kích hoạt x5.0
        set_speed_factor(5.0f);

        // 2. Chạy đúng 1.0 giây rồi trả về x1.0 an toàn
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set_speed_factor(1.0f);
        });
    }

    // Khi thanh đơn chuyển màu hoặc rời màn hình đơn -> Reset cờ sẵn sàng cho đơn sau
    if (!foundOrderScreen) {
        self.isTriggered = NO;
    }
}

- (void)fastSearch:(UIView *)view currentDepth:(NSInteger)depth maxDepth:(NSInteger)maxDepth foundTarget:(BOOL *)foundTarget foundOrder:(BOOL *)foundOrder {
    if (!view || view.isHidden || view.alpha < 0.1 || depth > maxDepth) return;

    // Tạo chuỗi mục tiêu cần tìm dựa trên triggerSecond lấy từ Sheets (ví dụ: "sau 3 giây", "sau 5 giây")
    NSString *matchPattern1 = [NSString stringWithFormat:@"sau %ld giây", (long)self.triggerSecond];
    NSString *matchPattern2 = [NSString stringWithFormat:@"%ld giây", (long)self.triggerSecond];

    // 1. Quét text trên UILabel
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
        // 2. Quét accessibility của React Native
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
