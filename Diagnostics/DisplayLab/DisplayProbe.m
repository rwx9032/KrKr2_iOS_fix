// XP3Compat DisplayProbe 1.0.0
//
// Read-only display/geometry diagnostic for XP3Player 1.3.11 on iOS/iPadOS and
// the PlayCover/Catalyst environment.  It is a diagnostic dylib, not a fix.
//
// Safety contract:
//   * public UIKit / Foundation / QuartzCore (UIView.layer) / dyld APIs only;
//   * no method swizzling or IMP replacement;
//   * no layout forcing (no layoutIfNeeded / setNeedsLayout);
//   * no new UIWindow, presenter, controller, or view;
//   * no game/engine hooks, no display transform, no scale override;
//   * no pixels, screenshots, view text, files, saves, certificates, or logs
//     from the host process are read;
//   * the only file written is the app's own
//     Documents/XP3CompatDisplayProbe.json.
//
// The probe records drawable geometry.  It does NOT prove that game/content
// fills the drawable, and it does NOT prove rendered content direction.
//
// surfaceSize/backingSize/width/height are obtained only through an
// NSMethodSignature validated by NSInvocation.  Missing selectors and unknown
// return encodings stay null; the return ABI is never guessed.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

#include <math.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static const NSUInteger XP3DPMaxHistory = 160;
static const NSUInteger XP3DPMaxDetailSnapshots = 4;
static const NSUInteger XP3DPMaxHierarchyNodes = 180;
static const NSUInteger XP3DPMaxHierarchyDepth = 10;
static const NSUInteger XP3DPMaxRenderViews = 4;
static const NSUInteger XP3DPMaxRenderScanNodes = 600;
static const NSUInteger XP3DPMaxRenderScanDepth = 16;
static const NSUInteger XP3DPMaxKeyboardEvents = 16;
static const NSUInteger XP3DPMaxRotationEvents = 16;
static const NSUInteger XP3DPMaxJSONBytes = 6 * 1024 * 1024;
static const NSTimeInterval XP3DPRapidPhase = 6.0;
static const NSTimeInterval XP3DPMediumPhase = 60.0;
static const NSTimeInterval XP3DPTotalDuration = 300.0;

static NSMutableArray *gHistory;
static NSMutableArray *gKeyboardEvents;
static NSMutableArray *gRotationEvents;
static NSMutableArray *gObservers;
static NSDictionary *gInfo;
static NSDictionary *gProcess;
static NSDictionary *gLastRecord;
static NSDictionary *gLastKeyboardEvent;
static NSDictionary *gLastRotationEvent;
static NSString *gRunID;
static NSString *gStartedAt;
static NSTimeInterval gStartUptime;
static NSTimeInterval gLastWrite;
static NSUInteger gSeq;
static NSUInteger gDetailCount;
static NSUInteger gDropped;
static NSUInteger gTrimmedForSize;
static NSInteger gLastPrimaryOrientation;
static CGRect gLastKeyboardEndFrame;
static BOOL gHasLastKeyboardEndFrame;
static BOOL gKeyboardVisible;
static NSTimeInterval gLastKeyboardUptime;
static BOOL gStarted;
static BOOL gTerminated;
static BOOL gTruncated;
static BOOL gHistoryTrimmed;
static NSTimer *gTimer;
static BOOL gFirstTimerSnapshot = YES;

static void XP3DPSnapshot(NSString *trigger, BOOL forceDetail);
static NSString *XP3DPTimestamp(void);
static NSTimeInterval XP3DPUptime(void);

#pragma mark - JSON-safe value helpers

static id XP3DPNum(double value) {
    if (isfinite(value)) {
        return @(value);
    }
    if (isnan(value)) {
        return @"nan";
    }
    return value > 0.0 ? @"+inf" : @"-inf";
}

static NSDictionary *XP3DPRectDict(CGRect rect) {
    return @{
        @"x": XP3DPNum(CGRectGetMinX(rect)),
        @"y": XP3DPNum(CGRectGetMinY(rect)),
        @"width": XP3DPNum(CGRectGetWidth(rect)),
        @"height": XP3DPNum(CGRectGetHeight(rect)),
        @"isNull": @(CGRectIsNull(rect)),
        @"isInfinite": @(CGRectIsInfinite(rect)),
        @"isEmpty": @(CGRectIsEmpty(rect))
    };
}

static NSDictionary *XP3DPSizeDict(CGSize size) {
    return @{
        @"width": XP3DPNum(size.width),
        @"height": XP3DPNum(size.height),
        @"isEmpty": @(size.width <= 0.0 || size.height <= 0.0)
    };
}

static NSDictionary *XP3DPPointDict(CGPoint point) {
    return @{
        @"x": XP3DPNum(point.x),
        @"y": XP3DPNum(point.y)
    };
}

static NSDictionary *XP3DPInsetsDict(UIEdgeInsets insets) {
    return @{
        @"top": XP3DPNum(insets.top),
        @"left": XP3DPNum(insets.left),
        @"bottom": XP3DPNum(insets.bottom),
        @"right": XP3DPNum(insets.right)
    };
}

static NSDictionary *XP3DPAffineDict(CGAffineTransform transform) {
    return @{
        @"a": XP3DPNum(transform.a),
        @"b": XP3DPNum(transform.b),
        @"c": XP3DPNum(transform.c),
        @"d": XP3DPNum(transform.d),
        @"tx": XP3DPNum(transform.tx),
        @"ty": XP3DPNum(transform.ty),
        @"isIdentity": @(CGAffineTransformIsIdentity(transform))
    };
}

static NSDictionary *XP3DPLayerTransformDict(CATransform3D transform) {
    return @{
        @"m11": XP3DPNum(transform.m11), @"m12": XP3DPNum(transform.m12),
        @"m13": XP3DPNum(transform.m13), @"m14": XP3DPNum(transform.m14),
        @"m21": XP3DPNum(transform.m21), @"m22": XP3DPNum(transform.m22),
        @"m23": XP3DPNum(transform.m23), @"m24": XP3DPNum(transform.m24),
        @"m31": XP3DPNum(transform.m31), @"m32": XP3DPNum(transform.m32),
        @"m33": XP3DPNum(transform.m33), @"m34": XP3DPNum(transform.m34),
        @"m41": XP3DPNum(transform.m41), @"m42": XP3DPNum(transform.m42),
        @"m43": XP3DPNum(transform.m43), @"m44": XP3DPNum(transform.m44),
        @"isIdentity": @(CATransform3DIsIdentity(transform))
    };
}

static id XP3DPStringOrNull(id value) {
    return [value isKindOfClass:NSString.class] ? value : NSNull.null;
}

static id XP3DPNumberOrNull(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : NSNull.null;
}

static id XP3DPStringArrayOrNull(id value) {
    if (![value isKindOfClass:NSArray.class]) {
        return NSNull.null;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:NSString.class]) {
            [result addObject:item];
        }
    }
    return result;
}

static id XP3DPNumberArrayOrNull(id value) {
    if (![value isKindOfClass:NSArray.class]) {
        return NSNull.null;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:NSNumber.class]) {
            [result addObject:item];
        }
    }
    return result;
}

#pragma mark - Name helpers

static NSString *XP3DPInterfaceOrientationName(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationPortrait:
            return @"portrait";
        case UIInterfaceOrientationPortraitUpsideDown:
            return @"portraitUpsideDown";
        case UIInterfaceOrientationLandscapeLeft:
            return @"landscapeLeft";
        case UIInterfaceOrientationLandscapeRight:
            return @"landscapeRight";
        case UIInterfaceOrientationUnknown:
        default:
            return @"unknown";
    }
}

static NSString *XP3DPDeviceOrientationName(UIDeviceOrientation orientation) {
    switch (orientation) {
        case UIDeviceOrientationPortrait:
            return @"portrait";
        case UIDeviceOrientationPortraitUpsideDown:
            return @"portraitUpsideDown";
        case UIDeviceOrientationLandscapeLeft:
            return @"landscapeLeft";
        case UIDeviceOrientationLandscapeRight:
            return @"landscapeRight";
        case UIDeviceOrientationFaceUp:
            return @"faceUp";
        case UIDeviceOrientationFaceDown:
            return @"faceDown";
        case UIDeviceOrientationUnknown:
        default:
            return @"unknown";
    }
}

static NSString *XP3DPApplicationStateName(UIApplicationState state) {
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

static NSString *XP3DPActivationStateName(UISceneActivationState state) API_AVAILABLE(ios(13.0));
static NSString *XP3DPActivationStateName(UISceneActivationState state) {
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

static NSString *XP3DPIdiomName(UIUserInterfaceIdiom idiom) {
    switch (idiom) {
        case UIUserInterfaceIdiomPhone:
            return @"phone";
        case UIUserInterfaceIdiomPad:
            return @"pad";
        case UIUserInterfaceIdiomTV:
            return @"tv";
        case UIUserInterfaceIdiomCarPlay:
            return @"carPlay";
        case UIUserInterfaceIdiomMac:
            return @"mac";
        case UIUserInterfaceIdiomVision:
            return @"vision";
        case UIUserInterfaceIdiomUnspecified:
        default:
            return @"unspecified";
    }
}

static NSString *XP3DPSizeClassName(UIUserInterfaceSizeClass sizeClass) {
    switch (sizeClass) {
        case UIUserInterfaceSizeClassCompact:
            return @"compact";
        case UIUserInterfaceSizeClassRegular:
            return @"regular";
        case UIUserInterfaceSizeClassUnspecified:
        default:
            return @"unspecified";
    }
}

static NSString *XP3DPLayoutDirectionName(UIUserInterfaceLayoutDirection direction) {
    switch (direction) {
        case UIUserInterfaceLayoutDirectionLeftToRight:
            return @"leftToRight";
        case UIUserInterfaceLayoutDirectionRightToLeft:
            return @"rightToLeft";
        default:
            return @"unknown";
    }
}

static NSArray<NSString *> *XP3DPAutoresizingNames(UIViewAutoresizing mask) {
    NSMutableArray *names = [NSMutableArray array];
    if (mask & UIViewAutoresizingFlexibleLeftMargin) [names addObject:@"flexibleLeftMargin"];
    if (mask & UIViewAutoresizingFlexibleWidth) [names addObject:@"flexibleWidth"];
    if (mask & UIViewAutoresizingFlexibleRightMargin) [names addObject:@"flexibleRightMargin"];
    if (mask & UIViewAutoresizingFlexibleTopMargin) [names addObject:@"flexibleTopMargin"];
    if (mask & UIViewAutoresizingFlexibleHeight) [names addObject:@"flexibleHeight"];
    if (mask & UIViewAutoresizingFlexibleBottomMargin) [names addObject:@"flexibleBottomMargin"];
    return names;
}

static NSUInteger XP3DPMaskFromOrientationStrings(id value) {
    if (![value isKindOfClass:NSArray.class]) {
        return 0;
    }
    NSUInteger mask = 0;
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *text = (NSString *)item;
        if ([text isEqualToString:@"UIInterfaceOrientationPortrait"]) {
            mask |= (1UL << UIInterfaceOrientationPortrait);
        } else if ([text isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
            mask |= (1UL << UIInterfaceOrientationPortraitUpsideDown);
        } else if ([text isEqualToString:@"UIInterfaceOrientationLandscapeLeft"]) {
            mask |= (1UL << UIInterfaceOrientationLandscapeLeft);
        } else if ([text isEqualToString:@"UIInterfaceOrientationLandscapeRight"]) {
            mask |= (1UL << UIInterfaceOrientationLandscapeRight);
        }
    }
    return mask;
}

static NSArray<NSString *> *XP3DPMaskNames(NSUInteger mask) {
    NSMutableArray *names = [NSMutableArray array];
    if (mask & (1UL << UIInterfaceOrientationPortrait)) [names addObject:@"portrait"];
    if (mask & (1UL << UIInterfaceOrientationPortraitUpsideDown)) [names addObject:@"portraitUpsideDown"];
    if (mask & (1UL << UIInterfaceOrientationLandscapeLeft)) [names addObject:@"landscapeLeft"];
    if (mask & (1UL << UIInterfaceOrientationLandscapeRight)) [names addObject:@"landscapeRight"];
    return names;
}

static NSNumber *XP3DPOrientationNumberFromString(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *text = (NSString *)value;
    if ([text isEqualToString:@"UIInterfaceOrientationPortrait"]) return @(UIInterfaceOrientationPortrait);
    if ([text isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) return @(UIInterfaceOrientationPortraitUpsideDown);
    if ([text isEqualToString:@"UIInterfaceOrientationLandscapeLeft"]) return @(UIInterfaceOrientationLandscapeLeft);
    if ([text isEqualToString:@"UIInterfaceOrientationLandscapeRight"]) return @(UIInterfaceOrientationLandscapeRight);
    return nil;
}

#pragma mark - Trait/screen summaries

static NSDictionary *XP3DPTraitSummary(UITraitCollection *traits) {
    if (traits == nil) {
        return nil;
    }
    return @{
        @"userInterfaceIdiom": @(traits.userInterfaceIdiom),
        @"userInterfaceIdiomName": XP3DPIdiomName(traits.userInterfaceIdiom),
        @"displayScale": XP3DPNum(traits.displayScale),
        @"horizontalSizeClass": @(traits.horizontalSizeClass),
        @"horizontalSizeClassName": XP3DPSizeClassName(traits.horizontalSizeClass),
        @"verticalSizeClass": @(traits.verticalSizeClass),
        @"verticalSizeClassName": XP3DPSizeClassName(traits.verticalSizeClass),
        @"layoutDirection": @(traits.layoutDirection),
        @"layoutDirectionName": XP3DPLayoutDirectionName((UIUserInterfaceLayoutDirection)traits.layoutDirection)
    };
}

static NSDictionary *XP3DPScreenSummary(UIScreen *screen, BOOL isMain) {
    if (screen == nil) {
        return nil;
    }
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"isMain"] = @(isMain);
    record[@"bounds"] = XP3DPRectDict(screen.bounds);
    record[@"nativeBounds"] = XP3DPRectDict(screen.nativeBounds);
    record[@"scale"] = XP3DPNum(screen.scale);
    record[@"nativeScale"] = XP3DPNum(screen.nativeScale);
    record[@"coordinateSpaceBounds"] = XP3DPRectDict(screen.coordinateSpace.bounds);
    UIScreenMode *mode = screen.currentMode;
    if (mode != nil) {
        record[@"currentMode"] = @{
            @"size": XP3DPSizeDict(mode.size),
            @"pixelAspectRatio": XP3DPNum(mode.pixelAspectRatio)
        };
    } else {
        record[@"currentMode"] = NSNull.null;
    }
    return record;
}

static NSArray<NSDictionary *> *XP3DPScreenSummaries(BOOL *mainFound) {
    NSMutableArray *records = [NSMutableArray array];
    UIScreen *mainScreen = UIScreen.mainScreen;
    if (mainFound != NULL) {
        *mainFound = (mainScreen != nil);
    }
    if (mainScreen != nil) {
        NSDictionary *record = XP3DPScreenSummary(mainScreen, YES);
        if (record != nil) [records addObject:record];
    }
    NSArray<UIScreen *> *screens = UIScreen.screens;
    for (UIScreen *screen in screens) {
        if (screen == mainScreen) {
            continue;
        }
        NSDictionary *record = XP3DPScreenSummary(screen, NO);
        if (record != nil) [records addObject:record];
    }
    return records;
}

#pragma mark - Scene helpers (iOS 13+)

static id<UICoordinateSpace> XP3DPSceneCoordinateSpace(UIWindowScene *scene) API_AVAILABLE(ios(13.0));
static id<UICoordinateSpace> XP3DPSceneCoordinateSpace(UIWindowScene *scene) {
    if (scene == nil) {
        return nil;
    }
    if (@available(iOS 26.0, *)) {
        UIWindowSceneGeometry *geometry = scene.effectiveGeometry;
        if (geometry.coordinateSpace != nil) {
            return geometry.coordinateSpace;
        }
    }
    return scene.coordinateSpace;
}

static UIInterfaceOrientation XP3DPSceneInterfaceOrientation(UIWindowScene *scene) API_AVAILABLE(ios(13.0));
static UIInterfaceOrientation XP3DPSceneInterfaceOrientation(UIWindowScene *scene) {
    if (scene == nil) {
        return UIInterfaceOrientationUnknown;
    }
    if (@available(iOS 16.0, *)) {
        return scene.effectiveGeometry.interfaceOrientation;
    }
    return scene.interfaceOrientation;
}

static UIWindowScene *XP3DPWindowSceneForWindow(UIWindow *window) API_AVAILABLE(ios(13.0));
static UIWindowScene *XP3DPWindowSceneForWindow(UIWindow *window) {
    if (window == nil) {
        return nil;
    }
    return window.windowScene;
}

static NSArray<UIWindowScene *> *XP3DPAllScenes(void) API_AVAILABLE(ios(13.0));
static NSArray<UIWindowScene *> *XP3DPAllScenes(void) {
    NSMutableArray *scenes = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            [scenes addObject:(UIWindowScene *)scene];
        }
    }
    return scenes;
}

static NSDictionary *XP3DPSceneSummary(UIWindowScene *scene, NSUInteger index) API_AVAILABLE(ios(13.0));
static NSDictionary *XP3DPSceneSummary(UIWindowScene *scene, NSUInteger index) {
    if (scene == nil) {
        return nil;
    }
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"index"] = @(index);
    record[@"class"] = NSStringFromClass(scene.class) ?: @"<unknown>";
    record[@"activationState"] = @(scene.activationState);
    record[@"activationStateName"] = XP3DPActivationStateName(scene.activationState);

    UISceneSession *session = scene.session;
    if (session != nil) {
        record[@"sessionRole"] = XP3DPStringOrNull(session.role);
    } else {
        record[@"sessionRole"] = NSNull.null;
    }

    // Both coordinate-space sources are recorded so an OS-version difference
    // between scene.coordinateSpace and effectiveGeometry.coordinateSpace is
    // visible rather than silently picked.
    id<UICoordinateSpace> legacySpace = scene.coordinateSpace;
    record[@"legacyCoordinateSpaceBounds"] = legacySpace != nil
        ? XP3DPRectDict(legacySpace.bounds) : NSNull.null;
    id<UICoordinateSpace> currentSpace = XP3DPSceneCoordinateSpace(scene);
    record[@"currentCoordinateSpaceBounds"] = currentSpace != nil
        ? XP3DPRectDict(currentSpace.bounds) : NSNull.null;

    UIInterfaceOrientation legacyOrientation = scene.interfaceOrientation;
    UIInterfaceOrientation currentOrientation = XP3DPSceneInterfaceOrientation(scene);
    record[@"interfaceOrientation"] = @(legacyOrientation);
    record[@"interfaceOrientationName"] = XP3DPInterfaceOrientationName(legacyOrientation);
    record[@"effectiveInterfaceOrientation"] = @(currentOrientation);
    record[@"effectiveInterfaceOrientationName"] = XP3DPInterfaceOrientationName(currentOrientation);

    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometry *geometry = scene.effectiveGeometry;
        NSMutableDictionary *geometryRecord = [NSMutableDictionary dictionary];
        geometryRecord[@"interfaceOrientation"] = @(geometry.interfaceOrientation);
        geometryRecord[@"interfaceOrientationName"] = XP3DPInterfaceOrientationName(geometry.interfaceOrientation);
        if (@available(iOS 26.0, *)) {
            geometryRecord[@"coordinateSpaceBounds"] = geometry.coordinateSpace != nil
                ? XP3DPRectDict(geometry.coordinateSpace.bounds) : NSNull.null;
            geometryRecord[@"interfaceOrientationLocked"] = @(geometry.interfaceOrientationLocked);
            geometryRecord[@"interactivelyResizing"] = @(geometry.isInteractivelyResizing);
        }
        record[@"effectiveGeometry"] = geometryRecord;
    } else {
        record[@"effectiveGeometry"] = NSNull.null;
    }

    UIScreen *screen = scene.screen;
    record[@"screen"] = XP3DPScreenSummary(screen, screen == UIScreen.mainScreen) ?: NSNull.null;
    record[@"windowCount"] = @(scene.windows.count);
    if (@available(iOS 15.0, *)) {
        UIWindow *keyWindow = scene.keyWindow;
        if (keyWindow != nil) {
            NSUInteger keyIndex = NSNotFound;
            NSArray<UIWindow *> *windows = scene.windows;
            for (NSUInteger i = 0; i < windows.count; i++) {
                if (windows[i] == keyWindow) {
                    keyIndex = i;
                    break;
                }
            }
            record[@"keyWindowIndexInScene"] = keyIndex == NSNotFound ? NSNull.null : @(keyIndex);
        } else {
            record[@"keyWindowIndexInScene"] = NSNull.null;
        }
    } else {
        record[@"keyWindowIndexInScene"] = NSNull.null;
    }

    UISceneSizeRestrictions *restrictions = scene.sizeRestrictions;
    if (restrictions != nil) {
        record[@"sizeRestrictions"] = @{
            @"minimumSize": XP3DPSizeDict(restrictions.minimumSize),
            @"maximumSize": XP3DPSizeDict(restrictions.maximumSize)
        };
    } else {
        record[@"sizeRestrictions"] = NSNull.null;
    }

    record[@"traitCollection"] = XP3DPTraitSummary(scene.traitCollection) ?: NSNull.null;
    return record;
}

#pragma mark - View and layer summaries

static BOOL XP3DPIsRenderClass(Class cls) {
    NSString *name = NSStringFromClass(cls);
    if (name.length == 0) {
        return NO;
    }
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"cceagl"] || [lower containsString:@"eagl"] ||
           [lower containsString:@"glview"];
}

static NSDictionary *XP3DPLayerSummary(CALayer *layer) {
    if (layer == nil) {
        return nil;
    }
    return @{
        @"class": NSStringFromClass(layer.class) ?: @"<unknown>",
        @"bounds": XP3DPRectDict(layer.bounds),
        @"frame": XP3DPRectDict(layer.frame),
        @"position": XP3DPPointDict(layer.position),
        @"anchorPoint": XP3DPPointDict(layer.anchorPoint),
        @"anchorPointZ": XP3DPNum(layer.anchorPointZ),
        @"contentsScale": XP3DPNum(layer.contentsScale),
        @"masksToBounds": @(layer.masksToBounds),
        @"isGeometryFlipped": @(layer.isGeometryFlipped),
        @"transform": XP3DPLayerTransformDict(layer.transform)
    };
}

static NSDictionary *XP3DPViewSummary(UIView *view) {
    if (view == nil) {
        return nil;
    }
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"class"] = NSStringFromClass(view.class) ?: @"<unknown>";
    record[@"frame"] = XP3DPRectDict(view.frame);
    record[@"bounds"] = XP3DPRectDict(view.bounds);
    record[@"center"] = XP3DPPointDict(view.center);
    record[@"transform"] = XP3DPAffineDict(view.transform);
    record[@"contentScaleFactor"] = XP3DPNum(view.contentScaleFactor);
    record[@"autoresizingMask"] = @(view.autoresizingMask);
    record[@"autoresizingMaskNames"] = XP3DPAutoresizingNames(view.autoresizingMask);
    record[@"autoresizesSubviews"] = @(view.autoresizesSubviews);
    record[@"clipsToBounds"] = @(view.clipsToBounds);
    record[@"hidden"] = @(view.hidden);
    record[@"alpha"] = XP3DPNum(view.alpha);
    record[@"isOpaque"] = @(view.isOpaque);
    record[@"safeAreaInsets"] = XP3DPInsetsDict(view.safeAreaInsets);
    record[@"effectiveUserInterfaceLayoutDirection"] = @(view.effectiveUserInterfaceLayoutDirection);
    record[@"effectiveUserInterfaceLayoutDirectionName"] =
        XP3DPLayoutDirectionName(view.effectiveUserInterfaceLayoutDirection);
    record[@"traitCollection"] = XP3DPTraitSummary(view.traitCollection) ?: NSNull.null;
    record[@"layer"] = XP3DPLayerSummary(view.layer) ?: NSNull.null;
    record[@"windowAttached"] = @(view.window != nil);
    record[@"isRenderView"] = @(XP3DPIsRenderClass(view.class));
    return record;
}

static NSDictionary *XP3DPViewNode(UIView *view,
                                   NSUInteger depth,
                                   NSUInteger *nodeCount,
                                   BOOL *truncated) {
    if (view == nil || nodeCount == NULL || truncated == NULL ||
        *nodeCount >= XP3DPMaxHierarchyNodes) {
        if (truncated != NULL) {
            *truncated = YES;
        }
        return nil;
    }

    (*nodeCount)++;
    NSMutableDictionary *record = [XP3DPViewSummary(view) mutableCopy];
    NSArray<UIView *> *subviews = view.subviews;
    record[@"depth"] = @(depth);
    record[@"subviewCount"] = @(subviews.count);
    record[@"truncatedAtDepth"] = @NO;

    if (depth >= XP3DPMaxHierarchyDepth) {
        record[@"subviews"] = @[];
        if (subviews.count > 0) {
            record[@"truncatedAtDepth"] = @YES;
            *truncated = YES;
        }
        return record;
    }

    NSMutableArray *children = [NSMutableArray array];
    for (UIView *child in subviews) {
        if (*nodeCount >= XP3DPMaxHierarchyNodes) {
            *truncated = YES;
            break;
        }
        NSDictionary *childRecord = XP3DPViewNode(child, depth + 1, nodeCount, truncated);
        if (childRecord != nil) {
            [children addObject:childRecord];
        }
    }
    record[@"subviews"] = children;
    return record;
}

#pragma mark - Validated NSInvocation getters

typedef NS_ENUM(NSInteger, XP3DPGetterKind) {
    XP3DPGetterKindUnsupported = 0,
    XP3DPGetterKindCGSize,
    XP3DPGetterKindCGRect,
    XP3DPGetterKindCGFloat,
    XP3DPGetterKindNSInteger,
    XP3DPGetterKindNSUInteger,
    XP3DPGetterKindInt,
    XP3DPGetterKindUInt,
    XP3DPGetterKindFloat,
    XP3DPGetterKindBool
};

static XP3DPGetterKind XP3DPGetterKindForSignature(NSMethodSignature *signature) {
    const char *returnType = signature.methodReturnType;
    if (returnType == NULL) {
        return XP3DPGetterKindUnsupported;
    }
    if (strcmp(returnType, @encode(CGSize)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(CGSize)) {
        return XP3DPGetterKindCGSize;
    }
    if (strcmp(returnType, @encode(CGRect)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(CGRect)) {
        return XP3DPGetterKindCGRect;
    }
    if (strcmp(returnType, @encode(CGFloat)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(CGFloat)) {
        return XP3DPGetterKindCGFloat;
    }
    if (strcmp(returnType, @encode(NSInteger)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(NSInteger)) {
        return XP3DPGetterKindNSInteger;
    }
    if (strcmp(returnType, @encode(NSUInteger)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(NSUInteger)) {
        return XP3DPGetterKindNSUInteger;
    }
    if (strcmp(returnType, @encode(int)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(int)) {
        return XP3DPGetterKindInt;
    }
    if (strcmp(returnType, @encode(unsigned int)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(unsigned int)) {
        return XP3DPGetterKindUInt;
    }
    if (strcmp(returnType, @encode(float)) == 0 &&
        signature.methodReturnLength == (NSUInteger)sizeof(float)) {
        return XP3DPGetterKindFloat;
    }
    if ((strcmp(returnType, @encode(BOOL)) == 0 || strcmp(returnType, @encode(char)) == 0) &&
        signature.methodReturnLength == (NSUInteger)sizeof(BOOL)) {
        return XP3DPGetterKindBool;
    }
    return XP3DPGetterKindUnsupported;
}

static NSString *XP3DPGetterKindName(XP3DPGetterKind kind) {
    switch (kind) {
        case XP3DPGetterKindCGSize: return @"CGSize";
        case XP3DPGetterKindCGRect: return @"CGRect";
        case XP3DPGetterKindCGFloat: return @"CGFloat";
        case XP3DPGetterKindNSInteger: return @"NSInteger";
        case XP3DPGetterKindNSUInteger: return @"NSUInteger";
        case XP3DPGetterKindInt: return @"int";
        case XP3DPGetterKindUInt: return @"unsignedInt";
        case XP3DPGetterKindFloat: return @"float";
        case XP3DPGetterKindBool: return @"BOOL";
        case XP3DPGetterKindUnsupported:
        default: return @"unsupported";
    }
}

static NSDictionary *XP3DPInvokeGetter(id object, NSString *selectorName) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"selector"] = selectorName;
    record[@"status"] = @"missing";
    record[@"value"] = NSNull.null;
    record[@"kind"] = @"unsupported";
    record[@"returnEncoding"] = NSNull.null;
    record[@"returnLength"] = NSNull.null;
    record[@"argumentCount"] = NSNull.null;

    if (object == nil) {
        record[@"status"] = @"nil-target";
        return record;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (selector == NULL || ![object respondsToSelector:selector]) {
        return record;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil) {
        record[@"status"] = @"missing-signature";
        return record;
    }

    record[@"returnEncoding"] = signature.methodReturnType
        ? @(signature.methodReturnType) : NSNull.null;
    record[@"returnLength"] = @(signature.methodReturnLength);
    record[@"argumentCount"] = @(signature.numberOfArguments);

    if (signature.numberOfArguments != 2) {
        record[@"status"] = @"unsupported-argument-count";
        return record;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL || strcmp(returnType, @encode(void)) == 0) {
        record[@"status"] = @"void-return";
        return record;
    }

    XP3DPGetterKind kind = XP3DPGetterKindForSignature(signature);
    record[@"kind"] = XP3DPGetterKindName(kind);
    if (kind == XP3DPGetterKindUnsupported) {
        // Do not invoke: the return ABI is not one we can decode safely.
        record[@"status"] = @"unsupported-return-encoding";
        return record;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:object];
    [invocation setSelector:selector];

    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        // Record only the exception name; the reason may contain host content.
        record[@"status"] = @"exception";
        record[@"exceptionName"] = exception.name ?: @"<unknown>";
        return record;
    }

    switch (kind) {
        case XP3DPGetterKindCGSize: {
            CGSize value = CGSizeZero;
            [invocation getReturnValue:&value];
            record[@"value"] = XP3DPSizeDict(value);
            break;
        }
        case XP3DPGetterKindCGRect: {
            CGRect value = CGRectZero;
            [invocation getReturnValue:&value];
            record[@"value"] = XP3DPRectDict(value);
            break;
        }
        case XP3DPGetterKindCGFloat: {
            CGFloat value = 0.0;
            [invocation getReturnValue:&value];
            record[@"value"] = XP3DPNum(value);
            break;
        }
        case XP3DPGetterKindNSInteger: {
            NSInteger value = 0;
            [invocation getReturnValue:&value];
            record[@"value"] = @(value);
            break;
        }
        case XP3DPGetterKindNSUInteger: {
            NSUInteger value = 0;
            [invocation getReturnValue:&value];
            record[@"value"] = @(value);
            break;
        }
        case XP3DPGetterKindInt: {
            int value = 0;
            [invocation getReturnValue:&value];
            record[@"value"] = @(value);
            break;
        }
        case XP3DPGetterKindUInt: {
            unsigned int value = 0;
            [invocation getReturnValue:&value];
            record[@"value"] = @(value);
            break;
        }
        case XP3DPGetterKindFloat: {
            float value = 0.0f;
            [invocation getReturnValue:&value];
            record[@"value"] = XP3DPNum((double)value);
            break;
        }
        case XP3DPGetterKindBool: {
            BOOL value = NO;
            [invocation getReturnValue:&value];
            record[@"value"] = @(value);
            break;
        }
        case XP3DPGetterKindUnsupported:
        default:
            record[@"status"] = @"unsupported-return-encoding";
            return record;
    }

    record[@"status"] = @"ok";
    return record;
}

static NSArray<NSDictionary *> *XP3DPProbeRenderViewMethods(UIView *view) {
    static NSArray<NSString *> *selectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Candidate names only.  A selector is invoked only after its runtime
        // NSMethodSignature is validated as a zero-argument getter with a
        // return encoding we can decode exactly.  Missing/unknown stays null.
        selectors = @[
            @"surfaceSize", @"backingSize",
            @"getSurfaceSize", @"getBackingSize",
            @"surfaceWidth", @"surfaceHeight",
            @"backingWidth", @"backingHeight",
            @"width", @"height",
            @"framebufferWidth", @"framebufferHeight",
            @"drawableWidth", @"drawableHeight",
            @"pixelWidth", @"pixelHeight"
        ];
    });
    NSMutableArray *probes = [NSMutableArray arrayWithCapacity:selectors.count];
    for (NSString *selector in selectors) {
        [probes addObject:XP3DPInvokeGetter(view, selector)];
    }
    return probes;
}

#pragma mark - Render-view discovery

static NSArray<NSDictionary *> *XP3DPFindRenderViews(UIView *root) {
    NSMutableArray *results = [NSMutableArray array];
    if (root == nil) {
        return results;
    }

    NSMutableArray *stack = [NSMutableArray arrayWithObject:@{
        @"view": root,
        @"path": @"root",
        @"depth": @0
    }];
    NSUInteger scanned = 0;

    while (stack.count > 0 && results.count < XP3DPMaxRenderViews &&
           scanned < XP3DPMaxRenderScanNodes) {
        NSDictionary *item = stack.lastObject;
        [stack removeLastObject];
        UIView *view = item[@"view"];
        NSString *path = item[@"path"];
        NSUInteger depth = [item[@"depth"] unsignedIntegerValue];
        scanned++;

        if (XP3DPIsRenderClass(view.class)) {
            [results addObject:@{
                @"view": view,
                @"path": path,
                @"depth": @(depth)
            }];
        }

        if (depth >= XP3DPMaxRenderScanDepth) {
            continue;
        }
        NSArray<UIView *> *subviews = view.subviews;
        for (NSInteger index = (NSInteger)subviews.count - 1; index >= 0; index--) {
            UIView *child = subviews[(NSUInteger)index];
            NSString *childPath = [NSString stringWithFormat:@"%@.%ld", path, (long)index];
            [stack addObject:@{
                @"view": child,
                @"path": childPath,
                @"depth": @(depth + 1)
            }];
        }
    }
    return results;
}

#pragma mark - Coordinate conversion

static BOOL XP3DPViewIsAttached(UIView *view) {
    if (view == nil) {
        return NO;
    }
    if ([view isKindOfClass:UIWindow.class]) {
        return YES;
    }
    return view.window != nil;
}

static id XP3DPConvertToView(UIView *from, CGRect rect, UIView *to) {
    if (from == nil || to == nil || !XP3DPViewIsAttached(from) || !XP3DPViewIsAttached(to)) {
        return NSNull.null;
    }
    return XP3DPRectDict([from convertRect:rect toView:to]);
}

static id XP3DPConvertToSpace(UIView *from, CGRect rect, id<UICoordinateSpace> space) {
    if (from == nil || space == nil || !XP3DPViewIsAttached(from)) {
        return NSNull.null;
    }
    return XP3DPRectDict([from convertRect:rect toCoordinateSpace:space]);
}

static id XP3DPConvertFromSpace(id<UICoordinateSpace> space, CGRect rect, UIView *to) {
    if (to == nil || space == nil || !XP3DPViewIsAttached(to)) {
        return NSNull.null;
    }
    return XP3DPRectDict([to convertRect:rect fromCoordinateSpace:space]);
}

static BOOL XP3DPRectFromObject(id object, CGRect *rect) {
    if (rect == NULL || ![object isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *dictionary = (NSDictionary *)object;
    NSNumber *x = dictionary[@"x"];
    NSNumber *y = dictionary[@"y"];
    NSNumber *width = dictionary[@"width"];
    NSNumber *height = dictionary[@"height"];
    if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
        ![width isKindOfClass:NSNumber.class] || ![height isKindOfClass:NSNumber.class]) {
        return NO;
    }
    *rect = CGRectMake(x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue);
    return isfinite(rect->origin.x) && isfinite(rect->origin.y) &&
           isfinite(rect->size.width) && isfinite(rect->size.height);
}

static BOOL XP3DPRectsClose(CGRect a, CGRect b, CGFloat tolerance) {
    return fabs(CGRectGetMinX(a) - CGRectGetMinX(b)) <= tolerance &&
           fabs(CGRectGetMinY(a) - CGRectGetMinY(b)) <= tolerance &&
           fabs(CGRectGetWidth(a) - CGRectGetWidth(b)) <= tolerance &&
           fabs(CGRectGetHeight(a) - CGRectGetHeight(b)) <= tolerance;
}

static NSNumber *XP3DPCompareRectObjects(id first, id second) {
    CGRect a = CGRectZero;
    CGRect b = CGRectZero;
    if (!XP3DPRectFromObject(first, &a) || !XP3DPRectFromObject(second, &b)) {
        return nil;
    }
    return @(XP3DPRectsClose(a, b, 0.5));
}

static NSDictionary *XP3DPConvertSummaryForView(UIView *view,
                                                UIWindow *window,
                                                UIView *root,
                                                UIWindowScene *scene,
                                                UIScreen *screen) {
    if (view == nil) {
        return @{};
    }
    id<UICoordinateSpace> sceneSpace = scene != nil ? XP3DPSceneCoordinateSpace(scene) : nil;
    id<UICoordinateSpace> screenSpace = screen.coordinateSpace;
    CGRect bounds = view.bounds;

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"viewBounds"] = XP3DPRectDict(bounds);
    record[@"viewBoundsToRootView"] = XP3DPConvertToView(view, bounds, root);
    record[@"viewBoundsToRootSpace"] = XP3DPConvertToSpace(view, bounds, root);
    record[@"viewBoundsToWindowView"] = XP3DPConvertToView(view, bounds, window);
    record[@"viewBoundsToWindowSpace"] = XP3DPConvertToSpace(view, bounds, window);
    record[@"viewBoundsToScene"] = XP3DPConvertToSpace(view, bounds, sceneSpace);
    record[@"viewBoundsToScreen"] = XP3DPConvertToSpace(view, bounds, screenSpace);
    record[@"rootBoundsToView"] = root != nil
        ? XP3DPConvertFromSpace(root, root.bounds, view) : NSNull.null;
    record[@"windowBoundsToView"] = XP3DPConvertFromSpace(window, window.bounds, view);
    record[@"screenBoundsToView"] = XP3DPConvertFromSpace(screenSpace, screen.bounds, view);
    record[@"sceneBoundsToView"] = sceneSpace != nil
        ? XP3DPConvertFromSpace(sceneSpace, sceneSpace.bounds, view) : NSNull.null;

    // Asymmetric probes expose axis flips/rotation in the coordinate mapping.
    CGRect topLeft = CGRectMake(0.0, 0.0, 1.0, 1.0);
    CGRect bottomRight = CGRectMake(MAX(0.0, bounds.size.width - 1.0),
                                    MAX(0.0, bounds.size.height - 1.0), 1.0, 1.0);
    record[@"directionProbe"] = @{
        @"viewTopLeftToScreen": XP3DPConvertToSpace(view, topLeft, screenSpace),
        @"viewBottomRightToScreen": XP3DPConvertToSpace(view, bottomRight, screenSpace),
        @"screenTopLeftToView": XP3DPConvertFromSpace(screenSpace, topLeft, view),
        @"screenBottomRightToView": XP3DPConvertFromSpace(screenSpace, bottomRight, view),
        @"viewTopLeftToScene": XP3DPConvertToSpace(view, topLeft, sceneSpace),
        @"viewBottomRightToScene": XP3DPConvertToSpace(view, bottomRight, sceneSpace)
    };

    NSNumber *rootViewVsSpace = XP3DPCompareRectObjects(record[@"viewBoundsToRootView"],
                                                         record[@"viewBoundsToRootSpace"]);
    NSNumber *windowViewVsSpace = XP3DPCompareRectObjects(record[@"viewBoundsToWindowView"],
                                                           record[@"viewBoundsToWindowSpace"]);
    record[@"mappingConsistency"] = @{
        @"rootViewVsRootSpace": rootViewVsSpace ?: NSNull.null,
        @"windowViewVsWindowSpace": windowViewVsSpace ?: NSNull.null
    };
    return record;
}

static NSDictionary *XP3DPWindowConvertSummary(UIWindow *window, UIView *root) {
    if (window == nil) {
        return @{};
    }
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        scene = XP3DPWindowSceneForWindow(window);
    }
    id<UICoordinateSpace> sceneSpace = scene != nil ? XP3DPSceneCoordinateSpace(scene) : nil;
    UIScreen *screen = window.screen;
    id<UICoordinateSpace> screenSpace = screen.coordinateSpace;

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"windowBounds"] = XP3DPRectDict(window.bounds);
    record[@"windowFrame"] = XP3DPRectDict(window.frame);
    record[@"windowBoundsToScene"] = XP3DPConvertToSpace(window, window.bounds, sceneSpace);
    record[@"windowBoundsToScreen"] = XP3DPConvertToSpace(window, window.bounds, screenSpace);
    record[@"windowBoundsToRootView"] = XP3DPConvertToView(window, window.bounds, root);
    record[@"windowBoundsToRootSpace"] = XP3DPConvertToSpace(window, window.bounds, root);
    record[@"rootBoundsToWindowView"] = root != nil
        ? XP3DPConvertToView(root, root.bounds, window) : NSNull.null;
    record[@"rootBoundsToWindowSpace"] = root != nil
        ? XP3DPConvertToSpace(root, root.bounds, window) : NSNull.null;
    record[@"rootBoundsToScene"] = root != nil
        ? XP3DPConvertToSpace(root, root.bounds, sceneSpace) : NSNull.null;
    record[@"rootBoundsToScreen"] = root != nil
        ? XP3DPConvertToSpace(root, root.bounds, screenSpace) : NSNull.null;
    record[@"screenBoundsToWindow"] = XP3DPConvertFromSpace(screenSpace, screen.bounds, window);
    record[@"sceneBoundsToWindow"] = sceneSpace != nil
        ? XP3DPConvertFromSpace(sceneSpace, sceneSpace.bounds, window) : NSNull.null;

    CGRect topLeft = CGRectMake(0.0, 0.0, 1.0, 1.0);
    CGRect bottomRight = CGRectMake(MAX(0.0, window.bounds.size.width - 1.0),
                                    MAX(0.0, window.bounds.size.height - 1.0), 1.0, 1.0);
    record[@"directionProbe"] = @{
        @"windowTopLeftToScreen": XP3DPConvertToSpace(window, topLeft, screenSpace),
        @"windowBottomRightToScreen": XP3DPConvertToSpace(window, bottomRight, screenSpace),
        @"screenTopLeftToWindow": XP3DPConvertFromSpace(screenSpace, topLeft, window),
        @"screenBottomRightToWindow": XP3DPConvertFromSpace(screenSpace, bottomRight, window),
        @"windowTopLeftToScene": XP3DPConvertToSpace(window, topLeft, sceneSpace),
        @"windowBottomRightToScene": XP3DPConvertToSpace(window, bottomRight, sceneSpace)
    };

    NSNumber *rootViewVsSpace = XP3DPCompareRectObjects(record[@"windowBoundsToRootView"],
                                                         record[@"windowBoundsToRootSpace"]);
    record[@"mappingConsistency"] = @{
        @"windowRootViewVsRootSpace": rootViewVsSpace ?: NSNull.null
    };
    return record;
}

#pragma mark - Window/controller summaries

static NSDictionary *XP3DPRootViewControllerSummary(UIViewController *controller) {
    if (controller == nil) {
        return nil;
    }
    NSUInteger mask = [controller supportedInterfaceOrientations];
    UIInterfaceOrientation preferred = [controller preferredInterfaceOrientationForPresentation];
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"class"] = NSStringFromClass(controller.class) ?: @"<unknown>";
    record[@"isViewLoaded"] = @(controller.isViewLoaded);
    record[@"supportedInterfaceOrientations"] = @(mask);
    record[@"supportedInterfaceOrientationsMaskHex"] =
        [NSString stringWithFormat:@"0x%lx", (unsigned long)mask];
    record[@"supportedInterfaceOrientationsNames"] = XP3DPMaskNames(mask);
    record[@"preferredInterfaceOrientationForPresentation"] = @(preferred);
    record[@"preferredInterfaceOrientationForPresentationName"] =
        XP3DPInterfaceOrientationName(preferred);
    record[@"shouldAutorotate"] = @([controller shouldAutorotate]);
    record[@"isBeingPresented"] = @(controller.isBeingPresented);
    record[@"isBeingDismissed"] = @(controller.isBeingDismissed);
    record[@"traitCollection"] = XP3DPTraitSummary(controller.traitCollection) ?: NSNull.null;
    return record;
}

static NSDictionary *XP3DPWindowSummary(UIWindow *window,
                                        NSUInteger index,
                                        NSArray<UIWindowScene *> *scenes) {
    if (window == nil) {
        return nil;
    }
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"index"] = @(index);
    record[@"class"] = NSStringFromClass(window.class) ?: @"<unknown>";
    record[@"frame"] = XP3DPRectDict(window.frame);
    record[@"bounds"] = XP3DPRectDict(window.bounds);
    record[@"center"] = XP3DPPointDict(window.center);
    record[@"transform"] = XP3DPAffineDict(window.transform);
    record[@"contentScaleFactor"] = XP3DPNum(window.contentScaleFactor);
    record[@"windowLevel"] = XP3DPNum(window.windowLevel);
    record[@"hidden"] = @(window.hidden);
    record[@"keyWindow"] = @(window.isKeyWindow);
    record[@"autoresizingMask"] = @(window.autoresizingMask);
    record[@"autoresizingMaskNames"] = XP3DPAutoresizingNames(window.autoresizingMask);
    record[@"autoresizesSubviews"] = @(window.autoresizesSubviews);
    record[@"safeAreaInsets"] = XP3DPInsetsDict(window.safeAreaInsets);
    record[@"effectiveUserInterfaceLayoutDirection"] = @(window.effectiveUserInterfaceLayoutDirection);
    record[@"effectiveUserInterfaceLayoutDirectionName"] =
        XP3DPLayoutDirectionName(window.effectiveUserInterfaceLayoutDirection);
    record[@"traitCollection"] = XP3DPTraitSummary(window.traitCollection) ?: NSNull.null;
    record[@"layer"] = XP3DPLayerSummary(window.layer) ?: NSNull.null;

    UIScreen *screen = window.screen;
    record[@"screen"] = XP3DPScreenSummary(screen, screen == UIScreen.mainScreen) ?: NSNull.null;

    UIWindowScene *scene = nil;
    NSUInteger sceneIndex = NSNotFound;
    if (@available(iOS 13.0, *)) {
        scene = XP3DPWindowSceneForWindow(window);
        if (scene != nil) {
            for (NSUInteger i = 0; i < scenes.count; i++) {
                if (scenes[i] == scene) {
                    sceneIndex = i;
                    break;
                }
            }
        }
    }
    record[@"sceneIndex"] = sceneIndex == NSNotFound ? NSNull.null : @(sceneIndex);

    UIViewController *rootController = window.rootViewController;
    record[@"rootViewController"] = XP3DPRootViewControllerSummary(rootController) ?: NSNull.null;
    UIView *rootView = rootController.viewIfLoaded;
    record[@"rootView"] = XP3DPViewSummary(rootView) ?: NSNull.null;

    NSArray<NSDictionary *> *renderEntries = XP3DPFindRenderViews(rootView);
    NSMutableArray *renderRecords = [NSMutableArray arrayWithCapacity:renderEntries.count];
    for (NSDictionary *entry in renderEntries) {
        UIView *renderView = entry[@"view"];
        NSMutableDictionary *renderRecord = [NSMutableDictionary dictionary];
        renderRecord[@"path"] = entry[@"path"];
        renderRecord[@"depth"] = entry[@"depth"];
        renderRecord[@"summary"] = XP3DPViewSummary(renderView) ?: NSNull.null;
        renderRecord[@"methodProbes"] = XP3DPProbeRenderViewMethods(renderView);
        renderRecord[@"convert"] = XP3DPConvertSummaryForView(renderView, window, rootView,
                                                               scene, screen);
        [renderRecords addObject:renderRecord];
    }
    record[@"renderViewCount"] = @(renderRecords.count);
    record[@"renderViews"] = renderRecords;
    record[@"renderViewSearch"] = @{
        @"candidateClassSubstrings": @[@"CCEAGL", @"EAGL", @"GLView"],
        @"maxRenderViews": @(XP3DPMaxRenderViews),
        @"maxScannedNodes": @(XP3DPMaxRenderScanNodes),
        @"maxScanDepth": @(XP3DPMaxRenderScanDepth)
    };
    record[@"convert"] = XP3DPWindowConvertSummary(window, rootView);
    return record;
}

static NSArray<UIWindow *> *XP3DPAllWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    UIApplication *application = UIApplication.sharedApplication;
    for (UIWindow *window in application.windows) {
        if (![windows containsObject:window]) {
            [windows addObject:window];
        }
    }
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in XP3DPAllScenes()) {
            for (UIWindow *window in scene.windows) {
                if (![windows containsObject:window]) {
                    [windows addObject:window];
                }
            }
        }
    }
    return windows;
}

static UIWindow *XP3DPKeyWindow(NSArray<UIWindow *> *windows) {
    for (UIWindow *window in windows) {
        if (window.isKeyWindow && !window.hidden) {
            return window;
        }
    }
    for (UIWindow *window in windows) {
        if (!window.hidden && window.windowLevel == 0.0) {
            return window;
        }
    }
    return windows.firstObject;
}

#pragma mark - Orientation

static NSDictionary *XP3DPOrientationSummary(UIWindow *keyWindow,
                                             UIViewController *rootController) {
    UIInterfaceOrientation sceneOrientation = UIInterfaceOrientationUnknown;
    UIInterfaceOrientation sceneLegacyOrientation = UIInterfaceOrientationUnknown;
    NSNumber *orientationLocked = nil;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = keyWindow != nil ? XP3DPWindowSceneForWindow(keyWindow) : nil;
        if (scene == nil) {
            NSArray<UIWindowScene *> *scenes = XP3DPAllScenes();
            scene = scenes.firstObject;
        }
        if (scene != nil) {
            sceneOrientation = XP3DPSceneInterfaceOrientation(scene);
            sceneLegacyOrientation = scene.interfaceOrientation;
            if (@available(iOS 26.0, *)) {
                orientationLocked = @(scene.effectiveGeometry.interfaceOrientationLocked);
            }
        }
    }

    UIInterfaceOrientation applicationOrientation =
        UIApplication.sharedApplication.statusBarOrientation;
    UIInterfaceOrientation controllerOrientation = rootController != nil
        ? rootController.interfaceOrientation : UIInterfaceOrientationUnknown;
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;

    NSMutableArray<NSNumber *> *knownInterface = [NSMutableArray array];
    if (sceneOrientation >= UIInterfaceOrientationPortrait &&
        sceneOrientation <= UIInterfaceOrientationLandscapeRight) {
        [knownInterface addObject:@(sceneOrientation)];
    }
    if (applicationOrientation >= UIInterfaceOrientationPortrait &&
        applicationOrientation <= UIInterfaceOrientationLandscapeRight) {
        [knownInterface addObject:@(applicationOrientation)];
    }
    if (controllerOrientation >= UIInterfaceOrientationPortrait &&
        controllerOrientation <= UIInterfaceOrientationLandscapeRight) {
        [knownInterface addObject:@(controllerOrientation)];
    }

    BOOL agree = YES;
    if (knownInterface.count > 0) {
        NSInteger first = knownInterface.firstObject.integerValue;
        for (NSNumber *value in knownInterface) {
            if (value.integerValue != first) {
                agree = NO;
                break;
            }
        }
    }

    UIInterfaceOrientation primary = UIInterfaceOrientationUnknown;
    if (sceneOrientation >= UIInterfaceOrientationPortrait &&
        sceneOrientation <= UIInterfaceOrientationLandscapeRight) {
        primary = sceneOrientation;
    } else if (applicationOrientation >= UIInterfaceOrientationPortrait &&
               applicationOrientation <= UIInterfaceOrientationLandscapeRight) {
        primary = applicationOrientation;
    } else if (controllerOrientation >= UIInterfaceOrientationPortrait &&
               controllerOrientation <= UIInterfaceOrientationLandscapeRight) {
        primary = controllerOrientation;
    } else if (deviceOrientation >= UIDeviceOrientationPortrait &&
               deviceOrientation <= UIDeviceOrientationLandscapeRight) {
        primary = (UIInterfaceOrientation)deviceOrientation;
    }

    NSNumber *deviceAgrees = nil;
    if (primary != UIInterfaceOrientationUnknown &&
        deviceOrientation >= UIDeviceOrientationPortrait &&
        deviceOrientation <= UIDeviceOrientationLandscapeRight) {
        deviceAgrees = @((NSInteger)primary == (NSInteger)deviceOrientation);
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"primary"] = @(primary);
    record[@"primaryName"] = XP3DPInterfaceOrientationName(primary);
    record[@"scene"] = @(sceneOrientation);
    record[@"sceneName"] = XP3DPInterfaceOrientationName(sceneOrientation);
    record[@"sceneLegacy"] = @(sceneLegacyOrientation);
    record[@"sceneLegacyName"] = XP3DPInterfaceOrientationName(sceneLegacyOrientation);
    record[@"application"] = @(applicationOrientation);
    record[@"applicationName"] = XP3DPInterfaceOrientationName(applicationOrientation);
    record[@"rootViewController"] = @(controllerOrientation);
    record[@"rootViewControllerName"] = XP3DPInterfaceOrientationName(controllerOrientation);
    record[@"device"] = @(deviceOrientation);
    record[@"deviceName"] = XP3DPDeviceOrientationName(deviceOrientation);
    record[@"knownInterfaceSourceCount"] = @(knownInterface.count);
    record[@"allInterfaceSourcesAgree"] = knownInterface.count > 0 ? @(agree) : NSNull.null;
    record[@"deviceAgreesWithPrimary"] = deviceAgrees ?: NSNull.null;
    record[@"interfaceOrientationLocked"] = orientationLocked ?: NSNull.null;
    record[@"generatesDeviceOrientationNotifications"] =
        @(UIDevice.currentDevice.generatesDeviceOrientationNotifications);
    record[@"sources"] = @{
        @"scene": @{
            @"value": @(sceneOrientation),
            @"name": XP3DPInterfaceOrientationName(sceneOrientation)
        },
        @"application": @{
            @"value": @(applicationOrientation),
            @"name": XP3DPInterfaceOrientationName(applicationOrientation)
        },
        @"rootViewController": @{
            @"value": @(controllerOrientation),
            @"name": XP3DPInterfaceOrientationName(controllerOrientation)
        },
        @"device": @{
            @"value": @(deviceOrientation),
            @"name": XP3DPDeviceOrientationName(deviceOrientation)
        }
    };
    return record;
}

#pragma mark - Keyboard and rotation event records

static BOOL XP3DPRectFromValue(id value, CGRect *rect) {
    if (rect == NULL || ![value isKindOfClass:NSValue.class]) {
        return NO;
    }
    const char *type = [(NSValue *)value objCType];
    if (type == NULL || strcmp(type, @encode(CGRect)) != 0) {
        return NO;
    }
    [(NSValue *)value getValue:rect size:sizeof(*rect)];
    return isfinite(rect->origin.x) && isfinite(rect->origin.y) &&
           isfinite(rect->size.width) && isfinite(rect->size.height);
}

static void XP3DPAddBounded(NSMutableArray *array, id object, NSUInteger limit) {
    if (array == nil || object == nil) {
        return;
    }
    [array addObject:object];
    while (array.count > limit) {
        [array removeObjectAtIndex:0];
    }
}

static NSDictionary *XP3DPRotationEvent(NSString *source,
                                        NSString *phase,
                                        NSString *notificationName,
                                        NSNumber *fromOrientation,
                                        NSNumber *toOrientation,
                                        NSNumber *userInfoOrientation,
                                        NSDictionary *orientation) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"timestamp"] = XP3DPTimestamp();
    record[@"uptime"] = @(XP3DPUptime());
    record[@"source"] = source ?: @"unknown";
    record[@"phase"] = phase ?: @"unknown";
    record[@"notificationName"] = notificationName ?: NSNull.null;
    record[@"fromPrimary"] = fromOrientation ?: NSNull.null;
    record[@"toPrimary"] = toOrientation ?: NSNull.null;
    record[@"userInfoOrientation"] = userInfoOrientation ?: NSNull.null;
    record[@"userInfoOrientationName"] = userInfoOrientation != nil
        ? XP3DPInterfaceOrientationName((UIInterfaceOrientation)userInfoOrientation.integerValue)
        : NSNull.null;
    record[@"orientation"] = orientation ?: @{};
    return record;
}

static NSDictionary *XP3DPCurrentOrientationForEvents(void) {
    NSArray<UIWindow *> *windows = XP3DPAllWindows();
    UIWindow *keyWindow = XP3DPKeyWindow(windows);
    return XP3DPOrientationSummary(keyWindow, keyWindow.rootViewController);
}

static void XP3DPRecordRotationNotification(NSNotification *note, BOOL willChange) {
    NSDictionary *orientation = XP3DPCurrentOrientationForEvents();
    NSNumber *currentPrimary = orientation[@"primary"];
    NSNumber *userInfoOrientation = nil;
    id userInfoValue = note.userInfo[UIApplicationStatusBarOrientationUserInfoKey];
    if ([userInfoValue isKindOfClass:NSNumber.class]) {
        userInfoOrientation = (NSNumber *)userInfoValue;
    }

    NSNumber *fromOrientation = gLastPrimaryOrientation != 0
        ? @(gLastPrimaryOrientation) : nil;
    NSNumber *toOrientation = willChange
        ? userInfoOrientation : currentPrimary;

    NSDictionary *event = XP3DPRotationEvent(@"statusBar",
                                             willChange ? @"will" : @"did",
                                             note.name,
                                             fromOrientation,
                                             toOrientation,
                                             userInfoOrientation,
                                             orientation);
    XP3DPAddBounded(gRotationEvents, event, XP3DPMaxRotationEvents);
    gLastRotationEvent = event;

    if (!willChange && currentPrimary.integerValue != 0) {
        gLastPrimaryOrientation = currentPrimary.integerValue;
    }
}

static void XP3DPRecordDeviceOrientationNotification(NSNotification *note) {
    NSDictionary *orientation = XP3DPCurrentOrientationForEvents();
    NSDictionary *event = XP3DPRotationEvent(@"device",
                                             @"did",
                                             note.name,
                                             gLastPrimaryOrientation != 0 ? @(gLastPrimaryOrientation) : nil,
                                             orientation[@"primary"],
                                             nil,
                                             orientation);
    XP3DPAddBounded(gRotationEvents, event, XP3DPMaxRotationEvents);
    gLastRotationEvent = event;
}

static void XP3DPRecordKeyboardNotification(NSNotification *note) {
    NSDictionary *userInfo = note.userInfo ?: @{};
    CGRect beginFrame = CGRectZero;
    CGRect endFrame = CGRectZero;
    BOOL hasBegin = XP3DPRectFromValue(userInfo[UIKeyboardFrameBeginUserInfoKey], &beginFrame);
    BOOL hasEnd = XP3DPRectFromValue(userInfo[UIKeyboardFrameEndUserInfoKey], &endFrame);

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"timestamp"] = XP3DPTimestamp();
    record[@"uptime"] = @(XP3DPUptime());
    record[@"name"] = note.name ?: @"";
    record[@"phase"] = [note.name containsString:@"Will"] ? @"will" :
                       ([note.name containsString:@"Did"] ? @"did" : @"unknown");
    record[@"beginFrame"] = hasBegin ? XP3DPRectDict(beginFrame) : NSNull.null;
    record[@"endFrame"] = hasEnd ? XP3DPRectDict(endFrame) : NSNull.null;
    record[@"animationDuration"] = XP3DPNumberOrNull(userInfo[UIKeyboardAnimationDurationUserInfoKey]);
    record[@"animationCurve"] = XP3DPNumberOrNull(userInfo[UIKeyboardAnimationCurveUserInfoKey]);
    record[@"isLocal"] = XP3DPNumberOrNull(userInfo[UIKeyboardIsLocalUserInfoKey]);
    record[@"orientation"] = XP3DPCurrentOrientationForEvents();

    XP3DPAddBounded(gKeyboardEvents, record, XP3DPMaxKeyboardEvents);
    gLastKeyboardEvent = record;

    if (hasEnd) {
        gLastKeyboardEndFrame = endFrame;
        gHasLastKeyboardEndFrame = YES;
        gLastKeyboardUptime = XP3DPUptime();
    }
    if ([note.name isEqualToString:UIKeyboardWillHideNotification] ||
        [note.name isEqualToString:UIKeyboardDidHideNotification]) {
        gKeyboardVisible = NO;
    } else if (hasEnd) {
        gKeyboardVisible = YES;
    }
}

static NSDictionary *XP3DPKeyboardOverlapForView(UIView *view, CGRect keyboardFrame) {
    if (view == nil || !gHasLastKeyboardEndFrame) {
        return nil;
    }
    UIScreen *screen = nil;
    if ([view isKindOfClass:UIWindow.class]) {
        screen = ((UIWindow *)view).screen;
    } else {
        screen = view.window.screen;
    }
    if (screen == nil || !XP3DPViewIsAttached(view)) {
        return nil;
    }
    id<UICoordinateSpace> screenSpace = screen.coordinateSpace;
    CGRect viewFrame = [view convertRect:view.bounds toCoordinateSpace:screenSpace];
    CGRect intersection = CGRectIntersection(viewFrame, keyboardFrame);
    if (CGRectIsNull(intersection)) {
        intersection = CGRectZero;
    }
    CGFloat viewArea = MAX(0.0, viewFrame.size.width) * MAX(0.0, viewFrame.size.height);
    CGFloat intersectionArea = MAX(0.0, intersection.size.width) *
                               MAX(0.0, intersection.size.height);
    return @{
        @"viewFrameInScreen": XP3DPRectDict(viewFrame),
        @"intersection": XP3DPRectDict(intersection),
        @"intersects": @(!CGRectIsEmpty(intersection)),
        @"overlapFraction": viewArea > 0.0 ? XP3DPNum(intersectionArea / viewArea) : NSNull.null
    };
}

static NSDictionary *XP3DPKeyboardState(UIWindow *keyWindow,
                                        NSArray<UIWindow *> *windows) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"lastEvent"] = gLastKeyboardEvent ?: NSNull.null;
    record[@"hasEndFrame"] = @(gHasLastKeyboardEndFrame);
    record[@"visibleEstimate"] = @(gKeyboardVisible && gHasLastKeyboardEndFrame);
    if (gHasLastKeyboardEndFrame) {
        record[@"endFrame"] = XP3DPRectDict(gLastKeyboardEndFrame);
        record[@"eventAgeSeconds"] = XP3DPNum(MAX(0.0, XP3DPUptime() - gLastKeyboardUptime));
    } else {
        record[@"endFrame"] = NSNull.null;
        record[@"eventAgeSeconds"] = NSNull.null;
    }

    if (gHasLastKeyboardEndFrame && keyWindow != nil) {
        record[@"keyWindowOverlap"] = XP3DPKeyboardOverlapForView(keyWindow,
                                                                   gLastKeyboardEndFrame) ?: NSNull.null;
        UIView *rootView = keyWindow.rootViewController.viewIfLoaded;
        NSArray<NSDictionary *> *renderEntries = XP3DPFindRenderViews(rootView);
        NSMutableArray *renderOverlaps = [NSMutableArray array];
        for (NSDictionary *entry in renderEntries) {
            NSDictionary *overlap = XP3DPKeyboardOverlapForView(entry[@"view"],
                                                                 gLastKeyboardEndFrame);
            if (overlap != nil) {
                [renderOverlaps addObject:@{
                    @"path": entry[@"path"],
                    @"overlap": overlap
                }];
            }
        }
        record[@"renderViewOverlaps"] = renderOverlaps;
    } else {
        record[@"keyWindowOverlap"] = NSNull.null;
        record[@"renderViewOverlaps"] = @[];
    }
    record[@"windowCount"] = @(windows.count);
    return record;
}

#pragma mark - Info.plist display metadata

static NSDictionary *XP3DPBooleanKey(NSDictionary *info, NSString *key) {
    id value = info[key];
    if (value == nil) {
        return @{@"present": @NO};
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return @{
            @"present": @YES,
            @"value": value,
            @"bool": @([(NSNumber *)value boolValue])
        };
    }
    return @{
        @"present": @YES,
        @"type": NSStringFromClass([value class]) ?: @"<unknown>"
    };
}

static NSDictionary *XP3DPStringKey(NSDictionary *info, NSString *key) {
    id value = info[key];
    if (value == nil) {
        return @{@"present": @NO};
    }
    if ([value isKindOfClass:NSString.class]) {
        NSNumber *numeric = XP3DPOrientationNumberFromString(value);
        NSMutableDictionary *record = [@{
            @"present": @YES,
            @"value": value
        } mutableCopy];
        if (numeric != nil) {
            record[@"numeric"] = numeric;
            record[@"numericName"] = XP3DPInterfaceOrientationName(
                (UIInterfaceOrientation)numeric.integerValue);
        }
        return record;
    }
    return @{
        @"present": @YES,
        @"type": NSStringFromClass([value class]) ?: @"<unknown>"
    };
}

static NSDictionary *XP3DPStringPresenceKey(NSDictionary *info, NSString *key) {
    id value = info[key];
    if (value == nil) {
        return @{@"present": @NO};
    }
    if ([value isKindOfClass:NSString.class]) {
        return @{
            @"present": @YES,
            @"length": @([(NSString *)value length]),
            @"valueRedacted": @YES
        };
    }
    return @{
        @"present": @YES,
        @"type": NSStringFromClass([value class]) ?: @"<unknown>",
        @"valueRedacted": @YES
    };
}

static NSDictionary *XP3DPOrientationArrayKey(NSDictionary *info, NSString *key) {
    id value = info[key];
    if (value == nil) {
        return @{@"present": @NO};
    }
    if (![value isKindOfClass:NSArray.class]) {
        return @{
            @"present": @YES,
            @"type": NSStringFromClass([value class]) ?: @"<unknown>"
        };
    }
    NSArray *array = (NSArray *)value;
    NSMutableArray *values = [NSMutableArray array];
    for (id item in array) {
        if ([item isKindOfClass:NSString.class]) {
            [values addObject:item];
        }
    }
    NSUInteger mask = XP3DPMaskFromOrientationStrings(values);
    return @{
        @"present": @YES,
        @"values": values,
        @"count": @(values.count),
        @"mask": @(mask),
        @"maskHex": [NSString stringWithFormat:@"0x%lx", (unsigned long)mask],
        @"maskNames": XP3DPMaskNames(mask)
    };
}

static NSDictionary *XP3DPLaunchScreenDictionarySummary(id value) {
    if (value == nil) {
        return @{@"present": @NO};
    }
    if (![value isKindOfClass:NSDictionary.class]) {
        return @{
            @"present": @YES,
            @"type": NSStringFromClass([value class]) ?: @"<unknown>"
        };
    }
    NSDictionary *dictionary = (NSDictionary *)value;
    NSArray<NSString *> *keys = [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        id item = dictionary[key];
        if ([item isKindOfClass:NSNumber.class]) {
            details[key] = @{
                @"type": @"number",
                @"bool": @([(NSNumber *)item boolValue])
            };
        } else if ([item isKindOfClass:NSString.class]) {
            // Launch-screen asset names are resource names; record type/length
            // only, never the string itself.
            details[key] = @{
                @"type": @"string",
                @"length": @([(NSString *)item length]),
                @"valueRedacted": @YES
            };
        } else if ([item isKindOfClass:NSArray.class]) {
            details[key] = @{
                @"type": @"array",
                @"count": @([(NSArray *)item count])
            };
        } else if ([item isKindOfClass:NSDictionary.class]) {
            details[key] = @{
                @"type": @"dictionary",
                @"keyCount": @([(NSDictionary *)item count])
            };
        } else {
            details[key] = @{
                @"type": NSStringFromClass([item class]) ?: @"<unknown>"
            };
        }
    }
    NSMutableDictionary *record = [@{
        @"present": @YES,
        @"keys": keys,
        @"details": details
    } mutableCopy];
    id respectsSafeArea = dictionary[@"UIImageRespectsSafeAreaInsets"];
    if ([respectsSafeArea isKindOfClass:NSNumber.class]) {
        record[@"UIImageRespectsSafeAreaInsets"] = @([(NSNumber *)respectsSafeArea boolValue]);
    }
    return record;
}

static NSDictionary *XP3DPLaunchImagesSummary(id value) {
    if (value == nil) {
        return @{@"present": @NO};
    }
    if (![value isKindOfClass:NSArray.class]) {
        return @{
            @"present": @YES,
            @"type": NSStringFromClass([value class]) ?: @"<unknown>"
        };
    }
    NSArray *array = (NSArray *)value;
    NSMutableArray *entries = [NSMutableArray array];
    NSUInteger limit = MIN(array.count, (NSUInteger)32);
    for (NSUInteger i = 0; i < limit; i++) {
        id item = array[i];
        if (![item isKindOfClass:NSDictionary.class]) {
            [entries addObject:@{@"type": NSStringFromClass([item class]) ?: @"<unknown>"}];
            continue;
        }
        NSDictionary *dictionary = (NSDictionary *)item;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        // UILaunchImageName is a resource filename; only presence is recorded.
        entry[@"hasName"] = @([dictionary[@"UILaunchImageName"] isKindOfClass:NSString.class]);
        entry[@"orientation"] = XP3DPStringOrNull(dictionary[@"UILaunchImageOrientation"]);
        entry[@"minimumOSVersion"] = XP3DPStringOrNull(dictionary[@"UILaunchImageMinimumOSVersion"]);
        entry[@"size"] = XP3DPStringOrNull(dictionary[@"UILaunchImageSize"]);
        entry[@"subtype"] = XP3DPStringOrNull(dictionary[@"UILaunchImageSubtype"]);
        entry[@"idiom"] = XP3DPStringOrNull(dictionary[@"UILaunchImageIdiom"]);
        [entries addObject:entry];
    }
    return @{
        @"present": @YES,
        @"count": @(array.count),
        @"entries": entries,
        @"truncated": @(array.count > limit)
    };
}

static NSDictionary *XP3DPSceneManifestSummary(id value) {
    if (value == nil) {
        return @{@"present": @NO};
    }
    if (![value isKindOfClass:NSDictionary.class]) {
        return @{
            @"present": @YES,
            @"type": NSStringFromClass([value class]) ?: @"<unknown>"
        };
    }
    NSDictionary *manifest = (NSDictionary *)value;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"present"] = @YES;
    id multiple = manifest[@"UIApplicationSupportsMultipleScenes"];
    if ([multiple isKindOfClass:NSNumber.class]) {
        record[@"supportsMultipleScenes"] = @([(NSNumber *)multiple boolValue]);
    } else {
        record[@"supportsMultipleScenes"] = NSNull.null;
    }
    id configurations = manifest[@"UISceneConfigurations"];
    if ([configurations isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)configurations;
        record[@"configurationRoles"] = [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (NSString *role in dictionary) {
            id configurationsForRole = dictionary[role];
            counts[role] = [configurationsForRole isKindOfClass:NSArray.class]
                ? @([(NSArray *)configurationsForRole count]) : @0;
        }
        record[@"configurationCounts"] = counts;
    } else {
        record[@"configurationRoles"] = @[];
        record[@"configurationCounts"] = @{};
    }
    return record;
}

static NSDictionary *XP3DPAnalyzeLaunchMetadata(NSDictionary *info) {
    BOOL legacyImages = info[@"UILaunchImages"] != nil ||
                        info[@"UILaunchImageFile"] != nil ||
                        info[@"UILaunchImages~ipad"] != nil ||
                        info[@"UILaunchImageFile~ipad"] != nil ||
                        info[@"UILaunchImageFile~iphone"] != nil ||
                        info[@"UILaunchImages~iphone"] != nil;
    BOOL storyboard = info[@"UILaunchStoryboardName"] != nil;
    BOOL launchScreenDictionary = info[@"UILaunchScreen"] != nil;
    BOOL iPadOverride = info[@"UISupportedInterfaceOrientations~ipad"] != nil;
    BOOL iPhoneOverride = info[@"UISupportedInterfaceOrientations~iphone"] != nil;

    BOOL supportsPad = NO;
    id family = info[@"UIDeviceFamily"];
    if ([family isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)family) {
            if ([item isKindOfClass:NSNumber.class] && [(NSNumber *)item integerValue] == 2) {
                supportsPad = YES;
                break;
            }
        }
    } else if ([family isKindOfClass:NSNumber.class]) {
        supportsPad = [(NSNumber *)family integerValue] == 2;
    }

    NSString *mode = @"none-or-other";
    NSUInteger modernCount = (storyboard ? 1UL : 0UL) + (launchScreenDictionary ? 1UL : 0UL);
    if (modernCount > 1) {
        mode = @"multiple-modern";
    } else if (storyboard) {
        mode = @"storyboard";
    } else if (launchScreenDictionary) {
        mode = @"info-plist-dictionary";
    } else if (legacyImages) {
        mode = @"legacy-images";
    }

    NSMutableArray *notes = [NSMutableArray array];
    [notes addObject:@"This probe is read-only; it does not alter launch metadata, layout, transforms, or game scaling."];
    [notes addObject:@"Launch resource-name strings are redacted; presence, count, orientation, size, and minimum-OS metadata are retained."];
    [notes addObject:@"UILaunchScreen is a plist-only modern launch configuration (iOS 14+), an alternative to a storyboard, but it is not assumed to change compatibility geometry; identical A/B runtime evidence is required."];
    [notes addObject:@"No fullscreen, content-coverage, or visual-direction conclusion is made from Info.plist keys."];

    return @{
        @"usesLegacyLaunchImages": @(legacyImages),
        @"usesLaunchStoryboard": @(storyboard),
        @"usesLaunchScreenDictionary": @(launchScreenDictionary),
        @"modernLaunchConfiguration": @(storyboard || launchScreenDictionary),
        @"launchMode": mode,
        @"supportsIPad": @(supportsPad),
        @"iPadOrientationOverridePresent": @(iPadOverride),
        @"iPhoneOrientationOverridePresent": @(iPhoneOverride),
        @"UIRequiresFullScreen": XP3DPBooleanKey(info, @"UIRequiresFullScreen"),
        @"notes": notes
    };
}

static NSDictionary *XP3DPInfoSummary(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"CFBundleShortVersionString"] = XP3DPStringOrNull(info[@"CFBundleShortVersionString"]);
    record[@"CFBundleVersion"] = XP3DPStringOrNull(info[@"CFBundleVersion"]);
    record[@"MinimumOSVersion"] = XP3DPStringOrNull(info[@"MinimumOSVersion"]);
    record[@"DTSDKName"] = XP3DPStringOrNull(info[@"DTSDKName"]);
    record[@"DTPlatformVersion"] = XP3DPStringOrNull(info[@"DTPlatformVersion"]);
    record[@"CFBundleSupportedPlatforms"] = XP3DPStringArrayOrNull(info[@"CFBundleSupportedPlatforms"]);
    record[@"UIDeviceFamily"] = XP3DPNumberArrayOrNull(info[@"UIDeviceFamily"]);
    record[@"UIRequiresFullScreen"] = XP3DPBooleanKey(info, @"UIRequiresFullScreen");
    record[@"UIStatusBarHidden"] = XP3DPBooleanKey(info, @"UIStatusBarHidden");
    record[@"UIViewControllerBasedStatusBarAppearance"] =
        XP3DPBooleanKey(info, @"UIViewControllerBasedStatusBarAppearance");
    record[@"UIInterfaceOrientation"] = XP3DPStringKey(info, @"UIInterfaceOrientation");
    record[@"UIInterfaceOrientation~ipad"] = XP3DPStringKey(info, @"UIInterfaceOrientation~ipad");
    record[@"UIInterfaceOrientation~iphone"] = XP3DPStringKey(info, @"UIInterfaceOrientation~iphone");
    record[@"UISupportedInterfaceOrientations"] =
        XP3DPOrientationArrayKey(info, @"UISupportedInterfaceOrientations");
    record[@"UISupportedInterfaceOrientations~ipad"] =
        XP3DPOrientationArrayKey(info, @"UISupportedInterfaceOrientations~ipad");
    record[@"UISupportedInterfaceOrientations~iphone"] =
        XP3DPOrientationArrayKey(info, @"UISupportedInterfaceOrientations~iphone");

    record[@"UILaunchStoryboardName"] = XP3DPStringPresenceKey(info, @"UILaunchStoryboardName");
    record[@"UILaunchImageFile"] = XP3DPStringPresenceKey(info, @"UILaunchImageFile");
    record[@"UILaunchImageFile~ipad"] = XP3DPStringPresenceKey(info, @"UILaunchImageFile~ipad");
    record[@"UILaunchImageFile~iphone"] = XP3DPStringPresenceKey(info, @"UILaunchImageFile~iphone");
    record[@"UILaunchImages"] = XP3DPLaunchImagesSummary(info[@"UILaunchImages"]);
    record[@"UILaunchImages~ipad"] = XP3DPLaunchImagesSummary(info[@"UILaunchImages~ipad"]);
    record[@"UILaunchImages~iphone"] = XP3DPLaunchImagesSummary(info[@"UILaunchImages~iphone"]);
    record[@"UILaunchScreen"] = XP3DPLaunchScreenDictionarySummary(info[@"UILaunchScreen"]);
    record[@"UIApplicationSceneManifest"] =
        XP3DPSceneManifestSummary(info[@"UIApplicationSceneManifest"]);
    record[@"launchMetadataAnalysis"] = XP3DPAnalyzeLaunchMetadata(info);
    record[@"readPolicy"] = @{
        @"source": @"NSBundle.mainBundle.infoDictionary",
        @"launchResourceNamesRedacted": @YES,
        @"userDataRead": @NO
    };
    return record;
}

#pragma mark - Process/runtime information

static NSDictionary *XP3DPProcessSummary(void) {
    UIDevice *device = UIDevice.currentDevice;
    UIApplication *application = UIApplication.sharedApplication;
    NSProcessInfo *process = NSProcessInfo.processInfo;

    uint32_t imageCount = _dyld_image_count();
    int cpuType = 0;
    int cpuSubtype = 0;
    BOOL executable64 = NO;
    const struct mach_header *header = _dyld_get_image_header(0);
    if (header != NULL) {
        if (header->magic == MH_MAGIC_64) {
            const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
            cpuType = header64->cputype;
            cpuSubtype = header64->cpusubtype;
            executable64 = YES;
        } else {
            cpuType = header->cputype;
            cpuSubtype = header->cpusubtype;
            executable64 = NO;
        }
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"deviceModel"] = XP3DPStringOrNull(device.model);
    record[@"deviceUserInterfaceIdiom"] = @(device.userInterfaceIdiom);
    record[@"deviceUserInterfaceIdiomName"] = XP3DPIdiomName(device.userInterfaceIdiom);
    record[@"systemName"] = XP3DPStringOrNull(device.systemName);
    record[@"systemVersion"] = XP3DPStringOrNull(device.systemVersion);
    record[@"deviceOrientation"] = @(device.orientation);
    record[@"deviceOrientationName"] = XP3DPDeviceOrientationName(device.orientation);
    record[@"generatesDeviceOrientationNotifications"] =
        @(device.generatesDeviceOrientationNotifications);
    record[@"applicationState"] = @(application.applicationState);
    record[@"applicationStateName"] = XP3DPApplicationStateName(application.applicationState);
    record[@"operatingSystemVersionString"] = XP3DPStringOrNull(process.operatingSystemVersionString);
    record[@"systemUptime"] = @(process.systemUptime);
    record[@"processorCount"] = @(process.processorCount);
    record[@"dyldImageCount"] = @(imageCount);
    record[@"mainExecutableCPUType"] = @(cpuType);
    record[@"mainExecutableCPUSubtype"] = @(cpuSubtype);
    record[@"mainExecutableIs64Bit"] = @(executable64);
    record[@"screenCount"] = @(UIScreen.screens.count);
    record[@"notes"] = @[
        @"deviceModel is the generic UIKit model (for example iPhone/iPad), not the user's device name.",
        @"No locale, time zone, user name, file name, or app-container path is recorded."
    ];
    return record;
}

#pragma mark - Time

static NSString *XP3DPTimestamp(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                  NSISO8601DateFormatWithFractionalSeconds;
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [formatter stringFromDate:[NSDate date]] ?: @"";
}

static NSTimeInterval XP3DPUptime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

#pragma mark - Coverage analysis

static CGSize XP3DPSizeFromDict(id object) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return CGSizeZero;
    }
    NSDictionary *dictionary = (NSDictionary *)object;
    NSNumber *width = dictionary[@"width"];
    NSNumber *height = dictionary[@"height"];
    if (![width isKindOfClass:NSNumber.class] || ![height isKindOfClass:NSNumber.class]) {
        return CGSizeZero;
    }
    return CGSizeMake(width.doubleValue, height.doubleValue);
}

static BOOL XP3DPRectCoversRect(CGRect outer, CGRect inner, CGFloat tolerance) {
    if (CGRectIsNull(outer) || CGRectIsNull(inner)) {
        return NO;
    }
    return fabs(CGRectGetMinX(outer)) <= tolerance &&
           fabs(CGRectGetMinY(outer)) <= tolerance &&
           fabs(CGRectGetWidth(outer) - CGRectGetWidth(inner)) <= tolerance &&
           fabs(CGRectGetHeight(outer) - CGRectGetHeight(inner)) <= tolerance;
}

static NSDictionary *XP3DPSizeNativeComparison(CGSize size, CGSize native) {
    if (size.width <= 0.0 || size.height <= 0.0 ||
        native.width <= 0.0 || native.height <= 0.0) {
        return @{@"available": @NO};
    }
    BOOL same = fabs(size.width - native.width) <= 1.0 &&
                fabs(size.height - native.height) <= 1.0;
    BOOL swapped = fabs(size.width - native.height) <= 1.0 &&
                   fabs(size.height - native.width) <= 1.0;
    return @{
        @"available": @YES,
        @"size": XP3DPSizeDict(size),
        @"nativeSize": XP3DPSizeDict(native),
        @"sameOrientation": @(same),
        @"swappedOrientation": @(swapped),
        @"matches": @(same || swapped)
    };
}

static id XP3DPMethodProbeValue(NSArray *probes, NSString *selector, NSString *kind) {
    if (![probes isKindOfClass:NSArray.class]) {
        return nil;
    }
    for (NSDictionary *probe in probes) {
        if (![probe isKindOfClass:NSDictionary.class]) {
            continue;
        }
        if ([probe[@"selector"] isEqual:selector] &&
            [probe[@"status"] isEqual:@"ok"] &&
            [probe[@"kind"] isEqual:kind]) {
            return probe[@"value"];
        }
    }
    return nil;
}

static id XP3DPMethodProbeAnyNumber(NSArray *probes, NSString *selector) {
    if (![probes isKindOfClass:NSArray.class]) {
        return nil;
    }
    for (NSDictionary *probe in probes) {
        if (![probe isKindOfClass:NSDictionary.class] ||
            ![probe[@"selector"] isEqual:selector] ||
            ![probe[@"status"] isEqual:@"ok"]) {
            continue;
        }
        NSString *kind = probe[@"kind"];
        if ([kind isEqual:@"CGFloat"] || [kind isEqual:@"NSInteger"] ||
            [kind isEqual:@"NSUInteger"] || [kind isEqual:@"int"] ||
            [kind isEqual:@"unsignedInt"] || [kind isEqual:@"float"] ||
            [kind isEqual:@"BOOL"]) {
            return probe[@"value"];
        }
    }
    return nil;
}

static id XP3DPMethodProbeStatus(NSArray *probes, NSString *selector) {
    if (![probes isKindOfClass:NSArray.class]) {
        return NSNull.null;
    }
    for (NSDictionary *probe in probes) {
        if ([probe isKindOfClass:NSDictionary.class] &&
            [probe[@"selector"] isEqual:selector]) {
            return probe[@"status"] ?: NSNull.null;
        }
    }
    return NSNull.null;
}

static NSDictionary *XP3DPCoverageForRecord(NSDictionary *record) {
    NSMutableDictionary *coverage = [NSMutableDictionary dictionary];
    coverage[@"available"] = @NO;
    coverage[@"note"] = @"No window/root/render view was available at this snapshot.";
    coverage[@"content"] = @{
        @"measured": @NO,
        @"note": @"Drawable geometry is not content coverage. The probe does not read pixels or game canvas."
    };
    coverage[@"direction"] = @{
        @"contentDirectionVerified": @NO,
        @"note": @"Orientation sources and convertRect mappings are recorded; rendered content direction requires visual/fixture verification."
    };
    coverage[@"conclusion"] = @"not-proven-drawable-geometry-only";

    NSDictionary *screen = [record[@"screen"] isKindOfClass:NSDictionary.class]
        ? record[@"screen"] : nil;
    NSArray *windows = [record[@"windows"] isKindOfClass:NSArray.class]
        ? record[@"windows"] : @[];
    NSDictionary *window = nil;
    for (NSDictionary *candidate in windows) {
        if ([candidate isKindOfClass:NSDictionary.class] &&
            [candidate[@"keyWindow"] boolValue]) {
            window = candidate;
            break;
        }
    }
    if (window == nil && windows.count > 0 &&
        [windows.firstObject isKindOfClass:NSDictionary.class]) {
        window = windows.firstObject;
    }
    if (screen == nil || window == nil) {
        return coverage;
    }

    coverage[@"available"] = @YES;
    coverage[@"note"] = @"Drawable coverage only; content coverage and visual direction are not measured.";
    NSDictionary *rootView = [window[@"rootView"] isKindOfClass:NSDictionary.class]
        ? window[@"rootView"] : nil;
    NSArray *renderViews = [window[@"renderViews"] isKindOfClass:NSArray.class]
        ? window[@"renderViews"] : @[];
    NSDictionary *renderView = renderViews.count > 0 &&
        [renderViews.firstObject isKindOfClass:NSDictionary.class]
        ? renderViews.firstObject : nil;
    NSDictionary *renderSummary = renderView != nil &&
        [renderView[@"summary"] isKindOfClass:NSDictionary.class]
        ? renderView[@"summary"] : nil;
    NSArray *probes = renderView != nil &&
        [renderView[@"methodProbes"] isKindOfClass:NSArray.class]
        ? renderView[@"methodProbes"] : @[];

    CGRect screenRect = CGRectZero;
    CGRect nativeRect = CGRectZero;
    XP3DPRectFromObject(screen[@"bounds"], &screenRect);
    XP3DPRectFromObject(screen[@"nativeBounds"], &nativeRect);
    CGSize screenSize = screenRect.size;
    CGSize nativeSize = nativeRect.size;

    CGRect windowFrame = CGRectZero;
    CGRect windowBounds = CGRectZero;
    XP3DPRectFromObject(window[@"frame"], &windowFrame);
    XP3DPRectFromObject(window[@"bounds"], &windowBounds);
    CGRect rootBounds = CGRectZero;
    CGRect rootFrame = CGRectZero;
    if (rootView != nil) {
        XP3DPRectFromObject(rootView[@"bounds"], &rootBounds);
        XP3DPRectFromObject(rootView[@"frame"], &rootFrame);
    }
    CGRect renderBounds = CGRectZero;
    CGRect layerBounds = CGRectZero;
    if (renderSummary != nil) {
        XP3DPRectFromObject(renderSummary[@"bounds"], &renderBounds);
        NSDictionary *layer = [renderSummary[@"layer"] isKindOfClass:NSDictionary.class]
            ? renderSummary[@"layer"] : nil;
        if (layer != nil) {
            XP3DPRectFromObject(layer[@"bounds"], &layerBounds);
        }
    }

    // Prefer the layer's contentsScale for drawable backing pixels; fall back
    // to the view content scale only when the layer value is unavailable.
    CGFloat contentsScale = 0.0;
    if (renderSummary != nil) {
        NSDictionary *layer = [renderSummary[@"layer"] isKindOfClass:NSDictionary.class]
            ? renderSummary[@"layer"] : nil;
        id layerScale = layer[@"contentsScale"];
        if ([layerScale isKindOfClass:NSNumber.class]) {
            contentsScale = [(NSNumber *)layerScale doubleValue];
        } else {
            id viewScale = renderSummary[@"contentScaleFactor"];
            if ([viewScale isKindOfClass:NSNumber.class]) {
                contentsScale = [(NSNumber *)viewScale doubleValue];
            }
        }
    }
    CGSize layerBacking = CGSizeMake(layerBounds.size.width * contentsScale,
                                     layerBounds.size.height * contentsScale);

    id surfaceValue = XP3DPMethodProbeValue(probes, @"surfaceSize", @"CGSize");
    id backingValue = XP3DPMethodProbeValue(probes, @"backingSize", @"CGSize");
    CGSize surfaceSize = XP3DPSizeFromDict(surfaceValue);
    CGSize backingSize = XP3DPSizeFromDict(backingValue);

    NSDictionary *renderConvert = renderView != nil &&
        [renderView[@"convert"] isKindOfClass:NSDictionary.class]
        ? renderView[@"convert"] : nil;
    CGRect glToScreen = CGRectZero;
    CGRect glToWindow = CGRectZero;
    CGRect glToRoot = CGRectZero;
    BOOL hasGLToScreen = renderConvert != nil &&
        XP3DPRectFromObject(renderConvert[@"viewBoundsToScreen"], &glToScreen);
    BOOL hasGLToWindow = renderConvert != nil &&
        XP3DPRectFromObject(renderConvert[@"viewBoundsToWindowView"], &glToWindow);
    BOOL hasGLToRoot = renderConvert != nil &&
        XP3DPRectFromObject(renderConvert[@"viewBoundsToRootView"], &glToRoot);

    BOOL windowCoversScreen = XP3DPRectCoversRect(windowFrame, screenRect, 0.5);
    BOOL rootCoversWindow = rootView != nil && XP3DPRectCoversRect(rootFrame,
                                                                   CGRectMake(0, 0,
                                                                              windowBounds.size.width,
                                                                              windowBounds.size.height),
                                                                   0.5);
    BOOL glCoversWindow = renderView != nil && hasGLToWindow &&
        XP3DPRectCoversRect(glToWindow,
                            CGRectMake(0, 0, windowBounds.size.width, windowBounds.size.height),
                            0.5);
    BOOL glCoversRoot = renderView != nil && rootView != nil && hasGLToRoot &&
        XP3DPRectCoversRect(glToRoot, rootBounds, 0.5);
    BOOL glCoversScreen = renderView != nil && hasGLToScreen &&
        XP3DPRectCoversRect(glToScreen, screenRect, 0.5);

    coverage[@"screen"] = @{
        @"bounds": XP3DPRectDict(screenRect),
        @"nativeBounds": XP3DPRectDict(nativeRect),
        @"scale": screen[@"scale"] ?: NSNull.null,
        @"nativeScale": screen[@"nativeScale"] ?: NSNull.null
    };
    coverage[@"window"] = @{
        @"index": window[@"index"] ?: NSNull.null,
        @"class": window[@"class"] ?: NSNull.null,
        @"frame": XP3DPRectDict(windowFrame),
        @"bounds": XP3DPRectDict(windowBounds)
    };
    coverage[@"views"] = @{
        @"root": rootView ?: NSNull.null,
        @"renderView": renderSummary ?: NSNull.null,
        @"renderPath": renderView != nil ? (renderView[@"path"] ?: NSNull.null) : NSNull.null,
        @"rootViewAvailable": @(rootView != nil),
        @"renderViewAvailable": @(renderView != nil)
    };

    coverage[@"drawable"] = @{
        @"unitsNote": @"screen/window/root/render bounds are points; nativeBounds/surface/backing/layerBacking are pixels when available.",
        @"screenPoints": XP3DPSizeDict(screenSize),
        @"screenNativePixels": XP3DPSizeDict(nativeSize),
        @"windowFramePoints": XP3DPRectDict(windowFrame),
        @"windowBoundsPoints": XP3DPRectDict(windowBounds),
        @"rootFramePoints": rootView != nil ? XP3DPRectDict(rootFrame) : NSNull.null,
        @"rootBoundsPoints": rootView != nil ? XP3DPRectDict(rootBounds) : NSNull.null,
        @"renderBoundsPoints": renderView != nil ? XP3DPRectDict(renderBounds) : NSNull.null,
        @"layerBoundsPoints": renderView != nil ? XP3DPRectDict(layerBounds) : NSNull.null,
        @"layerContentsScale": renderView != nil ? XP3DPNum(contentsScale) : NSNull.null,
        @"layerBackingPixels": renderView != nil ? XP3DPSizeDict(layerBacking) : NSNull.null,
        @"surfaceSize": surfaceValue ?: NSNull.null,
        @"backingSize": backingValue ?: NSNull.null,
        @"widthProbe": XP3DPMethodProbeAnyNumber(probes, @"width") ?: NSNull.null,
        @"heightProbe": XP3DPMethodProbeAnyNumber(probes, @"height") ?: NSNull.null,
        @"methodProbeStatus": @{
            @"surfaceSize": XP3DPMethodProbeStatus(probes, @"surfaceSize"),
            @"backingSize": XP3DPMethodProbeStatus(probes, @"backingSize"),
            @"width": XP3DPMethodProbeStatus(probes, @"width"),
            @"height": XP3DPMethodProbeStatus(probes, @"height")
        },
        @"windowCoversScreenPoints": @(windowCoversScreen),
        @"rootCoversWindowPoints": @(rootCoversWindow),
        @"renderCoversRootPoints": @(glCoversRoot),
        @"renderCoversWindowPoints": @(glCoversWindow),
        @"renderCoversScreenPoints": @(glCoversScreen),
        @"renderToScreen": hasGLToScreen ? XP3DPRectDict(glToScreen) : NSNull.null,
        @"renderToWindow": hasGLToWindow ? XP3DPRectDict(glToWindow) : NSNull.null,
        @"renderToRoot": hasGLToRoot ? XP3DPRectDict(glToRoot) : NSNull.null,
        @"layerBackingMatchesNativePixels": renderView != nil
            ? XP3DPSizeNativeComparison(layerBacking, nativeSize) : @{@"available": @NO},
        @"surfaceMatchesNativePixels": surfaceValue != nil
            ? XP3DPSizeNativeComparison(surfaceSize, nativeSize) : @{@"available": @NO},
        @"backingMatchesNativePixels": backingValue != nil
            ? XP3DPSizeNativeComparison(backingSize, nativeSize) : @{@"available": @NO}
    };

    NSDictionary *orientation = [record[@"orientation"] isKindOfClass:NSDictionary.class]
        ? record[@"orientation"] : @{};
    coverage[@"direction"] = @{
        @"contentDirectionVerified": @NO,
        @"primaryInterfaceOrientation": orientation[@"primary"] ?: NSNull.null,
        @"primaryInterfaceOrientationName": orientation[@"primaryName"] ?: NSNull.null,
        @"allInterfaceSourcesAgree": orientation[@"allInterfaceSourcesAgree"] ?: NSNull.null,
        @"deviceAgreesWithPrimary": orientation[@"deviceAgreesWithPrimary"] ?: NSNull.null,
        @"sources": orientation[@"sources"] ?: @{},
        @"note": @"Orientation enums and convertRect mappings are recorded; they do not prove rendered content direction."
    };
    coverage[@"conclusion"] = @"drawable-geometry-only; content and visual direction not measured";
    return coverage;
}

#pragma mark - JSON output

static NSDictionary *XP3DPCountTriggers(NSArray<NSDictionary *> *history) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSDictionary *record in history) {
        NSString *trigger = [record[@"trigger"] isKindOfClass:NSString.class]
            ? record[@"trigger"] : @"unknown";
        NSNumber *count = counts[trigger] ?: @0;
        counts[trigger] = @(count.unsignedIntegerValue + 1);
    }
    return counts;
}

static NSDictionary *XP3DPBuildSummary(void) {
    NSDictionary *first = gHistory.count > 0 ? gHistory.firstObject : nil;
    NSDictionary *last = gHistory.count > 0 ? gHistory.lastObject : nil;
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"recordCount"] = @(gHistory.count);
    summary[@"detailRecordCount"] = @(gDetailCount);
    summary[@"firstTimestamp"] = first[@"timestamp"] ?: NSNull.null;
    summary[@"lastTimestamp"] = last[@"timestamp"] ?: NSNull.null;
    summary[@"durationSeconds"] = @(MAX(0.0, XP3DPUptime() - gStartUptime));
    summary[@"triggers"] = XP3DPCountTriggers(gHistory);
    summary[@"truncated"] = @(gTruncated);
    summary[@"droppedRecords"] = @(gDropped);
    summary[@"historyTrimmedForSize"] = @(gHistoryTrimmed);
    summary[@"recordsTrimmedForSize"] = @(gTrimmedForSize);
    summary[@"recentKeyboardEventCount"] = @(gKeyboardEvents.count);
    summary[@"recentRotationEventCount"] = @(gRotationEvents.count);
    summary[@"latestCoverage"] = gLastRecord[@"coverage"] ?: NSNull.null;
    summary[@"latestOrientation"] = gLastRecord[@"orientation"] ?: NSNull.null;
    summary[@"interpretation"] = @[
        @"windowCoversScreenPoints / rootCoversWindowPoints / renderCovers* describe drawable geometry only.",
        @"surfaceSize/backingSize/width/height are null unless a validated NSInvocation getter returned them.",
        @"content.measured=false and direction.contentDirectionVerified=false are intentional: the probe does not read pixels or visible text.",
        @"A full drawable does not prove full content; a full content does not prove upright visual direction."
    ];
    return summary;
}

static NSDictionary *XP3DPBuildPayload(void) {
    NSMutableDictionary *probe = [NSMutableDictionary dictionary];
    probe[@"name"] = @"XP3Compat DisplayProbe";
    probe[@"version"] = @"1.0.0";
    probe[@"schema"] = @2;
    probe[@"built"] = [NSString stringWithFormat:@"%s %s", __DATE__, __TIME__];
    probe[@"readOnly"] = @YES;
    probe[@"publicAPIs"] = @[@"UIKit", @"Foundation", @"QuartzCore (UIView.layer)", @"dyld"];
    probe[@"safety"] = @{
        @"methodSwizzling": @NO,
        @"methodReplacement": @NO,
        @"layoutForcing": @NO,
        @"createsWindow": @NO,
        @"createsPresenterOrController": @NO,
        @"displayTransformOrScaleOverride": @NO,
        @"gameOrEngineHooks": @NO,
        @"privateAPIs": @NO,
        @"readsPixelsOrScreenshots": @NO,
        @"readsViewText": @NO,
        @"readsUserFiles": @NO,
        @"writesOnlyFileName": @"XP3CompatDisplayProbe.json"
    };
    probe[@"limits"] = @{
        @"maxHistory": @(XP3DPMaxHistory),
        @"maxDetailSnapshots": @(XP3DPMaxDetailSnapshots),
        @"maxHierarchyNodes": @(XP3DPMaxHierarchyNodes),
        @"maxHierarchyDepth": @(XP3DPMaxHierarchyDepth),
        @"maxRenderViewsPerWindow": @(XP3DPMaxRenderViews),
        @"maxKeyboardEvents": @(XP3DPMaxKeyboardEvents),
        @"maxRotationEvents": @(XP3DPMaxRotationEvents),
        @"maxJSONBytes": @(XP3DPMaxJSONBytes),
        @"timerSeconds": @{
            @"rapidPhase": @(XP3DPRapidPhase),
            @"rapidInterval": @0.25,
            @"mediumPhase": @(XP3DPMediumPhase),
            @"mediumInterval": @1.0,
            @"totalDuration": @(XP3DPTotalDuration),
            @"slowInterval": @5.0
        }
    };
    probe[@"limitations"] = @[
        @"Geometry-only: no pixels, screenshots, view text, files, saves, or user content are read.",
        @"surfaceSize/backingSize/width/height are read only through validated NSMethodSignature/NSInvocation getters; missing or unsupported returns stay null.",
        @"No method swizzling, IMP replacement, layout call, new window, presenter, display transform, or game scaling change.",
        @"Drawable coverage is not content coverage: a full window/render view can still letterbox a 4:3 or other game canvas.",
        @"Interface/device orientation enums and convertRect mappings are recorded, but rendered content direction still requires a fixture or visual check."
    ];

    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    meta[@"runID"] = gRunID ?: @"";
    meta[@"startedAt"] = gStartedAt ?: @"";
    meta[@"startedUptime"] = @(gStartUptime);
    meta[@"info"] = gInfo ?: @{};
    meta[@"process"] = gProcess ?: @{};
    meta[@"output"] = @{
        @"container": @"app Documents",
        @"fileName": @"XP3CompatDisplayProbe.json",
        @"absolutePathRecorded": @NO
    };
    meta[@"eventPolicy"] = @{
        @"rotationSources": @[@"statusBar", @"device (if already generating)", @"timer-detected change"],
        @"keyboardSources": @[
            @"UIKeyboardWillShowNotification", @"UIKeyboardDidShowNotification",
            @"UIKeyboardWillHideNotification", @"UIKeyboardDidHideNotification",
            @"UIKeyboardWillChangeFrameNotification", @"UIKeyboardDidChangeFrameNotification"
        ],
        @"keyboardData": @"frames, animation metadata, orientation; no text"
    };

    return @{
        @"schema": @2,
        @"probe": probe,
        @"meta": meta,
        @"summary": XP3DPBuildSummary(),
        @"recentEvents": @{
            @"keyboard": gKeyboardEvents ?: @[],
            @"rotation": gRotationEvents ?: @[]
        },
        @"history": gHistory ?: @[]
    };
}

static void XP3DPWrite(BOOL force) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3DPWrite(force);
        });
        return;
    }
    if (!gStarted || gTerminated) {
        return;
    }

    NSTimeInterval now = XP3DPUptime();
    if (!force && now - gLastWrite < 1.0) {
        return;
    }
    gLastWrite = now;

    @autoreleasepool {
        NSDictionary *payload = XP3DPBuildPayload();
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
        if (data == nil) {
            NSLog(@"[XP3DisplayProbe] JSON serialization failed (domain=%@ code=%ld)",
                  error.domain ?: @"unknown", (long)error.code);
            return;
        }

        while (data.length > XP3DPMaxJSONBytes && gHistory.count > 1) {
            [gHistory removeObjectAtIndex:0];
            gTrimmedForSize++;
            gHistoryTrimmed = YES;
            gLastRecord = gHistory.lastObject;
            payload = XP3DPBuildPayload();
            data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
            if (data == nil) {
                NSLog(@"[XP3DisplayProbe] JSON serialization failed after trim (domain=%@ code=%ld)",
                      error.domain ?: @"unknown", (long)error.code);
                return;
            }
        }
        if (data.length > XP3DPMaxJSONBytes) {
            NSLog(@"[XP3DisplayProbe] bounded JSON still exceeds limit; file not updated");
            return;
        }

        NSArray<NSString *> *documentPaths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = documentPaths.firstObject;
        if (documentsPath.length == 0) {
            NSLog(@"[XP3DisplayProbe] app Documents directory unavailable");
            return;
        }
        NSString *path = [documentsPath stringByAppendingPathComponent:@"XP3CompatDisplayProbe.json"];
        if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"[XP3DisplayProbe] write failed (domain=%@ code=%ld)",
                  error.domain ?: @"unknown", (long)error.code);
            return;
        }
        NSLog(@"[XP3DisplayProbe] wrote XP3CompatDisplayProbe.json (%lu bytes, records=%lu, details=%lu, trimmed=%lu)",
              (unsigned long)data.length,
              (unsigned long)gHistory.count,
              (unsigned long)gDetailCount,
              (unsigned long)gTrimmedForSize);
    }
}

#pragma mark - Snapshot

static NSDictionary *XP3DPBuildRecord(NSString *trigger, BOOL forceDetail) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    gSeq++;
    record[@"seq"] = @(gSeq);
    record[@"trigger"] = trigger ?: @"unknown";
    record[@"timestamp"] = XP3DPTimestamp();
    record[@"uptime"] = @(XP3DPUptime());
    record[@"isMainThread"] = @([NSThread isMainThread]);

    UIApplication *application = UIApplication.sharedApplication;
    record[@"applicationState"] = @(application.applicationState);
    record[@"applicationStateName"] = XP3DPApplicationStateName(application.applicationState);

    BOOL mainScreenFound = NO;
    NSArray<NSDictionary *> *screens = XP3DPScreenSummaries(&mainScreenFound);
    record[@"mainScreenAvailable"] = @(mainScreenFound);
    record[@"screens"] = screens;
    record[@"screen"] = screens.count > 0 ? screens.firstObject : NSNull.null;

    NSArray<UIWindowScene *> *scenes = @[];
    if (@available(iOS 13.0, *)) {
        scenes = XP3DPAllScenes();
    }
    NSMutableArray *sceneRecords = [NSMutableArray arrayWithCapacity:scenes.count];
    for (NSUInteger i = 0; i < scenes.count; i++) {
        NSDictionary *sceneRecord = XP3DPSceneSummary(scenes[i], i);
        if (sceneRecord != nil) {
            [sceneRecords addObject:sceneRecord];
        }
    }
    record[@"scenes"] = sceneRecords;
    record[@"sceneCount"] = @(sceneRecords.count);

    NSArray<UIWindow *> *windows = XP3DPAllWindows();
    NSMutableArray *windowRecords = [NSMutableArray arrayWithCapacity:windows.count];
    UIWindow *keyWindow = XP3DPKeyWindow(windows);
    NSUInteger keyWindowIndex = NSNotFound;
    for (NSUInteger i = 0; i < windows.count; i++) {
        if (windows[i] == keyWindow) {
            keyWindowIndex = i;
        }
        NSDictionary *windowRecord = XP3DPWindowSummary(windows[i], i, scenes);
        if (windowRecord != nil) {
            [windowRecords addObject:windowRecord];
        }
    }
    record[@"windows"] = windowRecords;
    record[@"windowCount"] = @(windowRecords.count);
    record[@"keyWindowIndex"] = keyWindowIndex == NSNotFound ? NSNull.null : @(keyWindowIndex);

    NSDictionary *orientation = XP3DPOrientationSummary(keyWindow, keyWindow.rootViewController);
    record[@"orientation"] = orientation;

    NSInteger currentPrimary = [orientation[@"primary"] integerValue];
    if (currentPrimary != 0 && gLastPrimaryOrientation != 0 &&
        currentPrimary != gLastPrimaryOrientation) {
        NSDictionary *event = XP3DPRotationEvent(@"poll",
                                                 @"detected",
                                                 nil,
                                                 @(gLastPrimaryOrientation),
                                                 @(currentPrimary),
                                                 nil,
                                                 orientation);
        XP3DPAddBounded(gRotationEvents, event, XP3DPMaxRotationEvents);
        gLastRotationEvent = event;
    }
    if (currentPrimary != 0) {
        gLastPrimaryOrientation = currentPrimary;
    }
    record[@"lastRotationEvent"] = gLastRotationEvent ?: NSNull.null;
    record[@"lastKeyboardEvent"] = gLastKeyboardEvent ?: NSNull.null;
    record[@"keyboard"] = XP3DPKeyboardState(keyWindow, windows);

    if (forceDetail && gDetailCount < XP3DPMaxDetailSnapshots && keyWindow != nil) {
        UIView *rootView = keyWindow.rootViewController.viewIfLoaded;
        if (rootView != nil) {
            NSUInteger nodeCount = 0;
            BOOL truncated = NO;
            NSDictionary *rootNode = XP3DPViewNode(rootView, 0, &nodeCount, &truncated);
            if (rootNode != nil) {
                record[@"hierarchy"] = @{
                    @"windowIndex": keyWindowIndex == NSNotFound ? NSNull.null : @(keyWindowIndex),
                    @"nodeCount": @(nodeCount),
                    @"truncated": @(truncated),
                    @"root": rootNode
                };
                gDetailCount++;
            }
        }
    }

    record[@"coverage"] = XP3DPCoverageForRecord(record);
    return record;
}

static void XP3DPSnapshot(NSString *trigger, BOOL forceDetail) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XP3DPSnapshot(trigger, forceDetail);
        });
        return;
    }
    if (!gStarted || gTerminated) {
        return;
    }

    @autoreleasepool {
        if (gProcess == nil) {
            gProcess = XP3DPProcessSummary();
        }
        NSDictionary *record = XP3DPBuildRecord(trigger, forceDetail);
        if (gHistory.count < XP3DPMaxHistory) {
            [gHistory addObject:record];
        } else {
            gTruncated = YES;
            gDropped++;
        }
        gLastRecord = record;

        NSDictionary *coverage = [record[@"coverage"] isKindOfClass:NSDictionary.class]
            ? record[@"coverage"] : @{};
        NSDictionary *drawable = [coverage[@"drawable"] isKindOfClass:NSDictionary.class]
            ? coverage[@"drawable"] : @{};
        NSDictionary *orientation = [record[@"orientation"] isKindOfClass:NSDictionary.class]
            ? record[@"orientation"] : @{};
        NSDictionary *screen = [record[@"screen"] isKindOfClass:NSDictionary.class]
            ? record[@"screen"] : @{};
        CGSize screenSize = XP3DPSizeFromDict(screen[@"bounds"]);
        CGSize nativeSize = XP3DPSizeFromDict(screen[@"nativeBounds"]);
        NSDictionary *window = nil;
        NSArray *windowRecords = [record[@"windows"] isKindOfClass:NSArray.class]
            ? record[@"windows"] : @[];
        for (NSDictionary *candidate in windowRecords) {
            if ([candidate isKindOfClass:NSDictionary.class] &&
                [candidate[@"keyWindow"] boolValue]) {
                window = candidate;
                break;
            }
        }
        if (window == nil && windowRecords.count > 0 &&
            [windowRecords.firstObject isKindOfClass:NSDictionary.class]) {
            window = windowRecords.firstObject;
        }
        CGRect windowBounds = CGRectZero;
        if (window != nil) {
            XP3DPRectFromObject(window[@"bounds"], &windowBounds);
        }
        id renderCoverage = drawable[@"renderCoversScreenPoints"] ?: NSNull.null;
        id surfaceCoverage = drawable[@"surfaceMatchesNativePixels"] ?: NSNull.null;

        NSLog(@"[XP3DisplayProbe] #%lu trigger=%@ screen=%.0fx%.0f native=%.0fx%.0f window=%.0fx%.0f renderCovers=%@ surfaceNative=%@ orientation=%@",
              (unsigned long)gSeq,
              trigger ?: @"unknown",
              screenSize.width,
              screenSize.height,
              nativeSize.width,
              nativeSize.height,
              windowBounds.size.width,
              windowBounds.size.height,
              renderCoverage,
              surfaceCoverage,
              orientation[@"primaryName"] ?: @"unknown");

        BOOL forceWrite = forceDetail ||
            [trigger hasPrefix:@"orientation"] ||
            [trigger hasPrefix:@"keyboard"] ||
            [trigger hasPrefix:@"lifecycle"] ||
            [trigger hasPrefix:@"window"] ||
            [trigger hasPrefix:@"scene"] ||
            [trigger hasPrefix:@"screen"] ||
            [trigger isEqualToString:@"launch"] ||
            [trigger isEqualToString:@"timer-final"];
        XP3DPWrite(forceWrite);
    }
}

#pragma mark - Observers and start

typedef NS_ENUM(NSInteger, XP3DPRotationMode) {
    XP3DPRotationModeNone = 0,
    XP3DPRotationModeWill,
    XP3DPRotationModeDid,
    XP3DPRotationModeDevice
};

static void XP3DPAddObserver(NSString *name,
                             NSString *trigger,
                             XP3DPRotationMode rotationMode,
                             BOOL observeKeyboard,
                             BOOL forceDetail) {
    if (name.length == 0) {
        return;
    }
    id token = [[NSNotificationCenter defaultCenter]
        addObserverForName:name
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        switch (rotationMode) {
            case XP3DPRotationModeWill:
                XP3DPRecordRotationNotification(note, YES);
                break;
            case XP3DPRotationModeDid:
                XP3DPRecordRotationNotification(note, NO);
                break;
            case XP3DPRotationModeDevice:
                XP3DPRecordDeviceOrientationNotification(note);
                break;
            case XP3DPRotationModeNone:
            default:
                break;
        }
        if (observeKeyboard) {
            XP3DPRecordKeyboardNotification(note);
        }
        XP3DPSnapshot(trigger, forceDetail);
    }];
    if (token != nil) {
        [gObservers addObject:token];
    }
}

static void XP3DPRegisterObservers(void) {
    // App lifecycle.
    XP3DPAddObserver(UIApplicationDidFinishLaunchingNotification, @"lifecycle-didFinishLaunching", XP3DPRotationModeNone, NO, YES);
    XP3DPAddObserver(UIApplicationDidBecomeActiveNotification, @"lifecycle-didBecomeActive", XP3DPRotationModeNone, NO, YES);
    XP3DPAddObserver(UIApplicationWillResignActiveNotification, @"lifecycle-willResignActive", XP3DPRotationModeNone, NO, NO);
    XP3DPAddObserver(UIApplicationDidEnterBackgroundNotification, @"lifecycle-didEnterBackground", XP3DPRotationModeNone, NO, NO);
    XP3DPAddObserver(UIApplicationWillEnterForegroundNotification, @"lifecycle-willEnterForeground", XP3DPRotationModeNone, NO, YES);
    XP3DPAddObserver(UIApplicationWillTerminateNotification, @"lifecycle-willTerminate", XP3DPRotationModeNone, NO, NO);

    // Window readiness / key changes.
    XP3DPAddObserver(UIWindowDidBecomeKeyNotification, @"window-didBecomeKey", XP3DPRotationModeNone, NO, YES);
    XP3DPAddObserver(UIWindowDidBecomeVisibleNotification, @"window-didBecomeVisible", XP3DPRotationModeNone, NO, YES);
    XP3DPAddObserver(UIWindowDidResignKeyNotification, @"window-didResignKey", XP3DPRotationModeNone, NO, NO);

    // Screens (external display / PlayCover / simulator changes).
    XP3DPAddObserver(UIScreenDidConnectNotification, @"screen-didConnect", XP3DPRotationModeNone, NO, YES);
    XP3DPAddObserver(UIScreenDidDisconnectNotification, @"screen-didDisconnect", XP3DPRotationModeNone, NO, YES);
    XP3DPAddObserver(UIScreenModeDidChangeNotification, @"screen-modeDidChange", XP3DPRotationModeNone, NO, YES);

    // Rotation/status-bar events.
    XP3DPAddObserver(UIApplicationWillChangeStatusBarOrientationNotification, @"orientation-willChangeStatusBar", XP3DPRotationModeWill, NO, YES);
    XP3DPAddObserver(UIApplicationDidChangeStatusBarOrientationNotification, @"orientation-didChangeStatusBar", XP3DPRotationModeDid, NO, YES);
    XP3DPAddObserver(UIApplicationDidChangeStatusBarFrameNotification, @"orientation-didChangeStatusBarFrame", XP3DPRotationModeNone, NO, NO);
    XP3DPAddObserver(UIDeviceOrientationDidChangeNotification, @"orientation-deviceDidChange", XP3DPRotationModeDevice, NO, YES);

    // Keyboard events (frames/animation only, no text).
    XP3DPAddObserver(UIKeyboardWillShowNotification, @"keyboard-willShow", XP3DPRotationModeNone, YES, NO);
    XP3DPAddObserver(UIKeyboardDidShowNotification, @"keyboard-didShow", XP3DPRotationModeNone, YES, NO);
    XP3DPAddObserver(UIKeyboardWillHideNotification, @"keyboard-willHide", XP3DPRotationModeNone, YES, NO);
    XP3DPAddObserver(UIKeyboardDidHideNotification, @"keyboard-didHide", XP3DPRotationModeNone, YES, NO);
    XP3DPAddObserver(UIKeyboardWillChangeFrameNotification, @"keyboard-willChangeFrame", XP3DPRotationModeNone, YES, NO);
    XP3DPAddObserver(UIKeyboardDidChangeFrameNotification, @"keyboard-didChangeFrame", XP3DPRotationModeNone, YES, NO);

    // Scene lifecycle (iOS 13+).
    if (@available(iOS 13.0, *)) {
        XP3DPAddObserver(UISceneWillConnectNotification, @"scene-willConnect", XP3DPRotationModeNone, NO, YES);
        XP3DPAddObserver(UISceneDidActivateNotification, @"scene-didActivate", XP3DPRotationModeNone, NO, YES);
        XP3DPAddObserver(UISceneWillDeactivateNotification, @"scene-willDeactivate", XP3DPRotationModeNone, NO, NO);
        XP3DPAddObserver(UISceneDidEnterBackgroundNotification, @"scene-didEnterBackground", XP3DPRotationModeNone, NO, NO);
        XP3DPAddObserver(UISceneWillEnterForegroundNotification, @"scene-willEnterForeground", XP3DPRotationModeNone, NO, YES);
        XP3DPAddObserver(UISceneDidDisconnectNotification, @"scene-didDisconnect", XP3DPRotationModeNone, NO, NO);
    }
}

static void XP3DPScheduleTimer(NSTimeInterval delay) {
    if (gTimer != nil) {
        [gTimer invalidate];
    }
    gTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        if (!gStarted || gTerminated) {
            return;
        }
        NSTimeInterval elapsed = XP3DPUptime() - gStartUptime;
        if (elapsed >= XP3DPTotalDuration || gHistory.count >= XP3DPMaxHistory) {
            XP3DPSnapshot(@"timer-final", NO);
            XP3DPWrite(YES);
            gTimer = nil;
            return;
        }
        XP3DPSnapshot(gFirstTimerSnapshot ? @"launch" : @"timer", NO);
        gFirstTimerSnapshot = NO;
        NSTimeInterval next = elapsed < XP3DPRapidPhase ? 0.25 :
                              (elapsed < XP3DPMediumPhase ? 1.0 : 5.0);
        XP3DPScheduleTimer(next);
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

static void XP3DPStart(void) {
    if (gStarted) {
        return;
    }
    gStarted = YES;
    gStartUptime = XP3DPUptime();
    gRunID = NSUUID.UUID.UUIDString ?: @"";
    gStartedAt = XP3DPTimestamp();
    gHistory = [NSMutableArray array];
    gKeyboardEvents = [NSMutableArray array];
    gRotationEvents = [NSMutableArray array];
    gObservers = [NSMutableArray array];
    gLastWrite = 0.0;
    gInfo = XP3DPInfoSummary();

    XP3DPRegisterObservers();
    XP3DPScheduleTimer(0.05);

    NSLog(@"[XP3DisplayProbe] started read-only; output=Documents/XP3CompatDisplayProbe.json");
}

__attribute__((constructor))
static void XP3DPConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        XP3DPStart();
    });
}
