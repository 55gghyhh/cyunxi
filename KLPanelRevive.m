#import "KAlertLog.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <math.h>

// 这个包（XCameraPro 3.0.185 / ioskuka 5.1.0 dae300ef）里有一串"死代码"：
// __init_offsets 三个构造函数都不调用 0xF408，全 __text 也没有外部引用，
// 所以浮层窗口 / 酷卡球 / 设置面板从来没被创建过 —— "一直都没有面板"的根因。
//
// 两个关键函数（实测都是纯函数，不读 x0/x1，也不依赖 self）：
//   0xF408  建浮层窗口 + 酷卡球（球指针写进全局 0x7F140）
//   0xD508  onFab：把球显隐取反；球变隐藏后继续走 0xD568 建面板卡片
//
// 所以 App 起来后依次调这两个地址，球和面板都会出来，不需要用户去点球。

static const uintptr_t kKLBuildFabOffset  = 0xF408;
static const uintptr_t kKLToggleFabOffset = 0xD508;

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

// 打印一个视图往上到 window 的完整链
static void KLDumpChain(UIView *v, NSString *tag) {
    NSMutableString *s = [NSMutableString string];
    UIView *cur = v;
    int depth = 0;
    while (cur != nil && depth < 8) {
        [s appendFormat:@"%@<%@ (%.0f,%.0f,%.0f,%.0f) hid=%d a=%.2f> ",
         depth == 0 ? @"" : @"^",
         NSStringFromClass([cur class]),
         cur.frame.origin.x, cur.frame.origin.y,
         cur.frame.size.width, cur.frame.size.height,
         cur.isHidden ? 1 : 0, cur.alpha];
        cur = cur.superview;
        depth += 1;
    }
    KLLogC(@"REV", @"%@ 链: %@", tag, s.length ? s : @"(空)");
}

static BOOL KLLooksLikeFab(UIView *v) {
    CGSize s = v.bounds.size;
    return (s.width >= 46.0 && s.width <= 90.0 && fabs(s.width - s.height) < 3.0);
}

static int KLScanForFab(UIView *v, int depth) {
    int found = 0;
    if (depth > 12 || v == nil) {
        return 0;
    }
    if (KLLooksLikeFab(v)) {
        KLLogC(@"REV", @"候选球 %@ %.0fx%.0f origin=(%.0f,%.0f) hid=%d alpha=%.2f win=%@",
               NSStringFromClass([v class]),
               v.bounds.size.width, v.bounds.size.height,
               v.frame.origin.x, v.frame.origin.y,
               v.isHidden ? 1 : 0, v.alpha,
               v.window ? NSStringFromClass([v.window class]) : @"(无窗口)");
        KLDumpChain(v, @"  ");
        found += 1;
    }
    for (UIView *sub in v.subviews) {
        found += KLScanForFab(sub, depth + 1);
    }
    return found;
}

static void KLDumpWindows(NSString *tag) {
    UIApplication *app = [UIApplication sharedApplication];
    int wi = 0;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            KLLogC(@"REV", @"%@ win#%d %@ (%.0f,%.0f,%.0f,%.0f) hid=%d a=%.2f lv=%.0f root=%@ subs=%lu",
                   tag, wi, NSStringFromClass([w class]),
                   w.frame.origin.x, w.frame.origin.y,
                   w.frame.size.width, w.frame.size.height,
                   w.isHidden ? 1 : 0, w.alpha, w.windowLevel,
                   w.rootViewController ? NSStringFromClass([w.rootViewController class]) : @"(无)",
                   (unsigned long)w.subviews.count);
            KLScanForFab(w, 0);
            wi += 1;
        }
    }
    KLLogC(@"REV", @"%@ 共 %d 个窗口", tag, wi);
}

// 兜底：球强制可见、alpha 拉满、挪进屏幕
static BOOL KLForceShowFab(UIView *v, CGRect screen, int depth) {
    BOOL touched = NO;
    if (v == nil || depth > 12) {
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
            c.x > screen.size.width - 10.0 || c.y > screen.size.height - 10.0) {
            v.center = CGPointMake(screen.size.width - 44.0, screen.size.height - 160.0);
            touched = YES;
        }
    }
    for (UIView *sub in v.subviews) {
        if (KLForceShowFab(sub, screen, depth + 1)) {
            touched = YES;
        }
    }
    return touched;
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
    // 紧接着走 onFab：球显隐取反 -> 变隐藏 -> 0xD568 建面板。
    // onFab 只用全局 0x7F140，不读 self/sel，可以直接按地址调。
    KLCallVoid(base + kKLToggleFabOffset, @"0xD508 建面板");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KLDumpWindows(@"T+0.8s");
        KLEnsurePanelButtons();

        UIApplication *app = [UIApplication sharedApplication];
        int fixed = 0;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (KLForceShowFab(w, w.bounds, 0)) {
                    fixed += 1;
                }
            }
        }
        KLLogC(@"REV", @"兜底显示球：%d 个窗口有改动", fixed);
    });
}
