// Experimental, opt-in startup adaptation. Not part of the shipping plugin.
// The old AppController initializes the engine during didFinishLaunching using
// UIScreen.mainScreen, before UIKit supplies the scene (and its display).
// Replay that initialization once the scene exists, with only that main-thread
// call using the scene's screen. No device dimensions or orientation overrides.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL gXP3SBEnabled, gXP3SBDeferred, gXP3SBStarted;
static __weak id gXP3SBDelegate;
static NSDictionary *gXP3SBOptions;
static UIWindowScene *gXP3SBInitializingScene;
static UIScreen *gXP3SBSceneScreen;
static CGRect gXP3SBSceneBounds;
static BOOL (*gXP3SBOriginalLaunch)(id, SEL, UIApplication *, NSDictionary *);
static UIScreen *(*gXP3SBOriginalScreen)(id, SEL);
static CGRect (*gXP3SBOriginalBounds)(id, SEL);

static BOOL XP3SBLaunch(id self, SEL cmd, UIApplication *application, NSDictionary *options) {
    if (!gXP3SBEnabled || ![NSThread isMainThread])
        return gXP3SBOriginalLaunch(self, cmd, application, options);
    gXP3SBDelegate = self;
    gXP3SBOptions = [options copy];
    gXP3SBDeferred = YES;
    NSLog(@"[XP3SceneBootstrap] deferred engine startup until scene connection");
    return YES;
}

static UIScreen *XP3SBMainScreen(id self, SEL cmd) {
    if ([NSThread isMainThread] && gXP3SBInitializingScene)
        return gXP3SBSceneScreen;
    return gXP3SBOriginalScreen(self, cmd);
}

static CGRect XP3SBScreenBounds(id self, SEL cmd) {
    if ([NSThread isMainThread] && gXP3SBInitializingScene && self == gXP3SBSceneScreen)
        return gXP3SBSceneBounds;
    return gXP3SBOriginalBounds(self, cmd);
}

static BOOL XP3SBBootstrapScene(UIWindowScene *scene) {
    if (!gXP3SBEnabled || !gXP3SBDeferred || gXP3SBStarted) return NO;
    if (![NSThread isMainThread] || !scene || !gXP3SBDelegate) return NO;
    // UIScreen.bounds can still be portrait during connection even when the
    // scene is landscape. Capture scene coordinates before entering the scope.
    CGRect bounds = scene.coordinateSpace.bounds;
    if (CGRectIsEmpty(bounds) || CGRectIsInfinite(bounds) || CGRectIsNull(bounds)) return NO;
    UIScreen *screen = scene.screen;
    Method boundsGetter = class_getInstanceMethod(object_getClass(screen), @selector(bounds));
    if (!boundsGetter) return NO;
    gXP3SBOriginalBounds = (void *)method_getImplementation(boundsGetter);
    gXP3SBSceneScreen = screen;
    gXP3SBSceneBounds = bounds;
    gXP3SBStarted = YES;
    gXP3SBInitializingScene = scene;
    method_setImplementation(boundsGetter, (IMP)XP3SBScreenBounds);
    @try {
        BOOL ok = gXP3SBOriginalLaunch(gXP3SBDelegate,
            @selector(application:didFinishLaunchingWithOptions:),
            UIApplication.sharedApplication, gXP3SBOptions);
        NSLog(@"[XP3SceneBootstrap] original launch completed=%@ scene=%@",
              ok ? @"yes" : @"no", NSStringFromCGRect(scene.coordinateSpace.bounds));
        return ok;
    } @finally {
        method_setImplementation(boundsGetter, (IMP)gXP3SBOriginalBounds);
        gXP3SBInitializingScene = nil;
        gXP3SBSceneScreen = nil;
        gXP3SBOptions = nil;
    }
}

__attribute__((constructor)) static void XP3SBInstall(void) {
    @autoreleasepool {
        if (@available(iOS 13.0, *)) {} else { return; }
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle.bundleIdentifier isEqualToString:@"tvp.XP3Player.Compat"] ||
            ![bundle.infoDictionary[@"XP3CompatEnableSceneBootstrap"] boolValue]) return;
        Method launch = class_getInstanceMethod(NSClassFromString(@"AppController"),
            @selector(application:didFinishLaunchingWithOptions:));
        Method screen = class_getClassMethod(UIScreen.class, @selector(mainScreen));
        if (!launch || !screen) return;
        gXP3SBOriginalLaunch = (void *)method_getImplementation(launch);
        gXP3SBOriginalScreen = (void *)method_getImplementation(screen);
        gXP3SBEnabled = YES;
        method_setImplementation(launch, (IMP)XP3SBLaunch);
        method_setImplementation(screen, (IMP)XP3SBMainScreen);
    }
}
