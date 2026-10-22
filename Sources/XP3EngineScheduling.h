// Legacy dialogs synchronously wait for a result. UIKit update phases cannot
// host that nested run loop. Queue engine callbacks after UIKit returns, using
// public run-loop blocks, with all engine work kept on the main thread.
#pragma once

static NSMutableArray *XP3EngineWork;
static BOOL XP3EngineDrainScheduled, XP3EngineDraining;
static void XP3ScheduleEngineDrain(void);
static void XP3DrainEngineWork(void) {
    XP3EngineDrainScheduled = NO;
    if (XP3EngineDraining) return;
    XP3EngineDraining = YES;
    @try {
        while (XP3EngineWork.count) {
            void (^work)(void) = XP3EngineWork[0];
            [XP3EngineWork removeObjectAtIndex:0];
            work();
        }
    } @finally {
        XP3EngineDraining = NO;
        XP3ScheduleEngineDrain();
    }
}
static void XP3ScheduleEngineDrain(void) {
    if (XP3EngineDraining || XP3EngineDrainScheduled || !XP3EngineWork.count) return;
    XP3EngineDrainScheduled = YES;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{ XP3DrainEngineWork(); });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
static void XP3EnqueueEngineWork(void (^work)(void)) {
    if (!XP3EngineWork) XP3EngineWork = [NSMutableArray array];
    [XP3EngineWork addObject:[work copy]];
    XP3ScheduleEngineDrain();
}

// CCEAGLView reads view/location and move pressure, and uses object addresses
// as engine touch IDs. Engine-only carriers preserve gesture identity. They
// never enter UIKit, and no UITouch/UIEvent is retained by queued work.
@interface XP3EngineTouch : NSObject
@property(weak) UIView *view;
@property CGPoint point;
@property CGFloat force;
@property CGFloat maximumPossibleForce;
- (CGPoint)locationInView:(UIView *)view;
@end
@implementation XP3EngineTouch
- (CGPoint)locationInView:(UIView *)view {
    UIView *source = self.view;
    return source && source != view ? [source convertPoint:self.point toView:view] : self.point;
}
@end
@interface XP3EngineTouchSample : NSObject
@property(strong) XP3EngineTouch *identity;
@property(weak) UIView *view;
@property CGPoint point;
@property CGFloat force;
@property CGFloat maximumPossibleForce;
@end
@implementation XP3EngineTouchSample
@end
@interface XP3EngineInputState : NSObject
@property(strong) NSMapTable *touches;
@end
@implementation XP3EngineInputState
- (instancetype)init {
    self = [super init];
    if (self) _touches = [NSMapTable weakToStrongObjectsMapTable];
    return self;
}
@end
typedef void (*XP3EngineTouchIMP)(id, SEL, id, id);
static XP3EngineTouchIMP XP3OriginalEngineTouches[4];
static char XP3EngineInputKey;
static void XP3EngineCaptureTouches(id view, SEL cmd, NSSet *touches, NSUInteger phase) {
    XP3EngineInputState *state = objc_getAssociatedObject(view, &XP3EngineInputKey);
    if (!state) {
        state = [[XP3EngineInputState alloc] init];
        objc_setAssociatedObject(view, &XP3EngineInputKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSMutableArray *samples = [NSMutableArray array];
    NSArray *objects = [touches allObjects];
    for (NSUInteger i = 0; i < objects.count; ++i) {
        UITouch *touch = objects[i];
        XP3EngineTouch *identity = [state.touches objectForKey:touch];
        if (phase == 0) {
            identity = [[XP3EngineTouch alloc] init];
            [state.touches setObject:identity forKey:touch];
        }
        if (!identity) continue; // unmatched move/end has no engine touch ID
        XP3EngineTouchSample *sample = [[XP3EngineTouchSample alloc] init];
        sample.identity = identity;
        sample.view = touch.view;
        sample.point = [touch locationInView:sample.view];
        sample.force = touch.force;
        sample.maximumPossibleForce = touch.maximumPossibleForce;
        [samples addObject:sample];
        if (phase >= 2) [state.touches removeObjectForKey:touch];
    }
    if (!samples.count) return;
    __weak id weakView = view;
    XP3EnqueueEngineWork(^{
        id target = weakView;
        if (!target) return;
        NSMutableSet *engineTouches = [NSMutableSet set];
        for (NSUInteger i = 0; i < samples.count; ++i) {
            XP3EngineTouchSample *sample = samples[i];
            XP3EngineTouch *touch = sample.identity;
            touch.view = sample.view;
            touch.point = sample.point;
            touch.force = sample.force;
            touch.maximumPossibleForce = sample.maximumPossibleForce;
            [engineTouches addObject:touch];
        }
        // The target CCEAGLView does not read its UIEvent argument.
        XP3OriginalEngineTouches[phase](target, cmd, engineTouches, nil);
    });
}
static void XP3EngineTouchesBegan(id self, SEL cmd, NSSet *touches, id event) {
    (void)event; XP3EngineCaptureTouches(self, cmd, touches, 0);
}
static void XP3EngineTouchesMoved(id self, SEL cmd, NSSet *touches, id event) {
    (void)event; XP3EngineCaptureTouches(self, cmd, touches, 1);
}
static void XP3EngineTouchesEnded(id self, SEL cmd, NSSet *touches, id event) {
    (void)event; XP3EngineCaptureTouches(self, cmd, touches, 2);
}
static void XP3EngineTouchesCancelled(id self, SEL cmd, NSSet *touches, id event) {
    (void)event; XP3EngineCaptureTouches(self, cmd, touches, 3);
}

@interface XP3EngineFrameState : NSObject
@property NSUInteger generation;
@property BOOL pending;
@property BOOL running;
@end
@implementation XP3EngineFrameState
@end
static char XP3EngineFrameKey;
static void (*XP3OriginalEngineFrame)(id, SEL, id);
static void (*XP3OriginalEngineStop)(id, SEL);
static XP3EngineFrameState *XP3FrameState(id caller) {
    XP3EngineFrameState *state = objc_getAssociatedObject(caller, &XP3EngineFrameKey);
    if (!state) {
        state = [[XP3EngineFrameState alloc] init];
        objc_setAssociatedObject(caller, &XP3EngineFrameKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}
static void XP3EngineFrame(id self, SEL cmd, id sender) {
    XP3EngineFrameState *state = XP3FrameState(self);
    if (state.pending || state.running) return;
    state.pending = YES;
    NSUInteger generation = state.generation;
    __weak id weakCaller = self;
    XP3EnqueueEngineWork(^{
        id caller = weakCaller;
        if (!caller || state.generation != generation) return;
        state.pending = NO;
        state.running = YES;
        @try { XP3OriginalEngineFrame(caller, cmd, sender); }
        @finally { state.running = NO; }
    });
}
static void XP3EngineStop(id self, SEL cmd) {
    XP3EngineFrameState *state = XP3FrameState(self);
    ++state.generation;
    state.pending = NO;
    XP3OriginalEngineStop(self, cmd);
}
static Method XP3EngineOwnedMethod(Class cls, SEL selector, unsigned int arity) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method == class_getInstanceMethod(class_getSuperclass(cls), selector) ||
        method_getNumberOfArguments(method) != arity) return 0;
    char type[32] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'v') return 0;
    for (unsigned int i = 2; i < arity; ++i) {
        method_getArgumentType(method, i, type, sizeof(type));
        if (type[0] != '@') return 0;
    }
    return method;
}
static void XP3InstallEngineScheduling(BOOL touchInput, BOOL frames) {
    if (objc_getClass("NSAlert")) return; // PlayCover uses AppKit's modal loop
    static BOOL touchesInstalled, framesInstalled;
    if (touchInput && !touchesInstalled) {
        Class view = objc_getClass("CCEAGLView");
        SEL selectors[4] = {@selector(touchesBegan:withEvent:), @selector(touchesMoved:withEvent:),
            @selector(touchesEnded:withEvent:), @selector(touchesCancelled:withEvent:)};
        IMP hooks[4] = {(IMP)XP3EngineTouchesBegan, (IMP)XP3EngineTouchesMoved,
            (IMP)XP3EngineTouchesEnded, (IMP)XP3EngineTouchesCancelled};
        Method methods[4];
        BOOL valid = YES;
        for (NSUInteger i = 0; i < 4; ++i) {
            methods[i] = XP3EngineOwnedMethod(view, selectors[i], 4);
            if (!methods[i]) valid = NO;
        }
        if (valid) {
            for (NSUInteger i = 0; i < 4; ++i) {
                XP3OriginalEngineTouches[i] = (XP3EngineTouchIMP)method_getImplementation(methods[i]);
                method_setImplementation(methods[i], hooks[i]);
            }
            touchesInstalled = YES;
            NSLog(@"[XP3Compat] engine touch snapshots scheduled outside UIKit updates");
        } else NSLog(@"[XP3Compat] engine touch signatures unavailable; scheduling skipped");
    }
    if (frames && !framesInstalled) {
        Class caller = objc_getClass("CCDirectorCaller");
        Method frame = XP3EngineOwnedMethod(caller, @selector(doCaller:), 3);
        Method stop = XP3EngineOwnedMethod(caller, @selector(stopMainLoop), 2);
        if (frame && stop) {
            XP3OriginalEngineFrame = (void *)method_getImplementation(frame);
            XP3OriginalEngineStop = (void *)method_getImplementation(stop);
            method_setImplementation(frame, (IMP)XP3EngineFrame);
            method_setImplementation(stop, (IMP)XP3EngineStop);
            framesInstalled = YES;
            NSLog(@"[XP3Compat] engine frames scheduled outside UIKit updates");
        } else NSLog(@"[XP3Compat] engine frame signatures unavailable; scheduling skipped");
    }
}
