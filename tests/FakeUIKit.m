#import "FakeUIKit.h"

NSUInteger XP3FakeOriginalRunLoopCalls;
NSUInteger XP3FakePresentCount;
UIAlertController *XP3FakeLastPresentedAlert;

@implementation UIView
@end

@implementation UIViewController
- (instancetype)init {
    if ((self = [super init])) _view = [UIView new];
    return self;
}
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    (void)animated;
    NSCAssert(!self.presentedViewController, @"Attempt to present twice");
    self.presentedViewController = controller;
    controller.presentingViewController = self;
    controller.view.window = self.view.window;
    ++XP3FakePresentCount;
    if ([controller isKindOfClass:[UIAlertController class]]) XP3FakeLastPresentedAlert = (id)controller;
    if (completion) completion();
}
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    (void)animated;
    self.presentingViewController.presentedViewController = nil;
    self.presentingViewController = nil;
    self.view.window = nil;
    if (completion) completion();
}
@end

@implementation UIWindow
@end

@implementation UIApplication
+ (UIApplication *)sharedApplication {
    static UIApplication *application;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ application = [UIApplication new]; });
    return application;
}
@end

@implementation UITextField
@end

@implementation UIAlertAction
+ (UIAlertAction *)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self new];
    action.title = title;
    action.style = style;
    action.handler = handler;
    return action;
}
- (void)invoke {
    // UIKit dismisses an alert when an action is chosen. A test may deliberately
    // invoke the stored handler again to model duplicate/reentrant callbacks.
    [XP3FakeLastPresentedAlert dismissViewControllerAnimated:NO completion:nil];
    if (self.handler) self.handler(self);
}
@end

@implementation UIAlertController {
    NSMutableArray<UITextField *> *_fields;
    NSMutableArray<UIAlertAction *> *_mutableActions;
}
+ (UIAlertController *)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style {
    UIAlertController *controller = [self new];
    controller.title = title;
    controller.message = message;
    controller.preferredStyle = style;
    return controller;
}
- (instancetype)init {
    if ((self = [super init])) {
        _fields = [NSMutableArray array];
        _mutableActions = [NSMutableArray array];
    }
    return self;
}
- (NSArray<UITextField *> *)textFields { return _fields; }
- (NSArray<UIAlertAction *> *)actions { return _mutableActions; }
- (void)addTextFieldWithConfigurationHandler:(void (^)(UITextField *))handler {
    UITextField *field = [UITextField new];
    if (handler) handler(field);
    [_fields addObject:field];
}
- (void)addAction:(UIAlertAction *)action { [_mutableActions addObject:action]; }
@end

NSUInteger XP3FakeLegacyInitCount;
@implementation UIAlertView {
    NSMutableArray<NSString *> *_buttons;
    NSArray<UITextField *> *_legacyFields;
    NSUInteger _legacyShowCount, _legacyStyleCount, _legacyFieldCount, _legacyDismissCount;
}
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)firstOther, ... {
    ++XP3FakeLegacyInitCount;
    if ((self = [super init])) {
        _title = [title copy]; _message = [message copy]; _delegate = delegate;
        _buttons = [NSMutableArray array];
        _cancelButtonIndex = cancel ? 0 : -1;
        if (cancel) [_buttons addObject:cancel];
        va_list args;
        va_start(args, firstOther);
        for (NSString *button = firstOther; button; button = va_arg(args, NSString *)) [_buttons addObject:button];
        va_end(args);
    }
    return self;
}
- (NSInteger)numberOfButtons { return (NSInteger)_buttons.count; }
- (NSString *)buttonTitleAtIndex:(NSInteger)index { return _buttons[(NSUInteger)index]; }
- (NSInteger)addButtonWithTitle:(NSString *)title { [_buttons addObject:title]; return (NSInteger)_buttons.count - 1; }
- (void)setAlertViewStyle:(NSInteger)style {
    ++_legacyStyleCount;
    _alertViewStyle = style;
    if (style == 1 || style == 2) _legacyFields = @[[UITextField new]];
    else if (style == 3) _legacyFields = @[[UITextField new], [UITextField new]];
    else _legacyFields = @[];
}
- (UITextField *)textFieldAtIndex:(NSInteger)index {
    ++_legacyFieldCount;
    return index >= 0 && (NSUInteger)index < _legacyFields.count ? _legacyFields[(NSUInteger)index] : nil;
}
- (void)show { ++_legacyShowCount; }
- (void)dismissWithClickedButtonIndex:(NSInteger)index animated:(BOOL)animated {
    (void)index; (void)animated; ++_legacyDismissCount;
}
- (NSUInteger)legacyShowCount { return _legacyShowCount; }
- (NSUInteger)legacyStyleCount { return _legacyStyleCount; }
- (NSUInteger)legacyFieldCount { return _legacyFieldCount; }
- (NSUInteger)legacyDismissCount { return _legacyDismissCount; }
@end

@implementation DAFRunLoop
+ (instancetype)currentRunLoop { return [self new]; }
- (BOOL)runMode:(NSString *)mode beforeDate:(NSDate *)deadline {
    (void)mode; (void)deadline; ++XP3FakeOriginalRunLoopCalls; return YES;
}
@end

@implementation MessageBoxEventRecevier
- (instancetype)init {
    if ((self = [super init])) _selectedIndex = -1;
    return self;
}
- (int)getSelectedIndex { return (int)self.selectedIndex; }
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    ++self.callbackCount; self.selectedIndex = index; self.lastAlert = alert;
}
@end

void XP3FakeResetApplication(BOOL activePresenter) {
    UIApplication *application = [UIApplication sharedApplication];
    application.applicationState = 0;
    application.keyWindow = nil;
    application.windows = @[];
    XP3FakeLastPresentedAlert = nil;
    XP3FakePresentCount = 0;
    if (activePresenter) {
        UIWindow *window = [UIWindow new];
        window.keyWindow = YES;
        window.rootViewController = [UIViewController new];
        window.rootViewController.view.window = window;
        application.keyWindow = window;
        application.windows = @[window];
    }
}
