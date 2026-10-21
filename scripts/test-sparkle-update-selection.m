// Headless integration fixture: run Sparkle's actual parser and update selector.
// No archive is downloaded or installed. Hardware emulation is process-local.
#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>
#import <objc/runtime.h>

static NSString *feedURL;
static NSString *expectedArchitecture;
static NSString *hardware;
static NSString *preferencesDomain;
static id (*originalResolve)(id, SEL, id, id, id, id, id, id, id);

static void finish(int code, NSString *message) {
    if (preferencesDomain) [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:preferencesDomain];
    fprintf(code ? stderr : stdout, "%s\n", message.UTF8String);
    exit(code);
}

static id resolveState(id self, SEL selector, id informational, id minimumUpdate, id minimumOS,
                      id maximumOS, id minimumAuto, id critical, NSSet *requirements) {
    id state = originalResolve(self, selector, informational, minimumUpdate, minimumOS,
                              maximumOS, minimumAuto, critical, requirements);
    BOOL supported = ![requirements containsObject:@"arm64"] || [hardware isEqual:@"arm64"];
    [state setValue:@(supported) forKey:@"arm64HardwareRequirementIsOK"];
    return state;
}

@interface SilentDriver : NSObject <SPUUserDriver>
@end
@implementation SilentDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    finish(2, @"Unexpected permission request in isolated fixture");
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)dismissUpdateInstallation {}
@end

@interface SelectionDelegate : NSObject <SPUUpdaterDelegate>
@end
@implementation SelectionDelegate
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return feedURL; }
- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
    NSString *suffix = [NSString stringWithFormat:@"-%@.tar.xz", expectedArchitecture];
    if (![item.fileURL.lastPathComponent hasSuffix:suffix]) {
        finish(3, [NSString stringWithFormat:@"Wrong update selected: %@", item.fileURL]);
    }
    finish(0, [NSString stringWithFormat:@"PASS hardware=%@ selected=%@", hardware, item.fileURL.lastPathComponent]);
}
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error { finish(4, error.description); }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 5) return 64;
        NSBundle *host = [NSBundle bundleWithPath:@(argv[1])];
        feedURL = @(argv[2]); hardware = @(argv[3]); expectedArchitecture = @(argv[4]);
        preferencesDomain = host.bundleIdentifier;
        if (![hardware isEqual:@"native"]) {
            Class resolver = NSClassFromString(@"SPUAppcastItemStateResolver");
            SEL selector = NSSelectorFromString(@"resolveStateWithInformationalUpdateVersions:minimumUpdateVersion:minimumOperatingSystemVersion:maximumOperatingSystemVersion:minimumAutoupdateVersion:criticalUpdateDictionary:hardwareRequirements:");
            Method method = class_getInstanceMethod(resolver, selector);
            if (!method) finish(5, @"Sparkle hardware resolver unavailable");
            originalResolve = (void *)method_getImplementation(method);
            method_setImplementation(method, (IMP)resolveState);
        }
        SilentDriver *driver = [SilentDriver new];
        SelectionDelegate *delegate = [SelectionDelegate new];
        SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:host applicationBundle:host userDriver:driver delegate:delegate];
        NSError *error = nil;
        if (![updater startUpdater:&error]) finish(6, error.description);
        [updater checkForUpdateInformation];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(7, @"Sparkle selection timed out"); });
        [[NSRunLoop mainRunLoop] run];
    }
    return 8;
}
