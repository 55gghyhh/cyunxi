#import "KAlertLog.h"

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
    }];
    [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        (void)n;
        KLLogC(@"LIFE", @"收到内存警告");
    }];
}

__attribute__((constructor)) static void KAlertLogInit(void) {
    @autoreleasepool {
        KLInstallStderrCapture();
        [KLStore.shared append:@"==== 日志内核启动 ====" category:@"CORE"];
        KLInstallNSLogTap();
        KLLog(@"==== %@ %@ 启动 ====", KLAppName(), KLAppVersion());
        KLNetInstall();
        dispatch_async(dispatch_get_main_queue(), ^{
            KLRegisterLifecycle();
            KLStartPanelWatcher();
        });
    }
}
