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
#define DURATION_24H (24 * 60 * 60)

@protocol SpeedhackButtonDelegate <NSObject>
- (void)onLongPressFiveSeconds;
@end

@interface SpeedhackFloatingButton : UIButton
@property (nonatomic, assign) BOOL isSpeedOn;
@property (nonatomic, assign) BOOL isLocked;
@property (nonatomic, strong) NSTimer *idleTimer;
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
    
    if (_isLocked) {
        set_speed_factor(1.0f);
        _isSpeedOn = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
        self.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
        [self setTitle:@"LOCK" forState:UIControlStateNormal];
        self.alpha = 0.1;
    } else {
        _isSpeedOn = YES;
        set_speed_factor(5.0f);
        [self updateButtonUI];
        [self resetIdleTimer];
    }
}

- (void)updateButtonUI {
    if (_isLocked) return;

    if (_isSpeedOn) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.2 alpha:0.9];
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        [self setTitle:@"5X" forState:UIControlStateNormal];
    } else {
        self.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.9];
        self.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:0.8].CGColor;
        [self setTitle:@"1X" forState:UIControlStateNormal];
    }
}

- (void)toggleSpeed {
    if (_isLocked) return;
    _isSpeedOn = !_isSpeedOn;
    [self updateButtonUI];
    set_speed_factor(_isSpeedOn ? 5.0f : 1.0f);
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

@interface KeyAuthManager : NSObject <SpeedhackButtonDelegate>
@property (nonatomic, strong) SpeedhackFloatingButton *floatingButton;
@property (nonatomic, strong) NSTimer *expirationWatcherTimer;
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
    return [UIApplication sharedApplication].keyWindow;
}

- (NSString *)getDeviceID {
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (!uuid) return @"UNKNOWN-ID";
    return [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].uppercaseString;
}

- (NSString *)generateValidKeyForDevice:(NSString *)deviceID {
    NSString *rawInput = [NSString stringWithFormat:@"%@_%@", deviceID, SECRET_SALT];
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
        self.floatingButton = [[SpeedhackFloatingButton alloc] initWithFrame:CGRectMake(self.appWindow.bounds.size.width - 50, 120, 42, 42)];
        self.floatingButton.delegate = self;
        [self.appWindow addSubview:self.floatingButton];
    }
    [self checkLicenseValidity];
}

- (void)checkLicenseValidity {
    NSString *deviceID = [self getDeviceID];
    NSString *expectedKey = [self generateValidKeyForDevice:deviceID];

    NSString *savedKey = [[NSUserDefaults standardUserDefaults] stringForKey:KEY_STORAGE];
    NSTimeInterval expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if (savedKey && [savedKey isEqualToString:expectedKey] && now < expireTime) {
        [self.floatingButton setLockedState:NO];
        
        [self.expirationWatcherTimer invalidate];
        self.expirationWatcherTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(checkExpirationHeartbeat) userInfo:nil repeats:YES];
    } else {
        [self lockSpeedhack];
    }
}

- (void)checkExpirationHeartbeat {
    NSTimeInterval expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if (now >= expireTime) {
        NSLog(@"[KeyAuth] Key 24h expired! Locking menu and reverting to 1x...");
        [self lockSpeedhack];
    }
}

- (void)lockSpeedhack {
    [self.expirationWatcherTimer invalidate];
    self.expirationWatcherTimer = nil;

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

    NSString *title = @"KÍCH HOẠT KEY (24H)";
    NSString *msg = [NSString stringWithFormat:@"Mã máy của bạn:\n%@\n\n(Sao chép mã gửi admin để nhận Key kích hoạt 24h)", deviceID];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Dán mã Key vào đây";
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
            NSTimeInterval expireTime = [[NSDate date] timeIntervalSince1970] + DURATION_24H;
            [[NSUserDefaults standardUserDefaults] setObject:inputKey forKey:KEY_STORAGE];
            [[NSUserDefaults standardUserDefaults] setDouble:expireTime forKey:EXPIRE_STORAGE];
            [[NSUserDefaults standardUserDefaults] synchronize];

            [self.floatingButton setLockedState:NO];

            [self.expirationWatcherTimer invalidate];
            self.expirationWatcherTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(checkExpirationHeartbeat) userInfo:nil repeats:YES];
        } else {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Sai Key" message:@"Mã Key không chính xác cho thiết bị này." preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"Nhập Lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                [self showKeyInputDialogOn:rootVC deviceID:deviceID expectedKey:expectedKey];
            }]];
            [rootVC presentViewController:err animated:YES completion:nil];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];

    [rootVC presentViewController:alert animated:YES completion:nil];
}

@end
