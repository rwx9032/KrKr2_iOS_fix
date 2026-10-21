// Minimal, arm64 iOS public ABI declarations for machines without an iOS SDK.
// No private UIKit/CF layouts. Use the real SDK automatically when available.
#pragma once
typedef _Bool BOOL; // arm64 iOS uses the C99 bool ABI
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#define nil ((id)0)
#define Nil ((Class)0)
typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef double NSTimeInterval;
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
typedef struct objc_method *Method;
typedef void (*IMP)(void);
typedef void (^dispatch_block_t)(void);
typedef struct dispatch_queue_s *dispatch_queue_t;
extern struct dispatch_queue_s _dispatch_main_q;
static inline dispatch_queue_t dispatch_get_main_queue(void) { return &_dispatch_main_q; }
extern void dispatch_async(dispatch_queue_t, dispatch_block_t);
extern void dispatch_sync(dispatch_queue_t, dispatch_block_t);
extern Class objc_getClass(const char *);
extern Class object_getClass(id);
extern Method class_getInstanceMethod(Class, SEL);
extern Method class_getClassMethod(Class, SEL);
extern BOOL class_addMethod(Class, SEL, IMP, const char *);
extern const char *method_getTypeEncoding(Method);
extern IMP method_getImplementation(Method);
extern IMP method_setImplementation(Method, IMP);
extern unsigned int method_getNumberOfArguments(Method);
extern id objc_getAssociatedObject(id, const void *);
extern void objc_setAssociatedObject(id, const void *, id, NSUInteger);
#define OBJC_ASSOCIATION_RETAIN_NONATOMIC 1

@protocol NSObject
- (BOOL)respondsToSelector:(SEL)selector;
- (BOOL)isKindOfClass:(Class)cls;
@end
__attribute__((objc_root_class))
@interface NSObject <NSObject> {
    Class isa; // Public NSObject instance ABI: the first word is the isa pointer.
}
+ (id)alloc;
+ (Class)class;
- (id)init;
- (void)performSelector:(SEL)selector withObject:(id)object afterDelay:(NSTimeInterval)delay;
@end
@class NSString, NSDate, NSArray, UIWindow, UIViewController, UIAlertController;
@interface NSString : NSObject
- (BOOL)isEqualToString:(NSString *)other;
@end
@interface NSArray<ObjectType> : NSObject
@property(readonly) NSUInteger count;
- (ObjectType)objectAtIndexedSubscript:(NSUInteger)index;
@end
@interface NSMutableArray<ObjectType> : NSArray<ObjectType>
+ (id)array;
- (void)addObject:(ObjectType)object;
@end
@interface NSBundle : NSObject
+ (NSBundle *)mainBundle;
@property(readonly) NSString *bundleIdentifier;
@end
@interface NSDate : NSObject
+ (NSDate *)dateWithTimeIntervalSinceNow:(NSTimeInterval)seconds;
- (NSDate *)earlierDate:(NSDate *)other;
@end
@interface NSRunLoop : NSObject
+ (NSRunLoop *)currentRunLoop;
- (BOOL)runMode:(NSString *)mode beforeDate:(NSDate *)date;
@end
@interface NSThread : NSObject
+ (BOOL)isMainThread;
+ (void)sleepForTimeInterval:(NSTimeInterval)seconds;
@end
extern void NSLog(NSString *, ...);
@interface UIView : NSObject
@property(readonly) UIWindow *window;
@property(readonly) BOOL isHidden;
@end
@interface UIViewController : NSObject
@property(readonly) UIViewController *presentedViewController;
@property(readonly) UIView *view;
@property(readonly) BOOL isBeingPresented;
@property(readonly) BOOL isBeingDismissed;
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion;
@end
@interface UIWindow : UIView
@property(readonly) UIViewController *rootViewController;
@property(readonly) BOOL isKeyWindow;
@property(readonly) CGFloat windowLevel;
@end
@interface UIApplication : NSObject
+ (UIApplication *)sharedApplication;
@property(readonly) UIWindow *keyWindow;
@property(readonly) NSArray<UIWindow *> *windows;
@property(readonly) NSInteger applicationState;
@end
@interface UITextField : UIView
@property(copy) NSString *text;
@property(getter=isSecureTextEntry) BOOL secureTextEntry;
@property NSInteger autocorrectionType;
@property NSInteger autocapitalizationType;
@end
@interface UIAlertAction : NSObject
+ (UIAlertAction *)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler;
@end
@interface UIAlertController : UIViewController
+ (UIAlertController *)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
@property(copy) NSString *title;
@property(copy) NSString *message;
@property(readonly) NSArray<UITextField *> *textFields;
- (void)addTextFieldWithConfigurationHandler:(void (^)(UITextField *))handler;
- (void)addAction:(UIAlertAction *)action;
@end
@interface UIAlertView : UIView
@property(copy) NSString *title;
@property(copy) NSString *message;
@property(weak) id delegate;
@property NSInteger alertViewStyle;
@property(readonly) NSInteger numberOfButtons;
@property(readonly) NSInteger cancelButtonIndex;
- (NSString *)buttonTitleAtIndex:(NSInteger)index;
- (id)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)first, ...;
- (NSInteger)addButtonWithTitle:(NSString *)title;
- (UITextField *)textFieldAtIndex:(NSInteger)index;
- (void)setAlertViewStyle:(NSInteger)style;
- (void)show;
- (void)dismissWithClickedButtonIndex:(NSInteger)index animated:(BOOL)animated;
@end
@interface NSObject (XP3LegacyCallback)
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index;
@end
