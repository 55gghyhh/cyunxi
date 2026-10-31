# 注入与使用手册

## 0. 前提

- 设备已用 TrollStore（或等价方式）装好 TrollFools。
- 原 `TG：ioskuka.dylib` 已经注入到 `XCamera.app/XCamera`（你现在就是这个状态）。
- 这两个 dylib 互不依赖，谁先谁后都能用。

## 1. 先出 dylib（GitHub Actions）

Windows 上没法编 Theos，所以走你平时那套 CI：

1. 新建仓库，把 `KAlertLog/` 里的东西全部推到根目录
   （`Makefile`、`control`、`*.m`、`KAlertLog.h`、`.github/workflows/build.yml`）。
2. 推上去后 Actions 自动跑 `Build KAlertLog`，约 2–4 分钟。
3. 打开该次 run → 底部 **Artifacts** → 下载 `KAlertLog.zip`，里面有：

```
KAlertLog-arm64e.dylib   ← 用这个（和原 tweak 同架构，你的注入链路已验证过）
KAlertLog-arm64.dylib    ← A11 及更老设备才用
KAlertLog-fat.dylib      ← 双架构原始产物，TrollFools 切架构时可能只回写一片，别用
KAlertLog_1.0.0_iphoneos-arm64.deb
SHA256SUMS.txt
```

4. 每个文件都有 sha256，在 `SHA256SUMS.txt` 里，装前先对一遍。

> 想本地编也行：macOS 上 `export THEOS=~/theos`、`make package FINALPACKAGE=1`，
> dylib 落在 `.theos/obj/`。工程零依赖，不用 CydiaSubstrate、不用 Logos。

## 2. 把 dylib 传到手机

TrollFools 只认自己沙盒里的文件，日志里能看到它实际读的路径：

```
/var/mobile/Library/Application Support/Containers/wiki.qaq.TrollFools/Documents/Inbox/<文件名>.dylib
```

两种传法，任选：

- **分享菜单**：文件 App 里长按 `KAlertLog-arm64e.dylib` → 共享 → 选 TrollFools。
- **文件 App 直接放**：文件 → 我的 iPhone → TrollFools → Inbox，把 dylib 拷进去。

文件名建议就保持 `KAlertLog.dylib`（纯 ASCII）。原 tweak 那个全角冒号 `：` 能跑，
但那是没必要的变量，别学它。

## 3. TrollFools 注入

1. TrollFools 主界面找到 **今日水印相机**（`com.xhey.123` 那个），点进去。
2. 它会扫 App 里的 Mach-O，弹列表。**手动选 `XCamera`**（主程序，169.2 MB 那个）。
   - 别用默认项：上次 Pro 版就是默认选中了 `Frameworks/KSAdSDK.framework/KSAdSDK`，
     检查器会显示 `Selected Mach-O: KSAdSDK`，那样注了等于没注。
   - 正确的日志行是 `Prefer main executable` + `Selected Mach-O: XCamera`。
3. 选 `KAlertLog-arm64e.dylib` → 注入。TrollFools 会自动：
   - `cp` 出 `XCamera.troll-fools.bak` 备份
   - 把 dylib 拷进 `XCamera.app/Frameworks/`
   - `insert_dylib @rpath/KAlertLog.dylib … --weak`
   - `ldid -S` + `ct_bypass` 重签主程序
   - 再存一份到 `PersistentPlugins/com.xhey.123/KAlertLog.dylib`
4. 做完列表里会同时有两个插件：`TG：ioskuka.dylib` 和 `KAlertLog.dylib`。这是对的，
   两条 `LC_LOAD_WEAK_DYLIB` 并存，互不覆盖。

## 4. 首次启动确认

杀掉进程重开 App，展开右下角那个「酷卡」浮动按钮 → 面板。

- 面板最底部应出现一行两个按钮：**`[运行日志]` `[导出日志]`**，
  卡片高度比原来多一行（原卡片底部到「频道/群聊/访问官网」那一排下面）。
- 按钮的底色/圆角/字号是从面板里的「相册替拍」抄的，应该和上面那排浑然一体。

要看内核是否起来了，用 Console.app 连设备，过滤 `KAlertLog`，或者直接点「运行日志」看头几行：

```
[CORE] 日志内核启动
[APP] ==== 今日水印相机 x.y.z(build) 启动 ====
[NET] 网络钩子已安装（NSURLSession + __NSCFURLSession）
[UI] 面板已注入「运行日志 / 导出日志」 card=UIView 320x420 → 高 466, ref=UIButton 148x34
```

## 5. 用

**运行日志**
全屏等宽字体列表，每秒自刷，新行自动跟到底。右上「完成」关掉；
左上「清空日志」二次确认后清空（内存和会话文件一起清，清完的第一行是 `[UI] 日志已清空`）。

每行格式 `HH:mm:ss.SSS [类别] 内容`，类别：

| 类别 | 内容 |
|---|---|
| `CORE` / `APP` / `LIFE` | 内核启动、App 名与版本、前后台切换、内存警告 |
| `NET` | `↑` 上传/请求、`↑↑` 带 body 或表单上传、`↓` 响应；带序号可配对 |
| `LOG` / `NSLog` | stderr 与 NSLog 原文，含原 tweak 自己打的 `[KAlert XC] …` |
| `UI` / `ERR` | 按钮点击、导出结果、找不到面板之类的错误 |

**导出日志**
点一下直接弹系统分享面板：隔空投送 / 存到「文件」/ 发微信都行。
文件是 UTF-8 txt，名字是 `App名称_开始时间_结束时间.txt`，例如：

```
今日水印相机_20261031-201503_20261031-205541.txt
```

文件内容头部带 4 行元信息（应用、版本、会话开始、记录结束、行数），下面才是时间线。

## 6. 卸载 / 回滚

- 只去掉这两个按钮：TrollFools → 今日水印相机 → 插件列表里删 `KAlertLog.dylib` → 它会重签主程序并把注入撤掉。
- 整个还原成原始二进制：把 `XCamera.app/XCamera.troll-fools.bak` 拷回 `XCamera.app/XCamera`
  （TrollFools 卸载全部插件时也会自动做这件事）。
- 日志文件都在 App 容器 `tmp/KAlertLog/` 下，卸载时随容器一起没，不会留垃圾。

## 7. 排查

| 现象 | 原因 / 处理 |
|---|---|
| 面板出现了，但底部没有两个按钮 | 锚点文案对不上。点「运行日志」看不到（也没按钮），改看 Console 里的 `[ERR] 启动 12 秒仍未找到 KAlert 面板`。把面板里任意三个行标题发我，改 `KLAnchorTexts()` 一行重编 |
| 按钮出现了但位置压住原内容 | 卡片高度加得不够，改 `KLInstallRow` 里 `+ btnH + 14.0` 的余量 |
| 完全没有面板、App 也没崩 | 注入打到了 Frameworks 里的 SDK。回 TrollFools 里选 `XCamera` 重注 |
| App 一启动就闪退 | 先把 `KAlertLog.dylib` 从 TrollFools 里删掉、确认能正常启动，再单独注它复现；闪退日志（`.ips`）直接发我 |
| `[NET]` 里没有你要的请求 | 走 QUIC（Tquic SDK）或 WebSocket 的不经过 NSURLSession，抓不到。自定义 socket 同理 |
| 日志里出现大量乱码行 | 有些三方 SDK 往 stderr 打二进制。已知现象，不影响其它行 |

## 9. CI 报错对照（实测踩过的）

| 日志里的行 | 真正原因 | 处理 |
|---|---|---|
| `/bin/bash: ldid: command not found` → `Error 127` | Theos 在 macOS 上**不自带 ldid**，签名阶段按 PATH 找 | `brew install ldid xz`，并在跑 make 前把 ldid 软链到 `$THEOS/bin/ldid`。新 workflow 里 `Install toolchain deps` 这一步做的就是这件事，brew 失败还会回落到 Procursus 预编译包 |
| `make: *** [xxx.all.tweak.variables] Error 2` | 只是上面那条的连带结果，别去查 variables | 修 ldid 即可 |
| `multiply_defined is obsolete` 警告 | 正常现象，链 tweak 都会出 | 忽略 |
| `ld: framework not found XXX` | `_FRAMEWORKS` 里写了系统没有的框架 | 删掉那项 |
| `KAlertLog_CFLAGS` 不生效 / `cannot create __weak reference` | `TWEAK_NAME` 被改名了，但 `_FILES`/`_CFLAGS` 前缀没跟着改 | 三个前缀必须与 `TWEAK_NAME` 完全一致 |
| Actions 显示成功但 artifact 是空的 | `find -name xxx.dylib` 没命中，`cp` 静默跳过 | 新 workflow 改成从 `.theos` 递归找并 `if-no-files-found: error` |

`make -j4 FINALPACKAGE=1 DEBUG=0` 对 tweak target 只会产出 dylib，**不需要 dpkg**；
要 `.deb` 才需要 `make package`，TrollFools 用不上。

## 10. 在 Pro 版（XCameraPro）上的额外说明

Pro 版和普通版是两个独立的包，`KAlertLog` 两边都能加载，但**按钮是挂在 ioskuka 面板上的，
没有面板就没有卡片可挂**：

| | 普通版 `com.xhey.123` | Pro 版 `com.xhey.XCameraPro` |
|---|---|---|
| bundle id | com.xhey.123（container）| com.xhey.XCameraPro |
| app group | `group.TodayCamera` | **没有**（entitlements 里整段缺失）|
| 主程序 | XCamera (169.2 MB) | XCameraPro (132.1 MB) |
| Frameworks 里的 Mach-O | 19 个 | 3 个（XCameraPro / KSAdSDK / XHSpectrum） |

所以在 Pro 上要做到「面板里多一行按钮」，必须：

1. `TG：ioskuka.dylib` 注到 **XCameraPro 主程序**（13:28 那次只注了 KAlertLog；
   11:55 那次把 ioskuka 注到了 `Frameworks/KSAdSDK.framework/KSAdSDK`，那是错的）；
2. 再注 `KAlertLog.dylib` 到同一个主程序。

`KAlertLog` 自带兜底：启动约 6 秒（12 次 × 0.5 秒轮询）还找不到面板，就在窗口上放一个
**圆形「日志」悬浮球**（可拖动，位置记在 NSUserDefaults），点它进日志面板。
面板里的「分享」按钮同样能导出，所以就算 ioskuka 面板不存在，日志与导出也照用。

### 怎么确认 dylib 到底加载了没有

构造期会打一条 NSLog，Console.app 过滤 `KAlertLog`：

```
[KAlertLog] loaded into 今日水印相机Pro 5.x.x(bundle=com.xhey.XCameraPro)
```

- 有这行 → dylib 被 dyld 加载成功（`@rpath` 解析通过、签名通过）。
- 没有这行、App 也不崩 → `@rpath/KAlertLog.dylib` 没解析到，即主程序缺
  `LC_RPATH = @executable_path/Frameworks`。这是弱加载，静默跳过。
- 没有这行、App 闪退 → 看 `.ips` 的 `termination reason`，通常是签名/架构不符。

## 11. 无 UI 也能拿到日志与导出

KAlertLog 全程不需要点任何按钮：

| 文件 | 何时产生 | 说明 |
|---|---|---|
| `tmp/KAlertLog/session.log` | 启动即写，逐行追加 | 实时日志（含 `[NET]`） |
| `tmp/KAlertLog/<App名>_<开始>_<结束>.txt` | **每次退到后台自动落一份** | 带 4 行元信息的完整导出，格式同「导出日志」按钮 |

用 Filza 进 App 容器 `tmp/KAlertLog/` 直接取。判断「这次启动有没有真正加载」看 `session.log` **末尾时间戳**是不是刚才——老文件会一直留着，只看文件存在会被骗。

## 12. gzip 请求体的处理

很多 SDK（bugly、字节系、腾讯广告）的请求体和响应体是 gzip。以前会打成空行，现在会先 inflate 再预览，行首标 `[gunzip]`：

```
[NET] ↑ #2 POST https://pro.bugly.qq.com/appconfig/v7/config/xxx/ body=229B | Content-Type=application/x-www-form-urlencoded, Content-Encoding=gzip
[NET]    └ body: [gunzip] app_id=...&app_key=...&
```

依赖 `libz`，Makefile 里已加 `KAlertLog_LDFLAGS = -lz`。
