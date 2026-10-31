#import "KAlertLog.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <math.h>

// XCameraPro 3.0.185 / ioskuka 5.1.0(dae300ef) 里的"死代码"：
//   __init_offsets 三个构造函数都不调 0xF408，全 __text 也没有外部引用，
//   所以浮层窗口 / 酷卡球 / 设置面板从来没被创建过。
// 而且 0xF408 自身有两道早期 return（0xF448 cbz w0, 0xF454 tbnz w8,#0），
// 校验不过就直接跳尾部返回 —— 这就是"调用成功但什么都没建"的原因。
// 用 P7 补丁把这两条 nop 掉之后，0xF408 才会真正建窗口、建球。
//
//   0xF408  建浮层窗口(level 100) + 酷卡球（球指针写进全局 0x7F140）
//   0xD508  onFab：球显隐取反；球变隐藏后继续走 0xD568 建面板卡片
//
// 关键安全约束：ioskuka 的窗口 windowLevel = 100，App 自己的是 0。
// 所有"找球/修球"只允许作用于 windowLevel >= 50 的窗口，
// 绝不再碰 App 的任何视图（上一版按 46~90pt 方形乱扫，误改过水印/工具栏控件）。

static const uintptr_t kKLBuildFabOffset  = 0xF408;
static const uintptr_t kKLToggleFabOffset = 0xD508;
static const CGFloat   kKLMinOverlayLevel = 50.0;

static uintptr_t KLIoskukaBase(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm == NULL) {
            continue;
        }
        if (strstr(nm, "ioskuka") != NULL) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

static void KLCallVoid(uintptr_t addr, NSString *what) {
    if (addr == 0) {
        KLLogC(@"REV", @"%@ 地址为空，跳过", what);
        return;
    }
    void (*fn)(void) = (void (*)(void))addr;
    @try {
        fn();
        KLLogC(@"REV", @"%@ 调用返回", what);
    } @catch (NSException *e) {
        KLLogC(@"ERR", @"%@ 抛异常: %@", what, e.reason ?: @"?");
    }
}

static void KLDumpChain(UIView *v, NSString *tag) {
    NSMutableString *s = [NSMutableString string];
    UIView *cur = v;
    int depth = 0;
    while (cur != nil && depth < 6) {
        [s appendFormat:@"%@<%@ (%.0f,%.0f,%.0f,%.0f) hid=%d> ",
         depth == 0 ? @"" : @"^",
         NSStringFromClass([cur class]),
         cur.frame.origin.x, cur.frame.origin.y,
         cur.frame.size.width, cur.frame.size.height,
         cur.isHidden ? 1 : 0];
        cur = cur.superview;
        depth += 1;
    }
    KLLogC(@"REV", @"%@ 链: %@", tag, s.length ? s : @"(空)");
}

static BOOL KLLooksLikeFab(UIView *v) {
    CGSize s = v.bounds.size;
    return (s.width >= 46.0 && s.width <= 90.0 && fabs(s.width - s.height) < 3.0);
}

static int KLScanFabIn(UIView *v, int depth) {
    int found = 0;
    if (v == nil || depth > 10) {
        return 0;
    }
    if (KLLooksLikeFab(v)) {
        KLLogC(@"REV", @"  osk球 %@ %.0fx%.0f origin=(%.0f,%.0f) hid=%d a=%.2f",
               NSStringFromClass([v class]),
               v.bounds.size.width, v.bounds.size.height,
               v.frame.origin.x, v.frame.origin.y,
               v.isHidden ? 1 : 0, v.alpha);
        KLDumpChain(v, @"    ");
        found += 1;
    }
    for (UIView *sub in v.subviews) {
        found += KLScanFabIn(sub, depth + 1);
    }
    return found;
}

static BOOL KLFixFabIn(UIView *v, CGRect winBounds, int depth) {
    BOOL touched = NO;
    if (v == nil || depth > 10) {
        return NO;
    }
    if (KLLooksLikeFab(v)) {
        if (v.isHidden) {
            [v setHidden:NO];
            touched = YES;
        }
        if (v.alpha < 0.99) {
            v.alpha = 1.0;
            touched = YES;
        }
        CGPoint c = v.center;
        if (c.x < 20.0 || c.y < 20.0 ||
            c.x > winBounds.size.width - 10.0 || c.y > winBounds.size.height - 10.0) {
            v.center = CGPointMake(winBounds.size.width - 44.0, winBounds.size.height - 160.0);
            touched = YES;
        }
    }
    for (UIView *sub in v.subviews) {
        if (KLFixFabIn(sub, winBounds, depth + 1)) {
            touched = YES;
        }
    }
    return touched;
}

// 只处理 ioskuka 的浮层窗口
static void KLDumpAndFixOverlays(NSString *tag) {
    UIApplication *app = [UIApplication sharedApplication];
    int total = 0, overlays = 0, fabs_ = 0, fixed = 0;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            total += 1;
            BOOL isOverlay = (w.windowLevel >= kKLMinOverlayLevel);
            KLLogC(@"REV", @"%@ win %@ lv=%.0f (%.0f,%.0f,%.0f,%.0f) hid=%d%@",
                   tag, NSStringFromClass([w class]), w.windowLevel,
                   w.frame.origin.x, w.frame.origin.y,
                   w.frame.size.width, w.frame.size.height,
                   w.isHidden ? 1 : 0,
                   isOverlay ? @" [ioskuka浮层]" : @" [App]");
            if (!isOverlay) {
                continue;   // ← 绝不碰 App 自己的窗口
            }
            overlays += 1;
            fabs_ += KLScanFabIn(w, 0);
            if (KLFixFabIn(w, w.bounds, 0)) {
                fixed += 1;
            }
        }
    }
    KLLogC(@"REV", @"%@ 窗口 %d 个，其中浮层 %d 个，找到球 %d 个，修正 %d 个",
           tag, total, overlays, fabs_, fixed);
}

void KLRevivePanel(void) {
    uintptr_t base = KLIoskukaBase();
    if (base == 0) {
        KLLogC(@"REV", @"没找到 ioskuka 镜像，跳过面板复活");
        return;
    }
    KLLogC(@"REV", @"ioskuka base=0x%lx  建球=0x%lx  建面板=0x%lx",
           (unsigned long)base,
           (unsigned long)(base + kKLBuildFabOffset),
           (unsigned long)(base + kKLToggleFabOffset));

    KLCallVoid(base + kKLBuildFabOffset, @"0xF408 建球");
    KLCallVoid(base + kKLToggleFabOffset, @"0xD508 建面板");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KLDumpAndFixOverlays(@"T+0.8s");
        KLEnsurePanelButtons();
    });
}
