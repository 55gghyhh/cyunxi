#import "KAlertLog.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const void *kKLRowKey = &kKLRowKey;

static UIWindow *KLKeyWindow(void);

@interface KLActionTarget : NSObject
- (void)onViewLog:(UIButton *)sender;
- (void)onExportLog:(UIButton *)sender;
- (void)onFabTap:(UIButton *)sender;
- (void)onFabPan:(UIPanGestureRecognizer *)g;
@end

static KLActionTarget *gTarget = nil;
static NSInteger gAttempts = 0;
static BOOL gReportedMissing = NO;
static __weak UIView *gCardRef = nil;

static void KLFabPan(UIPanGestureRecognizer *g);

@implementation KLActionTarget

- (void)onViewLog:(UIButton *)sender {
    (void)sender;
    KLLogC(@"UI", @"点击「运行日志」");
    KLPresentLogViewer();
}

- (void)onExportLog:(UIButton *)sender {
    KLLogC(@"UI", @"点击「导出日志」");
    KLShareLogFromView(sender);
}

- (void)onFabPan:(UIPanGestureRecognizer *)g {
    KLFabPan(g);
}

- (void)onFabTap:(UIButton *)sender {
    (void)sender;
    KLLogC(@"UI", @"点击悬浮球「日志」");
    KLPresentLogViewer();
}

@end

static NSArray<NSString *> *KLAnchorTexts(void) {
    static NSArray<NSString *> *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"假定位", @"去广告", @"假时间", @"相册替拍", @"改天气",
              @"地图选点", @"输入坐标", @"选择天气", @"清除图片"];
    });
    return a;
}

static NSInteger KLCollect(UIView *v, NSInteger depth, NSArray *texts,
                           NSMutableArray<NSNumber *> *depths, NSMutableArray<UIView *> *views) {
    if (views.count > 3000) {
        return 0;
    }
    NSInteger n = 0;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length && [texts containsObject:t]) {
            n = 1;
        }
    } else if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [((UIButton *)v) titleForState:UIControlStateNormal];
        if (t.length && [texts containsObject:t]) {
            n = 1;
        }
    }
    for (UIView *s in v.subviews) {
        n += KLCollect(s, depth + 1, texts, depths, views);
    }
    if (n >= 3) {
        [depths addObject:@(depth)];
        [views addObject:v];
    }
    return n;
}

static BOOL KLLooksLikeCard(UIView *v) {
    UIColor *bg = v.backgroundColor;
    if (bg != nil && CGColorGetAlpha(bg.CGColor) > 0.05) {
        return YES;
    }
    if (v.layer.cornerRadius >= 6.0) {
        return YES;
    }
    if ([v isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) {
        return YES;
    }
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UIVisualEffectView class]]) {
            return YES;
        }
    }
    return NO;
}

static UIView *KLFindPanelCard(void) {
    NSArray *texts = KLAnchorTexts();
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            KLCollect(w, 0, texts, depths, views);
        }
    }
    UIView *best = nil;
    NSInteger bestDepth = -1;
    for (NSUInteger i = 0; i < views.count; i++) {
        NSInteger d = depths[i].integerValue;
        if (d > bestDepth) {
            bestDepth = d;
            best = views[i];
        }
    }
    if (best == nil) {
        return nil;
    }
    UIView *node = best;
    for (NSInteger i = 0; i < 6 && node.superview != nil; i++) {
        if (KLLooksLikeCard(node)) {
            return node;
        }
        node = node.superview;
    }
    return best;
}

static UIButton *KLFindButton(UIView *v, NSArray<NSString *> *titles, NSInteger depth) {
    if (depth > 4) {
        return nil;
    }
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length && [titles containsObject:t]) {
            return b;
        }
    }
    for (UIView *s in v.subviews) {
        UIButton *hit = KLFindButton(s, titles, depth + 1);
        if (hit) {
            return hit;
        }
    }
    return nil;
}

static UIButton *KLFindWideButton(UIView *v, NSInteger depth) {
    if (depth > 4) {
        return nil;
    }
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        CGRect r = b.bounds;
        if (r.size.width >= 60.0 && r.size.height >= 24.0) {
            return b;
        }
    }
    for (UIView *s in v.subviews) {
        UIButton *hit = KLFindWideButton(s, depth + 1);
        if (hit) {
            return hit;
        }
    }
    return nil;
}

static UIButton *KLReferenceButton(UIView *card) {
    NSArray *named = @[@"相册替拍", @"清除图片", @"地图选点", @"设置时间", @"选择天气"];
    UIButton *b = KLFindButton(card, named, 0);
    if (b) {
        return b;
    }
    return KLFindWideButton(card, 0);
}

// 判断参考按钮的配色是否"几乎不可见"（透明底 + 白字，落在白色背景上会看不见）
static BOOL KLRefStyleIsInvisible(UIButton *ref) {
    if (ref == nil) {
        return YES;
    }
    UIColor *bg = ref.backgroundColor;
    if (bg == nil) {
        return YES;
    }
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![bg getRed:&r green:&g blue:&b alpha:&a]) {
        return YES;
    }
    if (a < 0.25) {
        return YES;   // 底色太透明
    }
    if (r > 0.95 && g > 0.95 && b > 0.95 && a < 0.6) {
        return YES;   // 近白且半透明
    }
    return NO;
}

static UIButton *KLMakeButton(NSString *title, UIButton *ref, CGRect frame) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];

    BOOL invisible = KLRefStyleIsInvisible(ref);
    if (ref && !invisible) {
        UIColor *bg = ref.backgroundColor;
        b.backgroundColor = bg;
        UIColor *fg = [ref titleColorForState:UIControlStateNormal];
        [b setTitleColor:(fg ?: [UIColor whiteColor]) forState:UIControlStateNormal];
        UIFont *f = ref.titleLabel.font;
        b.titleLabel.font = f ?: [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        b.layer.cornerRadius = ref.layer.cornerRadius;
        b.clipsToBounds = ref.clipsToBounds;
        b.layer.borderWidth = ref.layer.borderWidth;
        b.layer.borderColor = ref.layer.borderColor;
    } else {
        // 保底样式：深色底 + 白字 + 描边，任何背景上都看得见
        b.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:0.92];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        b.layer.cornerRadius = 8.0;
        b.clipsToBounds = YES;
        b.layer.borderWidth = 1.0;
        b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    }
    return b;
}

static void KLInstallRow(UIView *card) {
    if (gTarget == nil) {
        gTarget = [[KLActionTarget alloc] init];
    }
    if (card == nil) {
        return;
    }

    UIView *bar = objc_getAssociatedObject(card, kKLRowKey);
    if (bar != nil && bar.superview != nil) {
        // 已装过：跟随卡片位置（不含改卡片尺寸）
        UIView *host = bar.superview;
        if (host == card) {
            return;
        }
        CGRect cf = [card convertRect:card.bounds toView:host];
        CGRect f = bar.frame;
        f.origin.x = CGRectGetMinX(cf) + 14.0;
        f.origin.y = CGRectGetMaxY(cf) + 6.0;
        f.size.width = MAX(120.0, CGRectGetWidth(cf) - 28.0);
        bar.frame = f;
        return;
    }

    UIButton *ref = KLReferenceButton(card);
    CGFloat width = card.bounds.size.width;
    CGFloat baseH = card.bounds.size.height;
    if (width < 80.0 || baseH < 60.0) {
        KLLogC(@"UI", @"跳过卡片：尺寸太小 %.0fx%.0f", width, baseH);
        return;
    }

    CGFloat inset = 14.0;
    CGFloat btnH = 34.0;
    if (ref != nil) {
        CGRect refRect = ref.frame;
        if (ref.superview != nil) {
            refRect = [ref.superview convertRect:ref.frame toView:card];
        }
        inset = MAX(refRect.origin.x, 10.0);
        // convertRect 在深层/带变换的层级里可能算出极大值，必须夹紧，
        // 否则 usable 变负 → 静默 return（上一版 370x470 的真面板就是这么被跳过的）
        inset = MIN(inset, width * 0.15);
        if (refRect.size.height >= 22.0 && refRect.size.height <= 80.0) {
            btnH = refRect.size.height;
        }
    }
    CGFloat usable = width - inset * 2.0;
    if (usable < 100.0) {
        KLLogC(@"ERR", @"跳过卡片：usable 太小 %.0f (width=%.0f inset=%.0f ref=%@)",
               usable, width, inset, ref ? NSStringFromClass([ref class]) : @"nil");
        return;
    }
    CGFloat gap = 10.0;
    CGFloat btnW = (usable - gap) / 2.0;

    // 关键：绝不修改 card.frame。
    // 这张卡片用的是 Auto Layout，改高度会把底部内容（开关状态文本）挤出可视区。
    // 按钮条一律放到 card 的父视图里、紧贴卡片底边下方；下方放不下就改放到上方。
    UIView *host = card.superview ?: card.window;
    if (host == nil) {
        return;
    }
    CGRect cf = [card convertRect:card.bounds toView:host];
    CGFloat yBelow = CGRectGetMaxY(cf) + 6.0;

    CGFloat screenH = host.bounds.size.height;
    UIView *barParent = host;
    if (yBelow + btnH > screenH - 8.0) {
        // 下方不够 → 放卡片上方
        CGFloat yAbove = CGRectGetMinY(cf) - btnH - 6.0;
        if (yAbove < 8.0) {
            // 上下都不够，退回放卡片内底部（仍不改 frame，靠 layer 绘制）
            barParent = card;
            yBelow = baseH - btnH - 8.0;
        } else {
            yBelow = yAbove;
        }
    }

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMinX(cf) + inset,
                                                                 yBelow,
                                                                 usable,
                                                                 btnH)];
    container.backgroundColor = [UIColor clearColor];
    [barParent addSubview:container];
    if (barParent != card) {
        [barParent bringSubviewToFront:container];
    }

    UIButton *bLog = KLMakeButton(@"运行日志", ref, CGRectMake(0.0, 0.0, btnW, btnH));
    [bLog addTarget:gTarget action:@selector(onViewLog:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:bLog];

    UIButton *bExp = KLMakeButton(@"导出日志", ref, CGRectMake(btnW + gap, 0.0, btnW, btnH));
    [bExp addTarget:gTarget action:@selector(onExportLog:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:bExp];

    objc_setAssociatedObject(card, kKLRowKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGRect hostRect = [container.superview convertRect:container.frame toView:nil];
    KLLogC(@"UI", @"面板已注入「运行日志 / 导出日志」 card=%@ %.0fx%.0f 按钮 %.0fx%.0f 参考样式%@ 父视图=%@ 窗口坐标=(%.0f,%.0f,%.0f,%.0f)",
           NSStringFromClass([card class]), width, baseH, btnW, btnH,
           KLRefStyleIsInvisible(ref) ? @"不可见→用保底深色" : @"可用",
           NSStringFromClass([container.superview class]),
           hostRect.origin.x, hostRect.origin.y, hostRect.size.width, hostRect.size.height);
}

static UIWindow *KLKeyWindow(void);

__attribute__((unused)) void KLBootProbe(NSString *extra) {
    UIWindow *w = KLKeyWindow();
    UIViewController *root = w.rootViewController;
    if (root == nil) {
        return;
    }
    while (root.presentedViewController != nil) {
        root = root.presentedViewController;
    }
    NSString *msg = [NSString stringWithFormat:@"bundle: %@\nversion: %@\n\n%@",
                     [NSBundle mainBundle].bundleIdentifier ?: @"?",
                     KLAppVersion(),
                     extra ?: @""];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"KAlertLog 已加载"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [root presentViewController:ac animated:YES completion:nil];
    // 8 秒后自动收掉，避免挡住用户操作
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ac dismissViewControllerAnimated:YES completion:nil];
    });
}

static UIButton *gFab = nil;
static const void *kKLFabPanKey = &kKLFabPanKey;

// 只认 ioskuka 自己的浮层窗口：类名 XCPassWindow 或 windowLevel == 2100。
// 键盘窗口（UIInputSetHostView / UITextEffectsWindow）level 也很高，
// 上一版按 level>=50 过滤时把按钮注入到了键盘里（y=1220，屏幕外）。
static BOOL KLIsIoskukaWindow(UIWindow *w) {
    if (w == nil) {
        return NO;
    }
    NSString *cn = NSStringFromClass([w class]);
    if ([cn containsString:@"XCPassWindow"]) {
        return YES;
    }
    if ([cn containsString:@"Input"] || [cn containsString:@"TextEffects"] ||
        [cn containsString:@"Keyboard"] || [cn containsString:@"StatusBar"]) {
        return NO;
    }
    return (fabs(w.windowLevel - 2100.0) < 1.0);
}

static NSArray<UIWindow *> *KLOverylayWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (KLIsIoskukaWindow(w)) {
                [out addObject:w];
            }
        }
    }
    return out;
}

// 优先 App 自己的窗口（level 0）。日志球必须挂在这里，
// 否则挂到浮层窗口上，面板一关窗口隐藏，球也没了。
static UIWindow *KLKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *appWin = nil;
    UIWindow *anyKey = nil;
    UIWindow *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.windowLevel < 1.0 && w.rootViewController != nil) {
                if (appWin == nil) {
                    appWin = w;
                }
                if (w.isKeyWindow) {
                    return w;
                }
            }
            if (w.isKeyWindow && anyKey == nil) {
                anyKey = w;
            }
            if (fallback == nil && w.rootViewController != nil) {
                fallback = w;
            }
        }
    }
    if (appWin != nil) {
        return appWin;
    }
    if (anyKey != nil) {
        return anyKey;
    }
    return fallback;
}

static void KLFabPan(UIPanGestureRecognizer *g) {
    UIView *v = g.view;
    UIWindow *w = v.window;
    if (v == nil || w == nil) {
        return;
    }
    CGPoint t = [g translationInView:w];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    CGFloat halfW = v.bounds.size.width / 2.0;
    CGFloat halfH = v.bounds.size.height / 2.0;
    CGFloat topInset = 0.0;
    CGFloat botInset = 0.0;
    if (@available(iOS 11.0, *)) {
        topInset = w.safeAreaInsets.top;
        botInset = w.safeAreaInsets.bottom;
    }
    c.x = MAX(halfW + 6.0, MIN(w.bounds.size.width - halfW - 6.0, c.x));
    c.y = MAX(halfH + topInset + 6.0, MIN(w.bounds.size.height - halfH - botInset - 6.0, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:w];

    if (g.state == UIGestureRecognizerStateEnded) {
        [[NSUserDefaults standardUserDefaults] setDouble:c.x forKey:@"KAlertLog.fabX"];
        [[NSUserDefaults standardUserDefaults] setDouble:c.y forKey:@"KAlertLog.fabY"];
    }
}

__attribute__((unused)) static void KLInstallFallbackFab(void) {
    if (gFab != nil && gFab.window != nil) {
        [gFab.superview bringSubviewToFront:gFab];
        return;
    }
    UIWindow *w = KLKeyWindow();
    if (w == nil) {
        return;
    }
    if (gTarget == nil) {
        gTarget = [[KLActionTarget alloc] init];
    }
    CGFloat side = 46.0;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGFloat x = [d objectForKey:@"KAlertLog.fabX"] ? [d doubleForKey:@"KAlertLog.fabX"] : 34.0;
    CGFloat y = [d objectForKey:@"KAlertLog.fabY"] ? [d doubleForKey:@"KAlertLog.fabY"]
                                                   : (w.bounds.size.height - 120.0);
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, side, side);
    b.center = CGPointMake(x, y);
    [b setTitle:@"日志" forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    b.layer.cornerRadius = side / 2.0;
    b.clipsToBounds = YES;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    [b addTarget:gTarget action:@selector(onFabTap:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gTarget
                                                                        action:@selector(onFabPan:)];
    [b addGestureRecognizer:pan];
    objc_setAssociatedObject(b, kKLFabPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [w addSubview:b];
    [w bringSubviewToFront:b];
    gFab = b;
    KLLogC(@"UI", @"未找到 KAlert 面板，已改用悬浮球入口（可拖动）");
}

// 保活：ioskuka 关闭面板时会把整个浮层窗口 hid=1，球也跟着不见。
// 每 0.5s 检查一次，被隐藏就恢复 —— 关闭面板后窗口里只剩球，正是想要的状态。
static BOOL gOverlayWasHidden = NO;
static BOOL gReportedNoFab = NO;

static void KLKeepOverlayAlive(void) {
    NSArray<UIWindow *> *wins = KLOverylayWindows();
    BOOL anyHidden = NO;
    for (UIWindow *w in wins) {
        if (w.isHidden) {
            [w setHidden:NO];
            anyHidden = YES;
        }
        if (w.alpha < 0.99) {
            w.alpha = 1.0;
        }
    }
    if (anyHidden != gOverlayWasHidden) {
        gOverlayWasHidden = anyHidden;
        KLLogC(@"UI", @"浮层窗口%s", anyHidden ? "隐藏→已恢复" : "已隐藏（面板关闭，球保持可见）");
    }
}

// 按结构认面板：浮层窗口里 modal 呈现的那个 VC 的最大子视图就是卡片。
// 不依赖文字锚点 —— 这个包的面板行是自绘控件，文本匹配不可靠。
static UIView *KLPanelFromOverlay(void) {
    for (UIWindow *w in KLOverylayWindows()) {
        if (w.isHidden) {
            continue;
        }
        UIViewController *vc = w.rootViewController;
        int guard = 0;
        while (vc.presentedViewController != nil && guard < 4) {
            vc = vc.presentedViewController;
            guard += 1;
        }
        if (vc == nil || vc.view == nil) {
            continue;
        }
        // 要区分「遮罩层」和「卡片」：
        //   遮罩 ≈ 整个屏幕（面积比接近 1），卡片 ≈ 屏宽 60~85%、高度 < 80%
        CGRect vb = vc.view.bounds;
        CGFloat vArea = vb.size.width * vb.size.height;
        if (vArea < 1.0) {
            continue;
        }
        UIView *best = nil;
        CGFloat bestArea = 0;
        for (UIView *sub in vc.view.subviews) {
            CGRect r = sub.frame;
            CGFloat a = r.size.width * r.size.height;
            CGFloat ratio = a / vArea;
            BOOL tooBig = (ratio > 0.92);                       // 遮罩/全屏容器
            BOOL tooSmall = (a < 120.0 * 80.0);
            if (tooBig || tooSmall) {
                continue;
            }
            if (a > bestArea) {
                bestArea = a;
                best = sub;
            }
        }
        if (best != nil) {
            KLLogC(@"UI", @"面板卡片候选 %@ %.0fx%.0f (占屏 %.0f%%)",
                   NSStringFromClass([best class]),
                   best.bounds.size.width, best.bounds.size.height,
                   (bestArea / vArea) * 100.0);
            return best;
        }
        // 再退一层：VC.view 直接当卡片（尺寸合理时）
        if (vb.size.width >= 120.0 && vb.size.height >= 80.0 && vb.size.height < vArea / vb.size.width * 0.92) {
            return vc.view;
        }
    }
    return nil;
}

void KLEnsurePanelButtons(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != UIApplicationStateActive) {
        return;
    }
    gAttempts += 1;
    KLKeepOverlayAlive();

    UIView *cached = gCardRef;
    if (cached != nil && cached.window != nil) {
        KLInstallRow(cached);
        return;
    }
    UIView *card = KLPanelFromOverlay();   // 先按窗口结构认
    if (card == nil) {
        card = KLFindPanelCard();          // 再退回文字锚点
    }
    gCardRef = card;
    if (card == nil) {
        if (gAttempts > 12) {
            if (!gReportedMissing) {
                gReportedMissing = YES;
                KLLogC(@"ERR", @"启动 %ld 次仍未找到 KAlert 面板，按钮未注入（锚点文案不匹配？）",
                       (long)gAttempts);
            }
            // 需求变更：不要悬浮日志球，只在面板里提供入口。
            // 找不到面板时什么都不放（面板本身由 KLRevivePanel 负责拉起来）。
            if (!gReportedNoFab) {
                gReportedNoFab = YES;
                KLLogC(@"UI", @"未把按钮挂到面板上（不创建悬浮球，按需求只保留面板入口）");
            }
        }
        return;
    }
    KLInstallRow(card);
}
