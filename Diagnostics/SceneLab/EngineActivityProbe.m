// Diagnostic only. Observe the app-owned legacy display-link driver; no ticks
// are manufactured and no lifecycle, paused state, or display link is changed.
//
// Audit notes for this revision:
//   * the raw singleton slot is checked nonnull/readable before the public
//     sharedDirectorCaller getter is sent (the getter is never used to create);
//   * the hook is installed only when CCDirectorCaller itself owns doCaller:,
//     so an inherited/superclass implementation is never mutated;
//   * the original implementation is saved before replacement and invoked
//     exactly once with the original arguments;
//   * timestamp/duration are emitted only when finite, otherwise JSON null.
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

static NSUInteger gXP3EACalls;
static void (*gXP3EAOriginalCall)(id, SEL, id);

static BOOL XP3EAOwnsMethod(Class cls, SEL selector) {
    if (cls == Nil || selector == NULL) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            owns = YES;
            break;
        }
    }
    if (methods != NULL) free(methods);
    return owns;
}

static void XP3EACall(id self, SEL cmd, id link) {
    // The callback can arrive on a different run-loop thread in principle;
    // count atomically while preserving the original call exactly once.
    __atomic_fetch_add(&gXP3EACalls, 1, __ATOMIC_RELAXED);
    void (*original)(id, SEL, id) =
        __atomic_load_n(&gXP3EAOriginalCall, __ATOMIC_ACQUIRE);
    if (original != NULL) {
        original(self, cmd, link);
    }
}

static NSDictionary *XP3EARecord(void) {
    NSUInteger calls = __atomic_load_n(&gXP3EACalls, __ATOMIC_RELAXED);
    NSMutableDictionary *r = [@{@"callbackCount": @(calls)} mutableCopy];
    uintptr_t pointer = 0;
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    if (base == 0 || base > UINTPTR_MAX - 0x1fa0cb8 ||
        !XP3EFPointer(base + 0x1fa0cb8, &pointer) || pointer == 0) {
        r[@"callerExists"] = @NO;
        r[@"reason"] = base == 0 ? @"mainHeaderUnavailable" : @"callerSlotUnreadableOrNull";
        return r;
    }

    Class cls = NSClassFromString(@"CCDirectorCaller");
    SEL getter = NSSelectorFromString(@"sharedDirectorCaller");
    if (cls == Nil || ![cls respondsToSelector:getter]) {
        r[@"callerExists"] = @NO;
        r[@"reason"] = cls == Nil ? @"callerClassMissing" : @"callerGetterMissing";
        return r;
    }
    IMP getterIMP = [cls methodForSelector:getter];
    if (getterIMP == NULL) {
        r[@"callerExists"] = @NO;
        r[@"reason"] = @"callerGetterUnavailable";
        return r;
    }

    // The singleton slot is already nonnull, so this public getter cannot
    // create a driver as a side effect. Never message the raw stored pointer.
    id caller = ((id (*)(id, SEL))getterIMP)(cls, getter);
    if ((uintptr_t)(__bridge void *)caller != pointer || ![caller isKindOfClass:cls]) {
        r[@"callerExists"] = @NO;
        r[@"reason"] = @"singletonIdentityMismatch";
        return r;
    }
    r[@"callerExists"] = @YES;

    BOOL readable = YES;
    @try {
        id active = [caller valueForKey:@"isAppActive"];
        if ([active isKindOfClass:[NSNumber class]]) {
            r[@"driverActive"] = @([active boolValue]);
        } else {
            r[@"driverActive"] = [NSNull null];
            readable = NO;
        }

        id link = [caller valueForKey:@"displayLink"];
        BOOL isDisplayLink = [link isKindOfClass:CADisplayLink.class];
        r[@"hasDisplayLink"] = @(isDisplayLink);
        if (isDisplayLink) {
            CADisplayLink *displayLink = (CADisplayLink *)link;
            r[@"paused"] = @(displayLink.paused);
            double timestamp = displayLink.timestamp;
            double duration = displayLink.duration;
            BOOL timestampFinite = isfinite(timestamp);
            BOOL durationFinite = isfinite(duration);
            r[@"timestampFinite"] = @(timestampFinite);
            r[@"durationFinite"] = @(durationFinite);
            r[@"timestamp"] = timestampFinite ? @(timestamp) : [NSNull null];
            r[@"duration"] = durationFinite ? @(duration) : [NSNull null];
        }
    } @catch (NSException *exception) {
        (void)exception;
        readable = NO;
    }
    r[@"stateReadable"] = @(readable);
    return r;
}

__attribute__((constructor)) static void XP3EAInstall(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle.infoDictionary[@"XP3CompatEnableActivityProbe"] boolValue] ||
            !XP3EFUUIDOK()) return;

        Class cls = NSClassFromString(@"CCDirectorCaller");
        SEL selector = NSSelectorFromString(@"doCaller:");
        Method call = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
        if (call == NULL || !XP3EAOwnsMethod(cls, selector) ||
            strcmp(method_getTypeEncoding(call), "v24@0:8@16") != 0) {
            NSLog(@"[XP3ActivityProbe] doCaller: is not directly hookable; skipped");
            return;
        }

        IMP original = method_getImplementation(call);
        if (original == NULL) {
            NSLog(@"[XP3ActivityProbe] doCaller: original implementation missing; skipped");
            return;
        }
        // Publish the original before the swap so a concurrent callback cannot
        // see a null original after the hook becomes reachable.
        __atomic_store_n(&gXP3EAOriginalCall,
                         (void (*)(id, SEL, id))original, __ATOMIC_RELEASE);
        method_setImplementation(call, (IMP)XP3EACall);
        gXP3EFActivityProvider = XP3EARecord;
        NSLog(@"[XP3ActivityProbe] installed read-only caller counter");
    }
}
