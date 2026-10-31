//
//  KXUniversal.m —— 通用注入层（不绑任何 App）
//
//  原始 dylib 的钩子全部挂在 XCamera 私有类上（XHLocationManager / XHCameraKit /
//  XHWatermarkView），在别的 App 里这些类不存在，所以"改成对所有 App 生效"必须换实现：
//  这里全部改用系统 API —— CLLocationManager / AVFoundation / NSURLProtocol。
//
//  配置全部走 NSUserDefaults（每个 App 自己的容器里，可用 Filza 编辑该 App 的
//  Library/Preferences/<bundleid>.plist）：
//
//    KX.enable          总开关，默认 YES
//    KX.enableLoc       定位伪造，默认 NO（需要同时给 KX.lat / KX.lng）
//    KX.lat / KX.lng    伪造坐标
//    KX.enableAdblock   广告拦截，默认 NO
//    KX.enablePhoto     相机换图，默认 NO（需要 KX.photoPath）
//    KX.photoPath       用作替换的图片绝对路径
//    KX.logOnly         只记日志、不改行为，默认 NO
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreVideo/CoreVideo.h>
#import "KXLog.h"

#pragma mark - 配置

static NSUserDefaults *KXU(void) { return [NSUserDefaults standardUserDefaults]; }
static BOOL KXOn(NSString *key) {
    NSUserDefaults *u = KXU();
    if (![u objectForKey:key]) return NO;
    return [u boolForKey:key];
}
static BOOL KXMaster(void) {
    NSUserDefaults *u = KXU();
    if (![u objectForKey:@"KX.enable"]) return YES;      // 默认开启
    return [u boolForKey:@"KX.enable"];
}
static BOOL KXLogOnly(void) { return KXOn(@"KX.logOnly"); }

static BOOL KXLocEnabled(void) {
    if (!KXMaster() || KXLogOnly()) return NO;
    if (!KXOn(@"KX.enableLoc")) return NO;
    NSUserDefaults *u = KXU();
    return ([u objectForKey:@"KX.lat"] != nil) && ([u objectForKey:@"KX.lng"] != nil);
}
static BOOL KXAdEnabled(void) { return KXMaster() && !KXLogOnly() && KXOn(@"KX.enableAdblock"); }
static BOOL KXPhotoEnabled(void) {
    if (!KXMaster() || KXLogOnly() || !KXOn(@"KX.enablePhoto")) return NO;
    return [KXU() stringForKey:@"KX.photoPath"].length > 0;
}

#pragma mark - Hook 工具

static IMP KXHookClassMethod(Class cls, const char *name, IMP newImp) {
    if (!cls) return NULL;
    Class meta = object_getClass(cls);
    Method m = class_getInstanceMethod(meta, NSSelectorFromString([NSString stringWithUTF8String:name]));
    if (!m) return NULL;
    IMP old = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return old;
}
static IMP KXHookInstanceMethod(Class cls, const char *name, IMP newImp) {
    if (!cls) return NULL;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString([NSString stringWithUTF8String:name]));
    if (!m) return NULL;
    IMP old = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return old;
}

#pragma mark - 定位伪造

static CLLocation *(*o_loc)(id, SEL);
static void (*o_startUpd)(id, SEL);

static CLLocation *KXFakeLocation(void) {
    NSUserDefaults *u = KXU();
    double lat = [u doubleForKey:@"KX.lat"];
    double lng = [u doubleForKey:@"KX.lng"];
    CLLocation *l = [[CLLocation alloc] initWithLatitude:lat longitude:lng];
    KXLogAdd(@"LOC", @"伪造坐标 %.6f, %.6f", lat, lng);
    return l;
}

static CLLocation *h_location(id self, SEL _cmd) {
    if (KXLocEnabled()) return KXFakeLocation();
    return o_loc ? o_loc(self, _cmd) : nil;
}

static void h_startUpdatingLocation(id self, SEL _cmd) {
    if (o_startUpd) o_startUpd(self, _cmd);
    if (!KXLocEnabled()) return;
    CLLocation *fake = KXFakeLocation();
    id mgr = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id del = [mgr delegate];
        SEL s = NSSelectorFromString(@"locationManager:didUpdateLocations:");
        if (del && [del respondsToSelector:s]) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(del, s, mgr, @[fake]);
            KXLogAdd(@"LOC", @"已向 delegate 投递伪造位置");
        }
    });
}

static void KXInstallLocation(void) {
    Class c = NSClassFromString(@"CLLocationManager");
    o_loc      = (CLLocation *(*)(id, SEL))KXHookInstanceMethod(c, "location",              (IMP)h_location);
    o_startUpd = (void (*)(id, SEL))KXHookInstanceMethod(c, "startUpdatingLocation",        (IMP)h_startUpdatingLocation);
    KXLogAdd(@"HOOK", @"定位钩子 %@", (o_loc && o_startUpd) ? @"已安装" : @"未命中");
}

#pragma mark - 广告拦截

static NSArray<NSString *> *KXAdHosts(void) {
    static NSArray *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[ @"googleads.g.doubleclick.net", @"pagead2.googlesyndication.com",
                   @"adservice.google.com", @"ad.doubleclick.net", @"gdt.qq.com", @"e.qq.com",
                   @"mi.gdt.qq.com", @"v.gdt.qq.com", @"ad.qq.com", @"pgdt.gtimg.cn",
                   @"pgdt.gtimg.com", @"fusion.qq.com", @"is.snssdk.com", @"ad.zijieapi.com",
                   @"pangolin-sdk-toutiao.com", @"pglstatp-toutiao.com", @"open.e.kuaishou.com",
                   @"mobads.baidu.com", @"cpro.baidu.com", @"pos.baidu.com",
                   @"mobads-logs.baidu.com", @"ads.union.jd.com", @"iadsdk.apple.com",
                   @"applovin.com", @"unityads.unity3d.com", @"vungle.com",
                   @"admob.com", @"inmobi.com" ];
    });
    return hosts;
}

static BOOL KXShouldBlock(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString;
    for (NSString *h in KXAdHosts())
        if ([host isEqualToString:h]) return YES;
    NSString *p = url.path.lowercaseString;
    return [p containsString:@"/ads/"] || [p containsString:@"/advert"] || [p containsString:@"ad_track"];
}

@interface KXAdProtocol : NSURLProtocol @end
@implementation KXAdProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!KXAdEnabled()) return NO;
    if (!KXShouldBlock(request.URL)) return NO;
    KXLogAdd(@"ADBLOCK", @"%@%@", request.URL.host ?: @"-", request.URL.path ?: @"");
    return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    id<NSURLProtocolClient> c = self.client;
    NSError *e = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [c URLProtocol:self didFailWithError:e];
}
- (void)stopLoading {}
@end

static id (*o_defaultCfg)(id, SEL);
static id (*o_ephemeralCfg)(id, SEL);

static NSURLSessionConfiguration *KXInject(NSURLSessionConfiguration *cfg) {
    if (!KXAdEnabled() || !cfg) return cfg;
    NSMutableArray *pc = [cfg.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![pc containsObject:[KXAdProtocol class]]) [pc insertObject:[KXAdProtocol class] atIndex:0];
    cfg.protocolClasses = pc;
    return cfg;
}

static id h_defaultCfg(id self, SEL _cmd) { return KXInject(o_defaultCfg ? o_defaultCfg(self, _cmd) : nil); }
static id h_ephemeralCfg(id self, SEL _cmd) { return KXInject(o_ephemeralCfg ? o_ephemeralCfg(self, _cmd) : nil); }

static void KXInstallAdblock(void) {
    Class c = NSClassFromString(@"NSURLSessionConfiguration");
    o_defaultCfg   = (id (*)(id, SEL))KXHookClassMethod(c, "defaultSessionConfiguration",   (IMP)h_defaultCfg);
    o_ephemeralCfg = (id (*)(id, SEL))KXHookClassMethod(c, "ephemeralSessionConfiguration", (IMP)h_ephemeralCfg);
    KXLogAdd(@"HOOK", @"广告拦截 %@", (o_defaultCfg || o_ephemeralCfg) ? @"已安装" : @"未命中");
}

#pragma mark - 相机换图（CVPixelBuffer 原地绘制）

static UIImage *gSwapImage;
static IMP o_captureOut;
static Class gSwizzledDelegate;

static void KXDrawInto(CVPixelBufferRef pb, UIImage *img) {
    if (!pb || !img) return;
    CVPixelBufferLockBaseAddress(pb, 0);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    void *base = CVPixelBufferGetBaseAddress(pb);

    if (base && (fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32ABGR)) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (ctx) {
            CGImageRef cg = img.CGImage;
            if (cg) {
                size_t iw = CGImageGetWidth(cg), ih = CGImageGetHeight(cg);
                if (iw && ih) {
                    CGFloat sx = (CGFloat)w / iw, sy = (CGFloat)h / ih;
                    CGFloat s = MAX(sx, sy);                       // aspect fill
                    CGFloat dw = iw * s, dh = ih * s;
                    CGRect r = CGRectMake((w - dw) / 2, (h - dh) / 2, dw, dh);
                    CGContextDrawImage(ctx, r, cg);
                    KXLogAdd(@"PHOTO", @"原地绘制 %zux%zu fmt=0x%08x", w, h, (unsigned)fmt);
                }
            }
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

static void h_captureOut(id self, SEL _cmd, id output, CMSampleBufferRef sbuf, id conn) {
    if (KXPhotoEnabled() && sbuf) {
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
        if (pb) KXDrawInto((CVPixelBufferRef)pb, gSwapImage);
    }
    if (o_captureOut) ((void(*)(id,SEL,id,void*,id))o_captureOut)(self, _cmd, output, (void *)sbuf, conn);
}

static void (*o_setSampleDelegate)(id, SEL, id, id);
static void h_setSampleDelegate(id self, SEL _cmd, id delegate, id queue) {
    if (o_setSampleDelegate) o_setSampleDelegate(self, _cmd, delegate, queue);
    if (!delegate || !KXPhotoEnabled()) return;
    Class dc = object_getClass(delegate);
    if (dc && dc != gSwizzledDelegate) {
        gSwizzledDelegate = dc;
        o_captureOut = KXHookInstanceMethod(dc, "captureOutput:didOutputSampleBuffer:fromConnection:", (IMP)h_captureOut);
        KXLogAdd(@"HOOK", @"相机帧钩子 %@ (%@)", dc, o_captureOut ? @"已安装" : @"未命中");
    }
}

static void KXInstallPhoto(void) {
    if (!KXPhotoEnabled()) return;
    NSString *p = [KXU() stringForKey:@"KX.photoPath"];
    gSwapImage = [UIImage imageWithContentsOfFile:p];
    if (!gSwapImage) { KXLogAdd(@"PHOTO", @"图片读取失败：%@", p); return; }
    KXLogAdd(@"PHOTO", @"替换图 %@ (%.0fx%.0f)", p.lastPathComponent,
             gSwapImage.size.width, gSwapImage.size.height);
    Class c = NSClassFromString(@"AVCaptureVideoDataOutput");
    o_setSampleDelegate = (void (*)(id, SEL, id, id))
        KXHookInstanceMethod(c, "setSampleBufferDelegate:queue:", (IMP)h_setSampleDelegate);
}

#pragma mark - 入口

__attribute__((constructor))
static void KXUniversalInit(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
    KXLogAdd(@"BOOT", @"%@ v%@ | %@", bid,
             [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
             KXMaster() ? @"总开关开" : @"总开关关");

    dispatch_async(dispatch_get_main_queue(), ^{
        KXInstallLocation();
        KXInstallAdblock();
        KXInstallPhoto();
        KXLogInstallUI();
    });
}
