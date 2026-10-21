// Public AppKit event-monitor API, resolved at runtime for the iOS dylib.
// PlayTools consumes mouse events intended for a native NSAlert. While that
// window is modal, its events must reach AppKit instead of touch emulation.
@interface XP3AppKitEvent : NSObject
@property(readonly) id window;
@end

typedef id (^XP3LocalEventHandler)(id event);
static id XP3ModalEventWindow;
static id (*XP3OriginalAddLocalMonitor)(id, SEL, NSUInteger, XP3LocalEventHandler);

static id XP3AddLocalMonitor(id cls, SEL cmd, NSUInteger mask, XP3LocalEventHandler handler) {
    if (!handler) return XP3OriginalAddLocalMonitor(cls, cmd, mask, handler);
    return XP3OriginalAddLocalMonitor(cls, cmd, mask, ^id(id event) {
        // Preserve every event and monitor result outside this exact window.
        // In particular, the game's mouse/keyboard mapping stays active there.
        if (XP3ModalEventWindow && [(XP3AppKitEvent *)event window] == XP3ModalEventWindow)
            return event;
        return handler(event);
    });
}

static void XP3InstallAppKitInputBridge(void) {
    if (XP3OriginalAddLocalMonitor) return;
    Class cls = objc_getClass("NSEvent");
    SEL selector = @selector(addLocalMonitorForEventsMatchingMask:handler:);
    Method method = class_getClassMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 4) return;
    XP3OriginalAddLocalMonitor = (void *)method_getImplementation(method);
    if (!class_addMethod(object_getClass(cls), selector, (IMP)XP3AddLocalMonitor,
                         method_getTypeEncoding(method)))
        method_setImplementation(method, (IMP)XP3AddLocalMonitor);
    NSLog(@"[XP3Compat] native modal event routing installed");
}
