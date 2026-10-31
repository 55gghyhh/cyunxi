#import "KAlertLog.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <math.h>

// 这个包（XCameraPro 3.0.185 / ioskuka 5.1.0 dae300ef）里，面板构建函数
// 0xF408 是死代码：__init_offsets 三个构造函数都不调它，全 __text 也没有任何
// 外部引用。所以酷卡球和面板从来没被创建过 —— 这就是"一直都没有面板"的根因。
//
// 这里在 App 起来之后（主队列 T+2s）主动调用它一次，把球和面板建出来，
// 剩下的事（认领卡片、加两个按钮）由 KLPanel.m 原有的轮询逻辑完成。
//
// 0xF408 不读 x0/x1（不依赖 self/sel），是纯函数，可以直接按地址调。

static const uintptr_t kKLBuildPanelOffset = 0xF408;

static uintptr_t KLIoskukaBase(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm == NULL) {
            continue;
        }
        if (strstr(nm, "ioskuka") != NULL) {
            const struct mach_header *h = _dyld_get_image_header(i);
            return (uintptr_t)h;
        }
    }
    return 0;
}

// 把 64pt 左右的圆形悬浮球找出来并强制可见、顺手挪进屏幕内。
static BOOL KLFixUpFab(UIView *v, CGRect screen) {
    BOOL touched = NO;
    CGSize s = v.bounds.size;
    if (s.width >= 48.0 && s.width <= 88.0 && fabs(s.width - s.height) < 2.0) {
        if (v.isHidden) {
            [v setHidden:NO];
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
        if (KLFixUpFab(sub, screen)) {
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
    KLLogC(@"REV", @"ioskuka base=0x%lx, 调用 0x%lx 建面板", (unsigned long)base,
           (unsigned long)(base + kKLBuildPanelOffset));

    void (*build)(void) = (void (*)(void))(base + kKLBuildPanelOffset);
    @try {
        build();
        KLLogC(@"REV", @"0xF408 调用返回");
    } @catch (NSException *e) {
        KLLogC(@"ERR", @"0xF408 抛异常: %@", e.reason ?: @"?");
        return;
    }

    // 给 UIKit 一点时间把 window 挂上，再修球
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        int fixed = 0;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (KLFixUpFab(w, w.bounds)) {
                    fixed += 1;
                }
            }
        }
        KLLogC(@"REV", @"悬浮球修正：%d 个窗口有改动", fixed);
        KLEnsurePanelButtons();
    });
}
