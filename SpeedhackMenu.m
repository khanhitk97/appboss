#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

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

@protocol SpeedhackButtonDelegate <NSObject>
- (void)onLongPressFiveSeconds;
@end

@interface SpeedhackFloatingButton : UIButton
@property (nonatomic, assign) BOOL isLocked;
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) NSTimer *countdownTimer;
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

        [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];

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
        self.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
        self.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
        [self setTitle:@"LOCK" forState:UIControlStateNormal];
        self.alpha = 0.1;
    } else {
        // Luôn luôn duy trì 5X khi đã mở khóa
        set_speed_factor(SPEED_MULTIPLIER);
        [self updateButtonUI];
        [self resetIdleTimer];
    }
}

// Bù trừ thời gian chạy nhanh 5x để đếm lùi chuẩn từng giây đời thực
- (NSString *)formattedRemainingTime {
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    double now = [[NSDate date] timeIntervalSince1970];
    double diff = expireTime - now;

    if (diff <= 0) return @"00:00";

    NSInteger remaining = (NSInteger)(diff / SPEED_MULTIPLIER);

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

    // Cứ 0.2s game = 1s đời thực
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 
                                                           target:self 
                                                         selector:@selector(refreshButtonContent) 
                                                         userInfo:nil 
                                                          repeats:YES];
}

- (void)stopCountdown {
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
}

- (void)refreshButtonContent {
    if (_isLocked) {
        [self stopCountdown];
        return;
    }
    NSString *timeStr = [self formattedRemainingTime];
    [self setTitle:timeStr forState:UIControlStateNormal];
}

- (void)updateButtonUI {
    if (_isLocked) return;

    self.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.2 alpha:0.9];
    self.layer.borderColor = [UIColor whiteColor].CGColor;
    [self startCountdown];
}

// Chạm vào nút chỉ làm sáng lại 100% chứ không tắt speed
- (void)handleTap {
    if (_isLocked) return;
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
@property (nonatomic, strong) NSTimer *heartbeatTimer;
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
            [sharedAuth initialSetup];
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
    
    NSString *dateStr = [formatter stringFromDate:[NSDate date]];
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
    double now = [[NSDate date] timeIntervalSince1970];

    if (savedKey && [savedKey isEqualToString:expectedKey] && now < expireTime) {
        [self.floatingButton setLockedState:NO];
        [self startHeartbeat];
    } else {
        [self lockSpeedhack];
    }
}

- (void)startHeartbeat {
    [self stopHeartbeat];
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 
                                                           target:self 
                                                         selector:@selector(checkExpirationHeartbeat) 
                                                         userInfo:nil 
                                                          repeats:YES];
}

- (void)stopHeartbeat {
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
}

- (void)checkExpirationHeartbeat {
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    double now = [[NSDate date] timeIntervalSince1970];

    if (now >= expireTime) {
        NSLog(@"[KeyAuth] License expired! Locking floating button and reverting speed...");
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

        if ([inputKey isEqualToString:expectedKey]) {
            // Khi bật speedhack x5, thời gian trong app chạy nhanh gấp 5 lần
            NSTimeInterval realDurationInGame = DURATION_TEST * SPEED_MULTIPLIER;
            double expireTime = [[NSDate date] timeIntervalSince1970] + realDurationInGame;
            
            [[NSUserDefaults standardUserDefaults] setObject:inputKey forKey:KEY_STORAGE];
            [[NSUserDefaults standardUserDefaults] setDouble:expireTime forKey:EXPIRE_STORAGE];
            [[NSUserDefaults standardUserDefaults] synchronize];

            [self.floatingButton setLockedState:NO];
            [self startHeartbeat];
            
            UIAlertController *success = [UIAlertController alertControllerWithTitle:@"Thành Công" message:@"Kích hoạt thành công!" preferredStyle:UIAlertControllerStyleAlert];
            [success addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [rootVC presentViewController:success animated:YES completion:nil];
        } else {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Lỗi" message:@"Mã Key không chính xác hoặc đã hết hạn." preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"Thử Lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                [self showKeyInputDialogOn:rootVC deviceID:deviceID expectedKey:expectedKey];
            }]];
            [rootVC presentViewController:err animated:YES completion:nil];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];

    [rootVC presentViewController:alert animated:YES completion:nil];
}

@end
