// Included after the SDK or project ABI declarations.
static inline BOOL XP3CompatBundleIsSupported(NSString *bundleID, NSDictionary *info) {
    if ([bundleID isEqualToString:@"tvp.XP3Player"] ||
        [bundleID isEqualToString:@"tvp.XP3Player.Compat"]) return YES;
    return ([bundleID isEqualToString:@"tvp.XP3Player.free"] ||
            [bundleID isEqualToString:@"tvp.XP3Player.free.Compat"] ||
            [info[@"XP3CompatOriginalBundleIdentifier"] isEqualToString:@"tvp.XP3Player.free"]) &&
           [info[@"CFBundleExecutable"] isEqualToString:@"Kirikiroid2"] &&
           [info[@"CFBundleShortVersionString"] isEqualToString:@"1.3.9"] &&
           [info[@"CFBundleVersion"] isEqualToString:@"20"];
}
