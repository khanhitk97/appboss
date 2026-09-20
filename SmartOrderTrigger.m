#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

extern BOOL is_license_active(void);
extern void notify_burst_state_to_button(BOOL active);

@interface SmartOrderDetector : NSObject
@property (nonatomic, strong) dispatch_source_t scanTimer;
@property (nonatomic, assign) BOOL isTriggered;
@property (nonatomic, assign) BOOL isScanning;
@end

@implementation SmartOrderDetector

+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SmartOrderDetector sharedInstance] startMonitoring];
    });
}

+ (instancetype)sharedInstance {
    static SmartOrderDetector *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SmartOrderDetector alloc] init];
        instance.isTriggered = NO;
        instance.isScanning = NO;
    });
    return instance;
}

- (void)startMonitoring {
    // Tối ưu chu kỳ: Quét mỗi 400ms (0.4 giây) - đủ bắt số 3 mà không nghẽn CPU
    self.scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.scanTimer, dispatch_walltime(NULL, 0), 400ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.scanTimer, ^{
        [weakSelf scanCurrentScreenFast];
    });
    dispatch_resume(self.scanTimer);
}

- (void)scanCurrentScreenFast {
    if (!is_license_active()) return;
    if (self.isScanning) return; // Chống chồng chéo chu kỳ quét nếu frame trước chưa xử lý xong
    self.isScanning = YES;

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) {
        self.isScanning = NO;
        return;
    }

    BOOL foundSecond3 = NO;
    BOOL foundOrderScreen = NO;

    // Quét có giới hạn độ sâu (maxDepth = 8) để không đơ luồng giao diện
    [self fastSearch:window currentDepth:0 maxDepth:8 found3:&foundSecond3 foundOrder:&foundOrderScreen];

    // PHÁT HIỆN MỐC GIÂY THỨ 3
    if (foundSecond3 && !self.isTriggered) {
        self.isTriggered = YES;

        notify_burst_state_to_button(YES);
        set_speed_factor(5.0f);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set_speed_factor(1.0f);
            notify_burst_state_to_button(NO);
        });
    }

    if (!foundOrderScreen) {
        self.isTriggered = NO;
    }

    self.isScanning = NO;
}

- (void)fastSearch:(UIView *)view currentDepth:(NSInteger)depth maxDepth:(NSInteger)maxDepth found3:(BOOL *)found3 foundOrder:(BOOL *)foundOrder {
    if (!view || view.isHidden || view.alpha < 0.1 || depth > maxDepth) return;

    // 1. Kiểm tra nhanh UILabel
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *txt = [(UILabel *)view text];
        if (txt.length > 5) { // Bỏ qua text quá ngắn không liên quan
            if ([txt containsString:@"được nhận đơn sau"]) {
                *foundOrder = YES;
                if ([txt containsString:@"3 giây"] || [txt containsString:@"sau 3"]) {
                    *found3 = YES;
                    return;
                }
            } else if ([txt containsString:@"Vuốt để nhận đơn"]) {
                *foundOrder = YES;
            }
        }
    } else {
        // 2. Kiểm tra nhanh React Native accessibility
        NSString *acc = view.accessibilityLabel;
        if (acc.length > 5) {
            if ([acc containsString:@"được nhận đơn sau"]) {
                *foundOrder = YES;
                if ([acc containsString:@"3 giây"] || [acc containsString:@"sau 3"]) {
                    *found3 = YES;
                    return;
                }
            } else if ([acc containsString:@"Vuốt để nhận đơn"]) {
                *foundOrder = YES;
            }
        }
    }

    // Đệ quy có kiểm soát - ưu tiên các view con từ dưới lên (nơi thường chứa popup/modal)
    for (UIView *sub in [view.subviews reverseObjectEnumerator]) {
        [self fastSearch:sub currentDepth:depth + 1 maxDepth:maxDepth found3:found3 foundOrder:foundOrder];
        if (*found3) break;
    }
}

@end
