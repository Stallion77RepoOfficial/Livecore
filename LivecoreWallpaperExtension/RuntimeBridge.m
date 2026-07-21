#import "RuntimeBridge.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <IOSurface/IOSurfaceObjC.h>

@interface CAContext : NSObject
+ (instancetype)localContextWithOptions:(NSDictionary *)options;
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
@property(nonatomic, retain) CALayer *layer;
@property(nonatomic, readonly) uint32_t contextId;
@end

static NSMutableArray *LivecoreContexts(void) {
    static NSMutableArray *contexts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ contexts = [NSMutableArray array]; });
    return contexts;
}

static NSMutableArray *LivecoreSurfaces(void) {
    static NSMutableArray *surfaces;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ surfaces = [NSMutableArray array]; });
    return surfaces;
}

WallpaperRemoteContextXPC *LCCreateRemoteContext(CALayer *rootLayer) {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_NOW);
    Class contextClass = NSClassFromString(@"CAContext");
    Class wrapperClass = NSClassFromString(@"WallpaperRemoteContextXPC");
    if (!contextClass || !wrapperClass) return nil;

    CAContext *context = [contextClass remoteContextWithOptions:@{}];
    context.layer = rootLayer;
    @synchronized (LivecoreContexts()) { [LivecoreContexts() addObject:context]; }

    id wrapper = class_createInstance(wrapperClass, 0);
    Ivar box = class_getInstanceVariable(wrapperClass, "box");
    ptrdiff_t offset = box ? ivar_getOffset(box) : 8;
    if (!wrapper || offset < 0 || (size_t)offset + sizeof(uint32_t) > class_getInstanceSize(wrapperClass)) return nil;
    *(uint32_t *)((uint8_t *)(__bridge void *)wrapper + offset) = context.contextId;
    return wrapper;
}

WallpaperSnapshotXPC *LCCreateWallpaperSnapshot(CGImageRef image) {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_NOW);
    Class wrapperClass = NSClassFromString(@"WallpaperSnapshotXPC");
    if (!wrapperClass || class_getInstanceSize(wrapperClass) < 16) return nil;
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    IOSurface *surface = [[IOSurface alloc] initWithProperties:@{
        IOSurfacePropertyKeyWidth: @(width),
        IOSurfacePropertyKeyHeight: @(height),
        IOSurfacePropertyKeyBytesPerElement: @4,
        IOSurfacePropertyKeyPixelFormat: @((uint32_t)'BGRA')
    }];
    if (!surface || [surface lockWithOptions:0 seed:nil] != kIOReturnSuccess) return nil;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        surface.baseAddress, width, height, 8, surface.bytesPerRow, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        [surface unlockWithOptions:0 seed:nil];
        return nil;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    [surface unlockWithOptions:0 seed:nil];
    @synchronized (LivecoreSurfaces()) { [LivecoreSurfaces() addObject:surface]; }

    id wrapper = class_createInstance(wrapperClass, 0);
    Ivar rawValue = class_getInstanceVariable(wrapperClass, "rawValue");
    if (!wrapper) return nil;
    if (rawValue) object_setIvar(wrapper, rawValue, surface);
    else *(void **)((uint8_t *)(__bridge void *)wrapper + 8) = (__bridge_retained void *)surface;
    return wrapper;
}
