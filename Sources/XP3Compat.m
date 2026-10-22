// XP3Player 1.3.11 (15) compatibility patch. ARC; public APIs only.
#if XP3COMPAT_TESTING
#import "../tests/FakeUIKit.h"
#elif XP3_MINIMAL_SDK
#import "XP3ABI.h"
#else
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>
@interface NSObject (XP3LegacyCallback)
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index;
@end
#endif
#include <stdarg.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include "XP3EngineScheduling.h"

// The original DAFRunLoop dereferences CFRunLoop internals at fixed offsets.
// Never call its original IMP: those offsets changed across OS releases.
static BOOL XP3PublicRunMode(id self, SEL cmd, NSString *mode, NSDate *deadline) {
    (void)self; (void)cmd;
    NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:0.05];
    if (deadline) slice = [slice earlierDate:deadline];
    BOOL handled = [[NSRunLoop currentRunLoop] runMode:mode beforeDate:slice];
    if (!handled) [NSThread sleepForTimeInterval:0.001];
    return handled;
}

static void XP3OnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

static void (*XP3OriginalShow)(id, SEL);
static void (*XP3OriginalStyle)(id, SEL, NSInteger);
static UITextField *(*XP3OriginalField)(id, SEL, NSInteger);
static void (*XP3OriginalDismiss)(id, SEL, NSInteger, BOOL);
static char XP3BridgeKey;
typedef id (*XP3AllocIMP)(Class, SEL, void *) __attribute__((ns_returns_retained));
static XP3AllocIMP XP3OriginalAlloc;
typedef id (*XP3ClassAllocIMP)(Class, SEL) __attribute__((ns_returns_retained));
static XP3ClassAllocIMP XP3OriginalClassAlloc;

// AppKit is already loaded in PlayCover/Catalyst. Resolve its public classes at
// runtime so the same iOS dylib has no AppKit dependency on an iPhone or iPad.
@interface XP3AppKitView : NSObject
- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(id)view;
@property(copy) NSString *stringValue;
@end
@interface XP3AppKitAlert : NSObject
@property(copy) NSString *messageText;
@property(copy) NSString *informativeText;
@property(strong) id accessoryView;
@property(readonly) id window;
- (id)addButtonWithTitle:(NSString *)title;
- (NSInteger)runModal;
@end

#include "XP3AppKitInput.h"

static BOOL XP3IsTarget(UIAlertView *alert) {
    Class cls = objc_getClass("MessageBoxEventRecevier"); // upstream typo is intentional
    return cls && [alert.delegate isKindOfClass:cls];
}

@interface XP3DialogBridge : NSObject
@property(strong) UIAlertController *controller;
@property(strong) UIAlertView *activeAlert;
@property(strong) id callbackReceiver;
@property NSInteger style;
@property NSUInteger retries;
@property BOOL started;
@property BOOL finished;
- (void)configureStyle:(NSInteger)style alert:(UIAlertView *)alert;
- (void)begin:(UIAlertView *)alert;
- (void)tryPresent;
- (void)finish:(NSInteger)index;
- (BOOL)runAppKitModal;
@end

static XP3DialogBridge *XP3Bridge(UIAlertView *alert) {
    XP3DialogBridge *bridge = objc_getAssociatedObject(alert, &XP3BridgeKey);
    if (!bridge) {
        bridge = [[XP3DialogBridge alloc] init];
        objc_setAssociatedObject(alert, &XP3BridgeKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return bridge;
}

// This app has a legacy, single-window lifecycle. Reuse its existing window;
// presenting an alert must not create a second UIWindow or change its root.
static UIViewController *XP3Presenter(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != 0) return nil; // UIApplicationStateActive
    UIWindow *window = app.keyWindow;
    if (!window || window.isHidden || !window.rootViewController) {
        window = nil;
        NSArray<UIWindow *> *windows = app.windows;
        for (NSUInteger i = 0; i < windows.count; ++i) {
            UIWindow *candidate = windows[i];
            if (!candidate.isHidden && candidate.windowLevel == 0 && candidate.rootViewController) {
                window = candidate;
                if (candidate.isKeyWindow) break;
            }
        }
    }
    UIViewController *vc = window.rootViewController;
    for (NSUInteger depth = 0; vc.presentedViewController && depth < 32; ++depth) {
        if (vc.isBeingPresented || vc.isBeingDismissed) return nil;
        vc = vc.presentedViewController;
    }
    if (!vc || !vc.view.window || vc.isBeingPresented || vc.isBeingDismissed ||
        [vc isKindOfClass:[UIAlertController class]]) return nil;
    return vc;
}

@implementation XP3DialogBridge
- (void)configureStyle:(NSInteger)style alert:(UIAlertView *)alert {
    if (self.started || (self.controller && self.style == style)) return;
    self.style = style;
    self.controller = [UIAlertController alertControllerWithTitle:alert.title
        message:alert.message preferredStyle:1]; // UIAlertControllerStyleAlert
    NSUInteger count = style == 3 ? 2 : ((style == 1 || style == 2) ? 1 : 0);
    for (NSUInteger i = 0; i < count; ++i) {
        BOOL secure = style == 1 || (style == 3 && i == 1);
        [self.controller addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.secureTextEntry = secure;
            field.autocorrectionType = 1; // UITextAutocorrectionTypeNo
            field.autocapitalizationType = 0;
        }];
    }
}
- (void)begin:(UIAlertView *)alert {
    if (self.started) return;
    if (!self.controller) [self configureStyle:0 alert:alert];
    self.started = YES;
    self.activeAlert = alert; // balanced in finish; keeps the legacy delegate context alive
    self.callbackReceiver = alert.delegate;
    self.controller.title = alert.title;
    self.controller.message = alert.message;
    NSInteger count = alert.numberOfButtons;
    NSInteger cancel = alert.cancelButtonIndex;
    __weak XP3DialogBridge *weakSelf = self;
    for (NSInteger index = 0; index < count; ++index) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:[alert buttonTitleAtIndex:index]
            style:(index == cancel ? 1 : 0) handler:^(UIAlertAction *sender) {
                (void)sender;
                [weakSelf finish:index];
            }];
        [self.controller addAction:action];
    }
    NSLog(@"[XP3Compat] modern dialog, buttons=%ld style=%ld", (long)count, (long)self.style);
    if (count <= 0) {
        [self.controller addAction:[UIAlertAction actionWithTitle:@"Close" style:0
            handler:^(UIAlertAction *sender) { (void)sender; [weakSelf finish:0]; }]];
    }
    if ([self runAppKitModal]) return;
    [self tryPresent]; // main-thread path must stay synchronous: nested run loop below
}
- (BOOL)runAppKitModal {
    Class alertClass = objc_getClass("NSAlert");
    Class fieldClass = objc_getClass("NSTextField");
    Class viewClass = objc_getClass("NSView");
    if (!alertClass || !fieldClass || !viewClass) return NO;
    XP3AppKitAlert *native = [[(id)alertClass alloc] init];
    native.messageText = self.activeAlert.title ?: @"";
    native.informativeText = self.activeAlert.message ?: @"";
    NSInteger count = self.activeAlert.numberOfButtons;
    for (NSInteger i = 0; i < count; ++i)
        [native addButtonWithTitle:[self.activeAlert buttonTitleAtIndex:i]];
    if (count <= 0) [native addButtonWithTitle:@"Close"];
    NSMutableArray<XP3AppKitView *> *nativeFields = [NSMutableArray array];
    NSArray<UITextField *> *fields = self.controller.textFields;
    if (fields.count) {
        CGRect frame = {{0, 0}, {320, 30 * fields.count}};
        XP3AppKitView *container = [[(id)viewClass alloc] initWithFrame:frame];
        for (NSUInteger i = 0; i < fields.count; ++i) {
            Class type = fields[i].secureTextEntry ? objc_getClass("NSSecureTextField") : fieldClass;
            CGRect fieldFrame = {{0, 30 * (fields.count - i - 1)}, {320, 24}};
            XP3AppKitView *input = [[(id)type alloc] initWithFrame:fieldFrame];
            input.stringValue = fields[i].text ?: @"";
            [container addSubview:input];
            [nativeFields addObject:input];
        }
        native.accessoryView = container;
    }
    NSLog(@"[XP3Compat] AppKit native modal started");
    id previousModalWindow = XP3ModalEventWindow;
    XP3ModalEventWindow = native.window;
    NSInteger response;
    @try {
        response = [native runModal];
    } @finally {
        XP3ModalEventWindow = previousModalWindow;
    }
    for (NSUInteger i = 0; i < fields.count; ++i) fields[i].text = nativeFields[i].stringValue;
    NSInteger index = response - 1000; // NSAlertFirstButtonReturn
    NSLog(@"[XP3Compat] AppKit modal completed, index=%ld", (long)index);
    [self finish:index];
    return YES;
}
- (void)tryPresent {
    if (self.finished) return;
    UIViewController *presenter = XP3Presenter();
    if (!presenter) {
        if (++self.retries % 60 == 0)
            NSLog(@"[XP3Compat] awaiting an active presenter; no action selected");
        // NSDefaultRunLoopMode timer works while the old code waits for a result.
        // Do not enqueue on the main dispatch queue from inside its own callback.
        // Never guess a button: legacy dialogs have no universal cancel index.
        [self performSelector:@selector(tryPresent) withObject:nil afterDelay:0.05];
        return;
    }
    [presenter presentViewController:self.controller animated:YES completion:nil];
}
- (void)finish:(NSInteger)index {
    if (self.finished) return;
    UIAlertView *alert = self.activeAlert;
    if (index < 0 || index >= (alert.numberOfButtons > 0 ? alert.numberOfButtons : 1)) {
        NSLog(@"[XP3Compat] invalid programmatic button index ignored");
        return;
    }
    self.finished = YES;
    id receiver = self.callbackReceiver;
    // Receiver only implements clickedButtonAtIndex:, writing its SelectedIndex.
    // -1 would leave getSelectedIndex spinning forever.
    if ([receiver respondsToSelector:@selector(alertView:clickedButtonAtIndex:)])
        [receiver alertView:alert clickedButtonAtIndex:index];
    self.activeAlert = nil;
    self.callbackReceiver = nil;
    // Keep controller/textFields in the associated bridge: caller holds the exact
    // UITextField returned BEFORE show, and reads it AFTER the callback.
}
@end

static void XP3Show(UIAlertView *alert, SEL cmd) {
    if (!XP3IsTarget(alert)) { XP3OriginalShow(alert, cmd); return; }
    XP3OnMain(^{ [XP3Bridge(alert) begin:alert]; });
}
static void XP3SetStyle(UIAlertView *alert, SEL cmd, NSInteger style) {
    if (!XP3IsTarget(alert)) { XP3OriginalStyle(alert, cmd, style); return; }
    XP3OnMain(^{ [XP3Bridge(alert) configureStyle:style alert:alert]; });
}
static UITextField *XP3Field(UIAlertView *alert, SEL cmd, NSInteger index) {
    if (!XP3IsTarget(alert)) return XP3OriginalField(alert, cmd, index);
    __block UITextField *field;
    XP3OnMain(^{
        NSArray<UITextField *> *fields = XP3Bridge(alert).controller.textFields;
        if (index >= 0 && (NSUInteger)index < fields.count) field = fields[(NSUInteger)index];
    });
    return field;
}
static void XP3Dismiss(UIAlertView *alert, SEL cmd, NSInteger index, BOOL animated) {
    XP3DialogBridge *bridge = objc_getAssociatedObject(alert, &XP3BridgeKey);
    if (!bridge || !bridge.started) { XP3OriginalDismiss(alert, cmd, index, animated); return; }
    XP3OnMain(^{
        if (index < 0 || index >= (alert.numberOfButtons > 0 ? alert.numberOfButtons : 1)) return;
        [bridge.controller dismissViewControllerAnimated:animated completion:nil];
        [bridge finish:index];
    });
}

// Catalyst can discard deprecated UIAlertView instances before show is reached.
// Allocate a configuration-only object, then decide from its initializer's
// delegate whether to bridge it or return the original UIKit object.
@interface XP3LegacyAlert : NSObject
@property(copy) NSString *title;
@property(copy) NSString *message;
@property(weak) id delegate;
@property(strong) NSMutableArray<NSString *> *buttons;
@property NSInteger cancelButtonIndex;
@property(nonatomic) NSInteger alertViewStyle;
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate
    cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)first, ...;
@end

@implementation XP3LegacyAlert
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate
    cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)first, ... {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    va_list args;
    va_start(args, first);
    for (NSString *button = first; button; button = va_arg(args, NSString *))
        [titles addObject:button];
    va_end(args);
    Class receiver = objc_getClass("MessageBoxEventRecevier");
    if (!receiver || ![delegate isKindOfClass:receiver]) {
        // Class-cluster-style substitution preserves ownership of init's result.
        UIAlertView *native = XP3OriginalAlloc(objc_getClass("UIAlertView"), @selector(allocWithZone:), 0);
        native = [native initWithTitle:title message:message delegate:delegate
            cancelButtonTitle:cancel otherButtonTitles:nil];
        for (NSUInteger i = 0; i < titles.count; ++i) [native addButtonWithTitle:titles[i]];
        self = (id)native;
        return self;
    }
    self = [super init];
    if (self) {
        NSLog(@"[XP3Compat] legacy dialog configuration captured");
        _title = title;
        _message = message;
        _delegate = delegate;
        _buttons = [NSMutableArray array];
        _cancelButtonIndex = -1;
        if (cancel) { [_buttons addObject:cancel]; _cancelButtonIndex = 0; }
        for (NSUInteger i = 0; i < titles.count; ++i) [_buttons addObject:titles[i]];
    }
    return self;
}
- (NSInteger)numberOfButtons { return (NSInteger)self.buttons.count; }
- (NSString *)buttonTitleAtIndex:(NSInteger)index {
    return index >= 0 && (NSUInteger)index < self.buttons.count ? self.buttons[(NSUInteger)index] : nil;
}
- (NSInteger)addButtonWithTitle:(NSString *)title {
    if (!title) return -1;
    [self.buttons addObject:title];
    return (NSInteger)self.buttons.count - 1;
}
- (void)setAlertViewStyle:(NSInteger)style {
    _alertViewStyle = style;
    XP3SetStyle((id)self, @selector(setAlertViewStyle:), style);
}
- (UITextField *)textFieldAtIndex:(NSInteger)index { return XP3Field((id)self, _cmd, index); }
- (void)show { XP3Show((id)self, _cmd); }
- (void)dismissWithClickedButtonIndex:(NSInteger)index animated:(BOOL)animated {
    XP3Dismiss((id)self, _cmd, index, animated);
}
@end

static id XP3Allocate(Class cls, SEL cmd, void *zone) __attribute__((ns_returns_retained));
static id XP3Allocate(Class cls, SEL cmd, void *zone) {
    if (cls != objc_getClass("UIAlertView")) return XP3OriginalAlloc(cls, cmd, zone);
    return [[XP3LegacyAlert alloc] init];
}
static id XP3AllocateClass(Class cls, SEL cmd) __attribute__((ns_returns_retained));
static id XP3AllocateClass(Class cls, SEL cmd) {
    if (cls != objc_getClass("UIAlertView")) return XP3OriginalClassAlloc(cls, cmd);
    return [[XP3LegacyAlert alloc] init];
}

// Hook only implementations with the expected selector arity. Do not exchange
// inherited NSObject methods or change unrelated application classes.
__attribute__((visibility("default")))
void XP3CompatInstall(void) {
    static BOOL installed;
    if (installed) return;
    installed = YES;
    XP3InstallAppKitInputBridge();
    XP3InstallEngineScheduling(YES, YES);
    Class loop = objc_getClass("DAFRunLoop");
    Method run = class_getInstanceMethod(loop, @selector(runMode:beforeDate:));
    if (run && method_getNumberOfArguments(run) == 4) {
        method_setImplementation(run, (IMP)XP3PublicRunMode);
        NSLog(@"[XP3Compat] DAFRunLoop uses public NSRunLoop API (50 ms slices)");
    } else NSLog(@"[XP3Compat] DAFRunLoop signature missing; hook skipped");

    Class legacy = objc_getClass("UIAlertView");
    Method show = class_getInstanceMethod(legacy, @selector(show));
    Method style = class_getInstanceMethod(legacy, @selector(setAlertViewStyle:));
    Method field = class_getInstanceMethod(legacy, @selector(textFieldAtIndex:));
    Method dismiss = class_getInstanceMethod(legacy, @selector(dismissWithClickedButtonIndex:animated:));
    if (!show || !style || !field || !dismiss || !objc_getClass("MessageBoxEventRecevier") ||
        !objc_getClass("UIAlertController")) { NSLog(@"[XP3Compat] legacy dialog bridge unavailable"); return; }
    XP3OriginalShow = (void *)method_getImplementation(show);
    XP3OriginalStyle = (void *)method_getImplementation(style);
    XP3OriginalField = (void *)method_getImplementation(field);
    XP3OriginalDismiss = (void *)method_getImplementation(dismiss);
    method_setImplementation(show, (IMP)XP3Show);
    method_setImplementation(style, (IMP)XP3SetStyle);
    method_setImplementation(field, (IMP)XP3Field);
    method_setImplementation(dismiss, (IMP)XP3Dismiss);
    Method alloc = class_getClassMethod(legacy, @selector(allocWithZone:));
    if (alloc) {
        XP3OriginalAlloc = (XP3AllocIMP)method_getImplementation(alloc);
        // allocWithZone: is often inherited from NSObject. Add to UIAlertView's
        // own metaclass; NEVER replace the inherited NSObject implementation.
        if (!class_addMethod(object_getClass(legacy), @selector(allocWithZone:),
            (IMP)XP3Allocate, method_getTypeEncoding(alloc)))
            method_setImplementation(class_getClassMethod(legacy, @selector(allocWithZone:)), (IMP)XP3Allocate);
    }
    Method classAlloc = class_getClassMethod(legacy, @selector(alloc));
    if (classAlloc) {
        XP3OriginalClassAlloc = (XP3ClassAllocIMP)method_getImplementation(classAlloc);
        if (!class_addMethod(object_getClass(legacy), @selector(alloc),
            (IMP)XP3AllocateClass, method_getTypeEncoding(classAlloc)))
            method_setImplementation(class_getClassMethod(legacy, @selector(alloc)), (IMP)XP3AllocateClass);
    }
    NSLog(@"[XP3Compat] targeted UIAlertView bridge installed");
}

#if !XP3COMPAT_TESTING
__attribute__((constructor)) static void XP3CompatLoad(void) {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (![bundleID isEqualToString:@"tvp.XP3Player"] &&
            ![bundleID isEqualToString:@"tvp.XP3Player.Compat"]) return;
        XP3CompatInstall();
    }
}
#endif
