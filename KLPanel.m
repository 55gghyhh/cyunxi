#import "KAlertLog.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const void *kKLRowKey = &kKLRowKey;

@interface KLActionTarget : NSObject
- (void)onViewLog:(UIButton *)sender;
- (void)onExportLog:(UIButton *)sender;
@end

static KLActionTarget *gTarget = nil;
static NSInteger gAttempts = 0;
static BOOL gReportedMissing = NO;
static __weak UIView *gCardRef = nil;

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
    UIView *row = objc_getAssociatedObject(card, kKLRowKey);
    if (row != nil && row.superview == card) {
        CGFloat need = CGRectGetMaxY(row.frame) + 10.0;
        if (card.bounds.size.height + 0.5 < need) {
            CGRect f = card.frame;
            f.size.height = need;
            card.frame = f;
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

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(inset, baseH + 6.0, usable, btnH)];
    container.backgroundColor = [UIColor clearColor];

    UIButton *bLog = KLMakeButton(@"运行日志", ref, CGRectMake(0.0, 0.0, btnW, btnH));
    [bLog addTarget:gTarget action:@selector(onViewLog:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:bLog];

    UIButton *bExp = KLMakeButton(@"导出日志", ref, CGRectMake(btnW + gap, 0.0, btnW, btnH));
    [bExp addTarget:gTarget action:@selector(onExportLog:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:bExp];

    CGRect cf = card.frame;
    cf.size.height = baseH + btnH + 14.0;
    card.frame = cf;

    [card addSubview:container];
    objc_setAssociatedObject(card, kKLRowKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    KLLogC(@"UI", @"面板已注入「运行日志 / 导出日志」 card=%@ %.0fx%.0f → 高 %.0f, ref=%@ %.0fx%.0f",
           NSStringFromClass([card class]), width, baseH, cf.size.height,
           ref ? NSStringFromClass([ref class]) : @"none", refRect.size.width, btnH);
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
        if (gAttempts > 12 && !gReportedMissing) {
            gReportedMissing = YES;
            KLLogC(@"ERR", @"启动 %ld 秒仍未找到 KAlert 面板，按钮未注入（锚点文案不匹配？）",
                   (long)gAttempts);
        }
        return;
    }
    KLInstallRow(card);
}
