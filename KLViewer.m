#import "KAlertLog.h"
#import <QuartzCore/QuartzCore.h>

static UIViewController *KLTopViewController(void) {
    UIWindow *key = nil;
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) {
                key = w;
                break;
            }
        }
        if (key) {
            break;
        }
    }
    if (key == nil) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.rootViewController) {
                    key = w;
                    break;
                }
            }
            if (key) {
                break;
            }
        }
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

@interface KLViewerVC ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) NSUInteger lastCount;
@property (nonatomic, assign) BOOL stickToBottom;
@end

@implementation KLViewerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(onClose)];

    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithTitle:@"分享"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(onShare)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(onClear)];
    self.navigationItem.rightBarButtonItems = @[ share, clear ];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.selectable = YES;
    tv.alwaysBounceVertical = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    self.textView = tv;

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
    ]];

    self.stickToBottom = YES;
    [self reloadLog];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
        (void)t;
        [weakSelf reloadLog];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)reloadLog {
    KLStore *store = [KLStore shared];
    NSUInteger count = [store lineCount];
    NSUInteger shown = 4000;
    BOOL needs = (count != self.lastCount) || (self.textView.text.length == 0);
    if (!needs) {
        return;
    }
    self.lastCount = count;

    UIScrollView *sv = self.textView;
    BOOL atBottom = (sv.contentOffset.y + sv.bounds.size.height + 40.0 >= sv.contentSize.height);
    NSString *text = [store snapshotForDisplay:shown];
    self.textView.text = text;

    if (atBottom || self.stickToBottom) {
        NSUInteger len = text.length;
        if (len > 0) {
            NSRange end = NSMakeRange(len - 1, 1);
            [self.textView scrollRangeToVisible:end];
        }
    }
}

- (void)onClear {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空日志"
                                                                message:@"将删除本次会话已记录的日志，不可恢复。"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"清空"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        (void)a;
        [[KLStore shared] clearAll];
        weakSelf.lastCount = 0;
        [weakSelf reloadLog];
        KLLogC(@"UI", @"日志已清空");
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onShare {
    [self presentShareFromBarButton];
}

- (void)presentShareFromBarButton {
    NSURL *url = [[KLStore shared] writeExportFile];
    if (url == nil) {
        return;
    }
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                                    applicationActivities:nil];
    if (av.popoverPresentationController) {
        av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    }
    [self presentViewController:av animated:YES completion:nil];
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

void KLPresentLogViewer(void) {
    UIViewController *top = KLTopViewController();
    if (top == nil) {
        KLLogC(@"ERR", @"找不到可用的顶层控制器，日志面板无法弹出");
        return;
    }
    KLViewerVC *vc = [[KLViewerVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:nav animated:YES completion:^{
        KLLogC(@"UI", @"日志面板已打开");
    }];
}

void KLShareLogFromView(UIView *src) {
    UIViewController *top = KLTopViewController();
    NSURL *url = [[KLStore shared] writeExportFile];
    if (url == nil) {
        return;
    }
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                    applicationActivities:nil];
    if (av.popoverPresentationController && src) {
        av.popoverPresentationController.sourceView = src;
        av.popoverPresentationController.sourceRect = src.bounds;
    }
    if (top == nil) {
        KLLogC(@"ERR", @"找不到可用的顶层控制器，导出分享未弹出");
        return;
    }
    [top presentViewController:av animated:YES completion:nil];
}
