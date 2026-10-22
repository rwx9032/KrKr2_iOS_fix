// XP3Compat OfflineContinuation -- EXPERIMENTAL public UIScene lifecycle adapter.
// DIAGNOSTIC ONLY. This file is not part of the shipped XP3Compat.dylib.
//
// Derived from Diagnostics/SceneLab/XP3SceneAdapter.m
// (SHA-256 861d2c3b357cb055e5855322b08cfc5cc9a833cf2ec1832602f96cb4ec277824).
// Additions in this copy, each behind its own Info.plist opt-in:
//   * XP3CompatEnableSceneContextProbe  (read-only context samples; no behaviour change)
//   * XP3CompatEnableSceneWindowHandoff (single behavioural change: adopt the scene
//     with a window created by -[UIWindow initWithWindowScene:], then move the
//     existing root view controller into it and repoint the legacy delegate)
// With both keys absent the code path and output are identical to the original
// adapter; only the existing XP3CompatSceneProbe.json is written.
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
#import <QuartzCore/QuartzCore.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static const NSUInteger XP3SAMaxEvents = 48;
static const NSUInteger XP3SAMaxJSONBytes = 64 * 1024;
static const NSUInteger XP3SAMaxClassNameLength = 96;
static const NSUInteger XP3SAMaxContextSamples = 24;
static const NSUInteger XP3SAMaxContextJSONBytes = 96 * 1024;
static const NSUInteger XP3SAMaxTreeNodes = 96;
static const NSTimeInterval XP3SATimerDelays[] = {0.5, 2.0, 6.0, 12.0, 20.0};

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

static BOOL gXP3SAContextProbe = NO;
static BOOL gXP3SAHandoff = NO;
static NSMutableArray<NSDictionary *> *gXP3SAContextSamples = nil;
static NSUInteger gXP3SAContextDropped = 0;
static NSString *gXP3SAContextRunID = nil;
static NSString *gXP3SAContextFirstSampleAt = nil;
static CFTimeInterval gXP3SAContextStart = 0.0;

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

static BOOL XP3SAFlag(NSDictionary *info, NSString *key) {
    id value = info[key];
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value boolValue];
    return NO;
}

static NSDictionary *XP3SAPoint(CGPoint point) {
    return @{ @"x": @(point.x), @"y": @(point.y) };
}

static NSDictionary *XP3SAAffine(CGAffineTransform t) {
    return @{
        @"a": @(t.a), @"b": @(t.b), @"c": @(t.c),
        @"d": @(t.d), @"tx": @(t.tx), @"ty": @(t.ty),
        @"isIdentity": @(CGAffineTransformIsIdentity(t))
    };
}

static NSDictionary *XP3SATransform(CATransform3D t) {
    return @{
        @"m11": @(t.m11), @"m12": @(t.m12), @"m13": @(t.m13), @"m14": @(t.m14),
        @"m21": @(t.m21), @"m22": @(t.m22), @"m23": @(t.m23), @"m24": @(t.m24),
        @"m31": @(t.m31), @"m32": @(t.m32), @"m33": @(t.m33), @"m34": @(t.m34),
        @"m41": @(t.m41), @"m42": @(t.m42), @"m43": @(t.m43), @"m44": @(t.m44),
        @"isIdentity": @(CATransform3DIsIdentity(t))
    };
}

static NSString *XP3SAOrientationName(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationPortrait: return @"portrait";
        case UIInterfaceOrientationPortraitUpsideDown: return @"portraitUpsideDown";
        case UIInterfaceOrientationLandscapeLeft: return @"landscapeLeft";
        case UIInterfaceOrientationLandscapeRight: return @"landscapeRight";
        case UIInterfaceOrientationUnknown:
        default: return @"unknown";
    }
}

// Bounded breadth-first search for a view whose class name matches exactly.
static UIView *XP3SAFindViewByClassName(UIView *root, NSString *className) {
    if (root == nil || className.length == 0) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger head = 0, visited = 0;
    while (head < queue.count && visited < XP3SAMaxTreeNodes) {
        UIView *view = queue[head++];
        visited++;
        if ([XP3SAClassName(view) isEqualToString:className]) return view;
        if (queue.count > XP3SAMaxTreeNodes * 2) break;
        for (UIView *child in view.subviews) {
            if (queue.count - head > XP3SAMaxTreeNodes) break;
            [queue addObject:child];
        }
    }
    return nil;
}

static NSDictionary *XP3SAViewSummary(UIView *view, UIWindow *window) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"class"] = XP3SAClassName(view);
    record[@"bounds"] = XP3SARect(view.bounds);
    record[@"frame"] = XP3SARect(view.frame);
    record[@"center"] = XP3SAPoint(view.center);
    record[@"transform"] = XP3SAAffine(view.transform);
    record[@"hidden"] = @(view.hidden);
    record[@"alpha"] = @(view.alpha);
    record[@"contentScaleFactor"] = @(view.contentScaleFactor);
    CALayer *layer = view.layer;
    if (layer != nil) {
        record[@"layerBounds"] = XP3SARect(layer.bounds);
        record[@"layerFrame"] = XP3SARect(layer.frame);
        record[@"layerPosition"] = XP3SAPoint(layer.position);
        record[@"layerAnchorPoint"] = XP3SAPoint(layer.anchorPoint);
        record[@"layerContentsScale"] = @(layer.contentsScale);
        record[@"layerTransform"] = XP3SATransform(layer.transform);
        record[@"layerClass"] = XP3SAClassName(layer);
        record[@"masksToBounds"] = @(layer.masksToBounds);
    }
    if (window != nil) {
        record[@"boundsInWindow"] = XP3SARect([view convertRect:view.bounds toView:window]);
    }
    record[@"windowAttached"] = @(view.window != nil);
    return record;
}

static NSDictionary *XP3SAWindowSummary(UIWindow *window, UIWindowScene *scene) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"class"] = XP3SAClassName(window);
    record[@"bounds"] = XP3SARect(window.bounds);
    record[@"frame"] = XP3SARect(window.frame);
    record[@"center"] = XP3SAPoint(window.center);
    record[@"transform"] = XP3SAAffine(window.transform);
    record[@"layerTransform"] = XP3SATransform(window.layer.transform);
    record[@"hidden"] = @(window.hidden);
    record[@"key"] = @(window.isKeyWindow);
    record[@"windowLevel"] = @(window.windowLevel);
    record[@"sceneMatches"] = @((UIWindowScene *)window.windowScene == scene);
    UIScreen *screen = window.screen;
    record[@"screenBounds"] = XP3SARect(screen.bounds);
    record[@"screenScale"] = @(screen.scale);
    record[@"screenNativeBounds"] = XP3SARect(screen.nativeBounds);

    UIViewController *root = window.rootViewController;
    if (root != nil) {
        NSMutableDictionary *controller = [NSMutableDictionary dictionary];
        controller[@"class"] = XP3SAClassName(root);
        controller[@"supportedInterfaceOrientations"] = @(root.supportedInterfaceOrientations);
        controller[@"shouldAutorotate"] = @(root.shouldAutorotate);
        controller[@"preferredInterfaceOrientation"] =
            XP3SAOrientationName(root.preferredInterfaceOrientationForPresentation);
        controller[@"viewLoaded"] = @(root.viewIfLoaded != nil);
        UIView *rootView = root.viewIfLoaded;
        if (rootView != nil) {
            controller[@"view"] = XP3SAViewSummary(rootView, window);
            UIView *renderView = XP3SAFindViewByClassName(rootView, @"CCEAGLView");
            if (renderView != nil) {
                controller[@"renderView"] = XP3SAViewSummary(renderView, window);
            }
        }
        record[@"rootViewController"] = controller;
    }
    return record;
}

static NSDictionary *XP3SAContextSnapshot(UIWindowScene *scene,
                                          UIWindow *window,
                                          NSString *trigger) {
    NSMutableDictionary *sample = [NSMutableDictionary dictionary];
    sample[@"trigger"] = trigger ?: @"unknown";
    sample[@"timestamp"] = XP3SATimestamp();
    sample[@"uptime"] = @(XP3SAUptime());
    sample[@"mainThread"] = @([NSThread isMainThread]);
    sample[@"appState"] = XP3SAAppStateName(UIApplication.sharedApplication.applicationState);
    sample[@"appDelegateClass"] = XP3SAClassName(UIApplication.sharedApplication.delegate);
    sample[@"connectedSceneCount"] = @(UIApplication.sharedApplication.connectedScenes.count);
    sample[@"handoffEnabled"] = @(gXP3SAHandoff);
    sample[@"windowSceneAttached"] = @((UIWindowScene *)window.windowScene == scene);

    if (scene != nil) {
        NSMutableDictionary *record = [NSMutableDictionary dictionary];
        record[@"class"] = XP3SAClassName(scene);
        record[@"activationState"] = XP3SASceneStateName(scene.activationState);
        record[@"coordinateSpaceBounds"] = XP3SARect(scene.coordinateSpace.bounds);
        record[@"interfaceOrientation"] = XP3SAOrientationName(scene.interfaceOrientation);
        if (@available(iOS 16.0, *)) {
            UIWindowSceneGeometry *geometry = scene.effectiveGeometry;
            record[@"effectiveInterfaceOrientation"] =
                XP3SAOrientationName(geometry.interfaceOrientation);
            record[@"effectiveCoordinateSpaceBounds"] = XP3SARect(geometry.coordinateSpace.bounds);
        }
        UIScreen *screen = scene.screen;
        record[@"screenBounds"] = XP3SARect(screen.bounds);
        record[@"screenScale"] = @(screen.scale);
        record[@"screenNativeBounds"] = XP3SARect(screen.nativeBounds);
        record[@"windowCount"] = @(scene.windows.count);
        if (@available(iOS 15.0, *)) {
            record[@"sceneKeyWindowClass"] = XP3SAClassName(scene.keyWindow);
        }
        sample[@"scene"] = record;
    }
    if (window != nil) {
        sample[@"window"] = XP3SAWindowSummary(window, scene);
    }
    return sample;
}

static NSDictionary *XP3SAContextPayload(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    return @{
        @"schema": @1,
        @"probe": @{
            @"name": @"XP3CompatSceneContextProbe",
            @"version": @"1.0.0",
            @"experimental": @YES,
            @"readOnly": @YES,
            @"production": @NO,
            @"purpose":
                @"Record public UIKit scene/window/root/render-view geometry, transforms and interface orientations so that a visible frame mismatch can be attributed to the UIKit layer tree or to the renderer.",
            @"policy": @[
                @"Public UIKit/QuartzCore properties only; no swizzling of UIKit, no private methods, no pixels.",
                @"No window, view controller, view, renderer or display link is created by the probe.",
                @"No UIScreen.main decision, no device frame constants, no forced rotation, no layout forcing.",
                @"Writes only the app's own Documents/XP3CompatSceneContextProbe.json."
            ]
        },
        @"meta": @{
            @"runID": gXP3SAContextRunID ?: @"",
            @"firstSampleAt": gXP3SAContextFirstSampleAt ?: @"",
            @"startedUptime": @(gXP3SAContextStart),
            @"bundleIdentifier": info[@"CFBundleIdentifier"] ?: @"",
            @"DTSDKName": info[@"DTSDKName"] ?: @"",
            @"limits": @{
                @"maxSamples": @(XP3SAMaxContextSamples),
                @"maxJSONBytes": @(XP3SAMaxContextJSONBytes),
                @"droppedSamples": @(gXP3SAContextDropped)
            }
        },
        @"samples": gXP3SAContextSamples ?: @[]
    };
}

static void XP3SAWriteContext(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3SAWriteContext();
        });
        return;
    }
    if (!gXP3SAContextProbe || gXP3SAContextSamples == nil) return;

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:XP3SAContextPayload()
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (data == nil) {
        NSLog(@"[XP3SceneContext] JSON serialization failed (domain=%@ code=%ld)",
              error.domain ?: @"unknown", (long)error.code);
        return;
    }
    while (data.length > XP3SAMaxContextJSONBytes && gXP3SAContextSamples.count > 1) {
        [gXP3SAContextSamples removeObjectAtIndex:0];
        gXP3SAContextDropped++;
        data = [NSJSONSerialization dataWithJSONObject:XP3SAContextPayload()
                                               options:NSJSONWritingPrettyPrinted
                                                 error:&error];
        if (data == nil) {
            NSLog(@"[XP3SceneContext] JSON serialization failed after trim (domain=%@ code=%ld)",
                  error.domain ?: @"unknown", (long)error.code);
            return;
        }
    }
    if (data.length > XP3SAMaxContextJSONBytes) {
        NSLog(@"[XP3SceneContext] bounded JSON still exceeds limit; file not updated");
        return;
    }

    NSArray<NSString *> *documentPaths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = documentPaths.firstObject;
    if (documentsPath.length == 0) {
        NSLog(@"[XP3SceneContext] app Documents directory unavailable");
        return;
    }
    NSString *path = [documentsPath stringByAppendingPathComponent:@"XP3CompatSceneContextProbe.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[XP3SceneContext] write failed (domain=%@ code=%ld)",
              error.domain ?: @"unknown", (long)error.code);
    }
}

static void XP3SAAddContextSample(UIWindowScene *scene, UIWindow *window, NSString *trigger) {
    if (!gXP3SAContextProbe) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3SAAddContextSample(scene, window, trigger);
        });
        return;
    }
    if (gXP3SAContextSamples == nil) {
        gXP3SAContextSamples = [NSMutableArray array];
        gXP3SAContextRunID = NSUUID.UUID.UUIDString ?: @"";
        gXP3SAContextStart = XP3SAUptime();
    }
    if (gXP3SAContextSamples.count >= XP3SAMaxContextSamples) {
        [gXP3SAContextSamples removeObjectAtIndex:0];
        gXP3SAContextDropped++;
    }
    NSDictionary *sample = XP3SAContextSnapshot(scene, window, trigger);
    if (gXP3SAContextFirstSampleAt.length == 0) {
        gXP3SAContextFirstSampleAt = sample[@"timestamp"] ?: @"";
    }
    [gXP3SAContextSamples addObject:sample];
    XP3SAWriteContext();
}

static void XP3SAScheduleContextTimers(UIWindowScene *scene, UIWindow *window) {
    if (!gXP3SAContextProbe) return;
    const NSUInteger count = sizeof(XP3SATimerDelays) / sizeof(XP3SATimerDelays[0]);
    for (NSUInteger i = 0; i < count; i++) {
        NSTimeInterval delay = XP3SATimerDelays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *trigger = [NSString stringWithFormat:@"timer-%.1fs", delay];
            XP3SAAddContextSample(scene, window, trigger);
        });
    }
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

// Single-factor experiment. Adopt the scene with a window created by
// -[UIWindow initWithWindowScene:] (the only initializer the public header
// documents as having matching frame & interface orientations), move the
// existing root view controller into it, and repoint the legacy delegate.
// A failed transaction falls back only after the original ownership is restored.
// If a custom setter even rejects rollback, keep every original object alive
// and stop this diagnostic connection instead of attaching a half-moved root.
static NSArray *gXP3SAHandoffRecoveryObjects;
static void XP3SARestoreStep(NSString *name, NSMutableArray *errors,
                            void (^operation)(void)) {
    @try { operation(); }
    @catch (NSException *exception) {
        [errors addObject:@{@"step": name, @"exception": exception.name ?: @""}];
    }
}

static UIWindow *XP3SAHandoffWindow(UIWindow *legacy,
                                    UIWindowScene *scene,
                                    NSMutableDictionary *details) {
    if (legacy == nil || scene == nil || details == nil) return nil;
    if (!NSThread.isMainThread) {
        details[@"handoffSkipped"] = @"window handoff requires the main thread";
        return nil;
    }
    UIViewController *root = legacy.rootViewController;
    if (root == nil) {
        details[@"handoffSkipped"] = @"legacy window has no root view controller";
        return nil;
    }
    if (legacy.windowScene != nil) {
        details[@"handoffSkipped"] = @"legacy window already belongs to a scene";
        return nil;
    }
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) {
        details[@"handoffSkipped"] = @"application delegate missing";
        return nil;
    }
    // Inspect ownership without a trial setter call, which could have effects.
    @try {
        if ([delegate valueForKey:@"window"] != legacy) {
            details[@"handoffSkipped"] = @"delegate does not own the selected window";
            return nil;
        }
    } @catch (NSException *exception) {
        details[@"handoffSkipped"] = @"application delegate window getter failed";
        details[@"handoffException"] = exception.name ?: @"";
        return nil;
    }

    BOOL wasHidden = legacy.hidden;
    BOOL wasKey = legacy.isKeyWindow;
    UIWindow *sceneWindow = nil;
    NSString *operation = @"initWithWindowScene";
    @try {
        sceneWindow = [[UIWindow alloc] initWithWindowScene:scene];
        if (!sceneWindow) {
            details[@"handoffSkipped"] = @"initWithWindowScene: returned nil";
            return nil;
        }
        sceneWindow.windowLevel = legacy.windowLevel;
        operation = @"delegate-window";
        [delegate setValue:sceneWindow forKey:@"window"];
        if ([delegate valueForKey:@"window"] != sceneWindow)
            @throw [NSException exceptionWithName:@"XP3WindowOwnershipRejected"
                                           reason:nil userInfo:nil];
        operation = @"detach-original-root";
        legacy.hidden = YES;
        legacy.rootViewController = nil;
        operation = @"attach-scene-root";
        sceneWindow.rootViewController = root;
        operation = @"show-scene-window";
        [sceneWindow makeKeyAndVisible];
    } @catch (NSException *exception) {
        details[@"handoffFailedOperation"] = operation;
        details[@"handoffException"] = exception.name ?: @"";
        NSMutableArray *errors = [NSMutableArray array];
        XP3SARestoreStep(@"hide-candidate", errors, ^{ sceneWindow.hidden = YES; });
        XP3SARestoreStep(@"detach-candidate-root", errors, ^{
            if (sceneWindow.rootViewController == root) sceneWindow.rootViewController = nil;
        });
        XP3SARestoreStep(@"restore-delegate", errors, ^{ [delegate setValue:legacy forKey:@"window"]; });
        XP3SARestoreStep(@"restore-original-root", errors, ^{ legacy.rootViewController = root; });
        XP3SARestoreStep(@"restore-original-visibility", errors, ^{
            legacy.hidden = wasHidden;
            if (wasKey && !wasHidden) [legacy makeKeyAndVisible];
        });
        __block BOOL restored = NO;
        XP3SARestoreStep(@"verify-rollback", errors, ^{
            restored = [delegate valueForKey:@"window"] == legacy && legacy.rootViewController == root &&
                sceneWindow.rootViewController == nil && legacy.hidden == wasHidden &&
                (!wasKey || legacy.isKeyWindow);
        });
        details[@"handoffRollbackErrors"] = errors;
        details[@"handoffRollbackComplete"] = @(restored);
        if (!restored) {
            gXP3SAHandoffRecoveryObjects = sceneWindow ? @[legacy, sceneWindow, root] : @[legacy, root];
            details[@"handoffRollbackIncomplete"] = @YES;
        }
        details[@"handoffSkipped"] = restored ? @"handoff failed; original ownership restored"
                                               : @"handoff failed; connection stopped";
        return nil;
    }

    details[@"sceneWindowClass"] = XP3SAClassName(sceneWindow);
    details[@"sceneWindowBounds"] = XP3SARect(sceneWindow.bounds);
    details[@"sceneWindowFrame"] = XP3SARect(sceneWindow.frame);
    details[@"legacyWindowHidden"] = @(legacy.hidden);
    details[@"rootViewControllerPreserved"] = @(sceneWindow.rootViewController == root);
    details[@"legacyRootDetached"] = @(legacy.rootViewController == nil);
    details[@"delegateWindowMatches"] = @YES; // verified within the transaction
    return sceneWindow;
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
- (void)windowScene:(UIWindowScene *)windowScene
    didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
    interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
    traitCollection:(UITraitCollection *)previousTraitCollection;
- (void)windowScene:(UIWindowScene *)windowScene
    didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previousEffectiveGeometry;
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
    XP3SAAddContextSample(windowScene, nil, @"willConnect-before-attach");
    details[@"action"] = @"attaching-existing-window";
    XP3SAAddEvent(@"scene-willConnect-attaching-existing-window", details);

    UIWindow *adoptedWindow = existingWindow;
    if (gXP3SAHandoff) {
        UIWindow *handoffWindow = XP3SAHandoffWindow(existingWindow, windowScene, details);
        details[@"handoffRequested"] = @YES;
        if ([details[@"handoffRollbackIncomplete"] boolValue]) {
            details[@"action"] = @"handoff-rollback-incomplete; connection-stopped";
            XP3SAAddEvent(@"scene-willConnect-handoff-stopped", details);
            return;
        }
        if (handoffWindow != nil) {
            adoptedWindow = handoffWindow;
            details[@"action"] = @"handoff-to-scene-window";
        } else {
            // Handoff refused before moving anything; use the legacy attachment.
            details[@"action"] = @"handoff-refused-legacy-attach";
        }
    }

    // Public adoption only: retain the legacy window, attach it to this scene,
    // then let UIKit lay out the existing root/CCEAGLView naturally.
    self.window = adoptedWindow;
    if (adoptedWindow == existingWindow && previousScene != windowScene) {
        existingWindow.windowScene = windowScene;
    }
    [adoptedWindow makeKeyAndVisible];
    self.adoptedExistingWindow = YES;

    details[@"adoptedWindowClass"] = XP3SAClassName(adoptedWindow);
    details[@"windowAttached"] = @(adoptedWindow.windowScene == windowScene);
    details[@"windowBoundsAfter"] = XP3SARect(adoptedWindow.bounds);
    details[@"windowFrameAfter"] = XP3SARect(adoptedWindow.frame);
    details[@"windowHiddenAfter"] = @(adoptedWindow.hidden);
    details[@"windowKeyAfter"] = @(adoptedWindow.isKeyWindow);
    details[@"rootViewControllerClass"] = XP3SAClassName(adoptedWindow.rootViewController);
    details[@"rootViewLoaded"] = @(adoptedWindow.rootViewController.viewIfLoaded != nil);
    if (!gXP3SAHandoff) {
        details[@"action"] = @"adopted-existing-window";
    }
    XP3SAAddEvent(@"scene-willConnect-adopted-existing-window", details);
    XP3SAAddContextSample(windowScene, adoptedWindow, @"willConnect-after-attach");
    XP3SAScheduleContextTimers(windowScene, adoptedWindow);
    NSLog(@"[XP3SceneAdapter] adopted window %@ from %@; source=%@ attached=%@ handoff=%@",
          XP3SAClassName(adoptedWindow),
          XP3SAClassName(existingWindow),
          windowSource,
          adoptedWindow.windowScene == windowScene ? @"yes" : @"no",
          adoptedWindow != existingWindow ? @"yes" : @"no");
}

- (void)windowScene:(UIWindowScene *)windowScene
    didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
    interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
    traitCollection:(UITraitCollection *)previousTraitCollection {
    (void)previousCoordinateSpace;
    (void)previousInterfaceOrientation;
    (void)previousTraitCollection;
    if (!gXP3SAEnabled) return;
    XP3SAAddContextSample(windowScene, self.window, @"didUpdateCoordinateSpace");
}

- (void)windowScene:(UIWindowScene *)windowScene
    didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previousEffectiveGeometry {
    (void)previousEffectiveGeometry;
    if (!gXP3SAEnabled) return;
    XP3SAAddContextSample(windowScene, self.window, @"didUpdateEffectiveGeometry");
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
    XP3SAAddContextSample((UIWindowScene *)scene, self.window, @"scene-willEnterForeground");
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    XP3SAForwardToAppDelegate(@"scene-didBecomeActive",
                              @selector(applicationDidBecomeActive:),
                              XP3SAForwardStateActive,
                              scene,
                              self.window);
    XP3SAAddContextSample((UIWindowScene *)scene, self.window, @"scene-didBecomeActive");
}

- (void)sceneWillResignActive:(UIScene *)scene {
    XP3SAForwardToAppDelegate(@"scene-willResignActive",
                              @selector(applicationWillResignActive:),
                              XP3SAForwardStateInactive,
                              scene,
                              self.window);
    XP3SAAddContextSample((UIWindowScene *)scene, self.window, @"scene-willResignActive");
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    XP3SAForwardToAppDelegate(@"scene-didEnterBackground",
                              @selector(applicationDidEnterBackground:),
                              XP3SAForwardStateBackground,
                              scene,
                              self.window);
    XP3SAAddContextSample((UIWindowScene *)scene, self.window, @"scene-didEnterBackground");
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
        NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
        gXP3SAContextProbe = XP3SAFlag(info, @"XP3CompatEnableSceneContextProbe");
        gXP3SAHandoff = XP3SAFlag(info, @"XP3CompatEnableSceneWindowHandoff");
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
        NSLog(@"[XP3SceneAdapter] enabled experimental public scene adapter for %@ "
              @"(contextProbe=%@ handoff=%@)",
              bundleIdentifier,
              gXP3SAContextProbe ? @"yes" : @"no",
              gXP3SAHandoff ? @"yes" : @"no");
    }
}
