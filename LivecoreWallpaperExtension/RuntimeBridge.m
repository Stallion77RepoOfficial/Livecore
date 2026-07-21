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

static NSMutableDictionary<NSNumber *, CAContext *> *LivecoreContexts(void) {
    static NSMutableDictionary<NSNumber *, CAContext *> *contexts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ contexts = [NSMutableDictionary dictionary]; });
    return contexts;
}

static NSMutableArray<IOSurface *> *LivecoreSurfaces(void) {
    static NSMutableArray<IOSurface *> *surfaces;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ surfaces = [NSMutableArray array]; });
    return surfaces;
}

static uint32_t LCContextIdentifierFromWrapper(WallpaperRemoteContextXPC *wrapper) {
    if (!wrapper) return 0;
    Class wrapperClass = object_getClass(wrapper);
    Ivar box = class_getInstanceVariable(wrapperClass, "box");
    ptrdiff_t offset = box ? ivar_getOffset(box) : 8;
    if (offset < 0 || (size_t)offset + sizeof(uint32_t) > class_getInstanceSize(wrapperClass)) return 0;
    return *(uint32_t *)((uint8_t *)(__bridge void *)wrapper + offset);
}

WallpaperRemoteContextXPC *LCCreateRemoteContext(CALayer *rootLayer) {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_NOW);
    Class contextClass = NSClassFromString(@"CAContext");
    Class wrapperClass = NSClassFromString(@"WallpaperRemoteContextXPC");
    if (!contextClass || !wrapperClass) return nil;

    CAContext *context = [contextClass remoteContextWithOptions:@{}];
    context.layer = rootLayer;
    @synchronized (LivecoreContexts()) {
        LivecoreContexts()[@(context.contextId)] = context;
    }

    id wrapper = class_createInstance(wrapperClass, 0);
    Ivar box = class_getInstanceVariable(wrapperClass, "box");
    ptrdiff_t offset = box ? ivar_getOffset(box) : 8;
    if (!wrapper || offset < 0 || (size_t)offset + sizeof(uint32_t) > class_getInstanceSize(wrapperClass)) {
        @synchronized (LivecoreContexts()) {
            [LivecoreContexts() removeObjectForKey:@(context.contextId)];
        }
        return nil;
    }
    *(uint32_t *)((uint8_t *)(__bridge void *)wrapper + offset) = context.contextId;
    return wrapper;
}

void LCReleaseRemoteContext(WallpaperRemoteContextXPC *wrapper) {
    uint32_t identifier = LCContextIdentifierFromWrapper(wrapper);
    if (identifier == 0) return;
    @synchronized (LivecoreContexts()) {
        [LivecoreContexts() removeObjectForKey:@(identifier)];
    }
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
    @synchronized (LivecoreSurfaces()) {
        [LivecoreSurfaces() addObject:surface];
        while (LivecoreSurfaces().count > 16) {
            [LivecoreSurfaces() removeObjectAtIndex:0];
        }
    }

    id wrapper = class_createInstance(wrapperClass, 0);
    Ivar rawValue = class_getInstanceVariable(wrapperClass, "rawValue");
    if (!wrapper) return nil;
    if (rawValue) object_setIvar(wrapper, rawValue, surface);
    else *(void **)((uint8_t *)(__bridge void *)wrapper + 8) = (__bridge_retained void *)surface;
    return wrapper;
}
