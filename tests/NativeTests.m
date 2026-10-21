#import "FakeUIKit.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    ++checks;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static UIAlertView *MakeAlert(id receiver, BOOL cancel) {
    return [[UIAlertView alloc] initWithTitle:@"Create folder" message:@"Name"
        delegate:receiver cancelButtonTitle:cancel ? @"Cancel" : nil
        otherButtonTitles:@"OK", cancel ? nil : @"Cancel", nil];
}

static void PumpUntil(BOOL (^condition)(void), NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && end.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        [NSThread sleepForTimeInterval:0.001];
    }
}

static NSDate *recordedDeadline;
static NSString *recordedMode;
static NSUInteger publicLoopCalls;
static BOOL publicLoopResult;
static BOOL RecordPublicRunMode(id self, SEL cmd, NSString *mode, NSDate *deadline) {
    (void)self; (void)cmd;
    recordedDeadline = deadline;
    recordedMode = mode;
    ++publicLoopCalls;
    return publicLoopResult;
}

static void TestRunLoop(void) {
    Method method = class_getInstanceMethod([NSRunLoop class], @selector(runMode:beforeDate:));
    IMP original = method_setImplementation(method, (IMP)RecordPublicRunMode);
    @try {
        DAFRunLoop *loop = [DAFRunLoop currentRunLoop];
        NSDate *start = [NSDate date];
        publicLoopResult = YES;
        Check([loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]], @"run loop preserves public YES result");
        NSTimeInterval interval = [recordedDeadline timeIntervalSinceDate:start];
        Check(interval > 0 && interval <= 0.06, @"distant future is clamped to a 50 ms slice");
        Check([recordedMode isEqualToString:NSDefaultRunLoopMode], @"run loop mode is forwarded");
        NSDate *shortDeadline = [NSDate dateWithTimeIntervalSinceNow:0.005];
        [loop runMode:NSDefaultRunLoopMode beforeDate:shortDeadline];
        Check(recordedDeadline == shortDeadline, @"earlier caller deadline is preserved");
        publicLoopResult = NO;
        Check(![loop runMode:NSDefaultRunLoopMode beforeDate:nil], @"run loop preserves public NO result");
        Check(publicLoopCalls == 3 && XP3FakeOriginalRunLoopCalls == 0, @"original private-layout DAFRunLoop is never called");
    } @finally {
        method_setImplementation(method, original);
    }
}

static void TestUnrelatedAlert(void) {
    XP3FakeResetApplication(YES);
    NSObject *otherDelegate = [NSObject new];
    UIAlertView *alert = MakeAlert(otherDelegate, YES);
    alert.alertViewStyle = 2;
    UITextField *field = [alert textFieldAtIndex:0];
    [alert show];
    [alert dismissWithClickedButtonIndex:0 animated:NO];
    Check(alert.legacyStyleCount == 1 && alert.legacyFieldCount == 1 && field != nil,
          @"unrelated styles and fields use original UIKit implementations");
    Check(alert.legacyShowCount == 1 && alert.legacyDismissCount == 1,
          @"unrelated show and dismissal use original UIKit implementations");
    Check(XP3FakePresentCount == 0, @"unrelated delegate never enters modern bridge");
}

static void TestInputAndButtonMapping(void) {
    for (NSInteger selected = 0; selected < 2; ++selected) {
        XP3FakeResetApplication(YES);
        MessageBoxEventRecevier *receiver = [MessageBoxEventRecevier new];
        UIAlertView *alert = MakeAlert(receiver, NO);
        alert.alertViewStyle = 2;
        UITextField *beforeShow = [alert textFieldAtIndex:0];
        Check(beforeShow != nil && !beforeShow.secureTextEntry, @"style 2 creates a plain text field before show");
        beforeShow.text = @"Initial folder";
        [alert show];
        UIAlertController *controller = XP3FakeLastPresentedAlert;
        Check(controller != nil && controller.textFields[0] == beforeShow,
              @"pre-show field and displayed field are the exact same object");
        Check([controller.textFields[0].text isEqualToString:@"Initial folder"], @"initial text survives presentation");
        Check(controller.actions.count == 2 &&
              [controller.actions[0].title isEqualToString:@"OK"] &&
              [controller.actions[1].title isEqualToString:@"Cancel"], @"button order is preserved");
        [alert show];
        Check(XP3FakePresentCount == 1 && controller.actions.count == 2, @"duplicate show creates no extra presentation or actions");
        controller.textFields[0].text = @"Edited folder";
        [controller.actions[(NSUInteger)selected] invoke];
        Check(receiver.selectedIndex == selected && receiver.lastAlert == alert,
              @"legacy callback receives the original alert and exact button index");
        Check([beforeShow.text isEqualToString:@"Edited folder"] && [alert textFieldAtIndex:0] == beforeShow,
              @"caller can read the latest edited text through the retained pre-show field");
        [controller.actions[(NSUInteger)selected] invoke];
        [alert dismissWithClickedButtonIndex:1 animated:NO];
        [alert show];
        Check(receiver.callbackCount == 1 && XP3FakePresentCount == 1, @"duplicate action, dismiss, and show finish only once");
        Check([alert isKindOfClass:NSClassFromString(@"XP3LegacyAlert")],
              @"target dialog uses a configuration surrogate instead of deprecated UIKit allocation");
    }
}

static void TestStylesAndDismiss(void) {
    XP3FakeResetApplication(YES);
    MessageBoxEventRecevier *receiver = [MessageBoxEventRecevier new];
    UIAlertView *alert = MakeAlert(receiver, YES);
    alert.alertViewStyle = 3;
    UITextField *login = [alert textFieldAtIndex:0];
    UITextField *password = [alert textFieldAtIndex:1];
    Check(login && password && !login.secureTextEntry && password.secureTextEntry,
          @"login-and-password style gives only the password secure entry");
    Check([alert textFieldAtIndex:-1] == nil && [alert textFieldAtIndex:2] == nil,
          @"invalid field indexes return nil");
    [alert show];
    Check(XP3FakeLastPresentedAlert.actions[0].style == 1, @"legacy cancel button maps to cancel action style");
    [alert dismissWithClickedButtonIndex:-1 animated:NO];
    Check(receiver.callbackCount == 0 && receiver.selectedIndex == -1 &&
          XP3FakeLastPresentedAlert.presentingViewController != nil,
          @"invalid dismissal index neither dismisses nor guesses a legacy action");
    [alert dismissWithClickedButtonIndex:0 animated:NO];
    Check(receiver.callbackCount == 1 && receiver.selectedIndex == 0,
          @"valid programmatic cancel preserves its legacy index");
    Check([alert isKindOfClass:NSClassFromString(@"XP3LegacyAlert")], @"bridged dismissal uses the surrogate implementation");
}

static void TestUnavailablePresenter(void) {
    XP3FakeResetApplication(NO);
    MessageBoxEventRecevier *receiver = [MessageBoxEventRecevier new];
    UIAlertView *alert = MakeAlert(receiver, NO);
    [alert show];
    PumpUntil(^BOOL { return receiver.callbackCount != 0; }, 0.15);
    Check(receiver.callbackCount == 0 && receiver.selectedIndex == -1 && XP3FakePresentCount == 0,
          @"missing presenter does not guess a possibly destructive button");
    XP3FakeResetApplication(YES);
    PumpUntil(^BOOL { return XP3FakePresentCount != 0; }, 0.3);
    Check(XP3FakePresentCount == 1, @"pending dialog presents when a window becomes available");
    [XP3FakeLastPresentedAlert.actions[1] invoke];
    Check(receiver.callbackCount == 1 && receiver.selectedIndex == 1,
          @"user chooses cancellation after presenter recovery");
    [alert show];
    Check(receiver.callbackCount == 1, @"recovered presentation also completes exactly once");
}

static void TestButtonlessDialog(void) {
    XP3FakeResetApplication(YES);
    MessageBoxEventRecevier *receiver = [MessageBoxEventRecevier new];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Notice" message:@"Message"
        delegate:receiver cancelButtonTitle:nil otherButtonTitles:nil];
    [alert show];
    Check(XP3FakeLastPresentedAlert.actions.count == 1 &&
          [XP3FakeLastPresentedAlert.actions[0].title isEqualToString:@"Close"],
          @"buttonless dialog gains a visible Close action");
    Check(receiver.callbackCount == 0, @"buttonless dialog waits for user interaction");
    [alert dismissWithClickedButtonIndex:1 animated:NO];
    Check(receiver.callbackCount == 0 && XP3FakeLastPresentedAlert.presentingViewController != nil,
          @"buttonless dialog rejects indexes outside its single synthetic Close action");
    [XP3FakeLastPresentedAlert.actions[0] invoke];
    Check(receiver.callbackCount == 1 && receiver.selectedIndex == 0,
          @"Close ends a buttonless legacy wait with a nonnegative index");
}

static void TestTransientInactiveApplication(void) {
    XP3FakeResetApplication(YES);
    UIApplication *application = [UIApplication sharedApplication];
    application.applicationState = 1;
    MessageBoxEventRecevier *receiver = [MessageBoxEventRecevier new];
    UIAlertView *alert = MakeAlert(receiver, NO);
    [alert show];
    Check(XP3FakePresentCount == 0 && receiver.callbackCount == 0, @"inactive application defers presentation");
    application.applicationState = 0;
    PumpUntil(^BOOL { return XP3FakePresentCount != 0; }, 0.3);
    Check(XP3FakePresentCount == 1, @"active application recovers on scheduled retry");
    [XP3FakeLastPresentedAlert.actions[0] invoke];
    Check(receiver.callbackCount == 1 && receiver.selectedIndex == 0, @"retried presentation keeps callback mapping");
}

static void TestRealNestedRunLoop(void) {
    XP3FakeResetApplication(YES);
    MessageBoxEventRecevier *receiver = [MessageBoxEventRecevier new];
    UIAlertView *alert = MakeAlert(receiver, NO);
    alert.alertViewStyle = 2;
    UITextField *field = [alert textFieldAtIndex:0];
    [alert show];
    // Exercise the public Foundation run loop, not the recording stub above.
    [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        field.text = @"新建目录";
        [XP3FakeLastPresentedAlert.actions[0] invoke];
    }];
    DAFRunLoop *loop = [DAFRunLoop currentRunLoop];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (receiver.selectedIndex < 0 && deadline.timeIntervalSinceNow > 0)
        [loop runMode:NSDefaultRunLoopMode beforeDate:deadline];
    Check(receiver.selectedIndex == 0 && receiver.callbackCount == 1,
          @"actual Foundation nested run loop processes completion and ends legacy wait");
    Check([field.text isEqualToString:@"新建目录"] && XP3FakeOriginalRunLoopCalls == 0,
          @"actual nested wait preserves edited Unicode text without entering private DAF code");
}

static void TestAllocationScope(void) {
    Check([[NSObject new] class] == [NSObject class], @"NSObject allocation remains untouched");
    NSUInteger before = XP3FakeLegacyInitCount;
    MessageBoxEventRecevier *receiver = [MessageBoxEventRecevier new];
    UIAlertView *target = MakeAlert(receiver, NO);
    Check(target != nil && XP3FakeLegacyInitCount == before,
          @"target initializer bypasses original UIKit construction completely");
    NSObject *other = [NSObject new];
    UIAlertView *native = [[UIAlertView alloc] initWithTitle:@"Unrelated" message:nil delegate:other
        cancelButtonTitle:@"Cancel" otherButtonTitles:@"One", @"Two", nil];
    Check([native class] == [UIAlertView class] && XP3FakeLegacyInitCount == before + 1,
          @"unrelated delegate still gets the original UIKit class and initializer");
    Check(native.numberOfButtons == 3 && native.cancelButtonIndex == 0 &&
        [[native buttonTitleAtIndex:2] isEqualToString:@"Two"],
        @"unrelated initializer preserves all variadic buttons and cancel index");
}

int main(void) {
    @autoreleasepool {
        Check([NSThread isMainThread], @"tests start on the main thread");
        XP3CompatInstall();
        XP3CompatInstall(); // Installation must remain idempotent.
        TestRunLoop();
        TestAllocationScope();
        TestUnrelatedAlert();
        TestInputAndButtonMapping();
        TestStylesAndDismiss();
        TestUnavailablePresenter();
        TestButtonlessDialog();
        TestTransientInactiveApplication();
        TestRealNestedRunLoop();
        printf("PASS: %lu native semantic checks (Foundation + fake UIKit)\n", (unsigned long)checks);
    }
    return 0;
}
