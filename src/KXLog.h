//
//  KXLog.h —— 运行日志公共接口
//
#import <Foundation/Foundation.h>

/// 追加一条日志（线程安全，自动落盘 Library/Caches/KXLog.txt）
void KXLogAdd(NSString *tag, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
void KXLogClear(void);
NSString *KXLogText(void);
void KXLogInstallUI(void);      // 等 keyWindow 就绪后调用，挂悬浮球
