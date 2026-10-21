#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "../Sources/XP3AppKitInput.h"

static XP3LocalEventHandler registeredHandler;
@interface NSEvent : NSObject
@property(strong) id window;
+ (id)addLocalMonitorForEventsMatchingMask:(NSUInteger)mask handler:(XP3LocalEventHandler)handler;
@end
@implementation NSEvent
+ (id)addLocalMonitorForEventsMatchingMask:(NSUInteger)mask handler:(XP3LocalEventHandler)handler {
    (void)mask;
    registeredHandler = [handler copy];
    return @"monitor-token";
}
@end

static NSUInteger checks;
static void Check(BOOL value) {
    ++checks;
    if (!value) { fprintf(stderr, "FAIL: native modal input check %lu\n", (unsigned long)checks); exit(1); }
}

int main(void) {
    @autoreleasepool {
        XP3InstallAppKitInputBridge();
        IMP installed = method_getImplementation(class_getClassMethod([NSEvent class],
            @selector(addLocalMonitorForEventsMatchingMask:handler:)));
        XP3InstallAppKitInputBridge();
        Check(installed == method_getImplementation(class_getClassMethod([NSEvent class],
            @selector(addLocalMonitorForEventsMatchingMask:handler:))));
        __block NSUInteger intercepted = 0;
        id token = [NSEvent addLocalMonitorForEventsMatchingMask:~(NSUInteger)0 handler:^id(id event) {
            (void)event; ++intercepted; return nil;
        }];
        Check([token isEqual:@"monitor-token"]);
        NSEvent *game = [NSEvent new]; game.window = [NSObject new];
        NSEvent *dialog = [NSEvent new]; dialog.window = [NSObject new];
        Check(registeredHandler(game) == nil && intercepted == 1);
        XP3ModalEventWindow = dialog.window;
        Check(registeredHandler(dialog) == dialog && intercepted == 1);
        Check(registeredHandler(game) == nil && intercepted == 2);
        NSEvent *noWindow = [NSEvent new];
        Check(registeredHandler(noWindow) == nil && intercepted == 3);
        XP3ModalEventWindow = nil;
        Check(registeredHandler(dialog) == nil && intercepted == 4);
        [NSEvent addLocalMonitorForEventsMatchingMask:1 handler:^id(id event) { (void)event; return game; }];
        Check(registeredHandler(dialog) == game);
        [NSEvent addLocalMonitorForEventsMatchingMask:1 handler:nil];
        Check(registeredHandler == nil);
        printf("PASS: %lu native modal input checks\n", (unsigned long)checks);
    }
    return 0;
}
