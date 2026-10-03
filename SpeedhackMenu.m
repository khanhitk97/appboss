#import <UIKit/UIKit.h>

// URL Web App Google Apps Script của bạn
#define GOOGLE_SHEET_API_URL @"https://script.google.com/macros/s/AKfycbz6gvfUZuyuO8-BW8tRVkoTFGPvZNu_eJPz1JtI9AuVnUQd2NLKcMCCQ4wBckVPPg5V/exec"

#define USER_PHONE_KEY @"SAVED_USER_PHONE"
#define USER_PASS_KEY  @"SAVED_USER_PASS"
#define USER_ACTIVE_KEY @"SAVED_USER_ACTIVE"
#define USER_TRIGGER_SEC_KEY @"SAVED_USER_TRIGGER_SEC"
#define USER_EXPIRE_KEY @"SAVED_USER_EXPIRE"
#define USER_STATUS_KEY @"SAVED_USER_STATUS"

#ifdef __cplusplus
extern "C" {
#endif
extern void set_speed_factor(float factor);
#ifdef __cplusplus
}
#endif

// Hàm kiểm tra trạng thái khóa cứng
static inline BOOL is_device_blocked(void) {
    NSString *status = [[NSUserDefaults standardUserDefaults] stringForKey:USER_STATUS_KEY];
    if (!status) return NO;
    status = [status stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;
    return ([status isEqualToString:@"BLOCK"] || [status isEqualToString:@"BLOCKED"] || [status isEqualToString:@"LOCKED"]);
}

@interface AuthManager : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *appWindow;
@property (nonatomic, strong) UILongPressGestureRecognizer *tripleFingerGesture;
@property (nonatomic, strong) dispatch_source_t heartbeatTimer;
@end

@implementation AuthManager

static AuthManager *sharedAuth = nil;

+ (instancetype)sharedInstance {
    return sharedAuth;
}

+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = [self findActiveWindow];
        if (window) {
            sharedAuth = [[AuthManager alloc] init];
            sharedAuth.appWindow = window;
            [sharedAuth setupGesture];
            [sharedAuth setupAppStateObservers];
            [sharedAuth startHeartbeat];
        }
    });
}

+ (UIWindow *)findActiveWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (NSString *)getDeviceID {
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (!uuid) return @"UNKNOWN0";
    return [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].uppercaseString;
}

- (void)setupAppStateObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAppDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)handleAppDidBecomeActive {
    [self autoCheckLicense];
}

- (void)setupGesture {
    if (!self.appWindow) return;

    self.tripleFingerGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleTripleFingerLongPress:)];
    self.tripleFingerGesture.numberOfTouchesRequired = 3;
    self.tripleFingerGesture.minimumPressDuration = 3.0;
    self.tripleFingerGesture.cancelsTouchesInView = NO;
    self.tripleFingerGesture.delegate = self;

    [self.appWindow addGestureRecognizer:self.tripleFingerGesture];
}

// CHẶN TẬN GỐC: Không nhận bất kỳ cú chạm nào nếu đang bị BLOCK
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (is_device_blocked()) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

// Xử lý khi nhấn giữ 3 ngón tay 3 giây
- (void)handleTripleFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // Lớp bảo vệ 2: Kiểm tra lại một lần nữa
        if (is_device_blocked()) {
            set_speed_factor(1.0f);
            return;
        }

        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [feedback impactOccurred];
        }
        [self showMainInterface];
    }
}

// Kiểm tra ngầm định kỳ mỗi 60 giây
- (void)startHeartbeat {
    [self autoCheckLicense];

    self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.heartbeatTimer, dispatch_walltime(NULL, 0), 60ull * NSEC_PER_SEC, 5ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.heartbeatTimer, ^{
        [weakSelf autoCheckLicense];
    });
    dispatch_resume(self.heartbeatTimer);
}

- (void)autoCheckLicense {
    NSString *phone = [[NSUserDefaults standardUserDefaults] stringForKey:USER_PHONE_KEY];
    if (!phone || phone.length == 0) return;

    NSString *deviceId = [self getDeviceID];
    // Thêm tham số timestamp `&t=` để chống iOS lưu cache HTTP
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
    NSString *urlStr = [NSString stringWithFormat:@"%@?action=check&phone=%@&device_id=%@&t=%.0f",
                        GOOGLE_SHEET_API_URL,
                        [phone stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        deviceId, timestamp];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                   timeoutInterval:10.0];
    req.HTTPMethod = @"GET";

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                BOOL active = [json[@"is_active"] boolValue];
                NSInteger sec = [json[@"trigger_second"] integerValue];
                NSString *status = json[@"status"] ?: @"PENDING";
                NSString *expire = json[@"expire_at"] ?: @"";

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSUserDefaults standardUserDefaults] setBool:active forKey:USER_ACTIVE_KEY];
                    [[NSUserDefaults standardUserDefaults] setObject:status forKey:USER_STATUS_KEY];
                    [[NSUserDefaults standardUserDefaults] setObject:expire forKey:USER_EXPIRE_KEY];
                    if (sec > 0) {
                        [[NSUserDefaults standardUserDefaults] setInteger:sec forKey:USER_TRIGGER_SEC_KEY];
                    }
                    [[NSUserDefaults standardUserDefaults] synchronize];

                    // Nếu bị BLOCK hoặc LOCKED -> Lập tức ép tốc độ về 1.0x và đóng mọi popup đang mở
                    if (is_device_blocked() || !active) {
                        set_speed_factor(1.0f);
                        if (is_device_blocked()) {
                            UIViewController *rootVC = self.appWindow.rootViewController;
                            if (rootVC.presentedViewController) {
                                [rootVC dismissViewControllerAnimated:YES completion:nil];
                            }
                        }
                    }
                });
            }
        }
    }] resume];
}

- (void)showMainInterface {
    // Lớp bảo vệ 3: Tuyệt đối không mở nếu đang bị BLOCK
    if (is_device_blocked()) return;

    NSString *savedPhone = [[NSUserDefaults standardUserDefaults] stringForKey:USER_PHONE_KEY];
    if (savedPhone && savedPhone.length > 0) {
        [self showDashboardDialog];
    } else {
        [self showAuthInputDialog];
    }
}

- (void)showDashboardDialog {
    if (is_device_blocked()) return;

    UIViewController *rootVC = self.appWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    if (!rootVC) return;

    NSString *phone = [[NSUserDefaults standardUserDefaults] stringForKey:USER_PHONE_KEY];
    NSString *status = [[NSUserDefaults standardUserDefaults] stringForKey:USER_STATUS_KEY] ?: @"PENDING";
    NSString *expire = [[NSUserDefaults standardUserDefaults] stringForKey:USER_EXPIRE_KEY] ?: @"Chưa kích hoạt";
    NSInteger sec = [[NSUserDefaults standardUserDefaults] integerForKey:USER_TRIGGER_SEC_KEY];
    if (sec <= 0) sec = 3;

    NSString *remainingTimeStr = @"";
    if (expire.length > 0) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        [df setTimeZone:[NSTimeZone timeZoneWithName:@"GMT+7"]];
        NSDate *expDate = [df dateFromString:expire];
        if (expDate) {
            NSTimeInterval diff = [expDate timeIntervalSinceNow];
            if (diff > 0) {
                NSInteger mins = (NSInteger)(diff / 60);
                NSInteger hours = mins / 60;
                NSInteger days = hours / 24;
                if (days > 0) {
                    remainingTimeStr = [NSString stringWithFormat:@"\n(Còn lại: %ld ngày %ld giờ)", (long)days, (long)(hours % 24)];
                } else if (hours > 0) {
                    remainingTimeStr = [NSString stringWithFormat:@"\n(Còn lại: %ld giờ %ld phút)", (long)hours, (long)(mins % 60)];
                } else {
                    remainingTimeStr = [NSString stringWithFormat:@"\n(Còn lại: %ld phút %ld giây)", (long)mins, (long)((NSInteger)diff % 60)];
                }
            } else {
                remainingTimeStr = @"\n(ĐÃ HẾT HẠN)";
            }
        }
    }

    NSString *msg = [NSString stringWithFormat:@"Tài khoản: %@\nID Máy: %@\nTrạng thái: %@\nHạn dùng: %@%@\nMốc bứt tốc: %ld giây",
                     phone, [self getDeviceID], status, expire, remainingTimeStr, (long)sec];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"THÔNG TIN TÀI KHOẢN"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đồng Bộ Lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self autoCheckLicense];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đăng Xuất" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:USER_PHONE_KEY];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:USER_PASS_KEY];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:USER_ACTIVE_KEY];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:USER_STATUS_KEY];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:USER_EXPIRE_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
        set_speed_factor(1.0f);
        [self showAuthInputDialog];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:nil];
}

- (void)showAuthInputDialog {
    if (is_device_blocked()) return;

    UIViewController *rootVC = self.appWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    if (!rootVC) return;

    NSString *msg = [NSString stringWithFormat:@"ID Thiết bị: %@\n(Chưa đăng nhập)", [self getDeviceID]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"HỆ THỐNG XÁC THỰC"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Nhập Số Điện Thoại";
        textField.keyboardType = UIKeyboardTypePhonePad;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Nhập Mật Khẩu";
        textField.secureTextEntry = YES;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đăng Nhập" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *phone = alert.textFields[0].text;
        NSString *pass = alert.textFields[1].text;
        [self performAuthAction:@"login" phone:phone password:pass];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Tạo Tài Khoản Mới" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *phone = alert.textFields[0].text;
        NSString *pass = alert.textFields[1].text;
        [self performAuthAction:@"register" phone:phone password:pass];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:nil];
}

- (void)performAuthAction:(NSString *)action phone:(NSString *)phone password:(NSString *)password {
    phone = [phone stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    password = [password stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (phone.length == 0 || password.length == 0) {
        [self showAlertMessage:@"Vui lòng điền đủ SĐT và Mật khẩu!"];
        return;
    }

    NSString *deviceId = [self getDeviceID];
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
    NSString *urlStr = [NSString stringWithFormat:@"%@?action=%@&phone=%@&password=%@&device_id=%@&t=%.0f",
                        GOOGLE_SHEET_API_URL, action,
                        [phone stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        [password stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        deviceId, timestamp];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                   timeoutInterval:15.0];
    req.HTTPMethod = @"GET";

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) {
                [self showAlertMessage:[NSString stringWithFormat:@"Lỗi mạng: %@", err.localizedDescription]];
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                BOOL success = [json[@"success"] boolValue];
                NSString *message = json[@"message"] ?: @"Đã xử lý";

                if (success) {
                    [[NSUserDefaults standardUserDefaults] setObject:phone forKey:USER_PHONE_KEY];
                    [[NSUserDefaults standardUserDefaults] setObject:password forKey:USER_PASS_KEY];

                    BOOL active = [json[@"is_active"] boolValue];
                    NSInteger sec = [json[@"trigger_second"] integerValue];
                    NSString *status = json[@"status"] ?: (active ? @"ACTIVE" : @"PENDING");
                    NSString *expire = json[@"expire_at"] ?: @"";

                    [[NSUserDefaults standardUserDefaults] setBool:active forKey:USER_ACTIVE_KEY];
                    [[NSUserDefaults standardUserDefaults] setObject:status forKey:USER_STATUS_KEY];
                    [[NSUserDefaults standardUserDefaults] setObject:expire forKey:USER_EXPIRE_KEY];
                    if (sec > 0) {
                        [[NSUserDefaults standardUserDefaults] setInteger:sec forKey:USER_TRIGGER_SEC_KEY];
                    }
                    [[NSUserDefaults standardUserDefaults] synchronize];

                    if (!active || is_device_blocked()) {
                        set_speed_factor(1.0f);
                    }
                }

                [self showAlertMessage:message];
            }
        });
    }] resume];
}

- (void)showAlertMessage:(NSString *)msg {
    UIViewController *rootVC = self.appWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    if (!rootVC) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thông Báo"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:nil];
}

@end

// Kiểm tra bản quyền thời gian thực
BOOL is_license_active(void) {
    if (is_device_blocked()) {
        set_speed_factor(1.0f);
        return NO;
    }

    BOOL isActiveFlag = [[NSUserDefaults standardUserDefaults] boolForKey:USER_ACTIVE_KEY];
    if (!isActiveFlag) return NO;

    NSString *expireStr = [[NSUserDefaults standardUserDefaults] stringForKey:USER_EXPIRE_KEY];
    if (!expireStr || expireStr.length == 0) return NO;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    [df setTimeZone:[NSTimeZone timeZoneWithName:@"GMT+7"]];
    NSDate *expireDate = [df dateFromString:expireStr];

    if (expireDate) {
        if ([[NSDate date] compare:expireDate] == NSOrderedDescending) {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:USER_ACTIVE_KEY];
            [[NSUserDefaults standardUserDefaults] setObject:@"EXPIRED" forKey:USER_STATUS_KEY];
            [[NSUserDefaults standardUserDefaults] synchronize];
            set_speed_factor(1.0f);
            return NO;
        }
    }

    return YES;
}

NSInteger get_current_trigger_second(void) {
    NSInteger sec = [[NSUserDefaults standardUserDefaults] integerForKey:USER_TRIGGER_SEC_KEY];
    return (sec > 0) ? sec : 3;
}
