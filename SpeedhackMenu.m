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
#define DURATION_TEST (2 * 60) // 2 phút test (khi hoàn thiện đổi thành 24 * 60 * 60)
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

// Lấy thời gian Internet thực tế tại thời điểm gọi
static uint64_t get_current_real_time(void) {
    if (!g_has_synced_network_time) {
        return (uint64_t)[[NSDate date] timeIntervalSince1970];
    }
    return (uint64_t)(get_raw_hardware_tick() + g_network_time_offset);
}

// Đồng bộ giờ từ Server (Google) bằng HTTP HEAD Header 'Date'
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
// GIAO DIỆN NÚT NỔI (FLOATING BUTTON)
// ==========================================
@protocol SpeedhackButtonDelegate <NSObject>
- (void)onLongPressFiveSeconds;
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
        longPress.minimumPressDuration = 5.0;
        [self addGestureRecognizer:longPress];

        [self addTarget:self action:@selector(toggleSpeed) forControlEvents:UIControlEventTouchUpInside];

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
        self.alpha = 0.1;
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

    NSInteger hours = remaining / 3600;
    NSInteger minutes = (remaining % 3600) / 60;
    NSInteger seconds = remaining % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hours, (long)minutes, (long)seconds];
    } else {
        return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
    }
}

- (void)startCountdown {
    [self stopCountdown];
    [self refreshButtonContent];

    // Dùng GCD Dispatch Timer chạy theo thời gian thực để không bị dính hook RunLoop
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

- (void)toggleSpeed {
    if (_isLocked) return;
    _isSpeedOn = !_isSpeedOn;
    set_speed_factor(_isSpeedOn ? SPEED_MULTIPLIER : 1.0f);
    [self updateButtonUI];
    [self resetIdleTimer];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (_isLocked && [self.delegate respondsToSelector:@selector(onLongPressFiveSeconds)]) {
            [self.delegate onLongPressFiveSeconds];
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
    } else if (pan.state == UIPanGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        [pan setTranslation:CGPointZero inView:superview];
    } else if (pan.state == UIPanGestureRecognizerStateEnded || pan.state == UIPanGestureRecognizerStateCancelled) {
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
            
            // Đồng bộ giờ từ Server trước khi nạp giao diện
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

- (NSString *)generateValidKeyForDevice:(NSString *)deviceID {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"ddMMyyyy"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithName:@"Asia/Ho_Chi_Minh"]];
    [formatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    [formatter setCalendar:[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]];
    
    // Tạo ngày theo giờ chuẩn Internet hiện tại
    NSDate *currentDate = [NSDate dateWithTimeIntervalSince1970:get_current_real_time()];
    NSString *dateStr = [formatter stringFromDate:currentDate];
    NSString *rawInput = [NSString stringWithFormat:@"%@%@_%@", deviceID, dateStr, SECRET_SALT];

    const char *cStr = [rawInput UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    
    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hash appendFormat:@"%02X", digest[i]];
    }
    return [hash substringToIndex:8];
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
    NSString *deviceID = [self getDeviceID];
    NSString *expectedKey = [self generateValidKeyForDevice:deviceID];

    NSString *savedKey = [[NSUserDefaults standardUserDefaults] stringForKey:KEY_STORAGE];
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    uint64_t now = get_current_real_time();

    if (savedKey && [savedKey isEqualToString:expectedKey] && now < expireTime) {
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

- (void)onLongPressFiveSeconds {
    NSString *deviceID = [self getDeviceID];
    NSString *expectedKey = [self generateValidKeyForDevice:deviceID];
    [self showKeyInputDialogOn:self.appWindow.rootViewController deviceID:deviceID expectedKey:expectedKey];
}

- (void)showKeyInputDialogOn:(UIViewController *)rootVC deviceID:(NSString *)deviceID expectedKey:(NSString *)expectedKey {
    if (!rootVC) return;

    NSString *title = @"KÍCH HOẠT BẢN QUYỀN";
    NSString *msg = [NSString stringWithFormat:@"Mã máy của bạn:\n%@\n\n(Nhấn giữ 5s để mở bảng này. Sao chép mã máy gửi Admin để nhận Key)", deviceID];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title 
                                                                   message:msg 
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Nhập mã Key kích hoạt";
        textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Mã Máy" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = deviceID;
        [self showKeyInputDialogOn:rootVC deviceID:deviceID expectedKey:expectedKey];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Kích Hoạt" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *inputKey = alert.textFields.firstObject.text;
        inputKey = [inputKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;

        // Đồng bộ lại giờ trước khi kích hoạt
        sync_time_from_internet(^(BOOL success) {
            NSString *freshExpectedKey = [self generateValidKeyForDevice:deviceID];
            
            if ([inputKey isEqualToString:freshExpectedKey]) {
                uint64_t expireTime = get_current_real_time() + DURATION_TEST;
                [[NSUserDefaults standardUserDefaults] setObject:inputKey forKey:KEY_STORAGE];
                [[NSUserDefaults standardUserDefaults] setDouble:(double)expireTime forKey:EXPIRE_STORAGE];
                [[NSUserDefaults standardUserDefaults] synchronize];

                [self.floatingButton setLockedState:NO];
                [self startHeartbeat];
                
                UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Thành Công" message:@"Kích hoạt thành công!" preferredStyle:UIAlertControllerStyleAlert];
                [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [rootVC presentViewController:successAlert animated:YES completion:nil];
            } else {
                UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Lỗi" message:@"Mã Key không chính xác hoặc đã hết hạn." preferredStyle:UIAlertControllerStyleAlert];
                [err addAction:[UIAlertAction actionWithTitle:@"Thử Lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                    [self showKeyInputDialogOn:rootVC deviceID:deviceID expectedKey:freshExpectedKey];
                }]];
                [rootVC presentViewController:err animated:YES completion:nil];
            }
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];

    [rootVC presentViewController:alert animated:YES completion:nil];
}

@end
