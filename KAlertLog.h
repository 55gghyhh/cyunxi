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

NS_ASSUME_NONNULL_END
