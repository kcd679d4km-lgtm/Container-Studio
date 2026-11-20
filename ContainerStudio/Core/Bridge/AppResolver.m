//
//  AppResolver.m
//  ContainerStudio
//

#import "AppResolver.h"
#import <sys/xattr.h>
#import <sys/utsname.h>

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef _Nullable SecTaskCreateFromSelf(CFAllocatorRef _Nullable allocator);
extern CFTypeRef _Nullable SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef _Nullable * _Nullable error);

@interface NSObject (CS_LSPrivate)
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSURL *)bundleURL;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier allowPlaceholder:(BOOL)allowPlaceholder error:(NSError **)error;
- (NSURL *)URL;
@end

NSString * _Nullable cs_active_app_group(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return nil;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    if (!value) return nil;

    NSString *result = nil;
    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        NSArray *groups = (__bridge NSArray *)value;
        for (id item in groups) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                result = [(NSString *)item copy];
                break;
            }
        }
    }
    CFRelease(value);
    return result;
}

NSString * _Nullable cs_bundle_id_from_xattr(NSString *path) {
    if (path.length == 0) return nil;
    char buf[512];
    memset(buf, 0, sizeof(buf));
    ssize_t len = getxattr(path.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
    if (len <= 0) return nil;
    NSString *bid = [NSString stringWithUTF8String:buf];
    return bid.length > 0 ? bid : nil;
}

static NSString *name_from_bundle_url(NSURL *bundleURL) {
    if (!bundleURL) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[bundleURL URLByAppendingPathComponent:@"Info.plist"]];
    NSString *name = info[@"CFBundleDisplayName"];
    if (name.length == 0) name = info[@"CFBundleName"];
    return name.length > 0 ? name : nil;
}

NSString * _Nullable cs_display_name_for_bundle_id(NSString *bundleID) {
    if (bundleID.length == 0) return nil;

    Class recordClass = NSClassFromString(@"LSApplicationRecord");
    if ([recordClass instancesRespondToSelector:@selector(initWithBundleIdentifier:allowPlaceholder:error:)]) {
        NSError *error = nil;
        id record = [[recordClass alloc] initWithBundleIdentifier:bundleID allowPlaceholder:NO error:&error];
        if (record) {
            NSString *name = [record respondsToSelector:@selector(localizedName)] ? [record localizedName] : nil;
            if (name.length > 0) return name;
            NSURL *url = [record respondsToSelector:@selector(URL)] ? [record URL] : nil;
            name = name_from_bundle_url(url);
            if (name.length > 0) return name;
        }
    }

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if ([proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        id proxy = [proxyClass applicationProxyForIdentifier:bundleID];
        if (proxy) {
            NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
            if (name.length > 0) return name;
            NSURL *url = [proxy respondsToSelector:@selector(bundleURL)] ? [proxy bundleURL] : nil;
            name = name_from_bundle_url(url);
            if (name.length > 0) return name;
        }
    }

    return nil;
}

NSDictionary<NSString *, NSString *> *cs_all_bundle_display_names(void) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) return map;
    id workspace = [workspaceClass defaultWorkspace];
    if (!workspace) return map;

    NSArray *apps = nil;
    if ([workspace respondsToSelector:@selector(allApplications)]) {
        apps = [workspace allApplications];
    }
    if (apps.count == 0 && [workspace respondsToSelector:@selector(allInstalledApplications)]) {
        apps = [workspace allInstalledApplications];
    }

    for (id proxy in apps) {
        NSString *bundleID = nil;
        if ([proxy respondsToSelector:@selector(applicationIdentifier)]) {
            bundleID = [proxy applicationIdentifier];
        } else if ([proxy respondsToSelector:@selector(bundleIdentifier)]) {
            bundleID = [proxy bundleIdentifier];
        }
        NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
        if (bundleID.length > 0 && name.length > 0) {
            map[bundleID] = name;
        }
    }
    return map;
}

NSString *cs_device_machine_identifier(void) {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"iPhone";
}
