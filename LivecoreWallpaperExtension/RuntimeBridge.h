#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN
// Runtime-owned WallpaperExtensionKit wire types. Declaring them here preserves
// their concrete names in XPC reply block signatures without linking a private SDK.
@interface WallpaperSettingsViewModelsXPC : NSObject
@end
@interface WallpaperRemoteContextXPC : NSObject
@end
@interface WallpaperSnapshotXPC : NSObject
@end

WallpaperRemoteContextXPC * _Nullable LCCreateRemoteContext(CALayer *rootLayer);
WallpaperSnapshotXPC * _Nullable LCCreateWallpaperSnapshot(CGImageRef image);
NS_ASSUME_NONNULL_END
