#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

// Khai báo hàm kiểm tra bản quyền từ SpeedhackMenu.m
extern BOOL is_license_active(void);

@interface SmartOrderManager : NSObject
@property (nonatomic, assign) BOOL isTriggerRunning;
+ (instancetype)sharedInstance;
- (void)startBurstSequence;
@end

@implementation SmartOrderManager

+ (instancetype)sharedInstance {
    static SmartOrderManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SmartOrderManager alloc] init];
        instance.isTriggerRunning = NO;
    });
    return instance;
}

- (void)startBurstSequence {
    // 1. Kiểm tra bản quyền: Nếu hết hạn hoặc chưa kích hoạt thì không thực thi
    if (!is_license_active()) return;

    // 2. Chống lặp kích hoạt khi đơn hàng đang trong chu kỳ
    if (self.isTriggerRunning) return;
    self.isTriggerRunning = YES;

    // Tốc độ ban đầu giữ nguyên chuẩn x1.0
    set_speed_factor(1.0f);

    // 3. Đợi 4 giây (tương ứng lúc bộ đếm 7 giây trên app đếm về mốc 3 giây)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // KÍCH HOẠT TỐC ĐỘ x5.0
        set_speed_factor(5.0f);

        // 4. Chạy đúng 1 giây bứt tốc rồi hạ về x1.0
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set_speed_factor(1.0f);
            
            // Giữ khóa chống spam trong 3 giây tiếp theo trước khi nhận đơn mới
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.isTriggerRunning = NO;
            });
        });
    });
}

@end

// ==========================================
// TỰ ĐỘNG BẮT SỰ KIỆN CHẠM VIEW "Vuốt để nhận đơn"
// ==========================================
static void (*orig_sendEvent)(id, SEL, UIEvent *);

static void hook_sendEvent(UIWindow *self, SEL _cmd, UIEvent *event) {
    orig_sendEvent(self, _cmd, event);

    if (event.type == UIEventTypeTouches) {
        UITouch *touch = [event.allTouches anyObject];
        if (touch.phase == UITouchPhaseBegan) {
            UIView *view = touch.view;
            // Quét kiểm tra view hoặc view cha có chứa nội dung nhận đơn không
            NSString *viewDesc = [view description];
            NSString *parentDesc = [view.superview description];
            
            if ([viewDesc containsString:@"Vuốt để nhận đơn"] || 
                [parentDesc containsString:@"Vuốt để nhận đơn"]) {
                [[SmartOrderManager sharedInstance] startBurstSequence];
            }
        }
    }
}

__attribute__((constructor)) static void init_smart_order_hook(void) {
    Class windowClass = [UIWindow class];
    SEL sendEventSel = @selector(sendEvent:);
    Method sendEventMethod = class_getInstanceMethod(windowClass, sendEventSel);
    if (sendEventMethod) {
        orig_sendEvent = (void (*)(id, SEL, UIEvent *))method_getImplementation(sendEventMethod);
        method_setImplementation(sendEventMethod, (IMP)hook_sendEvent);
    }
}
