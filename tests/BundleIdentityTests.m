#import <Foundation/Foundation.h>
#import "../Sources/XP3BundleIdentity.h"
int main(void) {
    @autoreleasepool {
        NSCAssert(XP3CompatBundleIsSupported(@"tvp.XP3Player", @{}), @"original");
        NSCAssert(XP3CompatBundleIsSupported(@"tvp.XP3Player.Compat", @{}), @"original coexist");
        NSDictionary *free = @{@"XP3CompatOriginalBundleIdentifier": @"tvp.XP3Player.free", @"CFBundleExecutable": @"Kirikiroid2", @"CFBundleShortVersionString": @"1.3.9", @"CFBundleVersion": @"20"};
        for (NSString *bundle in @[@"tvp.XP3Player.free", @"tvp.XP3Player.free.Compat", @"com.example.free-fix"]) {
            NSCAssert(XP3CompatBundleIsSupported(bundle, free), @"free original/coexist/custom");
        }
        for (NSString *key in free) {
            NSMutableDictionary *wrong = [free mutableCopy]; wrong[key] = @"wrong";
            NSCAssert(!XP3CompatBundleIsSupported(@"com.example.free-fix", wrong), @"incorrect metadata");
        }
        NSCAssert(!XP3CompatBundleIsSupported(@"tvp.XP3Player.free", @{}), @"version required");
        NSCAssert(!XP3CompatBundleIsSupported(@"com.other.app", @{}), @"unrelated app");
        puts("PASS: original and free bundle identities");
    }
}
