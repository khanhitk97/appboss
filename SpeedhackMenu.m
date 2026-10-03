#import <UIKit/UIKit.h>

// ==========================================
// CẤU HÌNH API GOOGLE SHEETS MỚI NHẤT
// ==========================================
#define GOOGLE_SHEET_API_URL @"https://script.google.com/macros/s/AKfycbz6gvfUZuyuO8-BW8tRVkoTFGPvZNu_eJPz1JtI9AuVnUQd2NLKcMCCQ4wBckVPPg5V/exec"

#define USER_PHONE_KEY @"SAVED_USER_PHONE"
#define USER_PASS_KEY  @"SAVED_USER_PASS"
#define USER_ACTIVE_KEY @"SAVED_USER_ACTIVE"
#define USER_TRIGGER_SEC_KEY @"SAVED_USER_TRIGGER_SEC"
#define USER_EXPIRE_KEY @"SAVED_USER_EXPIRE"
#define USER_STATUS_KEY @"SAVED_USER_STATUS"

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

// Cử chỉ chạm giữ 3 ngón tay trong 3 giây
- (void)setupGesture {
    if (!self.appWindow) return;

    self.tripleFingerGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleTripleFingerLongPress:)];
    self.tripleFingerGesture.numberOfTouchesRequired = 3;
    self.tripleFingerGesture.minimumPressDuration = 3.0;
    self.tripleFingerGesture.cancelsTouchesInView = NO;
    self.tripleFingerGesture.delegate = self;

    [self.appWindow addGestureRecognizer:self.tripleFingerGesture];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleTripleFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [feedback impactOccurred];
        }
        [self showMainInterface];
    }
}

// Kiểm tra ngầm định kỳ mỗi 3 phút
- (void)startHeartbeat {
    [self autoCheckLicense];

    self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.heartbeatTimer, dispatch_walltime(NULL, 0), 180ull * NSEC_PER_SEC, 10ull * NSEC_PER_SEC);
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
    NSString *urlStr = [NSString stringWithFormat:@"%@?action=check&phone=%@&device_id=%@",
                        GOOGLE_SHEET_API_URL,
                        [phone stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        deviceId];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    req.HTTPMethod = @"GET";

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                BOOL active = [json[@"is_active"] boolValue];
                NSInteger sec = [json[@"trigger_second"] integerValue];
                NSString *status = json[@"status"] ?: @"PENDING";
                NSString *expire = json[@"expire_at"] ?: @"";

                [[NSUserDefaults standardUserDefaults] setBool:active forKey:USER_ACTIVE_KEY];
                [[NSUserDefaults standardUserDefaults] setObject:status forKey:USER_STATUS_KEY];
                [[NSUserDefaults standardUserDefaults] setObject:expire forKey:USER_EXPIRE_KEY];
                if (sec > 0) {
                    [[NSUserDefaults standardUserDefaults] setInteger:sec forKey:USER_TRIGGER_SEC_KEY];
                }
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
    }] resume];
}

// Điều hướng giao diện: Nếu đã có tài khoản thì hiện Dashboard, nếu chưa thì hiện Form Đăng nhập
- (void)showMainInterface {
    NSString *savedPhone = [[NSUserDefaults standardUserDefaults] stringForKey:USER_PHONE_KEY];
    if (savedPhone && savedPhone.length > 0) {
        [self showDashboardDialog];
    } else {
        [self showAuthInputDialog];
    }
}

// Bảng thông tin khi đã đăng nhập
- (void)showDashboardDialog {
    UIViewController *rootVC = self.appWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    if (!rootVC) return;

    NSString *phone = [[NSUserDefaults standardUserDefaults] stringForKey:USER_PHONE_KEY];
    NSString *status = [[NSUserDefaults standardUserDefaults] stringForKey:USER_STATUS_KEY] ?: @"PENDING";
    NSString *expire = [[NSUserDefaults standardUserDefaults] stringForKey:USER_EXPIRE_KEY] ?: @"Chưa kích hoạt";
    NSInteger sec = [[NSUserDefaults standardUserDefaults] integerForKey:USER_TRIGGER_SEC_KEY];
    if (sec <= 0) sec = 3;

    NSString *msg = [NSString stringWithFormat:@"Tài khoản: %@\nID Máy: %@\nTrạng thái: %@\nHạn dùng: %@\nMốc bứt tốc: %ld giây",
                     phone, [self getDeviceID], status, expire, (long)sec];

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
        [self showAuthInputDialog];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:nil];
}

// Bảng Đăng nhập & Đăng ký
- (void)showAuthInputDialog {
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
    NSString *urlStr = [NSString stringWithFormat:@"%@?action=%@&phone=%@&password=%@&device_id=%@",
                        GOOGLE_SHEET_API_URL, action,
                        [phone stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        [password stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                        deviceId];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
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

BOOL is_license_active(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:USER_ACTIVE_KEY];
}

NSInteger get_current_trigger_second(void) {
    NSInteger sec = [[NSUserDefaults standardUserDefaults] integerForKey:USER_TRIGGER_SEC_KEY];
    return (sec > 0) ? sec : 3;
}
