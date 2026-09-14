#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <time.h>

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

#define KEY_STORAGE @"SAVED_SPEEDHACK_LICENSE_KEY"
#define EXPIRE_STORAGE @"SPEEDHACK_EXPIRATION_TIME"
#define SECRET_SALT @"SECRET_SALT_2026"
#define SPEED_MULTIPLIER 5.0f

// ==========================================
// ĐỒNG HỒ THỜI GIAN THỰC (INTERNET + HARDWARE)
// ==========================================
static uint64_t get_raw_hardware_tick(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec;
}

static int64_t g_network_time_offset = 0;
static BOOL g_has_synced_network_time = NO;

static uint64_t get_current_real_time(void) {
    if (!g_has_synced_network_time) {
        return (uint64_t)[[NSDate date] timeIntervalSince1970];
    }
    return (uint64_t)(get_raw_hardware_tick() + g_network_time_offset);
}

static void sync_time_from_internet(void (^completion)(BOOL success)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.google.com"]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData 
                                                       timeoutInterval:5.0];
    request.HTTPMethod = @"HEAD";

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSString *dateStr = httpResponse.allHeaderFields[@"Date"];
            
            if (dateStr) {
                NSDateFormatter *rfc1123 = [[NSDateFormatter alloc] init];
                [rfc1123 setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss z"];
                [rfc1123 setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
                [rfc1123 setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];
                
                NSDate *serverDate = [rfc1123 dateFromString:dateStr];
                if (serverDate) {
                    uint64_t serverSec = (uint64_t)[serverDate timeIntervalSince1970];
                    uint64_t hardwareTick = get_raw_hardware_tick();
                    g_network_time_offset = (int64_t)serverSec - (int64_t)hardwareTick;
                    g_has_synced_network_time = YES;
                    
                    if (completion) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completion(YES);
                        });
                    }
                    return;
                }
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
        }
    }];
    [task resume];
}

// ==========================================
// GIẢI MÃ VÀ TÍNH THỜI HẠN GÓI TỪ KEY
// ==========================================
static uint64_t parse_duration_from_plan(NSString *planCode) {
    if (planCode.length < 2) return 0;
    
    char unit = [planCode characterAtIndex:0];
    int value = [[planCode substringFromIndex:1] intValue];
    if (value <= 0) return 0;

    switch (unit) {
        case 'M': return (uint64_t)value * 60;          // Phút (M03 = 180s)
        case 'H': return (uint64_t)value * 3600;        // Giờ (H02 = 7200s)
        case 'D': return (uint64_t)value * 86400;       // Ngày (D07 = 7 ngày)
        default: return 0;
    }
}

static NSString *generate_signature(NSString *planCode, NSString *deviceID) {
    NSString *raw = [NSString stringWithFormat:@"%@_%@_%@", planCode, deviceID, SECRET_SALT];
    const char *cStr = [raw UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
#pragma clang diagnostic pop

    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hash appendFormat:@"%02X", digest[i]];
    }
    return [hash substringToIndex:6]; // 6 ký tự chữ ký
}

// ==========================================
// GIAO DIỆN NÚT NỔI (FLOATING BUTTON)
// ==========================================
@protocol SpeedhackButtonDelegate <NSObject>
- (void)onOpenKeyDialog;
@end

@interface SpeedhackFloatingButton : UIButton
@property (nonatomic, assign) BOOL isSpeedOn;
@property (nonatomic, assign) BOOL isLocked;
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) dispatch_source_t countdownSource;
@property (nonatomic, weak) id<SpeedhackButtonDelegate> delegate;
@end

@implementation SpeedhackFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.5;
        self.titleLabel.font = [UIFont boldSystemFontOfSize:11.0];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 3.0;
        [self addGestureRecognizer:longPress];

        [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];

        _isSpeedOn = YES;
        _isLocked = NO;
        [self updateButtonUI];
        [self resetIdleTimer];
    }
    return self;
}

- (void)setLockedState:(BOOL)locked {
    _isLocked = locked;
    [self.idleTimer invalidate];
    [self stopCountdown];
    
    if (_isLocked) {
        set_speed_factor(1.0f);
        _isSpeedOn = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
        self.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
        [self setTitle:@"LOCK" forState:UIControlStateNormal];
        self.alpha = 0.3;
    } else {
        _isSpeedOn = YES;
        set_speed_factor(SPEED_MULTIPLIER);
        [self updateButtonUI];
        [self resetIdleTimer];
    }
}

- (NSString *)formattedRemainingTime {
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    uint64_t now = get_current_real_time();
    NSInteger remaining = (NSInteger)(expireTime - now);

    if (remaining <= 0) return @"00:00";

    NSInteger days = remaining / 86400;
    NSInteger hours = (remaining % 86400) / 3600;
    NSInteger minutes = (remaining % 3600) / 60;
    NSInteger seconds = remaining % 60;

    if (days > 0) {
        return [NSString stringWithFormat:@"%ldd %02ldh", (long)days, (long)hours];
    } else if (hours > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hours, (long)minutes, (long)seconds];
    } else {
        return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
    }
}

- (void)startCountdown {
    [self stopCountdown];
    [self refreshButtonContent];

    self.countdownSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.countdownSource, dispatch_walltime(NULL, 0), 1ull * NSEC_PER_SEC, 0);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.countdownSource, ^{
        [weakSelf refreshButtonContent];
    });
    dispatch_resume(self.countdownSource);
}

- (void)stopCountdown {
    if (self.countdownSource) {
        dispatch_source_cancel(self.countdownSource);
        self.countdownSource = nil;
    }
}

- (void)refreshButtonContent {
    if (_isLocked || !_isSpeedOn) {
        [self stopCountdown];
        return;
    }
    NSString *timeStr = [self formattedRemainingTime];
    [self setTitle:timeStr forState:UIControlStateNormal];
}

- (void)updateButtonUI {
    if (_isLocked) return;

    if (_isSpeedOn) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.2 alpha:0.9];
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        [self startCountdown];
    } else {
        [self stopCountdown];
        self.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.9];
        self.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:0.8].CGColor;
        [self setTitle:@"TẮT" forState:UIControlStateNormal];
    }
}

- (void)handleTap {
    if (_isLocked) {
        if ([self.delegate respondsToSelector:@selector(onOpenKeyDialog)]) {
            [self.delegate onOpenKeyDialog];
        }
        return;
    }
    _isSpeedOn = !_isSpeedOn;
    set_speed_factor(_isSpeedOn ? SPEED_MULTIPLIER : 1.0f);
    [self updateButtonUI];
    [self resetIdleTimer];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if ([self.delegate respondsToSelector:@selector(onOpenKeyDialog)]) {
            [self.delegate onOpenKeyDialog];
        }
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [pan translationInView:superview];

    if (pan.state == UIGestureRecognizerStateBegan) {
        if (!_isLocked) {
            [self bringToFullAlpha];
            [self.idleTimer invalidate];
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        [pan setTranslation:CGPointZero inView:superview];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat midX = superview.bounds.size.width / 2.0;
        CGFloat targetX = (self.center.x < midX) ? (self.frame.size.width / 2.0 + 8) : (superview.bounds.size.width - self.frame.size.width / 2.0 - 8);
        CGFloat targetY = MIN(MAX(self.center.y, 60), superview.bounds.size.height - 60);

        [UIView animateWithDuration:0.25 animations:^{
            self.center = CGPointMake(targetX, targetY);
        } completion:^(BOOL finished) {
            if (!_isLocked) [self resetIdleTimer];
        }];
    }
}

- (void)bringToFullAlpha {
    if (_isLocked) return;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 1.0;
    }];
}

- (void)resetIdleTimer {
    if (_isLocked) return;
    [self bringToFullAlpha];
    [self.idleTimer invalidate];
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(dimButton) userInfo:nil repeats:NO];
}

- (void)dimButton {
    [UIView animateWithDuration:0.5 animations:^{
        self.alpha = 0.1;
    }];
}

@end

// ==========================================
// MANAGER XÁC THỰC BẢN QUYỀN
// ==========================================
@interface KeyAuthManager : NSObject <SpeedhackButtonDelegate>
@property (nonatomic, strong) SpeedhackFloatingButton *floatingButton;
@property (nonatomic, strong) dispatch_source_t heartbeatSource;
@property (nonatomic, weak) UIWindow *appWindow;
@end

@implementation KeyAuthManager

static KeyAuthManager *sharedAuth = nil;

+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = [self getKeyWindow];
        if (window && window.rootViewController) {
            sharedAuth = [[KeyAuthManager alloc] init];
            sharedAuth.appWindow = window;
            
            sync_time_from_internet(^(BOOL success) {
                [sharedAuth initialSetup];
            });
        }
    });
}

+ (UIWindow *)getKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) return window;
                }
            }
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (NSString *)getDeviceID {
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (!uuid) return @"UNKNOWN-ID";
    return [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].uppercaseString;
}

- (BOOL)validateKeyFormat:(NSString *)key outPlanDuration:(uint64_t *)outDuration {
    NSArray *parts = [key componentsSeparatedByString:@"-"];
    if (parts.count != 3) return NO;

    NSString *planCode = parts[0];
    NSString *keyDeviceID = parts[1];
    NSString *receivedSign = parts[2];

    NSString *myDeviceID = [self getDeviceID];
    if (![keyDeviceID isEqualToString:myDeviceID]) return NO;

    NSString *expectedSign = generate_signature(planCode, myDeviceID);
    if (![receivedSign isEqualToString:expectedSign]) return NO;

    uint64_t duration = parse_duration_from_plan(planCode);
    if (duration == 0) return NO;

    if (outDuration) *outDuration = duration;
    return YES;
}

- (void)initialSetup {
    if (!self.floatingButton && self.appWindow) {
        self.floatingButton = [[SpeedhackFloatingButton alloc] initWithFrame:CGRectMake(self.appWindow.bounds.size.width - 54, 120, 46, 46)];
        self.floatingButton.delegate = self;
        [self.appWindow addSubview:self.floatingButton];
    }
    [self checkLicenseValidity];
}

- (void)checkLicenseValidity {
    NSString *savedKey = [[NSUserDefaults standardUserDefaults] stringForKey:KEY_STORAGE];
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    uint64_t now = get_current_real_time();

    if (savedKey && [self validateKeyFormat:savedKey outPlanDuration:NULL] && now < expireTime) {
        [self.floatingButton setLockedState:NO];
        [self startHeartbeat];
    } else {
        [self lockSpeedhack];
    }
}

- (void)startHeartbeat {
    [self stopHeartbeat];
    self.heartbeatSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.heartbeatSource, dispatch_walltime(NULL, 0), 1ull * NSEC_PER_SEC, 0);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.heartbeatSource, ^{
        [weakSelf checkExpirationHeartbeat];
    });
    dispatch_resume(self.heartbeatSource);
}

- (void)stopHeartbeat {
    if (self.heartbeatSource) {
        dispatch_source_cancel(self.heartbeatSource);
        self.heartbeatSource = nil;
    }
}

- (void)checkExpirationHeartbeat {
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    uint64_t now = get_current_real_time();

    if (now >= expireTime) {
        NSLog(@"[KeyAuth] License expired! Locking floating button...");
        [self lockSpeedhack];
    }
}

- (void)lockSpeedhack {
    [self stopHeartbeat];

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:KEY_STORAGE];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:EXPIRE_STORAGE];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self.floatingButton setLockedState:YES];
}

- (void)onOpenKeyDialog {
    NSString *deviceID = [self getDeviceID];
    [self showKeyInputDialogOn:self.appWindow.rootViewController deviceID:deviceID];
}

- (void)showKeyInputDialogOn:(UIViewController *)rootVC deviceID:(NSString *)deviceID {
    if (!rootVC) return;

    NSString *title = @"KÍCH HOẠT BẢN QUYỀN";
    NSString *msg = [NSString stringWithFormat:@"Mã máy của bạn:\n%@\n\n(Sao chép mã máy gửi Admin để nhận Key)", deviceID];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title 
                                                                   message:msg 
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Nhập Key (VD: D07-XXXXXXXX-XXXXXX)";
        textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Mã Máy" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = deviceID;
        [self showKeyInputDialogOn:rootVC deviceID:deviceID];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Kích Hoạt" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *rawInput = alert.textFields.firstObject.text;
        NSString *inputKey = [rawInput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;

        // 1. Kiểm tra cấu trúc phân tách dấu gạch ngang (-)
        NSArray *parts = [inputKey componentsSeparatedByString:@"-"];
        if (parts.count != 3) {
            NSString *debugMsg = [NSString stringWithFormat:
                                  @"LỖI CẤU TRÚC KEY:\n"
                                  @"- Key bạn nhập: [%@]\n"
                                  @"- Số phần tách được: %lu (Yêu cầu phải đúng 3 phần: GÓI-MÁY-SIGN)",
                                  inputKey, (unsigned long)parts.count];
            
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Debug Lỗi Key" message:debugMsg preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"Thử Lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                [self showKeyInputDialogOn:rootVC deviceID:deviceID];
            }]];
            [rootVC presentViewController:err animated:YES completion:nil];
            return;
        }

        NSString *planCode = parts[0];
        NSString *keyDeviceID = parts[1];
        NSString *receivedSign = parts[2];
        NSString *myDeviceID = [self getDeviceID];

        // 2. Tính toán chữ ký kỳ vọng
        NSString *expectedSign = generate_signature(planCode, myDeviceID);
        uint64_t planDuration = parse_duration_from_plan(planCode);

        // 3. So sánh chi tiết
        BOOL isDeviceMatch = [keyDeviceID isEqualToString:myDeviceID];
        BOOL isSignMatch = [receivedSign isEqualToString:expectedSign];
        BOOL isDurationValid = (planDuration > 0);

        if (!isDeviceMatch || !isSignMatch || !isDurationValid) {
            NSString *rawHashInput = [NSString stringWithFormat:@"%@_%@_%@", planCode, myDeviceID, SECRET_SALT];
            NSString *debugMsg = [NSString stringWithFormat:
                                  @"CHI TIẾT SO SÁNH:\n\n"
                                  @"1. Mã máy thực tế: [%@]\n"
                                  @"   Mã máy trong Key: [%@]\n"
                                  @"   -> Khớp máy: %@\n\n"
                                  @"2. Gói thời gian: [%@] (%llu giây)\n"
                                  @"   -> Hợp lệ: %@\n\n"
                                  @"3. Chuỗi băm thô: [%@]\n"
                                  @"   Chữ ký mong đợi: [%@]\n"
                                  @"   Chữ ký bạn nhập: [%@]\n"
                                  @"   -> Khớp chữ ký: %@",
                                  myDeviceID, keyDeviceID, isDeviceMatch ? @"ĐÚNG" : @"SAI",
                                  planCode, planDuration, isDurationValid ? @"ĐÚNG" : @"SAI",
                                  rawHashInput, expectedSign, receivedSign, isSignMatch ? @"ĐÚNG" : @"SAI"];

            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Debug Lỗi Xác Thực" message:debugMsg preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"Thử Lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                [self showKeyInputDialogOn:rootVC deviceID:deviceID];
            }]];
            [rootVC presentViewController:err animated:YES completion:nil];
            return;
        }

        // 4. Nếu hợp lệ -> Đồng bộ thời gian và kích hoạt
        sync_time_from_internet(^(BOOL success) {
            uint64_t expireTime = get_current_real_time() + planDuration;
            [[NSUserDefaults standardUserDefaults] setObject:inputKey forKey:KEY_STORAGE];
            [[NSUserDefaults standardUserDefaults] setDouble:(double)expireTime forKey:EXPIRE_STORAGE];
            [[NSUserDefaults standardUserDefaults] synchronize];

            [self.floatingButton setLockedState:NO];
            [self startHeartbeat];
            
            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Thành Công" 
                                                                                  message:[NSString stringWithFormat:@"Kích hoạt gói %@ thành công!", planCode] 
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [rootVC presentViewController:successAlert animated:YES completion:nil];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];

    [rootVC presentViewController:alert animated:YES completion:nil];
}

@end
