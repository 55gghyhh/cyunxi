#import "KAlertLog.h"
#import <objc/runtime.h>
#import <zlib.h>

typedef NSURLSessionDataTask *(*KLDTP_Req)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*KLDTP_URL)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*KLUPP_Data)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*KLUPP_File)(id, SEL, NSURLRequest *, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDownloadTask *(*KLDNP_Req)(id, SEL, NSURLRequest *, void (^)(NSURL *, NSURLResponse *, NSError *));
typedef NSURLSessionDownloadTask *(*KLDNP_URL)(id, SEL, NSURL *, void (^)(NSURL *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*KLDTP_ReqPlain)(id, SEL, NSURLRequest *);
typedef NSURLSessionUploadTask *(*KLUPP_DataPlain)(id, SEL, NSURLRequest *, NSData *);
typedef NSURLSessionUploadTask *(*KLUPP_FilePlain)(id, SEL, NSURLRequest *, NSURL *);
typedef NSURLSessionDownloadTask *(*KLDNP_ReqPlain)(id, SEL, NSURLRequest *);

static NSMutableDictionary<NSString *, NSValue *> *gOldIMPs = nil;
static NSLock *gOldLock = nil;
static int64_t gSeq = 0;
static BOOL gInstalled = NO;

static NSString *KLKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%p|%s", (void *)cls, sel_getName(sel)];
}

static void KLRemember(Class cls, SEL sel, IMP old) {
    if (gOldLock == nil) {
        gOldLock = [[NSLock alloc] init];
        gOldIMPs = [[NSMutableDictionary alloc] init];
    }
    [gOldLock lock];
    gOldIMPs[KLKey(cls, sel)] = [NSValue valueWithPointer:(const void *)old];
    [gOldLock unlock];
}

static IMP KLOrig(id self, SEL sel) {
    Class c = object_getClass(self);
    IMP found = NULL;
    if (gOldLock != nil) {
        [gOldLock lock];
        while (c != Nil && found == NULL) {
            NSValue *v = gOldIMPs[KLKey(c, sel)];
            if (v != nil) {
                found = (IMP)v.pointerValue;
            }
            c = class_getSuperclass(c);
        }
        [gOldLock unlock];
    }
    return found;
}

static Method KLOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    Method hit = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) {
            hit = list[i];
            break;
        }
    }
    if (list != NULL) {
        free(list);
    }
    return hit;
}

static BOOL KLSwizzle(Class cls, SEL sel, IMP newImp) {
    if (cls == Nil) {
        return NO;
    }
    Method m = KLOwnMethod(cls, sel);
    if (m == NULL) {
        return NO;
    }
    IMP old = method_getImplementation(m);
    if (old == newImp) {
        return NO;
    }
    KLRemember(cls, sel, old);
    method_setImplementation(m, newImp);
    return YES;
}

static NSString *KLNextTag(void) {
    int64_t v = __sync_add_and_fetch(&gSeq, 1);
    return [NSString stringWithFormat:@"%lld", (long long)v];
}

static NSString *KLClip(NSString *s, NSUInteger n) {
    if (s.length <= n) {
        return s;
    }
    return [[s substringToIndex:n] stringByAppendingString:@"…"];
}

static NSString *KLHeaderDigest(NSURLRequest *req) {
    NSDictionary<NSString *, NSString *> *h = req.allHTTPHeaderFields;
    if (h.count == 0) {
        return @"";
    }
    NSArray<NSString *> *keys = @[@"Content-Type", @"Content-Length", @"User-Agent", @"Accept", @"X-Request-Id"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *k in keys) {
        NSString *v = h[k];
        if (v.length) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, KLClip(v, 80)]];
        }
    }
    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    for (NSString *k in h) {
        if (![keys containsObject:k] && rest.count < 4) {
            [rest addObject:[NSString stringWithFormat:@"%@=%@", k, KLClip(h[k], 60)]];
        }
    }
    [parts addObjectsFromArray:rest];
    return [parts componentsJoinedByString:@", "];
}

// gzip/zlib 解压。iOS 上很多 SDK 的 body 和响应都是 gzip，
// 直接拿字节当 UTF-8 解会得到空串或乱码，所以先解压再看。
static NSData *KLInflate(NSData *in, NSUInteger maxOut) {
    if (in.length < 2) {
        return nil;
    }
    const uint8_t *p = in.bytes;
    if (!(p[0] == 0x1f && p[1] == 0x8b)) {
        return nil;
    }
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 15 + 32) != Z_OK) {
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:4096];
    uint8_t buf[4096];
    zs.next_in = (Bytef *)p;
    zs.avail_in = (uInt)in.length;
    int rc = Z_OK;
    while (rc != Z_STREAM_END) {
        zs.next_out = buf;
        zs.avail_out = (uInt)sizeof(buf);
        rc = inflate(&zs, Z_NO_FLUSH);
        if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
            break;
        }
        NSUInteger got = sizeof(buf) - zs.avail_out;
        if (got > 0) {
            [out appendBytes:buf length:got];
        }
        if (out.length >= maxOut || (got == 0 && rc == Z_BUF_ERROR)) {
            break;
        }
    }
    inflateEnd(&zs);
    return out.length ? out : nil;
}

static NSString *KLPreview(NSData *data, NSString *mime) {
    if (data.length == 0) {
        return @"";
    }
    BOOL wasGzip = NO;
    NSData *raw = data;
    NSData *inflated = KLInflate(data, 16384);
    if (inflated.length) {
        raw = inflated;
        wasGzip = YES;
    }
    NSString *m = mime.lowercaseString ?: @"";
    BOOL textual = ([m containsString:@"json"] || [m containsString:@"text"] ||
                    [m containsString:@"xml"] || [m containsString:@"javascript"] ||
                    [m containsString:@"x-www-form-urlencoded"]);
    if (textual) {
        NSUInteger n = MIN(raw.length, (NSUInteger)600);
        NSData *sub = [raw subdataWithRange:NSMakeRange(0, n)];
        NSString *s = [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding];
        if (s == nil) {
            s = [[NSString alloc] initWithData:sub encoding:NSISOLatin1StringEncoding];
        }
        if (s.length) {
            s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
            if (wasGzip) {
                s = [@"[gunzip] " stringByAppendingString:s];
            }
            return KLClip(s, 500);
        }
        return wasGzip ? @"[gunzip] <解压后非 UTF-8>" : @"";
    }
    NSUInteger n = MIN(raw.length, (NSUInteger)16);
    NSData *sub = [raw subdataWithRange:NSMakeRange(0, n)];
    return [NSString stringWithFormat:@"<%@ %luB%s hex=%@>",
            m.length ? m : @"bin",
            (unsigned long)data.length,
            wasGzip ? " gzip→解压" : "",
            sub];
}

static NSString *KLTagForRequest(NSURLRequest *req, NSString *prefix) {
    NSString *tag = KLNextTag();
    NSString *method = req.HTTPMethod.length ? req.HTTPMethod : @"GET";
    NSString *url = KLClip(req.URL.absoluteString ?: @"", 320);
    NSUInteger bodyLen = req.HTTPBody.length;
    NSString *digest = KLHeaderDigest(req);

    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ #%@ %@ %@",
                             prefix, tag, method, url];
    if (bodyLen > 0) {
        [line appendFormat:@" body=%luB", (unsigned long)bodyLen];
    } else if (req.HTTPBodyStream != nil) {
        [line appendString:@" body=stream"];
    }
    if (digest.length) {
        [line appendFormat:@" | %@", digest];
    }
    KLLogC(@"NET", @"%@", line);

    if (bodyLen > 0 && bodyLen <= 4096) {
        NSString *ct = req.allHTTPHeaderFields[@"Content-Type"] ?: @"";
        NSString *pv = KLPreview(req.HTTPBody, ct);
        if (pv.length) {
            KLLogC(@"NET", @"   └ body: %@", pv);
        }
    }
    return tag;
}

static void KLLogResponse(NSString *tag, NSURLResponse *resp, NSData *data, NSError *err) {
    if (err) {
        KLLogC(@"NET", @"↓ #%@ ERR %ld %@ | %@", tag,
               (long)err.code,
               err.domain ?: @"",
               KLClip(err.localizedDescription ?: @"", 200));
        return;
    }
    if (![resp isKindOfClass:[NSHTTPURLResponse class]]) {
        KLLogC(@"NET", @"↓ #%@ %luB <%@>", tag,
               (unsigned long)data.length,
               resp.MIMEType ?: @"?");
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
    KLLogC(@"NET", @"↓ #%@ %ld %@ %luB", tag,
           (long)http.statusCode,
           http.MIMEType ?: @"?",
           (unsigned long)data.length);
    NSString *pv = KLPreview(data, http.MIMEType);
    if (pv.length) {
        KLLogC(@"NET", @"   └ resp: %@", pv);
    }
}

static NSURLSessionDataTask *KLNewDTPReq(id self, SEL _cmd, NSURLRequest *req,
                                        void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    NSString *tag = KLTagForRequest(req, @"↑");
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        KLLogResponse(tag, r, d, e);
        if (cb) {
            cb(d, r, e);
        }
    };
    KLDTP_Req next = (KLDTP_Req)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req, wrapped) : nil;
}

static NSURLSessionDataTask *KLNewDTPURL(id self, SEL _cmd, NSURL *url,
                                        void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    NSString *tag = KLTagForRequest([NSURLRequest requestWithURL:url], @"↑");
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        KLLogResponse(tag, r, d, e);
        if (cb) {
            cb(d, r, e);
        }
    };
    KLDTP_URL next = (KLDTP_URL)KLOrig(self, _cmd);
    return next ? next(self, _cmd, url, wrapped) : nil;
}

static NSURLSessionUploadTask *KLNewUPPData(id self, SEL _cmd, NSURLRequest *req, NSData *body,
                                           void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    NSMutableURLRequest *mreq = [req mutableCopy];
    if (body.length && mreq != nil && mreq.HTTPBody == nil) {
        mreq.HTTPBody = body;
    }
    NSString *tag = KLTagForRequest(mreq ?: req, @"↑↑");
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        KLLogResponse(tag, r, d, e);
        if (cb) {
            cb(d, r, e);
        }
    };
    KLUPP_Data next = (KLUPP_Data)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req, body, wrapped) : nil;
}

static NSURLSessionUploadTask *KLNewUPPFile(id self, SEL _cmd, NSURLRequest *req, NSURL *file,
                                           void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    NSString *tag = KLNextTag();
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:(file.path ?: @"") error:NULL];
    unsigned long long size = [(NSNumber *)attr[NSFileSize] unsignedLongLongValue];
    KLLogC(@"NET", @"↑↑ #%@ %@ %@ file=%@ (%lluB)",
           tag,
           req.HTTPMethod ?: @"POST",
           KLClip(req.URL.absoluteString ?: @"", 300),
           file.lastPathComponent ?: @"?",
           size);
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        KLLogResponse(tag, r, d, e);
        if (cb) {
            cb(d, r, e);
        }
    };
    KLUPP_File next = (KLUPP_File)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req, file, wrapped) : nil;
}

static NSURLSessionDownloadTask *KLNewDNPReq(id self, SEL _cmd, NSURLRequest *req,
                                            void (^cb)(NSURL *, NSURLResponse *, NSError *)) {
    NSString *tag = KLNextTag();
    KLLogC(@"NET", @"↓ #%@ GET %@ (download)", tag, KLClip(req.URL.absoluteString ?: @"", 300));
    void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *u, NSURLResponse *r, NSError *e) {
        KLLogResponse(tag, r, nil, e);
        if (u) {
            KLLogC(@"NET", @"   └ saved: %@", u.lastPathComponent ?: @"?");
        }
        if (cb) {
            cb(u, r, e);
        }
    };
    KLDNP_Req next = (KLDNP_Req)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req, wrapped) : nil;
}

static NSURLSessionDownloadTask *KLNewDNPURL(id self, SEL _cmd, NSURL *url,
                                            void (^cb)(NSURL *, NSURLResponse *, NSError *)) {
    NSString *tag = KLNextTag();
    KLLogC(@"NET", @"↓ #%@ GET %@ (download)", tag, KLClip(url.absoluteString ?: @"", 300));
    void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *u, NSURLResponse *r, NSError *e) {
        KLLogResponse(tag, r, nil, e);
        if (u) {
            KLLogC(@"NET", @"   └ saved: %@", u.lastPathComponent ?: @"?");
        }
        if (cb) {
            cb(u, r, e);
        }
    };
    KLDNP_URL next = (KLDNP_URL)KLOrig(self, _cmd);
    return next ? next(self, _cmd, url, wrapped) : nil;
}

static NSURLSessionDataTask *KLNewDTPReqPlain(id self, SEL _cmd, NSURLRequest *req) {
    KLTagForRequest(req, @"↑");
    KLDTP_ReqPlain next = (KLDTP_ReqPlain)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req) : nil;
}

static NSURLSessionUploadTask *KLNewUPPDataPlain(id self, SEL _cmd, NSURLRequest *req, NSData *body) {
    NSMutableURLRequest *mreq = [req mutableCopy];
    if (body.length && mreq != nil && mreq.HTTPBody == nil) {
        mreq.HTTPBody = body;
    }
    KLTagForRequest(mreq ?: req, @"↑↑");
    KLUPP_DataPlain next = (KLUPP_DataPlain)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req, body) : nil;
}

static NSURLSessionUploadTask *KLNewUPPFilePlain(id self, SEL _cmd, NSURLRequest *req, NSURL *file) {
    KLLogC(@"NET", @"↑↑ %@ %@ file=%@",
           req.HTTPMethod ?: @"POST",
           KLClip(req.URL.absoluteString ?: @"", 300),
           file.lastPathComponent ?: @"?");
    KLUPP_FilePlain next = (KLUPP_FilePlain)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req, file) : nil;
}

static NSURLSessionDownloadTask *KLNewDNPReqPlain(id self, SEL _cmd, NSURLRequest *req) {
    KLLogC(@"NET", @"↓ GET %@ (download)", KLClip(req.URL.absoluteString ?: @"", 300));
    KLDNP_ReqPlain next = (KLDNP_ReqPlain)KLOrig(self, _cmd);
    return next ? next(self, _cmd, req) : nil;
}

static void KLInstallOnClass(Class cls) {
    if (cls == Nil) {
        return;
    }
    KLSwizzle(cls, @selector(dataTaskWithRequest:completionHandler:), (IMP)KLNewDTPReq);
    KLSwizzle(cls, @selector(dataTaskWithURL:completionHandler:), (IMP)KLNewDTPURL);
    KLSwizzle(cls, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)KLNewUPPData);
    KLSwizzle(cls, @selector(uploadTaskWithRequest:fromFile:completionHandler:), (IMP)KLNewUPPFile);
    KLSwizzle(cls, @selector(downloadTaskWithRequest:completionHandler:), (IMP)KLNewDNPReq);
    KLSwizzle(cls, @selector(downloadTaskWithURL:completionHandler:), (IMP)KLNewDNPURL);
    KLSwizzle(cls, @selector(dataTaskWithRequest:), (IMP)KLNewDTPReqPlain);
    KLSwizzle(cls, @selector(uploadTaskWithRequest:fromData:), (IMP)KLNewUPPDataPlain);
    KLSwizzle(cls, @selector(uploadTaskWithRequest:fromFile:), (IMP)KLNewUPPFilePlain);
    KLSwizzle(cls, @selector(downloadTaskWithRequest:), (IMP)KLNewDNPReqPlain);
}

void KLNetInstall(void) {
    if (gInstalled) {
        return;
    }
    gInstalled = YES;
    KLInstallOnClass([NSURLSession class]);

    NSArray<NSString *> *names = @[@"__NSCFURLSession", @"NSURLSession", @"_NSURLSession"];
    NSMutableArray<NSString *> *done = [NSMutableArray array];
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (c == Nil || c == [NSURLSession class]) {
            continue;
        }
        KLInstallOnClass(c);
        [done addObject:n];
    }
    if (done.count) {
        KLLogC(@"NET", @"网络钩子已安装（NSURLSession + %@）", [done componentsJoinedByString:@", "]);
    } else {
        KLLogC(@"NET", @"网络钩子已安装（NSURLSession）");
    }
}
