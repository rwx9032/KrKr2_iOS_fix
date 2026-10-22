// XP3Compat SceneLab -- EXPERIMENTAL public UIScene lifecycle adapter.
// DIAGNOSTIC ONLY. This file is not part of the shipped XP3Compat.dylib.
//
// Scope of this first phase:
//   * adopt the EXISTING UIWindow created by the legacy application delegate;
//   * attach it to the public UIWindowScene in scene:willConnectToSession:options:;
//   * never create a window, root view controller, renderer, or presenter;
//   * never hook, swizzle, or bypass UIKit's scene-adoption check;
//   * never read UIScreen.main, screenshots, view text, files, saves, or logs.
//
// The only file written is the app's own
// Documents/XP3CompatSceneProbe.json (bounded, schema 1).
//
// Public UIKit/Foundation APIs only. iOS 13+ runtime guard plus Bundle ID and
// Info.plist opt-in guard:
//   CFBundleIdentifier == tvp.XP3Player.Compat
//   XP3CompatEnableSceneAdapter == true (Boolean)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static const NSUInteger XP3SAMaxEvents = 48;
static const NSUInteger XP3SAMaxJSONBytes = 64 * 1024;
static const NSUInteger XP3SAMaxClassNameLength = 96;

static const NSInteger XP3SAForwardStateNone = 0;
static const NSInteger XP3SAForwardStateForeground = 1;
static const NSInteger XP3SAForwardStateActive = 2;
static const NSInteger XP3SAForwardStateInactive = 3;
static const NSInteger XP3SAForwardStateBackground = 4;

static BOOL gXP3SAEnabled = NO;
static NSMutableArray<NSDictionary *> *gXP3SAEvents = nil;
static NSUInteger gXP3SASeq = 0;
static NSUInteger gXP3SADropped = 0;
static NSTimeInterval gXP3SAStartUptime = 0.0;
static NSString *gXP3SARunID = nil;
static NSString *gXP3SAFirstEventAt = nil;
static NSInteger gXP3SAForwardedState = XP3SAForwardStateNone;

static NSTimeInterval XP3SAUptime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static NSString *XP3SATimestamp(void) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    return [formatter stringFromDate:[NSDate date]] ?: @"";
}

static NSString *XP3SAClassName(id object) {
    if (object == nil) return @"";
    NSString *name = NSStringFromClass([object class]) ?: @"";
    if (name.length > XP3SAMaxClassNameLength) {
        name = [name substringToIndex:XP3SAMaxClassNameLength];
    }
    return name;
}

static NSString *XP3SAAppStateName(UIApplicationState state) {
    switch (state) {
        case UIApplicationStateActive:
            return @"active";
        case UIApplicationStateInactive:
            return @"inactive";
        case UIApplicationStateBackground:
            return @"background";
        default:
            return @"unknown";
    }
}

static NSString *XP3SASceneStateName(UISceneActivationState state) API_AVAILABLE(ios(13.0));
static NSString *XP3SASceneStateName(UISceneActivationState state) {
    switch (state) {
        case UISceneActivationStateUnattached:
            return @"unattached";
        case UISceneActivationStateForegroundActive:
            return @"foregroundActive";
        case UISceneActivationStateForegroundInactive:
            return @"foregroundInactive";
        case UISceneActivationStateBackground:
            return @"background";
        default:
            return @"unknown";
    }
}

static NSDictionary *XP3SARect(CGRect rect) {
    return @{
        @"x": @(CGRectGetMinX(rect)),
        @"y": @(CGRectGetMinY(rect)),
        @"width": @(CGRectGetWidth(rect)),
        @"height": @(CGRectGetHeight(rect)),
        @"isNull": @(CGRectIsNull(rect)),
        @"isEmpty": @(CGRectIsEmpty(rect))
    };
}

static BOOL XP3SAReadOptIn(NSDictionary *info) {
    id value = info[@"XP3CompatEnableSceneAdapter"];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value boolValue];
    }
    return NO;
}

static NSDictionary *XP3SAPayload(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    return @{
        @"schema": @1,
        @"probe": @{
            @"name": @"XP3CompatSceneProbe",
            @"version": @"1.0.0",
            @"experimental": @YES,
            @"purpose": @"Observe public UIScene adoption of the existing legacy application window.",
            @"production": @NO,
            @"policy": @[
                @"Public UIKit/Foundation scene callbacks only; no swizzling, IMP replacement, private methods, or UIKit guard bypass.",
                @"No UIWindow/UIViewController/UIView/renderer is created by this adapter.",
                @"No UIScreen.main, device frame constant, forced rotation, display transform, or C++ mutation.",
                @"No screenshots, view text, user files, saves, certificates, or original app binaries are read.",
                @"The only output is the app's own Documents/XP3CompatSceneProbe.json."
            ]
        },
        @"meta": @{
            @"runID": gXP3SARunID ?: @"",
            @"firstEventAt": gXP3SAFirstEventAt ?: @"",
            @"startedUptime": @(gXP3SAStartUptime),
            @"bundleIdentifier": info[@"CFBundleIdentifier"] ?: @"",
            @"DTSDKName": info[@"DTSDKName"] ?: @"",
            @"UIDeviceFamily": info[@"UIDeviceFamily"] ?: @[],
            @"optInKey": @"XP3CompatEnableSceneAdapter",
            @"sceneDelegateClass": @"XP3CompatSceneDelegate",
            @"output": @{
                @"container": @"app Documents",
                @"fileName": @"XP3CompatSceneProbe.json",
                @"absolutePathRecorded": @NO
            },
            @"limits": @{
                @"maxEvents": @(XP3SAMaxEvents),
                @"maxJSONBytes": @(XP3SAMaxJSONBytes),
                @"droppedEvents": @(gXP3SADropped)
            },
            @"forwardingPolicy":
                @"Scene foreground/active/inactive/background callbacks forward to the existing UIApplicationDelegate methods only when that delegate responds. Consecutive identical states are suppressed. No private forwarding hook."
        },
        @"events": gXP3SAEvents ?: @[]
    };
}

static void XP3SAWrite(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3SAWrite();
        });
        return;
    }
    if (!gXP3SAEnabled || gXP3SAEvents == nil) return;

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:XP3SAPayload()
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (data == nil) {
        NSLog(@"[XP3SceneAdapter] JSON serialization failed (domain=%@ code=%ld)",
              error.domain ?: @"unknown", (long)error.code);
        return;
    }
    while (data.length > XP3SAMaxJSONBytes && gXP3SAEvents.count > 1) {
        [gXP3SAEvents removeObjectAtIndex:0];
        gXP3SADropped++;
        data = [NSJSONSerialization dataWithJSONObject:XP3SAPayload()
                                               options:NSJSONWritingPrettyPrinted
                                                 error:&error];
        if (data == nil) {
            NSLog(@"[XP3SceneAdapter] JSON serialization failed after trim (domain=%@ code=%ld)",
                  error.domain ?: @"unknown", (long)error.code);
            return;
        }
    }
    if (data.length > XP3SAMaxJSONBytes) {
        NSLog(@"[XP3SceneAdapter] bounded JSON still exceeds limit; file not updated");
        return;
    }

    NSArray<NSString *> *documentPaths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = documentPaths.firstObject;
    if (documentsPath.length == 0) {
        NSLog(@"[XP3SceneAdapter] app Documents directory unavailable");
        return;
    }
    NSString *path = [documentsPath stringByAppendingPathComponent:@"XP3CompatSceneProbe.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[XP3SceneAdapter] write failed (domain=%@ code=%ld)",
              error.domain ?: @"unknown", (long)error.code);
        return;
    }
    NSLog(@"[XP3SceneAdapter] wrote XP3CompatSceneProbe.json (%lu bytes, events=%lu, dropped=%lu)",
          (unsigned long)data.length,
          (unsigned long)gXP3SAEvents.count,
          (unsigned long)gXP3SADropped);
}

static void XP3SAAddEvent(NSString *event, NSDictionary *details) {
    if (!gXP3SAEnabled) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3SAAddEvent(event, details);
        });
        return;
    }
    if (gXP3SAEvents == nil) {
        gXP3SAEvents = [NSMutableArray array];
        gXP3SAStartUptime = XP3SAUptime();
        gXP3SARunID = NSUUID.UUID.UUIDString ?: @"";
    }
    if (gXP3SAFirstEventAt.length == 0) {
        gXP3SAFirstEventAt = XP3SATimestamp();
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"seq"] = @(++gXP3SASeq);
    record[@"event"] = event ?: @"unknown";
    record[@"timestamp"] = XP3SATimestamp();
    record[@"uptime"] = @(XP3SAUptime());
    record[@"mainThread"] = @([NSThread isMainThread]);
    if (details.count > 0) {
        [record addEntriesFromDictionary:details];
    }
    [gXP3SAEvents addObject:record];
    while (gXP3SAEvents.count > XP3SAMaxEvents) {
        [gXP3SAEvents removeObjectAtIndex:0];
        gXP3SADropped++;
    }
    XP3SAWrite();
}

// Reads a public property through its getter without relying on a private
// class layout. KVC is only a fallback for a legacy delegate that declares
// window as an ivar without an accessor.
static UIWindow *XP3SAWindowFromObject(id object, NSString *key, NSString **source) {
    if (object == nil || key.length == 0) return nil;
    SEL selector = NSSelectorFromString(key);
    if ([object respondsToSelector:selector]) {
        IMP implementation = [object methodForSelector:selector];
        if (implementation != NULL) {
            id value = ((id (*)(id, SEL))implementation)(object, selector);
            if ([value isKindOfClass:[UIWindow class]]) {
                if (source != NULL) *source = [@"appDelegate." stringByAppendingString:key];
                return (UIWindow *)value;
            }
        }
    }
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[UIWindow class]]) {
            if (source != NULL) *source = [@"appDelegate.kvc." stringByAppendingString:key];
            return (UIWindow *)value;
        }
    } @catch (NSException *exception) {
        // A non-KVC-compliant delegate simply has no readable window.
        (void)exception;
    }
    return nil;
}

static UIWindow *XP3SAFindExistingWindow(NSString **source) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *delegateWindow = XP3SAWindowFromObject(application.delegate, @"window", source);
    if (delegateWindow != nil) return delegateWindow;

    UIWindow *keyCandidate = nil;
    UIWindow *firstCandidate = nil;
    for (UIWindow *candidate in application.windows) {
        if (candidate.windowScene != nil) continue;
        if (candidate.windowLevel != UIWindowLevelNormal) continue;
        if (candidate.rootViewController == nil) continue;
        if (firstCandidate == nil) firstCandidate = candidate;
        if (candidate.isKeyWindow) {
            keyCandidate = candidate;
            break;
        }
    }
    if (keyCandidate != nil) {
        if (source != NULL) *source = @"uiApplication.windows.key";
        return keyCandidate;
    }
    if (firstCandidate != nil) {
        if (source != NULL) *source = @"uiApplication.windows.first";
        return firstCandidate;
    }
    if (source != NULL) *source = @"none";
    return nil;
}

static void XP3SAForwardToAppDelegate(NSString *event,
                                      SEL selector,
                                      NSInteger state,
                                      UIScene *scene,
                                      UIWindow *window) {
    if (!gXP3SAEnabled) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3SAForwardToAppDelegate(event, selector, state, scene, window);
        });
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    id delegate = application.delegate;
    BOOL duplicate = (gXP3SAForwardedState == state);
    BOOL forwarded = NO;
    BOOL responds = (delegate != nil) && [delegate respondsToSelector:selector];

    if (!duplicate) {
        gXP3SAForwardedState = state;
        if (responds) {
            IMP implementation = [delegate methodForSelector:selector];
            if (implementation != NULL) {
                ((void (*)(id, SEL, UIApplication *))implementation)(delegate, selector, application);
                forwarded = YES;
            }
        }
    }

    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    details[@"appState"] = XP3SAAppStateName(application.applicationState);
    details[@"appDelegateClass"] = XP3SAClassName(delegate);
    details[@"forwardSelector"] = NSStringFromSelector(selector);
    details[@"forwarded"] = @(forwarded);
    details[@"duplicateSuppressed"] = @(duplicate);
    details[@"connectedSceneCount"] = @(application.connectedScenes.count);
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        details[@"sceneActivationState"] = XP3SASceneStateName(windowScene.activationState);
        details[@"sceneBounds"] = XP3SARect(windowScene.coordinateSpace.bounds);
        details[@"sessionRole"] = windowScene.session.role ?: @"";
    }
    if (window != nil) {
        details[@"windowBounds"] = XP3SARect(window.bounds);
        details[@"windowFrame"] = XP3SARect(window.frame);
        details[@"windowHidden"] = @(window.hidden);
        details[@"windowKey"] = @(window.isKeyWindow);
        details[@"windowSceneMatches"] = @(window.windowScene == scene);
    } else {
        details[@"hasWindow"] = @NO;
    }
    XP3SAAddEvent(event, details);
}

API_AVAILABLE(ios(13.0))
@interface XP3CompatSceneDelegate : NSObject <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, weak) UIWindowScene *attachedScene;
@property (nonatomic) BOOL connected;
@property (nonatomic) BOOL adoptedExistingWindow;
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions;
- (void)sceneDidDisconnect:(UIScene *)scene;
- (void)sceneWillEnterForeground:(UIScene *)scene;
- (void)sceneDidBecomeActive:(UIScene *)scene;
- (void)sceneWillResignActive:(UIScene *)scene;
- (void)sceneDidEnterBackground:(UIScene *)scene;
@end

@implementation XP3CompatSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    (void)session;
    (void)connectionOptions;
    if (!gXP3SAEnabled) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scene:scene willConnectToSession:session options:connectionOptions];
        });
        return;
    }
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        XP3SAAddEvent(@"scene-willConnect-unexpected-scene", @{
            @"sceneClass": XP3SAClassName(scene)
        });
        return;
    }
    if (self.connected) {
        XP3SAAddEvent(@"scene-willConnect-duplicate-suppressed", @{
            @"sceneClass": XP3SAClassName(scene)
        });
        return;
    }
    self.connected = YES;
    self.attachedScene = (UIWindowScene *)scene;

    UIWindowScene *windowScene = (UIWindowScene *)scene;
#ifdef XP3_SCENE_BOOTSTRAP
    BOOL bootstrapped = XP3SBBootstrapScene(windowScene);
    XP3SAAddEvent(@"scene-bootstrap-result", @{@"completed": @(bootstrapped)});
#endif
    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    details[@"sceneClass"] = XP3SAClassName(scene);
    details[@"sceneActivationState"] = XP3SASceneStateName(windowScene.activationState);
    details[@"sceneBounds"] = XP3SARect(windowScene.coordinateSpace.bounds);
    details[@"sceneWindowCount"] = @(windowScene.windows.count);
    details[@"sessionRole"] = windowScene.session.role ?: @"";
    details[@"appState"] = XP3SAAppStateName(UIApplication.sharedApplication.applicationState);

    NSString *windowSource = @"none";
    UIWindow *existingWindow = XP3SAFindExistingWindow(&windowSource);
    details[@"windowSource"] = windowSource;
    if (existingWindow == nil) {
        details[@"hasWindow"] = @NO;
        details[@"action"] = @"reported-only; no window, root, renderer, or presenter was invented";
        XP3SAAddEvent(@"scene-willConnect-no-existing-window", details);
        NSLog(@"[XP3SceneAdapter] no existing application window at scene connect; adoption skipped");
        return;
    }

    UIWindowScene *previousScene = existingWindow.windowScene;
    details[@"hasWindow"] = @YES;
    details[@"windowClass"] = XP3SAClassName(existingWindow);
    details[@"windowBoundsBefore"] = XP3SARect(existingWindow.bounds);
    details[@"windowFrameBefore"] = XP3SARect(existingWindow.frame);
    details[@"windowHiddenBefore"] = @(existingWindow.hidden);
    details[@"windowKeyBefore"] = @(existingWindow.isKeyWindow);
    details[@"windowHadPreviousScene"] = @(previousScene != nil);
    if (previousScene != nil && previousScene != windowScene) {
        details[@"action"] = @"reported-only; existing window belongs to another scene and was not stolen";
        XP3SAAddEvent(@"scene-willConnect-window-other-scene", details);
        NSLog(@"[XP3SceneAdapter] existing window belongs to another scene; adoption skipped");
        return;
    }

    // Record the pre-attachment state before touching public scene properties,
    // so a failure inside makeKeyAndVisible still leaves a bounded diagnostic.
    details[@"action"] = @"attaching-existing-window";
    XP3SAAddEvent(@"scene-willConnect-attaching-existing-window", details);

    // Public adoption only: retain the legacy window, attach it to this scene,
    // then let UIKit lay out the existing root/CCEAGLView naturally.
    self.window = existingWindow;
    if (previousScene != windowScene) {
        existingWindow.windowScene = windowScene;
    }
    [existingWindow makeKeyAndVisible];
    self.adoptedExistingWindow = YES;

    details[@"windowAttached"] = @(existingWindow.windowScene == windowScene);
    details[@"windowBoundsAfter"] = XP3SARect(existingWindow.bounds);
    details[@"windowFrameAfter"] = XP3SARect(existingWindow.frame);
    details[@"windowHiddenAfter"] = @(existingWindow.hidden);
    details[@"windowKeyAfter"] = @(existingWindow.isKeyWindow);
    details[@"rootViewControllerClass"] = XP3SAClassName(existingWindow.rootViewController);
    details[@"rootViewLoaded"] = @(existingWindow.rootViewController.viewIfLoaded != nil);
    details[@"action"] = @"adopted-existing-window";
    XP3SAAddEvent(@"scene-willConnect-adopted-existing-window", details);
    NSLog(@"[XP3SceneAdapter] adopted existing window from %@; source=%@ attached=%@",
          XP3SAClassName(existingWindow),
          windowSource,
          existingWindow.windowScene == windowScene ? @"yes" : @"no");
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    if (!gXP3SAEnabled) return;
    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    details[@"sceneClass"] = XP3SAClassName(scene);
    details[@"hadAdoptedWindow"] = @(self.adoptedExistingWindow);
    details[@"retainedWindow"] = @(self.window != nil);
    XP3SAAddEvent(@"scene-didDisconnect", details);
    self.connected = NO;
    self.adoptedExistingWindow = NO;
    gXP3SAForwardedState = XP3SAForwardStateNone;
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    XP3SAForwardToAppDelegate(@"scene-willEnterForeground",
                              @selector(applicationWillEnterForeground:),
                              XP3SAForwardStateForeground,
                              scene,
                              self.window);
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    XP3SAForwardToAppDelegate(@"scene-didBecomeActive",
                              @selector(applicationDidBecomeActive:),
                              XP3SAForwardStateActive,
                              scene,
                              self.window);
}

- (void)sceneWillResignActive:(UIScene *)scene {
    XP3SAForwardToAppDelegate(@"scene-willResignActive",
                              @selector(applicationWillResignActive:),
                              XP3SAForwardStateInactive,
                              scene,
                              self.window);
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    XP3SAForwardToAppDelegate(@"scene-didEnterBackground",
                              @selector(applicationDidEnterBackground:),
                              XP3SAForwardStateBackground,
                              scene,
                              self.window);
}

@end

__attribute__((constructor))
static void XP3SceneAdapterLoad(void) {
    @autoreleasepool {
        if (@available(iOS 13.0, *)) {
            // Continue below.
        } else {
            return;
        }
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"tvp.XP3Player.Compat"]) {
            return;
        }
        if (!XP3SAReadOptIn(NSBundle.mainBundle.infoDictionary ?: @{})) {
            NSLog(@"[XP3SceneAdapter] disabled: Info.plist key XP3CompatEnableSceneAdapter is not true");
            return;
        }
        gXP3SAEnabled = YES;
        gXP3SAEvents = [NSMutableArray array];
        gXP3SARunID = NSUUID.UUID.UUIDString ?: @"";
        gXP3SAStartUptime = XP3SAUptime();
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3SAAddEvent(@"adapter-loaded", @{
                @"bundleIdentifier": bundleIdentifier ?: @"",
                @"sceneDelegateClass": @"XP3CompatSceneDelegate",
                @"optIn": @YES
            });
        });
        NSLog(@"[XP3SceneAdapter] enabled experimental public scene adapter for %@", bundleIdentifier);
    }
}
