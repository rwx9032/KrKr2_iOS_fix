// Test-only UIKit surface. Real Foundation and Objective-C runtime are used.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

@class UIWindow, UIAlertView, UIAlertController;
@interface UIView : NSObject
@property(weak) UIWindow *window;
@property(getter=isHidden) BOOL hidden;
@end

@interface UIViewController : NSObject
@property(strong) UIView *view;
@property(strong) UIViewController *presentedViewController;
@property(weak) UIViewController *presentingViewController;
@property BOOL isBeingPresented;
@property BOOL isBeingDismissed;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion;
@end

@interface UIWindow : UIView
@property(strong) UIViewController *rootViewController;
@property(getter=isKeyWindow) BOOL keyWindow;
@property CGFloat windowLevel;
@end

@interface UIApplication : NSObject
+ (UIApplication *)sharedApplication;
@property(strong) UIWindow *keyWindow;
@property(copy) NSArray<UIWindow *> *windows;
@property NSInteger applicationState;
@end

@interface UITextField : UIView
@property(copy) NSString *text;
@property(getter=isSecureTextEntry) BOOL secureTextEntry;
@property NSInteger autocorrectionType;
@property NSInteger autocapitalizationType;
@end

@interface UIAlertAction : NSObject
@property(copy) NSString *title;
@property NSInteger style;
@property(copy) void (^handler)(UIAlertAction *);
+ (UIAlertAction *)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler;
- (void)invoke;
@end

@interface UIAlertController : UIViewController
@property(copy) NSString *title;
@property(copy) NSString *message;
@property NSInteger preferredStyle;
@property(readonly) NSArray<UITextField *> *textFields;
@property(readonly) NSArray<UIAlertAction *> *actions;
+ (UIAlertController *)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
- (void)addTextFieldWithConfigurationHandler:(void (^)(UITextField *))handler;
- (void)addAction:(UIAlertAction *)action;
@end

@interface UIAlertView : UIView
@property(copy) NSString *title;
@property(copy) NSString *message;
@property(weak) id delegate;
@property(nonatomic) NSInteger alertViewStyle;
@property NSInteger cancelButtonIndex;
@property(readonly) NSInteger numberOfButtons;
@property(readonly) NSUInteger legacyShowCount;
@property(readonly) NSUInteger legacyStyleCount;
@property(readonly) NSUInteger legacyFieldCount;
@property(readonly) NSUInteger legacyDismissCount;
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)firstOther, ... NS_REQUIRES_NIL_TERMINATION;
- (NSString *)buttonTitleAtIndex:(NSInteger)index;
- (NSInteger)addButtonWithTitle:(NSString *)title;
- (UITextField *)textFieldAtIndex:(NSInteger)index;
- (void)show;
- (void)dismissWithClickedButtonIndex:(NSInteger)index animated:(BOOL)animated;
@end

@interface NSObject (XP3LegacyCallback)
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index;
@end

@interface DAFRunLoop : NSObject
+ (instancetype)currentRunLoop;
- (BOOL)runMode:(NSString *)mode beforeDate:(NSDate *)deadline;
@end

@interface MessageBoxEventRecevier : NSObject
@property NSInteger selectedIndex;
@property NSUInteger callbackCount;
@property(weak) UIAlertView *lastAlert;
- (int)getSelectedIndex;
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index;
@end

extern NSUInteger XP3FakeOriginalRunLoopCalls;
extern NSUInteger XP3FakeLegacyInitCount;
extern NSUInteger XP3FakePresentCount;
extern UIAlertController *XP3FakeLastPresentedAlert;
void XP3FakeResetApplication(BOOL activePresenter);
void XP3CompatInstall(void);
