//
//  AppResolver.h
//  ContainerStudio
//

#ifndef AppResolver_h
#define AppResolver_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads the first App Group identifier from the current binary's entitlements.
NSString * _Nullable cs_active_app_group(void);

/// Reads `com.apple.containermanager.identifier` extended attribute at `path`.
NSString * _Nullable cs_bundle_id_from_xattr(NSString *path);

/// Resolves localized display name for `bundleID` using LaunchServices private APIs.
NSString * _Nullable cs_display_name_for_bundle_id(NSString *bundleID);

/// Returns a dictionary mapping bundleID -> localized display name for all known apps.
NSDictionary<NSString *, NSString *> *cs_all_bundle_display_names(void);

/// Returns the hardware machine identifier (e.g., "iPhone16,2").
NSString *cs_device_machine_identifier(void);

NS_ASSUME_NONNULL_END

#endif /* AppResolver_h */
