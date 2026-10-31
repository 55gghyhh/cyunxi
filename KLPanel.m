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

static UIButton *KLMakeButton(NSString *title, UIButton *ref, CGRect frame) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    if (ref) {
        UIColor *bg = ref.backgroundColor;
        b.backgroundColor = bg ?: [UIColor colorWithWhite:1.0 alpha:0.14];
        UIColor *fg = [ref titleColorForState:UIControlStateNormal];
        [b setTitleColor:(fg ?: [UIColor whiteColor]) forState:UIControlStateNormal];
        UIFont *f = ref.titleLabel.font;
        b.titleLabel.font = f ?: [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        b.layer.cornerRadius = ref.layer.cornerRadius;
        b.clipsToBounds = ref.clipsToBounds;
        b.layer.borderWidth = ref.layer.borderWidth;
        b.layer.borderColor = ref.layer.borderColor;
    } else {
        b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 8.0;
        b.clipsToBounds = YES;
    }
    return b;
}

static void KLInstallRow(UIView *card) {
    if (gTarget == nil) {
        gTarget = [[KLActionTarget alloc] init];
    }
    UIWindow *win = card.window ?: KLKeyWindow();

    UIView *bar = objc_getAssociatedObject(card, kKLRowKey);
    if (bar != nil) {
        // 已经装过：只做“跟随”，卡片被挪动/改尺寸时把按钮条摆回去
        if (bar.superview == nil) {
            return;
        }
        CGFloat inset = MAX(8.0, bar.tag / 10.0);
        if (bar.superview == card) {
            CGFloat need = CGRectGetMaxY(bar.frame) + 10.0;
            if (card.bounds.size.height + 0.5 < need) {
                CGRect f = card.frame;
                f.size.height = need;
                card.frame = f;
            }
        } else {
            CGRect cf = [card convertRect:card.bounds toView:bar.superview];
            CGRect f = bar.frame;
            f.origin.x = CGRectGetMinX(cf) + inset;
            f.origin.y = CGRectGetMaxY(cf) + 8.0;
            f.size.width = MAX(120.0, CGRectGetWidth(cf) - inset * 2.0);
            bar.frame = f;
        }
        return;
    }

    UIButton *ref = KLReferenceButton(card);
    CGFloat width = card.bounds.size.width;
    CGFloat baseH = card.bounds.size.height;
    if (width < 80.0 || baseH < 60.0) {
        return;
    }

    CGFloat inset = 14.0;
    CGFloat btnH = 34.0;
    CGRect refRect = CGRectMake(inset, 0.0, width - inset * 2.0, btnH);
    if (ref != nil) {
        if (ref.superview != nil) {
            refRect = [ref.superview convertRect:ref.frame toView:card];
        } else {
            refRect = ref.frame;
        }
        inset = MAX(refRect.origin.x, 10.0);
        btnH = refRect.size.height;
    }
    if (btnH < 22.0 || btnH > 80.0) {
        btnH = 34.0;
    }
    CGFloat usable = width - inset * 2.0;
    if (usable < 100.0) {
        return;
    }
    CGFloat gap = 10.0;
    CGFloat btnW = (usable - gap) / 2.0;

    // 放哪儿：优先加进卡片底部（视觉上属于面板），
    // 但卡片长高后如果会顶出屏幕，就改成贴在卡片下方的兄弟视图——绝不覆盖/改动面板原有内容。
    CGRect cardInWin = card.bounds;
    if (win != nil) {
        cardInWin = [card convertRect:card.bounds toView:win];
    }
    CGFloat safeBottom = 0.0;
    if (@available(iOS 11.0, *)) {
        safeBottom = win.safeAreaInsets.bottom;
    }
    CGFloat limitY = (win != nil ? win.bounds.size.height : CGRectGetMaxY(cardInWin)) - safeBottom - 8.0;
    BOOL inside = (CGRectGetMaxY(cardInWin) + btnH + 14.0) <= limitY;

    UIView *container = nil;
    NSString *mode = nil;
    if (inside) {
        container = [[UIView alloc] initWithFrame:CGRectMake(inset, baseH + 6.0, usable, btnH)];
        container.backgroundColor = [UIColor clearColor];
        [card addSubview:container];
        CGRect cf = card.frame;
        cf.size.height = baseH + btnH + 14.0;
        card.frame = cf;
        mode = @"卡片内";
    } else {
        UIView *host = card.superview ?: win;
        if (host == nil) {
            return;
        }
        CGRect cf = [card convertRect:card.bounds toView:host];
        container = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMinX(cf) + inset,
                                                             CGRectGetMaxY(cf) + 8.0,
                                                             usable,
                                                             btnH)];
        container.backgroundColor = [UIColor clearColor];
        [host addSubview:container];
        [host bringSubviewToFront:container];
        mode = @"卡片下方（窗口空间不足，避免压住原面板）";
    }
    container.tag = (NSInteger)(inset * 10.0);
    container.autoresizingMask = UIViewAutoresizingNone;

    UIButton *bLog = KLMakeButton(@"运行日志", ref, CGRectMake(0.0, 0.0, btnW, btnH));
    [bLog addTarget:gTarget action:@selector(onViewLog:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:bLog];

    UIButton *bExp = KLMakeButton(@"导出日志", ref, CGRectMake(btnW + gap, 0.0, btnW, btnH));
    [bExp addTarget:gTarget action:@selector(onExportLog:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:bExp];

    objc_setAssociatedObject(card, kKLRowKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    KLLogC(@"UI", @"面板已注入「运行日志 / 导出日志」 方式=%@ card=%@ %.0fx%.0f 按钮 %.0fx%.0f ref=%@",
           mode, NSStringFromClass([card class]), width, baseH, btnW, btnH,
           ref ? NSStringFromClass([ref class]) : @"none");
}
static UIWindow *KLKeyWindow(void);

void KLBootProbe(NSString *extra) {
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

static UIWindow *KLKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) {
                return w;
            }
            if (fallback == nil && w.rootViewController != nil) {
                fallback = w;
            }
        }
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

static void KLInstallFallbackFab(void) {
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

void KLEnsurePanelButtons(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != UIApplicationStateActive) {
        return;
    }
    gAttempts += 1;
    UIView *cached = gCardRef;
    if (cached != nil && cached.window != nil) {
        KLInstallRow(cached);
        return;
    }
    UIView *card = KLFindPanelCard();
    gCardRef = card;
    if (card == nil) {
        if (gAttempts > 12) {
            if (!gReportedMissing) {
                gReportedMissing = YES;
                KLLogC(@"ERR", @"启动 %ld 次仍未找到 KAlert 面板，按钮未注入（锚点文案不匹配？）",
                       (long)gAttempts);
            }
            KLInstallFallbackFab();
        }
        return;
    }
    KLInstallRow(card);
}
