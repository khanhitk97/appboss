#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
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
#define KEYCHAIN_SERVICE @"com.speedhack.license.service"
#define KEYCHAIN_ACCOUNT @"UsedNoncesHistory"

// ==========================================
// QUẢN LÝ LỊCH SỬ KEY TRÊN IOS KEYCHAIN
// ==========================================
static NSArray *get_used_nonces_from_keychain(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KEYCHAIN_SERVICE,
        (__bridge id)kSecAttrAccount: KEYCHAIN_ACCOUNT,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef dataTypeRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &dataTypeRef);
    if (status == errSecSuccess) {
        NSData *data = (__bridge_transfer NSData *)dataTypeRef;
        NSError *err = nil;
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (!err && [arr isKindOfClass:[NSArray class]]) {
            return arr;
        }
    }
    return @[];
}

static BOOL is_nonce_already_used(NSString *nonce) {
    NSArray *usedList = get_used_nonces_from_keychain();
    return [usedList containsObject:nonce];
}

static void save_nonce_to_keychain(NSString *nonce) {
    NSMutableArray *usedList = [get_used_nonces_from_keychain() mutableCopy];
    if (!usedList) usedList = [NSMutableArray array];
    if (![usedList containsObject:nonce]) {
        [usedList addObject:nonce];
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:usedList options:0 error:nil];
    if (!data) return;

    NSDictionary *deleteQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KEYCHAIN_SERVICE,
        (__bridge id)kSecAttrAccount: KEYCHAIN_ACCOUNT
    };
    SecItemDelete((__bridge CFDictionaryRef)deleteQuery);

    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KEYCHAIN_SERVICE,
        (__bridge id)kSecAttrAccount: KEYCHAIN_ACCOUNT,
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
    };
    SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
}

// ==========================================
// ĐỒNG HỒ THỜI GIAN THỰC (INTERNET + MONOTONIC)
// ==========================================
static uint64_t get_raw_hardware_tick(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec;
}

static int64_t g_network_time_offset = 0;
static BOOL g_has_synced_network_time = NO;

uint64_t get_current_real_time(void) {
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
// XÁC THỰC VÀ BÓC TÁCH GÓI TỪ KEY
// ==========================================
static uint64_t parse_duration_from_plan(NSString *planCode) {
    if (planCode.length < 2) return 0;
    
    char unit = [planCode characterAtIndex:0];
    int value = [[planCode substringFromIndex:1] intValue];
    if (value <= 0) return 0;

    switch (unit) {
        case 'M': return (uint64_t)value * 60;
        case 'H': return (uint64_t)value * 3600;
        case 'D': return (uint64_t)value * 86400;
        default: return 0;
    }
}

static NSString *generate_signature(NSString *planCode, NSString *deviceID, NSString *nonce) {
    NSString *raw = [NSString stringWithFormat:@"%@_%@_%@_%@", planCode, deviceID, nonce, SECRET_SALT];
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
    return [hash substringToIndex:6];
}

// Trạng thái cho phép bắt đơn
static BOOL g_is_auto_enabled = YES;

BOOL is_license_active(void) {
    if (!g_is_auto_enabled) return NO;
    NSString *savedKey = [[NSUserDefaults standardUserDefaults] stringForKey:KEY_STORAGE];
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    uint64_t now = get_current_real_time();
    return (savedKey != nil && expireTime > 0 && now < expireTime);
}

// ==========================================
// VIEW CHỐNG CHỤP MÀN HÌNH (ANTI-SCREENSHOT)
// ==========================================
@interface SecureContainerView : UIView
@property (nonatomic, strong) UITextField *secureTextField;
@property (nonatomic, weak) UIView *contentView;
@end

@implementation SecureContainerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.secureTextField = [[UITextField alloc] initWithFrame:self.bounds];
        self.secureTextField.secureTextEntry = YES;
        self.secureTextField.userInteractionEnabled = NO;
        [self addSubview:self.secureTextField];

        // Lấy lớp Canvas ẩn bên dưới của UITextField
        UIView *canvasView = nil;
        for (UIView *sub in self.secureTextField.subviews) {
            if ([NSStringFromClass([sub class]) containsString:@"CanvasView"] ||
                [NSStringFromClass([sub class]) containsString:@"TextEffects"]) {
                canvasView = sub;
                break;
            }
        }
        if (!canvasView) {
            canvasView = self.secureTextField.subviews.firstObject;
        }

        if (canvasView) {
            canvasView.userInteractionEnabled = YES;
            _contentView = canvasView;
        } else {
            _contentView = self;
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.secureTextField.frame = self.bounds;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.secureTextField) return nil;
    return hit;
}

@end

// ==========================================
// GIAO DIỆN NÚT NỔI (FLOATING BUTTON)
// ==========================================
@protocol SpeedhackButtonDelegate <NSObject>
- (void)onOpenKeyDialog;
@end

@interface SpeedhackFloatingButton : UIButton <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL isLocked;
@property (nonatomic, assign) BOOL isAutoRunning;
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPressGesture;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, weak) id<SpeedhackButtonDelegate> delegate;
@end

@implementation SpeedhackFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.5;
        self.titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;

        self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        self.panGesture.delegate = self;
        [self addGestureRecognizer:self.panGesture];

        // Nhấn giữ 3 giây để mở bảng quản trị bản quyền
        self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        self.longPressGesture.minimumPressDuration = 3.0;
        self.longPressGesture.allowableMovement = 15.0;
        self.longPressGesture.delegate = self;
        [self addGestureRecognizer:self.longPressGesture];

        [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];

        _isLocked = NO;
        _isAutoRunning = YES;
        set_speed_factor(1.0f);

        [self updateButtonUI];
        [self resetIdleTimer];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)setLockedState:(BOOL)locked {
    _isLocked = locked;
    [self.idleTimer invalidate];
    set_speed_factor(1.0f);

    if (_isLocked) {
        self.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
        self.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
        [self setTitle:@"🔒" forState:UIControlStateNormal];
        self.alpha = 0.4;
    } else {
        _isAutoRunning = YES;
        g_is_auto_enabled = YES;
        [self updateButtonUI];
        [self resetIdleTimer];
    }
}

// Báo hiệu khi đang bứt tốc x5 (Hiệu ứng Cam + Rung máy)
- (void)showBurstEffect:(BOOL)isBursting {
    if (_isLocked) return;

    if (isBursting) {
        [self bringToFullAlpha];
        self.backgroundColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:0.95]; // Màu cam rực
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        [self setTitle:@"⚡" forState:UIControlStateNormal];

        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [fb impactOccurred];
        }
    } else {
        [self updateButtonUI];
        [self resetIdleTimer];
    }
}

- (void)updateButtonUI {
    if (_isLocked) return;

    if (_isAutoRunning) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.75 blue:0.25 alpha:0.9]; // Xanh lá
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        [self setTitle:@"⚡" forState:UIControlStateNormal];
    } else {
        self.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.85]; // Màu xám OFF
        self.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:0.8].CGColor;
        [self setTitle:@"OFF" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    }
}

- (void)handleTap {
    if (_isLocked) {
        if ([self.delegate respondsToSelector:@selector(onOpenKeyDialog)]) {
            [self.delegate onOpenKeyDialog];
        }
        return;
    }

    // Chạm 1 chạm để Bật/Tắt chế độ Auto
    _isAutoRunning = !_isAutoRunning;
    g_is_auto_enabled = _isAutoRunning;
    [self updateButtonUI];
    [self resetIdleTimer];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        if ([self.delegate respondsToSelector:@selector(onOpenKeyDialog)]) {
            [self.delegate onOpenKeyDialog];
        }
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *container = self.superview.superview ?: self.superview;
    UIView *targetView = self.superview; // Di chuyển cả khung chứa chống chụp
    if (!targetView) return;

    CGPoint translation = [pan translationInView:container];

    if (pan.state == UIGestureRecognizerStateBegan) {
        if (!_isLocked) {
            [self bringToFullAlpha];
            [self.idleTimer invalidate];
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        targetView.center = CGPointMake(targetView.center.x + translation.x, targetView.center.y + translation.y);
        [pan setTranslation:CGPointZero inView:container];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat midX = container.bounds.size.width / 2.0;
        CGFloat targetX = (targetView.center.x < midX) ? (targetView.frame.size.width / 2.0 + 8) : (container.bounds.size.width - targetView.frame.size.width / 2.0 - 8);
        CGFloat targetY = MIN(MAX(targetView.center.y, 60), container.bounds.size.height - 60);

        [UIView animateWithDuration:0.25 animations:^{
            targetView.center = CGPointMake(targetX, targetY);
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
        self.alpha = 0.2;
    }];
}

@end

// ==========================================
// QUẢN LÝ BẢN QUYỀN
// ==========================================
@interface KeyAuthManager : NSObject <SpeedhackButtonDelegate>
@property (nonatomic, strong) SecureContainerView *secureContainer;
@property (nonatomic, strong) SpeedhackFloatingButton *floatingButton;
@property (nonatomic, strong) dispatch_source_t heartbeatSource;
@property (nonatomic, weak) UIWindow *appWindow;
@end

@implementation KeyAuthManager

static KeyAuthManager *sharedAuth = nil;

+ (instancetype)sharedInstance {
    return sharedAuth;
}

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

- (BOOL)validateKeyFormat:(NSString *)key outPlanDuration:(uint64_t *)outDuration outNonce:(NSString **)outNonce {
    NSArray *parts = [key componentsSeparatedByString:@"-"];
    if (parts.count != 4) return NO;

    NSString *planCode = parts[0];
    NSString *keyDeviceID = parts[1];
    NSString *nonce = parts[2];
    NSString *receivedSign = parts[3];

    NSString *myDeviceID = [self getDeviceID];
    if (![keyDeviceID isEqualToString:myDeviceID]) return NO;

    NSString *expectedSign = generate_signature(planCode, myDeviceID, nonce);
    if (![receivedSign isEqualToString:expectedSign]) return NO;

    uint64_t duration = parse_duration_from_plan(planCode);
    if (duration == 0) return NO;

    if (outDuration) *outDuration = duration;
    if (outNonce) *outNonce = nonce;
    return YES;
}

- (void)initialSetup {
    if (!self.floatingButton && self.appWindow) {
        // Tạo khung chứa bảo mật chống chụp màn hình
        self.secureContainer = [[SecureContainerView alloc] initWithFrame:CGRectMake(self.appWindow.bounds.size.width - 54, 120, 46, 46)];
        
        self.floatingButton = [[SpeedhackFloatingButton alloc] initWithFrame:self.secureContainer.bounds];
        self.floatingButton.delegate = self;

        // Thêm nút vào canvas bảo vệ
        [self.secureContainer.contentView addSubview:self.floatingButton];
        [self.appWindow addSubview:self.secureContainer];
    }
    [self checkLicenseValidity];
}

- (void)checkLicenseValidity {
    NSString *savedKey = [[NSUserDefaults standardUserDefaults] stringForKey:KEY_STORAGE];
    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    uint64_t now = get_current_real_time();

    if (savedKey && [self validateKeyFormat:savedKey outPlanDuration:NULL outNonce:NULL] && now < expireTime) {
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

    double expireTime = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
    uint64_t now = get_current_real_time();
    NSString *statusInfo = @"";

    if (now < expireTime) {
        NSInteger remainingSec = (NSInteger)(expireTime - now);
        NSInteger days = remainingSec / 86400;
        NSInteger hours = (remainingSec % 86400) / 3600;
        NSInteger minutes = (remainingSec % 3600) / 60;
        statusInfo = [NSString stringWithFormat:@"\nTrạng thái: Còn %ld ngày %ld giờ %ld phút\n(Nhập Key mới để gia hạn thêm)", (long)days, (long)hours, (long)minutes];
    }

    NSString *title = @"KÍCH HOẠT BẢN QUYỀN";
    NSString *msg = [NSString stringWithFormat:@"Mã thiết bị của bạn:\n%@%@\n\n(Sao chép mã gửi Admin để nhận Key)", deviceID, statusInfo];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title 
                                                                   message:msg 
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Dán mã Key vào đây";
        textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Sao Chép Mã Máy" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = deviceID;
        [self showKeyInputDialogOn:rootVC deviceID:deviceID];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Kích Hoạt" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *rawInput = alert.textFields.firstObject.text;
        NSString *inputKey = [rawInput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;

        uint64_t planDuration = 0;
        NSString *nonce = nil;

        if (![self validateKeyFormat:inputKey outPlanDuration:&planDuration outNonce:&nonce]) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Thông Báo" 
                                                                         message:@"Mã Key không chính xác hoặc không áp dụng cho thiết bị này!" 
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"Nhập Lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                [self showKeyInputDialogOn:rootVC deviceID:deviceID];
            }]];
            [rootVC presentViewController:err animated:YES completion:nil];
            return;
        }

        if (is_nonce_already_used(nonce)) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Thông Báo" 
                                                                         message:@"Mã Key này đã được kích hoạt trước đó và không thể tái sử dụng!" 
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
            [rootVC presentViewController:err animated:YES completion:nil];
            return;
        }

        sync_time_from_internet(^(BOOL success) {
            save_nonce_to_keychain(nonce);

            uint64_t currentExpire = [[NSUserDefaults standardUserDefaults] doubleForKey:EXPIRE_STORAGE];
            uint64_t nowReal = get_current_real_time();
            uint64_t baseTime = (nowReal < currentExpire) ? currentExpire : nowReal;
            uint64_t newExpire = baseTime + planDuration;

            [[NSUserDefaults standardUserDefaults] setObject:inputKey forKey:KEY_STORAGE];
            [[NSUserDefaults standardUserDefaults] setDouble:(double)newExpire forKey:EXPIRE_STORAGE];
            [[NSUserDefaults standardUserDefaults] synchronize];

            [self.floatingButton setLockedState:NO];
            [self startHeartbeat];

            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Thành Công" 
                                                                                  message:@"Bản quyền đã được kích hoạt thành công!" 
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [rootVC presentViewController:successAlert animated:YES completion:nil];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];

    [rootVC presentViewController:alert animated:YES completion:nil];
}

// Hàm phụ để bên bắt đơn gọi đổi màu nút khi bứt tốc x5
- (void)triggerButtonBurstEffect:(BOOL)active {
    [self.floatingButton showBurstEffect:active];
}

@end

// Hàm toàn cục cho SmartOrderTrigger.m gọi
void notify_burst_state_to_button(BOOL active) {
    [[KeyAuthManager sharedInstance] triggerButtonBurstEffect:active];
}
