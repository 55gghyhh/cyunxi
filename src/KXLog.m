//
//  KXLog.m —— 运行日志：记录 / 查看 / 清空 / 导出 txt
//
//  UI 风格：对齐 ioskuka 的 KAlertSheet
//    primaryFill     暗 white(0.95) / 亮 white(0.11)
//    cardBackground  暗 rgb(0.11,0.11,0.13) / 亮 white
//    titleColor      暗 rgb(0.83,0.69,0.47) / 亮 rgb(0.72,0.53,0.28)
//    卡片圆角 20，按钮圆角 12，蒙层 black 0.45
//

#import <UIKit/UIKit.h>
#import "KXLog.h"

static NSMutableArray<NSString *> *gLines;
static NSRecursiveLock *gLock;
static NSString *gCacheFile;
static const NSUInteger kMaxLines = 3000;

static UIView *gPanel;
static UITextView *gText;
static UIView *gFab;

static void KXFlush(void) {
    if (!gCacheFile) return;
    NSString *all = [gLines componentsJoinedByString:@"\n"];
    [all writeToFile:gCacheFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

void KXLogAdd(NSString *tag, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!msg) return;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  [%@]  %@",
                      [df stringFromDate:[NSDate date]], tag ?: @"-", msg];

    [gLock lock];
    [gLines addObject:line];
    while (gLines.count > kMaxLines) [gLines removeObjectAtIndex:0];
    [gLock unlock];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ KXFlush(); });
}

void KXLogClear(void) {
    [gLock lock];
    [gLines removeAllObjects];
    [gLock unlock];
    KXLogAdd(@"CLEAR", @"日志已清空");
}

NSString *KXLogText(void) {
    [gLock lock];
    NSString *s = gLines.count ? [gLines componentsJoinedByString:@"\n"] : @"(暂无日志)";
    [gLock unlock];
    return s;
}

#pragma mark - 配色 / 窗口

static BOOL KXDark(void) {
    if (@available(iOS 13.0, *))
        return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    return NO;
}
static UIColor *KXFill(void)     { return KXDark() ? [UIColor colorWithWhite:0.95 alpha:1] : [UIColor colorWithWhite:0.11 alpha:1]; }
static UIColor *KXFillText(void) { return KXDark() ? [UIColor colorWithWhite:0.11 alpha:1] : [UIColor whiteColor]; }
static UIColor *KXCard(void)     { return KXDark() ? [UIColor colorWithRed:0.11 green:0.11 blue:0.13 alpha:1] : [UIColor whiteColor]; }
static UIColor *KXGold(void)     { return KXDark() ? [UIColor colorWithRed:0.83 green:0.69 blue:0.47 alpha:1]
                                                    : [UIColor colorWithRed:0.72 green:0.53 blue:0.28 alpha:1]; }

static UIWindow *KXWindow(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        if (w.isKeyWindow) return w;
    return UIApplication.sharedApplication.windows.firstObject;
}

#pragma mark - 目标对象

@interface KXLogTarget : NSObject
+ (instancetype)shared;
@end

@implementation KXLogTarget
+ (instancetype)shared {
    static KXLogTarget *t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[KXLogTarget alloc] init]; });
    return t;
}
- (void)onFab:(id)s { [self show]; }
- (void)onClose:(id)s { [gPanel removeFromSuperview]; gPanel = nil; gText = nil; }
- (void)onDim:(id)s { [self onClose:nil]; }

- (void)onClear:(id)s {
    KXLogClear();
    if (gText) gText.text = KXLogText();
}

- (void)onExport:(id)s {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"KXLog_%@.txt", [df stringFromDate:[NSDate date]]];
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:name];
    [KXLogText() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    KXLogAdd(@"EXPORT", @"%@", path);
    if (gText) gText.text = KXLogText();

    UIActivityViewController *act = [[UIActivityViewController alloc] initWithActivityItems:@[path]
                                                                     applicationActivities:nil];
    UIViewController *vc = KXWindow().rootViewController;
    if (vc) {
        act.popoverPresentationController.sourceView = gPanel ?: vc.view;
        [vc presentViewController:act animated:YES completion:nil];
    }
}

- (void)show {
    if (gPanel) { gText.text = KXLogText(); return; }
    UIWindow *win = KXWindow(); if (!win) return;

    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat pad = 16, cw = b.size.width - pad * 2, ch = b.size.height * 0.64;
    CGFloat top = (b.size.height - ch) / 2;

    gPanel = [[UIView alloc] initWithFrame:b];
    gPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [gPanel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDim:)]];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(pad, top, cw, ch)];
    card.backgroundColor = KXCard();
    card.layer.cornerRadius = 20;
    card.clipsToBounds = YES;
    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDim:)]];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 16, cw - 90, 26)];
    title.text = @"运行日志";
    title.textColor = KXGold();
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    title.userInteractionEnabled = NO;
    [card addSubview:title];

    UIButton *close = [[UIButton alloc] initWithFrame:CGRectMake(cw - 56, 12, 44, 34)];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(onClose:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    CGFloat bh = 42, by = ch - bh - 16;
    gText = [[UITextView alloc] initWithFrame:CGRectMake(12, 48, cw - 24, by - 56)];
    gText.editable = NO;
    gText.backgroundColor = [UIColor clearColor];
    gText.textColor = [UIColor labelColor];
    gText.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    gText.text = KXLogText();
    [card addSubview:gText];

    CGFloat bw = (cw - 34) / 2;
    NSArray<NSString *> *names = @[@"导出 TXT", @"清空日志"];
    NSArray<NSString *> *sels  = @[@"onExport:", @"onClear:"];
    for (int i = 0; i < 2; i++) {
        UIButton *btn = [[UIButton alloc] initWithFrame:CGRectMake(12 + i * (bw + 10), by, bw, bh)];
        [btn setTitle:names[i] forState:UIControlStateNormal];
        [btn setTitleColor:KXFillText() forState:UIControlStateNormal];
        btn.backgroundColor = KXFill();
        btn.layer.cornerRadius = 12;
        [btn addTarget:self action:NSSelectorFromString(sels[i]) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:btn];
    }

    [gPanel addSubview:card];
    [win addSubview:gPanel];
    KXLogAdd(@"UI", @"打开日志面板");
}
@end

#pragma mark - 悬浮球

static void KXBuildFab(void) {
    if (gFab) return;
    UIWindow *win = KXWindow(); if (!win) return;

    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat s = 46;
    gFab = [[UIView alloc] initWithFrame:CGRectMake(b.size.width - s - 8, 300, s, s)];
    gFab.backgroundColor = KXFill();
    gFab.layer.cornerRadius = s / 2;
    gFab.userInteractionEnabled = YES;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, s, s)];
    l.text = @"LOG";
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = KXFillText();
    l.font = [UIFont boldSystemFontOfSize:11];
    l.userInteractionEnabled = NO;
    [gFab addSubview:l];

    [gFab addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:[KXLogTarget shared]
                                                                      action:@selector(onFab:)]];
    [win addSubview:gFab];
    KXLogAdd(@"UI", @"悬浮入口已挂载");
}

void KXLogInstallUI(void) {
    __block int tries = 0;
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (gFab || ++tries > 40) { [timer invalidate]; return; }
        if (KXWindow()) KXBuildFab();
    }];
    (void)t;
}

#pragma mark - 初始化（由 KXUniversal 调用）

__attribute__((constructor))
static void KXLogInit(void) {
    gLock  = [[NSRecursiveLock alloc] init];
    gLines = [NSMutableArray array];
    gCacheFile = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                  stringByAppendingPathComponent:@"KXLog.txt"];
    KXLogAdd(@"BOOT", @"KXLog 已装载");
}
