#import "KAlertLog.h"
#import <unistd.h>
#import <sys/time.h>
#import <dlfcn.h>

static const NSUInteger kKLMaxLines = 20000;
static const NSUInteger kKLTrimBatch = 4000;

static NSMutableArray<NSString *> *gLines;
static NSLock *gLock;
static NSFileHandle *gFile;
static NSString *gDir;
static NSDate *gFirst;
static NSDate *gLast;

@interface KLStore ()
- (void)setup;
@end

static NSString *KLSafeName(NSString *in) {
    if (in.length == 0) {
        return @"App";
    }
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    return [[in componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
}

NSString *KLAppName(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSString *n = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (n.length == 0) {
        n = [b objectForInfoDictionaryKey:@"CFBundleName"];
    }
    if (n.length == 0) {
        n = b.bundleIdentifier;
    }
    return n.length ? n : @"App";
}

NSString *KLAppVersion(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSString *v = [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [b objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (v.length == 0) {
        return @"?";
    }
    return build.length ? [NSString stringWithFormat:@"%@(%@)", v, build] : v;
}

static NSDateFormatter *KLClockFormatter(void) {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"HH:mm:ss.SSS";
    });
    return f;
}

static NSDateFormatter *KLFileFormatter(void) {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyyMMdd-HHmmss";
    });
    return f;
}

NSString *KLNowStamp(void) {
    return [KLClockFormatter() stringFromDate:[NSDate date]];
}

@implementation KLStore

+ (instancetype)shared {
    static KLStore *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[KLStore alloc] init];
        [inst setup];
    });
    return inst;
}

- (void)setup {
    if (gLock) {
        return;
    }
    gLock = [[NSLock alloc] init];
    gLines = [NSMutableArray arrayWithCapacity:4096];
    gFirst = [NSDate date];
    gLast = gFirst;
    gDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"KAlertLog"];
    [[NSFileManager defaultManager] createDirectoryAtPath:gDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *path = [gDir stringByAppendingPathComponent:@"session.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    gFile = [NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [gFile seekToEndOfFile];
    } @catch (NSException *e) {
        (void)e;
        gFile = nil;
    }
}

- (void)append:(NSString *)text category:(NSString *)cat {
    if (text == nil) {
        return;
    }
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@", KLNowStamp(), cat, text];
    [self appendRaw:line];
}

- (void)appendRaw:(NSString *)text {
    if (text.length == 0) {
        return;
    }
    [gLock lock];
    NSDate *now = [NSDate date];
    gLast = now;
    if (gLines.count >= kKLMaxLines) {
        NSUInteger batch = MIN(kKLTrimBatch, gLines.count);
        [gLines removeObjectsInRange:NSMakeRange(0, batch)];
        [gLines addObject:[NSString stringWithFormat:@"-- 早期日志已截断（内存上限 %lu 行）--",
                           (unsigned long)kKLMaxLines]];
    }
    [gLines addObject:text];
    if (gFile) {
        NSData *d = [[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        if (d) {
            @try {
                [gFile writeData:d];
            } @catch (NSException *e) {
                (void)e;
                gFile = nil;
            }
        }
    }
    [gLock unlock];
}

- (NSUInteger)lineCount {
    [gLock lock];
    NSUInteger n = gLines.count;
    [gLock unlock];
    return n;
}

- (NSString *)snapshotForDisplay:(NSUInteger)maxLines {
    [gLock lock];
    NSUInteger total = gLines.count;
    NSUInteger start = (maxLines > 0 && total > maxLines) ? (total - maxLines) : 0;
    NSArray<NSString *> *slice = [gLines subarrayWithRange:NSMakeRange(start, total - start)];
    NSString *body = [slice componentsJoinedByString:@"\n"];
    NSDate *first = gFirst;
    [gLock unlock];

    NSMutableString *out = [NSMutableString stringWithCapacity:body.length + 160];
    [out appendFormat:@"# 共 %lu 行 · 会话开始 %@ · 显示 %lu 行\n",
                      (unsigned long)total,
                      [KLClockFormatter() stringFromDate:first],
                      (unsigned long)slice.count];
    if (start > 0) {
        [out appendFormat:@"# 以上省略 %lu 行（完整内容请用「导出日志」）\n", (unsigned long)start];
    }
    [out appendString:body];
    return out;
}

- (NSString *)snapshotAll {
    [gLock lock];
    NSString *body = [gLines componentsJoinedByString:@"\n"];
    NSDate *first = gFirst;
    NSDate *last = gLast;
    [gLock unlock];

    NSMutableString *out = [NSMutableString stringWithCapacity:body.length + 320];
    [out appendFormat:@"应用: %@\n版本: %@\n会话开始: %@\n记录结束: %@\n行数: %lu\n",
                      KLAppName(), KLAppVersion(),
                      [KLFileFormatter() stringFromDate:first],
                      [KLFileFormatter() stringFromDate:last],
                      (unsigned long)[self lineCount]];
    [out appendString:@"------------------------------------------------------------\n"];
    [out appendString:body];
    [out appendString:@"\n"];
    return out;
}

- (void)clearAll {
    [gLock lock];
    [gLines removeAllObjects];
    gFirst = [NSDate date];
    gLast = gFirst;
    if (gFile) {
        @try {
            [gFile truncateFileAtOffset:0];
            [gFile seekToFileOffset:0];
        } @catch (NSException *e) {
            (void)e;
            gFile = nil;
        }
    }
    [gLock unlock];
}

- (NSDate *)firstDate {
    [gLock lock];
    NSDate *d = gFirst;
    [gLock unlock];
    return d;
}

- (NSDate *)lastDate {
    [gLock lock];
    NSDate *d = gLast;
    [gLock unlock];
    return d;
}

- (NSString *)exportFileName {
    NSString *app = KLSafeName(KLAppName());
    NSString *from = [KLFileFormatter() stringFromDate:[self firstDate]];
    NSString *to = [KLFileFormatter() stringFromDate:[self lastDate]];
    return [NSString stringWithFormat:@"%@_%@_%@.txt", app, from, to];
}

- (NSURL *)writeExportFile {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"KAlertLog"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:[self exportFileName]];
    NSError *err = nil;
    BOOL ok = [[self snapshotAll] writeToFile:path
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:&err];
    if (!ok) {
        KLLogC(@"ERR", @"导出失败: %@", err.localizedDescription ?: @"unknown");
        return nil;
    }
    KLLogC(@"UI", @"已导出 %@", path.lastPathComponent);
    return [NSURL fileURLWithPath:path];
}

@end

void KLLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [[KLStore shared] append:msg category:@"APP"];
}

void KLLogC(NSString *cat, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [[KLStore shared] append:msg category:cat];
}

static int gErrPipe[2] = {-1, -1};

void KLInstallStderrCapture(void) {
    [[KLStore shared] setup];
    if (gErrPipe[0] >= 0) {
        return;
    }
    if (pipe(gErrPipe) != 0) {
        gErrPipe[0] = -1;
        gErrPipe[1] = -1;
        return;
    }
    dup2(gErrPipe[1], STDERR_FILENO);
    close(gErrPipe[1]);
    gErrPipe[1] = -1;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        char buf[4096];
        NSMutableData *acc = [[NSMutableData alloc] init];
        while (1) {
            ssize_t n = read(gErrPipe[0], buf, sizeof(buf));
            if (n <= 0) {
                usleep(20000);
                continue;
            }
            [acc appendBytes:buf length:(NSUInteger)n];
            while (1) {
                const char *bytes = (const char *)acc.bytes;
                NSUInteger len = acc.length;
                NSUInteger cut = NSNotFound;
                for (NSUInteger i = 0; i < len; i++) {
                    if (bytes[i] == '\n') {
                        cut = i;
                        break;
                    }
                }
                if (cut == NSNotFound) {
                    if (len > 8192) {
                        [acc setLength:0];
                    }
                    break;
                }
                NSData *lineData = [acc subdataWithRange:NSMakeRange(0, cut)];
                [acc replaceBytesInRange:NSMakeRange(0, cut + 1) withBytes:NULL length:0];
                NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                if (line.length) {
                    [[KLStore shared] append:line category:@"LOG"];
                }
            }
        }
    });
}

static void KLLogTap(const char *str, unsigned int len, BOOL banner) {
    (void)banner;
    if (str == NULL || len == 0) {
        return;
    }
    NSString *s = [[NSString alloc] initWithBytes:str length:len encoding:NSUTF8StringEncoding];
    if (s.length) {
        NSString *trim = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trim.length) {
            [[KLStore shared] append:trim category:@"NSLog"];
        }
    }
}

void KLInstallNSLogTap(void) {
    [[KLStore shared] setup];
    void *sym = dlsym(RTLD_DEFAULT, "_NSSetLogCStringFunction");
    if (sym == NULL) {
        KLLogC(@"ERR", @"_NSSetLogCStringFunction 不可用，仅靠 stderr 抓 NSLog");
        return;
    }
    typedef void (*KLLogCStringFn)(const char *, unsigned int, BOOL);
    typedef void (*KLSetLogCStringFn)(KLLogCStringFn);
    KLSetLogCStringFn setFn = (KLSetLogCStringFn)sym;
    if (setFn == NULL) {
        return;
    }
    setFn(KLLogTap);
}
