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
extern NSInteger get_current_trigger_second(void);

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
    set_speed_factor(1.0f);

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
    if (self.isScanning) return;
    self.isScanning = YES;

    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
        }
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    if (!window) {
        self.isScanning = NO;
        return;
    }

    BOOL foundTargetSec = NO;
    BOOL foundOrderScreen = NO;
    NSInteger targetSec = get_current_trigger_second();

    [self fastSearch:window currentDepth:0 maxDepth:8 targetSec:targetSec foundTarget:&foundTargetSec foundOrder:&foundOrderScreen];

    if (foundTargetSec && !self.isTriggered) {
        self.isTriggered = YES;

        set_speed_factor(5.0f);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            set_speed_factor(1.0f);
        });
    }

    if (!foundOrderScreen) {
        self.isTriggered = NO;
    }

    self.isScanning = NO;
}

- (void)fastSearch:(UIView *)view currentDepth:(NSInteger)depth maxDepth:(NSInteger)maxDepth targetSec:(NSInteger)sec foundTarget:(BOOL *)foundTarget foundOrder:(BOOL *)foundOrder {
    if (!view || view.isHidden || view.alpha < 0.1 || depth > maxDepth) return;

    NSString *matchPattern1 = [NSString stringWithFormat:@"sau %ld giây", (long)sec];
    NSString *matchPattern2 = [NSString stringWithFormat:@"%ld giây", (long)sec];

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
        [self fastSearch:sub currentDepth:depth + 1 maxDepth:maxDepth targetSec:sec foundTarget:foundTarget foundOrder:foundOrder];
        if (*foundTarget) break;
    }
}

@end
