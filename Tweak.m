#import "KAlertLog.h"
#import <unistd.h>

static NSTimer *gWatcher = nil;

static void KLStartPanelWatcher(void) {
    if (gWatcher != nil) {
        return;
    }
    gWatcher = [NSTimer timerWithTimeInterval:0.5
                                      repeats:YES
                                        block:^(NSTimer *t) {
        (void)t;
        KLEnsurePanelButtons();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gWatcher forMode:NSRunLoopCommonModes];
}

static void KLRegisterLifecycle(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        (void)n;
        KLLogC(@"LIFE", @"应用进入前台");
    }];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        (void)n;
        KLLogC(@"LIFE", @"应用进入后台");
        // 无 UI 也能拿到导出文件：每次退后台落一份带时间段的 txt
        NSURL *u = [[KLStore shared] writeExportFile];
        if (u != nil) {
            KLLogC(@"LIFE", @"已自动导出 → tmp/KAlertLog/%@", u.lastPathComponent);
        }
    }];
    [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        (void)n;
        KLLogC(@"LIFE", @"收到内存警告");
    }];
}

// __attribute__((constructor)) = dyld 加载完这个 dylib 就调，早于 main()。
// 这条 NSLog 必须是函数体的第一句：_NSSetLogCStringFunction 一旦被下面接管，
// NSLog 的输出就改道进 App 内日志，Console 里就再也看不到了。
__attribute__((constructor)) static void KAlertLogInit(void) {
    @autoreleasepool {
        NSLog(@"[KAlertLog] loaded into %@ %@ (bundle=%@) pid=%d",
              KLAppName(), KLAppVersion(),
              [NSBundle mainBundle].bundleIdentifier, (int)getpid());

        KLInstallStderrCapture();
        [KLStore.shared append:@"==== 日志内核启动 ====" category:@"CORE"];
        KLInstallNSLogTap();
        KLLog(@"==== %@ %@ 启动 ====", KLAppName(), KLAppVersion());
        KLNetInstall();

        dispatch_async(dispatch_get_main_queue(), ^{
            KLRegisterLifecycle();
            KLStartPanelWatcher();
            // App 起来之后再复活面板：构造函数阶段 UIKit 还没就绪，过早调用会崩
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                KLRevivePanel();
            });
            // 探针：1.2s 后弹框（等 App 自己的首屏铺完，避免被它的启动画面盖住）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                KLBootProbe(@"rpath 解析成功 → 加载链路通");
            });
        });
    }
}
