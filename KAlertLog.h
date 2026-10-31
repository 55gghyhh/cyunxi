#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

NSString *KLAppName(void);
NSString *KLAppVersion(void);
NSString *KLNowStamp(void);

void KLLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void KLLogC(NSString *cat, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);

@interface KLStore : NSObject
+ (instancetype)shared;
- (void)append:(NSString *)text category:(NSString *)cat;
- (void)appendRaw:(NSString *)text;
- (NSUInteger)lineCount;
- (NSString *)snapshotForDisplay:(NSUInteger)maxLines;
- (NSString *)snapshotAll;
- (void)clearAll;
- (NSString *)exportFileName;
- (nullable NSURL *)writeExportFile;
- (NSDate *)firstDate;
- (NSDate *)lastDate;
@end

void KLInstallStderrCapture(void);
void KLInstallNSLogTap(void);
void KLNetInstall(void);

@interface KLViewerVC : UIViewController
@end

void KLPresentLogViewer(void);
void KLShareLogFromView(UIView * _Nullable src);

void KLEnsurePanelButtons(void);

/* 主动调用 ioskuka 的 0xF408 把面板/悬浮球建出来（该函数在本包里是死代码）*/
void KLRevivePanel(void);

/* 启动探针：在 key window 上弹一个 8 秒自动消失的框。
   它只证明一件事——这个 dylib 真的被 dyld 加载、且主线程 UI 可用。
   拿它当判据，比看 Console 可靠（用户不一定有 Mac）。*/
void KLBootProbe(NSString *extra);

NS_ASSUME_NONNULL_END
