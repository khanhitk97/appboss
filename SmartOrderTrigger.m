#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

@interface SmartOrderManager : NSObject
@property (nonatomic, assign) BOOL isTriggerRunning;
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

// Hàm kích hoạt chu kỳ: Đợi 4s (đếm về 3) -> Bật x5 trong 1s -> Trả về x1
- (void)startBurstSequence {
    if (self.isTriggerRunning) return;
    self.isTriggerRunning = YES;

    // Giữ nguyên tốc độ bình thường x1.0 khi mới vào đơn
    set_speed_factor(1.0f);

    // Đợi 4 giây (thời điểm bộ đếm từ 7s rơi về mốc 3s)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 1. KÍCH HOẠT TĂNG TỐC x5
        set_speed_factor(5.0f);

        // 2. Chạy đúng 1 giây rồi TẮT ngay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set_speed_factor(1.0f);
            self.isTriggerRunning = NO;
        });
    });
}

@end
