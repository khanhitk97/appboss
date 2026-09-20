#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

// Các hàm liên kết từ SpeedhackMenu.m
extern BOOL is_license_active(void);
extern void notify_burst_state_to_button(BOOL active);

@interface SmartOrderDetector : NSObject
@property (nonatomic, strong) dispatch_source_t scanTimer;
@property (nonatomic, assign) BOOL isTriggered;
@end

@implementation SmartOrderDetector

+ (void)load {
    // Trì hoãn 2 giây sau khi app khởi động để đảm bảo UIWindow đã sẵn sàng
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SmartOrderDetector sharedInstance] startMonitoring];
    });
}

+ (instancetype)sharedInstance {
    static SmartOrderDetector *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SmartOrderDetector alloc] init];
        instance.isTriggered = NO;
    });
    return instance;
}

- (void)startMonitoring {
    // Quét nhẹ nhàng mỗi 200ms bằng GCD Timer trên Main Queue
    self.scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.scanTimer, dispatch_walltime(NULL, 0), 200ull * NSEC_PER_MSEC, 50ull * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.scanTimer, ^{
        [weakSelf scanCurrentScreen];
    });
    dispatch_resume(self.scanTimer);
}

- (void)scanCurrentScreen {
    // 1. Kiểm tra bản quyền: Chưa kích hoạt hoặc hết hạn thì bỏ qua
    if (!is_license_active()) return;

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    BOOL foundSecond3 = NO;
    BOOL foundOrderScreen = NO;

    [self searchViews:window found3:&foundSecond3 foundOrder:&foundOrderScreen];

    // 2. PHÁT HIỆN MỐC GIÂY THỨ 3
    if (foundSecond3 && !self.isTriggered) {
        self.isTriggered = YES;

        // Bật phản hồi trực quan trên nút Menu (chớp Cam + rung máy)
        notify_burst_state_to_button(YES);

        // Kích hoạt bứt tốc x5.0
        set_speed_factor(5.0f);

        // Chạy đúng 1.0 giây rồi trả về nhịp x1.0 an toàn
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set_speed_factor(1.0f);
            notify_burst_state_to_button(NO); // Nút trở về màu xanh ⚡
        });
    }

    // 3. Khi chuỗi đếm ngược biến mất (hoặc thoát popup đơn hàng) -> Reset cờ để đón đơn mới
    if (!foundOrderScreen) {
        self.isTriggered = NO;
    }
}

- (void)searchViews:(UIView *)view found3:(BOOL *)found3 foundOrder:(BOOL *)foundOrder {
    if (!view || view.isHidden || view.alpha < 0.1) return;

    // Quét text trên các thành phần UILabel gốc của iOS
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *txt = [(UILabel *)view text];
        if (txt.length > 0) {
            if ([txt containsString:@"được nhận đơn sau"]) {
                *foundOrder = YES;
                if ([txt containsString:@"sau 3 giây"] || [txt containsString:@"3 giây"]) {
                    *found3 = YES;
                }
            }
            if ([txt containsString:@"Vuốt để nhận đơn"]) {
                *foundOrder = YES;
            }
        }
    }

    // Quét thuộc tính Accessibility Text của React Native (RCTTextView / RCTParagraphComponentView)
    NSString *acc = view.accessibilityLabel;
    if (acc.length > 0) {
        if ([acc containsString:@"được nhận đơn sau"]) {
            *foundOrder = YES;
            if ([acc containsString:@"sau 3 giây"] || [acc containsString:@"3 giây"]) {
                *found3 = YES;
            }
        }
        if ([acc containsString:@"Vuốt để nhận đơn"]) {
            *foundOrder = YES;
        }
    }

    // Đệ quy duyệt qua các view con
    for (UIView *sub in view.subviews) {
        [self searchViews:sub found3:found3 foundOrder:foundOrder];
        if (*found3) break; // Đã tìm thấy mốc 3s thì dừng quét nhánh con này
    }
}

@end
