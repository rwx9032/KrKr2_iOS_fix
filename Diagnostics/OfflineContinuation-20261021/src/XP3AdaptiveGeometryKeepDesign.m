// EXPERIMENTAL. Requires the version/identity/read guards from EngineFrameProbe.
// Uses the renderer's actual backing size; no device dimensions or transforms.
// Existing game canvases retain their logical size; only their viewport changes.
//
// Derived from Diagnostics/SceneLab/XP3AdaptiveGeometry.m
// (SHA-256 67cf5cbf4471ed6e44610decd5bc379dc73ab06bae1f429e0c367811d90ab57e).
// One opt-in addition: XP3CompatEnableAdaptiveKeepDesign.
//   off (default): unchanged original behaviour - design height is derived from
//                  the surface aspect (designHeight = designWidth * surfaceH/surfaceW).
//   on:            keep the design resolution the application itself installed and
//                  only let frame/viewport follow the surface, so the game keeps its
//                  own logical canvas ratio instead of being re-shaped per display.
// This copy does not touch production sources and is diagnostic only.
#import <objc/runtime.h>
#include <dlfcn.h>

typedef struct { float width, height; } XP3AGSize;
static void (*gXP3AGOriginalLayout)(id, SEL);
static BOOL gXP3AGUpdating;
static BOOL gXP3AGKeepDesign;
static NSUInteger gXP3AGChanges;

static BOOL XP3AGCode(uintptr_t p, uintptr_t base) {
    if (p < base || p >= base + 0x1240000) return NO;
    vm_address_t a = p; vm_size_t n = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &a, &n,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object) mach_port_deallocate(mach_task_self(), object);
    return kr == KERN_SUCCESS && a <= p && p - a < n &&
           (info.protection & VM_PROT_EXECUTE);
}

static void XP3AGReconcile(UIView *view) {
    if (gXP3AGUpdating || ![NSThread isMainThread] || !view.window) return;
    uintptr_t b = (uintptr_t)_dyld_get_image_header(0);
    uintptr_t director = 0, gl = 0, native = 0, scene = 0, ui = 0, game = 0, vt = 0;
    if (!XP3EFPointer(b + XP3EFSlot, &director) ||
        !XP3EFPointer(director + XP3EFGLViewOff, &gl) ||
        !XP3EFPointer(gl + XP3EFNativeOff, &native) ||
        native != (uintptr_t)(__bridge void *)view ||
        !XP3EFPointer(gl, &vt) || vt != b + 0x17c3e20) return;
    XP3EFGL old;
    if (!XP3EFReadGL(gl, &old) || !XP3EFSane(&old) || old.policy != 2) return;
    SEL surface = NSSelectorFromString(@"surfaceSize");
    NSMethodSignature *sig = [view methodSignatureForSelector:surface];
    if (!sig || sig.numberOfArguments != 2 ||
        strcmp(sig.methodReturnType, @encode(CGSize)) != 0) return;
    CGSize pixels = ((CGSize (*)(id, SEL))[view methodForSelector:surface])(view, surface);
    if (!isfinite(pixels.width) || !isfinite(pixels.height) ||
        pixels.width < 1 || pixels.height < 1 ||
        pixels.width > 16384 || pixels.height > 16384) return;
    if (fabs(old.sw - pixels.width) < 0.5 && fabs(old.sh - pixels.height) < 0.5) return;
    if (!XP3EFPointer(b + 0x1f9d8e8, &scene) ||
        !XP3EFPointer(scene, &vt) || vt != b + 0x179f888 ||
        !XP3EFPointer(scene + 0x340, &ui) ||
        !XP3EFPointer(scene + 0x348, &game)) return;
    for (NSUInteger i = 0; i < 2; i++) {
        uintptr_t node = i ? game : ui;
        if (!XP3EFPointer(node, &vt) || vt != b + 0x17ba6c0) return;
    }
    // Read a bounded snapshot of the original Node::getChildren vector. Only
    // actual iTVPBaseForm children receive their original virtual layout call.
    void *(*cast)(void *, const void *, const void *, ptrdiff_t) =
        dlsym(RTLD_DEFAULT, "__dynamic_cast");
    if (!cast) return;
    uintptr_t vector = (uintptr_t)((void *(*)(void *))(b + 0xe6f460))((void *)ui);
    uintptr_t begin = 0, end = 0;
    if (!XP3EFRead(vector, sizeof(begin), &begin, 8) ||
        !XP3EFRead(vector + 8, sizeof(end), &end, 8) || end < begin ||
        (end - begin) % 8 || end - begin > 128 * 8) return;
    uintptr_t forms[128], layouts[128]; NSUInteger count = 0;
    for (uintptr_t p = begin; p < end; p += 8) {
        uintptr_t child = 0;
        if (!XP3EFPointer(p, &child) || !XP3EFPointer(child, &vt) ||
            vt < b + 0x1600000 || vt >= b + 0x1800000) return;
        uintptr_t form = (uintptr_t)cast((void *)child,
            (void *)(b + 0x17babe8), (void *)(b + 0x17a6d40), 0);
        if (!form) continue;
        uintptr_t layout = 0;
        if (!XP3EFPointer(form, &vt) ||
            !XP3EFRead(vt + 0x528, 8, &layout, 8) || !XP3AGCode(layout, b)) return;
        forms[count] = form; layouts[count++] = layout;
    }
    uintptr_t gameWindows[128]; XP3AGSize canvases[128]; NSUInteger gameCount = 0;
    vector = (uintptr_t)((void *(*)(void *))(b + 0xe6f460))((void *)game);
    if (!XP3EFRead(vector, 8, &begin, 8) || !XP3EFRead(vector + 8, 8, &end, 8) ||
        end < begin || (end - begin) % 8 || end - begin > 128 * 8) return;
    for (uintptr_t p = begin; p < end; p += 8) {
        uintptr_t child = 0;
        if (!XP3EFPointer(p, &child) || !XP3EFPointer(child, &vt)) return;
        if (vt != b + 0x17a0a40) continue; // exact TVPWindowLayer primary vtable
        XP3AGSize canvas;
        if (!XP3EFRead(child + 0x80, sizeof(canvas), &canvas, 4) ||
            !isfinite(canvas.width) || !isfinite(canvas.height) ||
            canvas.width < 1 || canvas.height < 1 ||
            canvas.width > 16384 || canvas.height > 16384) return;
        gameWindows[gameCount] = child; canvases[gameCount++] = canvas;
    }
    XP3AGSize size;
    size.width = old.dw;
    if (gXP3AGKeepDesign) {
        // Keep the application's own design resolution. A derived design would
        // change the logical canvas ratio (and therefore UI layout / input
        // mapping) whenever the surface aspect differs from the game's canvas.
        size.height = old.dh;
        if (!isfinite(size.width) || !isfinite(size.height) ||
            size.width < 1 || size.height < 1 ||
            size.width > 16384 || size.height > 16384) return;
    } else {
        size.height = old.dw * (float)(pixels.height / pixels.width);
        if (!isfinite(size.height) || size.height < 1 || size.height > 16384) return;
    }
    gXP3AGUpdating = YES;
    @try {
        ((void (*)(void *, float, float))(b + 0x111011c))((void *)gl,
            (float)pixels.width, (float)pixels.height);
        ((void (*)(void *, float, float, int))(b + 0x11100c4))((void *)gl,
            size.width, size.height, old.policy);
        void (*setSize)(void *, const XP3AGSize *) = (void *)(b + 0xff2478);
        setSize((void *)scene, &size);
        setSize((void *)ui, &size);
        setSize((void *)game, &size);
        for (NSUInteger i = 0; i < gameCount; i++) {
            // ScrollView::setViewSize also changes Node::contentSize. Restore
            // the game's logical canvas before its original aspect-fit code.
            ((void (*)(void *, const XP3AGSize *))(b + 0xf89318))((void *)gameWindows[i], &size);
            setSize((void *)gameWindows[i], &canvases[i]);
            ((void (*)(void *))(b + 0xe73300))((void *)gameWindows[i]);
        }
        for (NSUInteger i = 0; i < count; i++)
            ((void (*)(void *))layouts[i])((void *)forms[i]);
        if (gXP3AGChanges++ < 16)
            NSLog(@"[XP3AdaptiveGeometry] frame %.0fx%.0f -> %.0fx%.0f, design %.2fx%.2f, forms=%lu games=%lu",
                old.sw, old.sh, pixels.width, pixels.height,
                size.width, size.height, (unsigned long)count, (unsigned long)gameCount);
    } @finally {
        gXP3AGUpdating = NO;
    }
}

static void XP3AGLayout(id self, SEL cmd) {
    gXP3AGOriginalLayout(self, cmd);
    XP3AGReconcile(self);
}

__attribute__((constructor)) static void XP3AGInstall(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSDictionary *info = bundle.infoDictionary ?: @{};
        if (![bundle.bundleIdentifier isEqualToString:@"tvp.XP3Player.Compat"] ||
            ![info[@"XP3CompatEnableAdaptiveGeometry"] boolValue] ||
            !XP3EFUUIDOK()) return;
        id keepDesign = info[@"XP3CompatEnableAdaptiveKeepDesign"];
        gXP3AGKeepDesign = [keepDesign respondsToSelector:@selector(boolValue)]
            ? [keepDesign boolValue] : NO;
        NSLog(@"[XP3AdaptiveGeometry] installed (keepDesign=%@)",
              gXP3AGKeepDesign ? @"yes" : @"no");
        Method layout = class_getInstanceMethod(NSClassFromString(@"CCEAGLView"), @selector(layoutSubviews));
        if (!layout || strcmp(method_getTypeEncoding(layout), "v16@0:8") != 0) return;
        gXP3AGOriginalLayout = (void *)method_getImplementation(layout);
        method_setImplementation(layout, (IMP)XP3AGLayout);
    }
}
