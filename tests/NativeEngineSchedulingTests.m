#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

@interface UIView : NSObject
- (CGPoint)convertPoint:(CGPoint)point toView:(UIView *)view;
- (void)touchesBegan:(NSSet *)touches withEvent:(id)event;
- (void)touchesMoved:(NSSet *)touches withEvent:(id)event;
- (void)touchesEnded:(NSSet *)touches withEvent:(id)event;
- (void)touchesCancelled:(NSSet *)touches withEvent:(id)event;
@end
@implementation UIView
- (CGPoint)convertPoint:(CGPoint)point toView:(UIView *)view { (void)view; return point; }
- (void)touchesBegan:(NSSet *)touches withEvent:(id)event { (void)touches; (void)event; }
- (void)touchesMoved:(NSSet *)touches withEvent:(id)event { (void)touches; (void)event; }
- (void)touchesEnded:(NSSet *)touches withEvent:(id)event { (void)touches; (void)event; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(id)event { (void)touches; (void)event; }
@end

@interface UITouch : NSObject
@property(weak) UIView *view;
@property CGPoint point;
@property CGFloat force;
@property CGFloat maximumPossibleForce;
- (CGPoint)locationInView:(UIView *)view;
@end
@implementation UITouch
- (CGPoint)locationInView:(UIView *)view { (void)view; return self.point; }
@end

#include "../Sources/XP3EngineScheduling.h"

static NSMutableArray<NSDictionary *> *touchLog;
static NSUInteger frameCalls, stopCalls;
static BOOL runNestedFrameLoop, nestedTimerFired;
static BOOL runNestedTouchLoop, nestedTouchTimerFired;
static NSUInteger nestedTouchRecordsBefore, nestedTouchRecordsAfter;
static UITouch *nestedTouch;
@interface CCEAGLView : UIView
@end
@implementation CCEAGLView
- (void)record:(NSSet *)touches phase:(NSString *)phase {
    for (XP3EngineTouch *touch in touches) {
        [touchLog addObject:@{@"phase": phase, @"identity": touch,
            @"x": @(touch.point.x), @"y": @(touch.point.y), @"force": @(touch.force),
            @"maximum": @(touch.maximumPossibleForce), @"event": [NSNull null]}];
    }
}
- (void)touchesBegan:(NSSet *)touches withEvent:(id)event { (void)event; [self record:touches phase:@"began"]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(id)event { (void)event; [self record:touches phase:@"moved"]; }
- (void)touchesEnded:(NSSet *)touches withEvent:(id)event {
    (void)event;
    [self record:touches phase:@"ended"];
    if (!runNestedTouchLoop) return;
    runNestedTouchLoop = NO;
    nestedTouchRecordsBefore = touchLog.count;
    CCEAGLView *target = self;
    UITouch *timerTouch = nestedTouch;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.001, 1.0, 0, 0, ^(CFRunLoopTimerRef timer) {
            (void)timer;
            nestedTouchTimerFired = YES;
            [target touchesBegan:[NSSet setWithObject:timerTouch] withEvent:nil];
            [target touchesEnded:[NSSet setWithObject:timerTouch] withEvent:nil];
            nestedTouchRecordsAfter = touchLog.count;
            CFRunLoopStop(CFRunLoopGetCurrent());
        });
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFRelease(timer);
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(id)event { (void)event; [self record:touches phase:@"cancelled"]; }
@end

@interface CCDirectorCaller : NSObject
- (void)doCaller:(id)sender;
- (void)stopMainLoop;
@end
@implementation CCDirectorCaller
- (void)doCaller:(id)sender {
    (void)sender;
    ++frameCalls;
    if (runNestedFrameLoop) {
        runNestedFrameLoop = NO;
        CCDirectorCaller *caller = self;
        CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.001, 0, 0, 0, ^(CFRunLoopTimerRef timer) {
            (void)timer;
            nestedTimerFired = YES;
            [caller doCaller:nil]; // must be ignored while the outer frame is active
            CFRunLoopStop(CFRunLoopGetCurrent());
        });
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
        CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
        CFRelease(timer);
    }
}
- (void)stopMainLoop { ++stopCalls; }
@end

static NSUInteger checks;
static void Check(BOOL value, const char *message) {
    ++checks;
    if (!value) { fprintf(stderr, "FAIL: %s (check %lu)\n", message, (unsigned long)checks); exit(1); }
}
static void RunMainLoopBriefly(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
}
static UITouch *MakeTouch(UIView *view, CGFloat x, CGFloat y, CGFloat force, CGFloat maximum) {
    UITouch *touch = [UITouch new];
    touch.view = view; touch.point = CGPointMake(x, y);
    touch.force = force; touch.maximumPossibleForce = maximum;
    return touch;
}

int main(void) {
    @autoreleasepool {
        touchLog = [NSMutableArray array];
        CCEAGLView *view = [CCEAGLView new];
        SEL touchSelectors[4] = {@selector(touchesBegan:withEvent:), @selector(touchesMoved:withEvent:),
            @selector(touchesEnded:withEvent:), @selector(touchesCancelled:withEvent:)};
        IMP parentImplementations[4];
        for (NSUInteger i = 0; i < 4; ++i)
            parentImplementations[i] = class_getMethodImplementation([UIView class], touchSelectors[i]);
        XP3InstallEngineScheduling(YES, YES);
        IMP hookedBegan = class_getMethodImplementation([CCEAGLView class], @selector(touchesBegan:withEvent:));
        Check(hookedBegan != parentImplementations[0], "subclass touch method receives a scheduling hook");
        BOOL parentMethodsUnchanged = YES;
        for (NSUInteger i = 0; i < 4; ++i)
            parentMethodsUnchanged &= class_getMethodImplementation([UIView class], touchSelectors[i]) == parentImplementations[i];
        Check(parentMethodsUnchanged, "install leaves all parent UIView touch implementations unchanged");
        XP3InstallEngineScheduling(YES, YES);
        Check(class_getMethodImplementation([CCEAGLView class], @selector(touchesBegan:withEvent:)) == hookedBegan,
              "installation is idempotent");

        __weak UITouch *releasedTouch = nil;
        @autoreleasepool {
            UITouch *touch = MakeTouch(view, 12, 23, 0.25, 1.0);
            releasedTouch = touch;
            [view touchesBegan:[NSSet setWithObject:touch] withEvent:[NSObject new]];
            Check(touchLog.count == 0, "touch callback is delayed until after UIKit returns");
            touch.point = CGPointMake(90, 91); touch.force = 0.9; touch.maximumPossibleForce = 2.0;
        }
        Check(releasedTouch == nil, "queued callback does not retain the original UITouch");
        RunMainLoopBriefly();
        Check(touchLog.count == 1, "queued began callback drains");
        NSDictionary *began = touchLog[0];
        Check([began[@"x"] doubleValue] == 12 && [began[@"y"] doubleValue] == 23 &&
              [began[@"force"] doubleValue] == 0.25 && [began[@"maximum"] doubleValue] == 1.0,
              "began uses values captured before the UITouch was mutated");
        id firstIdentity = began[@"identity"];

        UITouch *gesture = MakeTouch(view, 30, 40, 0.4, 1.2);
        [view touchesBegan:[NSSet setWithObject:gesture] withEvent:nil];
        gesture.point = CGPointMake(31, 41); gesture.force = 0.6;
        [view touchesMoved:[NSSet setWithObject:gesture] withEvent:nil];
        gesture.point = CGPointMake(300, 400); gesture.force = 1.0;
        [view touchesEnded:[NSSet setWithObject:gesture] withEvent:nil];
        gesture.point = CGPointMake(500, 600); gesture.force = 0.1;
        RunMainLoopBriefly();
        Check(touchLog.count == 4, "begin, move and end callbacks all drain");
        Check(touchLog[1][@"identity"] == touchLog[2][@"identity"] &&
              touchLog[2][@"identity"] == touchLog[3][@"identity"] && touchLog[1][@"identity"] != firstIdentity,
              "one gesture keeps its engine identity while a new gesture gets another");
        Check([touchLog[1][@"x"] doubleValue] == 30 && [touchLog[1][@"y"] doubleValue] == 40 &&
              [touchLog[1][@"force"] doubleValue] == 0.4 && [touchLog[2][@"x"] doubleValue] == 31 &&
              [touchLog[2][@"force"] doubleValue] == 0.6 && [touchLog[3][@"x"] doubleValue] == 300 &&
              [touchLog[3][@"force"] doubleValue] == 1.0,
              "each phase preserves its own captured coordinates and pressure");

        UITouch *a = MakeTouch(view, 1, 2, 0.1, 1); UITouch *b = MakeTouch(view, 3, 4, 0.2, 1);
        [view touchesBegan:[NSSet setWithObjects:a, b, nil] withEvent:nil];
        RunMainLoopBriefly();
        Check(touchLog.count == 6 && touchLog[4][@"identity"] != touchLog[5][@"identity"],
              "simultaneous touches have separate stable identities");
        [view touchesCancelled:[NSSet setWithObject:a] withEvent:nil];
        RunMainLoopBriefly();
        id cancelledIdentity = touchLog.lastObject[@"identity"];
        [view touchesBegan:[NSSet setWithObject:a] withEvent:nil];
        RunMainLoopBriefly();
        Check(touchLog.lastObject[@"identity"] != cancelledIdentity,
              "cancel removes gesture identity before the next begin");

        NSUInteger touchCountBeforeNested = touchLog.count;
        nestedTouch = MakeTouch(view, 71, 82, 0.7, 1.0);
        nestedTouchTimerFired = NO; nestedTouchRecordsBefore = 0; nestedTouchRecordsAfter = 0;
        runNestedTouchLoop = YES;
        UITouch *outerTouch = MakeTouch(view, 61, 62, 0.3, 1.0);
        [view touchesBegan:[NSSet setWithObject:outerTouch] withEvent:nil];
        [view touchesEnded:[NSSet setWithObject:outerTouch] withEvent:nil];
        RunMainLoopBriefly();
        Check(nestedTouchTimerFired, "timer runs inside the engine touchesEnded nested run loop");
        Check(nestedTouchRecordsAfter == nestedTouchRecordsBefore,
              "timer-enqueued began/end callbacks do not run recursively inside engine touchesEnded");
        Check(touchLog.count == touchCountBeforeNested + 4,
              "timer-enqueued new gesture runs after the outer engine callback returns");
        nestedTouch = nil;

        NSUInteger touchCountBeforeDeallocation = touchLog.count;
        __weak CCEAGLView *releasedView = nil;
        @autoreleasepool {
            CCEAGLView *ephemeralView = [CCEAGLView new];
            releasedView = ephemeralView;
            UITouch *ephemeralTouch = MakeTouch(ephemeralView, 8, 9, 0.5, 1.0);
            [ephemeralView touchesBegan:[NSSet setWithObject:ephemeralTouch] withEvent:nil];
            ephemeralView = nil;
            ephemeralTouch = nil;
        }
        Check(releasedView == nil, "queued touch work does not retain its target view");
        RunMainLoopBriefly();
        Check(touchLog.count == touchCountBeforeDeallocation,
              "queued event safely skips engine callback after its view is destroyed");

        CCDirectorCaller *caller = [CCDirectorCaller new];
        NSUInteger beforeFrames = frameCalls;
        [caller doCaller:nil]; [caller doCaller:nil]; [caller doCaller:nil];
        Check(frameCalls == beforeFrames, "frame calls are delayed until the run loop drains");
        RunMainLoopBriefly();
        Check(frameCalls == beforeFrames + 1, "multiple pending display callbacks coalesce into one frame");

        beforeFrames = frameCalls;
        [caller doCaller:nil];
        [caller stopMainLoop];
        Check(stopCalls == 1 && frameCalls == beforeFrames, "stop is immediate while its pending frame remains deferred");
        [caller doCaller:nil]; // a post-stop frame belongs to the new generation
        RunMainLoopBriefly();
        Check(frameCalls == beforeFrames + 1, "stop invalidates the old pending frame and restart can run a new one");

        beforeFrames = frameCalls; nestedTimerFired = NO; runNestedFrameLoop = YES;
        [caller doCaller:nil];
        RunMainLoopBriefly();
        Check(frameCalls == beforeFrames + 1, "frame callback runs once");
        Check(nestedTimerFired, "timer remains responsive inside nested run loop");
        printf("PASS: %lu native engine scheduling checks\n", (unsigned long)checks);
    }
    return 0;
}
