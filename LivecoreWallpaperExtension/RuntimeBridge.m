#import "RuntimeBridge.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <IOSurface/IOSurfaceObjC.h>

// ARC emits this primitive for a strong ivar assignment. The private Swift
// snapshot wrapper cannot be imported, so use the same ownership operation
// after validating that the runtime exposes an Objective-C object ivar.
OBJC_EXPORT void objc_storeStrong(void * _Nonnull location, id _Nullable object);

@interface CAContext : NSObject
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
@property(nonatomic, retain) CALayer *layer;
@property(nonatomic, readonly) uint32_t contextId;
- (void)invalidate;
@end

static NSMutableDictionary<NSNumber *, CAContext *> *LivecoreContexts(void) {
    static NSMutableDictionary<NSNumber *, CAContext *> *contexts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ contexts = [NSMutableDictionary dictionary]; });
    return contexts;
}

static const void *LivecoreContextAssociationKey = &LivecoreContextAssociationKey;
static uint32_t LCContextIdentifierFromWrapper(id wrapper) {
    if (!wrapper) return 0;
    Class wrapperClass = object_getClass(wrapper);
    Ivar box = class_getInstanceVariable(wrapperClass, "box");
    if (!box) return 0;
    ptrdiff_t offset = ivar_getOffset(box);
    if (offset < 0 || (size_t)offset + sizeof(uint32_t) > class_getInstanceSize(wrapperClass)) return 0;
    return *(uint32_t *)((uint8_t *)(__bridge void *)wrapper + offset);
}

id LCCreateRemoteContext(CALayer *rootLayer, uint32_t displayID) {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_NOW);
    Class contextClass = NSClassFromString(@"CAContext");
    Class wrapperClass = NSClassFromString(@"WallpaperRemoteContextXPC");
    if (!contextClass || !wrapperClass) return nil;

    NSDictionary *options = displayID == 0 ? @{} : @{ @"displayId": @(displayID) };
    CAContext *context = [contextClass remoteContextWithOptions:options];
    if (!context || context.contextId == 0) return nil;
    context.layer = rootLayer;
    [CATransaction flush];
    @synchronized (LivecoreContexts()) {
        LivecoreContexts()[@(context.contextId)] = context;
    }

    id wrapper = class_createInstance(wrapperClass, 0);
    Ivar box = class_getInstanceVariable(wrapperClass, "box");
    if (!wrapper || !box) {
        @synchronized (LivecoreContexts()) {
            [LivecoreContexts() removeObjectForKey:@(context.contextId)];
        }
        return nil;
    }
    ptrdiff_t offset = ivar_getOffset(box);
    if (offset < 0 || (size_t)offset + sizeof(uint32_t) > class_getInstanceSize(wrapperClass)) {
        @synchronized (LivecoreContexts()) {
            [LivecoreContexts() removeObjectForKey:@(context.contextId)];
        }
        return nil;
    }
    *(uint32_t *)((uint8_t *)(__bridge void *)wrapper + offset) = context.contextId;
    objc_setAssociatedObject(wrapper, LivecoreContextAssociationKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return wrapper;
}

void LCReleaseRemoteContext(id wrapper) {
    uint32_t identifier = LCContextIdentifierFromWrapper(wrapper);
    if (identifier == 0) return;
    @synchronized (LivecoreContexts()) {
        CAContext *context = LivecoreContexts()[@(identifier)];
        if ([context respondsToSelector:@selector(invalidate)]) [context invalidate];
        [LivecoreContexts() removeObjectForKey:@(identifier)];
    }
}

id LCCreateWallpaperSnapshot(CGImageRef image) {
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
        kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        [surface unlockWithOptions:0 seed:nil];
        return nil;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    [surface unlockWithOptions:0 seed:nil];
    id wrapper = class_createInstance(wrapperClass, 0);
    Ivar rawValue = class_getInstanceVariable(wrapperClass, "rawValue");
    const char *typeEncoding = rawValue ? ivar_getTypeEncoding(rawValue) : NULL;
    if (!wrapper || !rawValue || !typeEncoding || typeEncoding[0] != '@') return nil;
    ptrdiff_t offset = ivar_getOffset(rawValue);
    if (offset < 0 || (size_t)offset + sizeof(void *) > class_getInstanceSize(wrapperClass)) return nil;
    void *surfaceSlot = (uint8_t *)(__bridge void *)wrapper + offset;
    objc_storeStrong(surfaceSlot, surface);
    return wrapper;
}
