#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

static const NSUInteger XP3MetricsMaxDepth = 5;
static const NSUInteger XP3MetricsMaxNodes = 80;

static NSDictionary *XP3MetricsRect(CGRect rect) {
    return @{
        @"x": @(CGRectGetMinX(rect)),
        @"y": @(CGRectGetMinY(rect)),
        @"width": @(CGRectGetWidth(rect)),
        @"height": @(CGRectGetHeight(rect))
    };
}

static NSDictionary *XP3MetricsInsets(UIEdgeInsets insets) {
    return @{
        @"top": @(insets.top),
        @"left": @(insets.left),
        @"bottom": @(insets.bottom),
        @"right": @(insets.right)
    };
}

static NSDictionary *XP3MetricsScreenRecord(UIScreen *screen) {
    if (screen == nil) {
        return nil;
    }
    return @{
        @"bounds": XP3MetricsRect(screen.bounds),
        @"nativeBounds": XP3MetricsRect(screen.nativeBounds),
        @"scale": @(screen.scale),
        @"nativeScale": @(screen.nativeScale)
    };
}

static NSString *XP3MetricsActivationStateName(UISceneActivationState state) {
    switch (state) {
        case UISceneActivationStateUnattached:
            return @"unattached";
        case UISceneActivationStateForegroundActive:
            return @"foregroundActive";
        case UISceneActivationStateForegroundInactive:
            return @"foregroundInactive";
        case UISceneActivationStateBackground:
            return @"background";
    }
    return @"unknown";
}

static NSDictionary *XP3MetricsSceneRecord(UIWindowScene *scene) {
    if (scene == nil) {
        return nil;
    }

    UIScreen *screen = scene.screen;
    CGRect legacySceneBounds = CGRectZero;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    id<UICoordinateSpace> legacyCoordinateSpace = scene.coordinateSpace;
#pragma clang diagnostic pop
    if (legacyCoordinateSpace != nil) {
        legacySceneBounds = legacyCoordinateSpace.bounds;
    }

    CGRect sceneBounds = legacySceneBounds;
    if (@available(iOS 26.0, *)) {
        id<UICoordinateSpace> coordinateSpace = scene.effectiveGeometry.coordinateSpace;
        if (coordinateSpace != nil) {
            sceneBounds = coordinateSpace.bounds;
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        id<UICoordinateSpace> coordinateSpace = scene.coordinateSpace;
#pragma clang diagnostic pop
        if (coordinateSpace != nil) {
            sceneBounds = coordinateSpace.bounds;
        }
    }

    UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 16.0, *)) {
        interfaceOrientation = scene.effectiveGeometry.interfaceOrientation;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        interfaceOrientation = scene.interfaceOrientation;
#pragma clang diagnostic pop
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"activationState"] = @(scene.activationState);
    record[@"activationStateName"] = XP3MetricsActivationStateName(scene.activationState);
    record[@"coordinateSpaceBounds"] = XP3MetricsRect(sceneBounds);
    record[@"legacyCoordinateSpaceBounds"] = XP3MetricsRect(legacySceneBounds);
    record[@"interfaceOrientation"] = @(interfaceOrientation);
    if (screen != nil) {
        NSDictionary *screenRecord = XP3MetricsScreenRecord(screen);
        record[@"screen"] = screenRecord;
        record[@"screenBounds"] = screenRecord[@"bounds"];
        record[@"screenNativeBounds"] = screenRecord[@"nativeBounds"];
        record[@"screenScale"] = screenRecord[@"scale"];
        record[@"screenNativeScale"] = screenRecord[@"nativeScale"];
    } else {
        record[@"screen"] = [NSNull null];
        record[@"screenBounds"] = [NSNull null];
        record[@"screenNativeBounds"] = [NSNull null];
        record[@"screenScale"] = [NSNull null];
        record[@"screenNativeScale"] = [NSNull null];
    }
    return record;
}

static NSDictionary *XP3MetricsViewRecord(UIView *view,
                                          NSUInteger depth,
                                          NSUInteger *nodeCount,
                                          BOOL *truncated) {
    if (view == nil || nodeCount == NULL || truncated == NULL || *nodeCount >= XP3MetricsMaxNodes) {
        if (truncated != NULL) {
            *truncated = YES;
        }
        return nil;
    }

    (*nodeCount)++;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"depth"] = @(depth);
    record[@"class"] = NSStringFromClass(view.class) ?: @"<unknown>";
    record[@"frame"] = XP3MetricsRect(view.frame);
    record[@"bounds"] = XP3MetricsRect(view.bounds);
    record[@"contentScaleFactor"] = @(view.contentScaleFactor);
    record[@"hidden"] = @(view.hidden);

    NSMutableArray *children = [NSMutableArray array];
    NSArray<UIView *> *subviews = view.subviews;
    if (depth >= XP3MetricsMaxDepth) {
        if (subviews.count != 0) {
            *truncated = YES;
        }
    } else {
        for (UIView *child in subviews) {
            if (*nodeCount >= XP3MetricsMaxNodes) {
                *truncated = YES;
                break;
            }
            NSDictionary *childRecord = XP3MetricsViewRecord(child, depth + 1, nodeCount, truncated);
            if (childRecord != nil) {
                [children addObject:childRecord];
            }
        }
    }
    record[@"subviews"] = children;
    return record;
}

static NSDictionary *XP3MetricsWindowRecord(UIWindow *window, NSUInteger index) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"index"] = @(index);
    record[@"class"] = NSStringFromClass(window.class) ?: @"<unknown>";
    record[@"hidden"] = @(window.hidden);
    record[@"keyWindow"] = @(window.isKeyWindow);
    record[@"frame"] = XP3MetricsRect(window.frame);
    record[@"bounds"] = XP3MetricsRect(window.bounds);
    record[@"safeAreaInsets"] = XP3MetricsInsets(window.safeAreaInsets);

    UIWindowScene *scene = window.windowScene;
    NSDictionary *sceneRecord = XP3MetricsSceneRecord(scene);
    record[@"scene"] = sceneRecord ?: [NSNull null];

    UIViewController *rootViewController = window.rootViewController;
    UIView *rootView = rootViewController.viewIfLoaded;
    record[@"rootViewControllerClass"] = rootViewController != nil
        ? (NSStringFromClass(rootViewController.class) ?: @"<unknown>")
        : [NSNull null];
    if (rootView != nil) {
        NSUInteger nodeCount = 0;
        BOOL truncated = NO;
        NSDictionary *rootRecord = XP3MetricsViewRecord(rootView, 0, &nodeCount, &truncated);
        record[@"rootView"] = rootRecord ?: [NSNull null];
        record[@"rootViewNodeCount"] = @(nodeCount);
        record[@"rootViewTruncated"] = @(truncated);
    } else {
        record[@"rootView"] = [NSNull null];
        record[@"rootViewNodeCount"] = @0;
        record[@"rootViewTruncated"] = @NO;
    }
    return record;
}

static void XP3MetricsCollect(void) {
    @autoreleasepool {
        UIApplication *application = UIApplication.sharedApplication;
        NSArray<UIWindow *> *windows = application.windows;
        NSMutableArray *windowRecords = [NSMutableArray arrayWithCapacity:windows.count];
        for (NSUInteger index = 0; index < windows.count; index++) {
            UIWindow *window = windows[index];
            [windowRecords addObject:XP3MetricsWindowRecord(window, index)];

            NSLog(@"[XP3Metrics] window[%lu] class=%@ key=%d hidden=%d frame=%@ bounds=%@ safe=%@",
                  (unsigned long)index,
                  NSStringFromClass(window.class),
                  window.isKeyWindow,
                  window.hidden,
                  NSStringFromCGRect(window.frame),
                  NSStringFromCGRect(window.bounds),
                  NSStringFromUIEdgeInsets(window.safeAreaInsets));
            UIView *rootView = window.rootViewController.viewIfLoaded;
            if (rootView != nil) {
                NSLog(@"[XP3Metrics] window[%lu] root=%@ frame=%@ bounds=%@ scale=%.3f nodes<=%lu",
                      (unsigned long)index,
                      NSStringFromClass(rootView.class),
                      NSStringFromCGRect(rootView.frame),
                      NSStringFromCGRect(rootView.bounds),
                      rootView.contentScaleFactor,
                      (unsigned long)XP3MetricsMaxNodes);
            }
            UIWindowScene *scene = window.windowScene;
            if (scene != nil) {
                NSDictionary *sceneRecord = XP3MetricsSceneRecord(scene);
                NSLog(@"[XP3Metrics] window[%lu] sceneState=%@ sceneBounds=%@ screenBounds=%@",
                      (unsigned long)index,
                      sceneRecord[@"activationStateName"],
                      sceneRecord[@"coordinateSpaceBounds"],
                      sceneRecord[@"screenBounds"]);
            }
        }

        NSMutableArray *sceneRecords = [NSMutableArray array];
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                NSDictionary *sceneRecord = XP3MetricsSceneRecord((UIWindowScene *)scene);
                if (sceneRecord != nil) {
                    [sceneRecords addObject:sceneRecord];
                }
            }
        }

        NSString *timestamp = [[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date];
        NSDictionary *payload = @{
            @"schema": @1,
            @"timestamp": timestamp ?: @"",
            @"mainScreen": XP3MetricsScreenRecord(UIScreen.mainScreen) ?: [NSNull null],
            @"windowCount": @(windowRecords.count),
            @"sceneCount": @(sceneRecords.count),
            @"scenes": sceneRecords,
            @"windows": windowRecords
        };

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&error];
        if (jsonData == nil) {
            NSLog(@"[XP3Metrics] JSON serialization failed: %@", error);
            return;
        }

        NSArray<NSString *> *documentPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = documentPaths.firstObject;
        NSString *outputPath = [documentsPath stringByAppendingPathComponent:@"XP3CompatGeometry.json"];
        if (![jsonData writeToFile:outputPath options:NSDataWritingAtomic error:&error]) {
            NSLog(@"[XP3Metrics] JSON write failed path=%@ error=%@", outputPath, error);
            return;
        }
        NSLog(@"[XP3Metrics] wrote %@ (%lu bytes), windows=%lu scenes=%lu",
              outputPath,
              (unsigned long)jsonData.length,
              (unsigned long)windowRecords.count,
              (unsigned long)sceneRecords.count);
    }
}

__attribute__((constructor))
static void XP3MetricsConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            XP3MetricsCollect();
        }];
    });
}
