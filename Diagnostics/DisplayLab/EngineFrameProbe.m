// XP3Compat EngineFrameProbe 1.0.0 -- DIAGNOSTIC ONLY, NOT SHIPPING.
// Separate constructor; own 2 s main NSTimer, 150-snapshot cap, own atomic
// Documents/XP3CompatEngineFrame.json.  Main UUID is parsed from public
// dyld/mach-o LC_UUID.  Every raw load is guarded by a public self-task
// vm_region_64 readability check and alignment.  No C++ calls/constructors, no
// messaging of stored pointers, no pixels/text/files/saves/certs, geometry only.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <uuid/uuid.h>
#include <math.h>
#include <stddef.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const NSTimeInterval XP3EFInterval = 2.0;
static const NSUInteger XP3EFMaxSnapshots = 150, XP3EFMaxWindows = 32;
static const NSUInteger XP3EFMaxNodes = 900, XP3EFMaxDepth = 16;
static const char *XP3EFUUID = "4D80597B-5F2E-3693-AA68-734DD4D827B1";
static const uintptr_t XP3EFSlot = 0x1f9f230;   // main+slot -> Director*
static const uintptr_t XP3EFGLViewOff = 0x108; // Director+off -> GLViewImpl*
static const uintptr_t XP3EFNativeOff = 0x78;  // GLViewImpl+off -> CCEAGLView*
static const uintptr_t XP3EFScreen = 0x24, XP3EFDesign = 0x2c, XP3EFViewport = 0x34;
static const uintptr_t XP3EFScales = 0x60, XP3EFPolicy = 0x68;

typedef struct { float sw, sh, dw, dh, vx, vy, vw, vh, sx, sy; int32_t policy; } XP3EFGL;
static NSMutableArray<NSDictionary *> *gXP3EFRecords;
static NSTimer *gXP3EFTimer;
static NSString *gXP3EFStartedAt, *gXP3EFStopReason;
static BOOL gXP3EFStarted, gXP3EFFinished, gXP3EFUUIDMatched;
static NSDictionary *(*gXP3EFActivityProvider)(void);

#pragma mark - Bounded raw reads

// iOS/arm64 marks <mach/mach_vm.h> unsupported; vm_region_64 is the public
// self-task region query there (same VM_REGION_BASIC_INFO_64 contract).
static BOOL XP3EFReadable(uintptr_t a, size_t n) {
    if (!a || !n || n > UINTPTR_MAX - a) return NO;
    vm_address_t region = (vm_address_t)a;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (kr != KERN_SUCCESS || !(info.protection & VM_PROT_READ)) return NO;
    if (a < (uintptr_t)region) return NO;
    uintptr_t off = a - (uintptr_t)region;
    return off <= (uintptr_t)size && n <= (size_t)((uintptr_t)size - off);
}

static BOOL XP3EFRead(uintptr_t a, size_t n, void *out, size_t align) {
    if (!out || !align || a % align || !XP3EFReadable(a, n)) return NO;
    memcpy(out, (const void *)a, n);
    return YES;
}

static BOOL XP3EFPointer(uintptr_t slot, uintptr_t *out) {
    uintptr_t p = 0;
    if (!XP3EFRead(slot, sizeof(p), &p, sizeof(void *))) return NO;
    if (!p || p % sizeof(void *) || !XP3EFReadable(p, sizeof(void *))) return NO;
    *out = p;
    return YES;
}

static BOOL XP3EFF32(uintptr_t b, uintptr_t off, float *out) {
    return b <= UINTPTR_MAX - off && XP3EFRead(b + off, sizeof(float), out, 4);
}
static BOOL XP3EFS32(uintptr_t b, uintptr_t off, int32_t *out) {
    return b <= UINTPTR_MAX - off && XP3EFRead(b + off, sizeof(int32_t), out, 4);
}

#pragma mark - Main UUID (public dyld + LC_UUID)

static BOOL XP3EFUUIDOK(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh) return NO;
    uintptr_t b = (uintptr_t)mh, start = b + sizeof(*mh), end = 0;
    uint32_t magic = 0, type = 0, ncmds = 0, cmdsz = 0;
    if (!XP3EFRead(b, 4, &magic, 4) || magic != MH_MAGIC_64) return NO;
    if (!XP3EFRead(b + offsetof(struct mach_header_64, filetype), 4, &type, 4) ||
        type != MH_EXECUTE) return NO;
    if (!XP3EFRead(b + offsetof(struct mach_header_64, ncmds), 4, &ncmds, 4) ||
        !XP3EFRead(b + offsetof(struct mach_header_64, sizeofcmds), 4, &cmdsz, 4)) return NO;
    end = start + cmdsz;
    if (!ncmds || ncmds > 1024 || cmdsz < 8 || end < start) return NO;
    uuid_t want;
    if (uuid_parse(XP3EFUUID, want) != 0) return NO;
    uintptr_t p = start;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = 0, n = 0;
        if (!XP3EFRead(p, 4, &cmd, 4) || !XP3EFRead(p + 4, 4, &n, 4)) return NO;
        if (n < 8 || n > end - p) return NO;
        if (cmd == LC_UUID) {
            uuid_t got;
            if (n < sizeof(struct uuid_command) ||
                !XP3EFRead(p + offsetof(struct uuid_command, uuid), sizeof(uuid_t), got, 1)) return NO;
            return uuid_compare(got, want) == 0;
        }
        p += n;
    }
    return NO;
}

#pragma mark - Bounded UIKit traversal (app-owned objects only)

static UIView *XP3EFSearch(UIView *v, uintptr_t target, NSUInteger depth, NSUInteger *seen) {
    if (!v || depth > XP3EFMaxDepth || *seen >= XP3EFMaxNodes) return nil;
    (*seen)++;
    if ((uintptr_t)(__bridge void *)v == target) return v;
    NSArray<UIView *> *kids = v.subviews;
    for (NSUInteger i = 0, n = MIN(kids.count, (NSUInteger)64); i < n; i++) {
        UIView *hit = XP3EFSearch(kids[i], target, depth + 1, seen);
        if (hit) return hit;
    }
    return nil;
}

static NSArray<UIWindow *> *XP3EFAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            // Active, connected scenes first; the engine window lives here after
            // public UIScene adoption, where deprecated UIApplication.windows
            // may no longer report it.
            if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in windowScene.windows) {
                if (w && ![windows containsObject:w]) [windows addObject:w];
            }
        }
    }
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w && ![windows containsObject:w]) [windows addObject:w];
    }
    return windows;
}

static UIView *XP3EFNativeView(uintptr_t target, UIWindow **owner) {
    NSArray<UIWindow *> *windows = XP3EFAllWindows();
    NSUInteger seen = 0;
    for (NSUInteger i = 0, n = MIN(windows.count, XP3EFMaxWindows); i < n; i++) {
        UIView *hit = XP3EFSearch(windows[i], target, 0, &seen);
        if (hit) { if (owner) *owner = windows[i]; return hit; }
    }
    return nil;
}

static UIWindow *XP3EFKeyWindow(void) {
    NSArray<UIWindow *> *windows = XP3EFAllWindows();
    UIWindow *first = nil;
    for (NSUInteger i = 0, n = MIN(windows.count, XP3EFMaxWindows); i < n; i++) {
        UIWindow *w = windows[i];
        if (!first) first = w;
        if (w.isKeyWindow && !w.isHidden) return w;
    }
    return first;
}

#pragma mark - Geometry helpers

static BOOL XP3EFRange(float v, float lo, float hi) {
    return isfinite(v) && v >= lo && v <= hi;
}

static BOOL XP3EFReadGL(uintptr_t g, XP3EFGL *f) {
    memset(f, 0, sizeof(*f));
    return XP3EFF32(g, XP3EFScreen, &f->sw) && XP3EFF32(g, XP3EFScreen + 4, &f->sh) &&
           XP3EFF32(g, XP3EFDesign, &f->dw) && XP3EFF32(g, XP3EFDesign + 4, &f->dh) &&
           XP3EFF32(g, XP3EFViewport, &f->vx) && XP3EFF32(g, XP3EFViewport + 4, &f->vy) &&
           XP3EFF32(g, XP3EFViewport + 8, &f->vw) && XP3EFF32(g, XP3EFViewport + 12, &f->vh) &&
           XP3EFF32(g, XP3EFScales, &f->sx) && XP3EFF32(g, XP3EFScales + 4, &f->sy) &&
           XP3EFS32(g, XP3EFPolicy, &f->policy);
}

static BOOL XP3EFSane(const XP3EFGL *f) {
    return XP3EFRange(f->sw, 1, 16384) && XP3EFRange(f->sh, 1, 16384) &&
           XP3EFRange(f->dw, 1, 16384) && XP3EFRange(f->dh, 1, 16384) &&
           XP3EFRange(f->vx, -16384, 16384) && XP3EFRange(f->vy, -16384, 16384) &&
           XP3EFRange(f->vw, 0.01f, 16384) && XP3EFRange(f->vh, 0.01f, 16384) &&
           XP3EFRange(f->sx, 0.01f, 64) && XP3EFRange(f->sy, 0.01f, 64) &&
           f->policy >= 0 && f->policy <= 8;
}

static id XP3EFRect(CGRect r) {
    if (CGRectIsNull(r) || CGRectIsInfinite(r) || !isfinite(r.origin.x) ||
        !isfinite(r.origin.y) || !isfinite(r.size.width) || !isfinite(r.size.height))
        return [NSNull null];
    return @{@"x": @(r.origin.x), @"y": @(r.origin.y),
             @"width": @(r.size.width), @"height": @(r.size.height)};
}

static id XP3EFSize(float w, float h) {
    return (isfinite(w) && isfinite(h)) ? @{@"width": @(w), @"height": @(h)} : [NSNull null];
}

static id XP3EFPair(float x, float y) {
    return (isfinite(x) && isfinite(y)) ? @{@"x": @(x), @"y": @(y)} : [NSNull null];
}

static id XP3EFScene(UIWindow *w) {
    UIWindowScene *s = w.windowScene;
    return s ? XP3EFRect(s.coordinateSpace.bounds) : [NSNull null];
}

static NSString *XP3EFNow(void) {
    static NSISO8601DateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSISO8601DateFormatter new]; });
    return [f stringFromDate:[NSDate date]];
}

#pragma mark - Snapshot / output

static NSDictionary *XP3EFRecord(void) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"seq"] = @(gXP3EFRecords.count + 1);
    r[@"timestamp"] = XP3EFNow();
    r[@"uptime"] = @([NSProcessInfo processInfo].systemUptime);

    uintptr_t b = (uintptr_t)_dyld_get_image_header(0), director = 0, gl = 0, native = 0;
    BOOL directorOK = b && b <= UINTPTR_MAX - XP3EFSlot &&
                      XP3EFPointer(b + XP3EFSlot, &director);
    BOOL glOK = directorOK && director <= UINTPTR_MAX - XP3EFGLViewOff &&
                XP3EFPointer(director + XP3EFGLViewOff, &gl);
    BOOL nativeOK = glOK && gl <= UINTPTR_MAX - XP3EFNativeOff &&
                    XP3EFPointer(gl + XP3EFNativeOff, &native);
    UIWindow *owner = nil;
    UIView *view = nativeOK ? XP3EFNativeView(native, &owner) : nil;
    BOOL matched = view != nil, read = NO, sane = NO;
    XP3EFGL f;
    // GL fields are touched only after the stored pointer is proven identical to
    // a traversed UIView; the stored pointer itself is never messaged.
    if (matched) {
        read = XP3EFReadGL(gl, &f);
        sane = read && XP3EFSane(&f);
    }
    UIWindow *w = matched ? owner : XP3EFKeyWindow();
    r[@"nativeViewBounds"] = matched ? XP3EFRect(view.bounds) : [NSNull null];
    r[@"windowBounds"] = w ? XP3EFRect(w.bounds) : [NSNull null];
    r[@"sceneBounds"] = w ? XP3EFScene(w) : [NSNull null];
    r[@"gl"] = sane ? @{@"screenSize": XP3EFSize(f.sw, f.sh),
                        @"designSize": XP3EFSize(f.dw, f.dh),
                        @"viewport": @{@"x": @(f.vx), @"y": @(f.vy),
                                       @"width": @(f.vw), @"height": @(f.vh)},
                        @"scales": XP3EFPair(f.sx, f.sy),
                        @"resolutionPolicy": @(f.policy)} : [NSNull null];
    NSString *why = !directorOK ? @"directorUnreadable" :
                    !glOK ? @"glViewUnreadable" :
                    !nativeOK ? @"nativePointerUnreadable" :
                    !matched ? @"nativePointerNotInWindowTree" :
                    !read ? @"glFieldsUnreadable" :
                    !sane ? @"glFieldsNotSensible" : nil;
    r[@"geometryValid"] = @(sane);
    r[@"invalidReason"] = why ?: [NSNull null];
    r[@"checks"] = @{@"directorReadable": @(directorOK), @"glViewReadable": @(glOK),
                     @"nativePointerReadable": @(nativeOK), @"nativeViewMatched": @(matched),
                     @"glFieldsReadable": @(read), @"glFieldsSensible": @(sane)};
    if (gXP3EFActivityProvider) r[@"activity"] = gXP3EFActivityProvider();
    return r;
}

static NSDictionary *XP3EFPayload(void) {
    return @{@"schema": @1,
        @"probe": @{@"name": @"XP3Compat EngineFrameProbe", @"version": @"1.0.0",
            @"built": [NSString stringWithFormat:@"%s %s", __DATE__, __TIME__],
            @"readOnly": @YES, @"mode": @"engine-frame-geometry-only",
            @"timerSeconds": @(XP3EFInterval), @"maxSnapshots": @(XP3EFMaxSnapshots),
            @"outputFileName": @"XP3CompatEngineFrame.json",
            @"boundaries": @[@"requires main executable UUID via public dyld/mach-o",
                @"raw reads guarded by public self-task vm_region_64 readability + alignment",
                @"no C++ calls or constructors; stored pointers are never messaged",
                @"native view accepted only by exact UIView pointer identity in bounded window tree",
                @"geometry only: no pixels/text/files/saves/certs or pointer dumps",
                @"writes only app Documents/XP3CompatEngineFrame.json atomically"]},
        @"main": @{@"uuidExpected": [NSString stringWithUTF8String:XP3EFUUID],
                   @"uuidMatched": @(gXP3EFUUIDMatched)},
        @"startedAt": gXP3EFStartedAt ?: @"", @"stopReason": gXP3EFStopReason ?: @"running",
        @"snapshotCount": @(gXP3EFRecords.count), @"records": gXP3EFRecords ?: @[]};
}

static void XP3EFWrite(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ XP3EFWrite(); });
        return;
    }
    if (!gXP3EFStarted || !gXP3EFRecords) return;
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:XP3EFPayload()
        options:NSJSONWritingPrettyPrinted error:&err];
    NSString *dir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!data || !dir.length) {
        NSLog(@"[XP3EngineProbe] JSON/Documents unavailable (domain=%@ code=%ld)",
              err.domain ?: @"unknown", (long)err.code);
        return;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"XP3CompatEngineFrame.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&err])
        NSLog(@"[XP3EngineProbe] atomic write failed (domain=%@ code=%ld)",
              err.domain ?: @"unknown", (long)err.code);
}

static void XP3EFSnapshot(void) {
    if (!gXP3EFStarted || gXP3EFFinished) return;
    [gXP3EFRecords addObject:XP3EFRecord()];
    if (gXP3EFRecords.count >= XP3EFMaxSnapshots) {
        gXP3EFFinished = YES;
        gXP3EFStopReason = @"maxSnapshots";
        [gXP3EFTimer invalidate];
        gXP3EFTimer = nil;
    }
    XP3EFWrite();
}

static void XP3EFStart(void) {
    if (gXP3EFStarted || ![NSThread isMainThread]) return;
    gXP3EFStarted = YES;
    gXP3EFUUIDMatched = XP3EFUUIDOK();
    if (!gXP3EFUUIDMatched) {
        NSLog(@"[XP3EngineProbe] main UUID mismatch (%s); sampling skipped", XP3EFUUID);
        return;
    }
    gXP3EFStartedAt = XP3EFNow();
    gXP3EFRecords = [NSMutableArray arrayWithCapacity:XP3EFMaxSnapshots];
    gXP3EFStopReason = @"running";
    gXP3EFTimer = [NSTimer timerWithTimeInterval:XP3EFInterval repeats:YES
        block:^(NSTimer *t) { (void)t; XP3EFSnapshot(); }];
    [[NSRunLoop mainRunLoop] addTimer:gXP3EFTimer forMode:NSRunLoopCommonModes];
    XP3EFWrite();
    NSLog(@"[XP3EngineProbe] started read-only; output=Documents/XP3CompatEngineFrame.json");
}

__attribute__((constructor))
static void XP3EFConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ XP3EFStart(); });
}
