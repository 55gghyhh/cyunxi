# KAlertLog — 给「酷卡 / ioskuka」面板加两个按钮

## 这是什么

给 `TG：ioskuka.dylib`（XCamera 5.1.0 arm64e）那张浮层面板底部补一行两个按钮：

- **运行日志**：弹出本次 App 启动以来的运行日志（含网络上传/下发），面板里自带「清空日志」。
- **导出日志**：把当前日志写成 txt，经系统分享面板发到其它 App / 隔空投送。
  文件名 = `App名称_开始时间_结束时间.txt`（例：`今日水印相机_20261031-201503_20261031-205541.txt`）。

实现方式是**独立的一个 dylib**，不碰原 tweak。原因：原 tweak 只有二进制没有源码，
硬改它得重排整个 0xf408 面板构建函数的布局运算，风险高；独立 dylib 只需要在运行时
认领那张卡片并在底部追加一行，回滚成本也低（TrollFools 里卸载这一个就行）。

## 目录

```
KAlertLog/
├── Makefile
├── control
├── KAlertLog.h          公共声明
├── Tweak.m              %ctor：装日志内核 / 网络钩子 / 面板轮询
├── KLStore.m            日志内核（内存环 + 会话文件 + 导出命名 + stderr/NSLog 抓取）
├── KLNetLog.m           NSURLSession 上传/下发记录
├── KLViewer.m           日志查看器（含清空）+ 分享
└── KLPanel.m            找到 KAlert 面板卡片并注入两个按钮
.github/workflows/build.yml
```

## 编译

CI（推荐，跟你的既有流程一致）：

```
推仓库 → Actions「Build KAlertLog」→ 下载 artifact → 取 KAlertLog.dylib
```

本地 macOS + Theos：`make package FINALPACKAGE=1`，dylib 在 `.theos/obj/` 下。

> 依赖为零：不用 CydiaSubstrate，也不用 Logos，所有 hook 走
> `class_getInstanceMethod` + `method_setImplementation`，所以 TrollFools 不需要改写
> 任何 `libsubstrate` 路径。

## 注入

1. TrollFools → XCamera → 选择主程序 `XCamera.app/XCamera`（**不要**选 Frameworks 里的 SDK）。
2. 先注入 `TG：ioskuka.dylib`，再注入 `KAlertLog.dylib`（顺序其实无所谓，面板识别是轮询的）。
3. 启动 App，展开面板，底部应出现 `[运行日志] [导出日志]`。

## 自检（Console 过滤 `KAlertLog` 或看日志面板首行）

启动后日志里应依次出现：

```
[CORE] 日志内核启动
[APP] ==== <App 名> <版本> 启动 ====
[NET] 网络钩子已安装（NSURLSession 上传/下发记录）
[UI] 面板已注入「运行日志 / 导出日志」 card=UIView WxH → 高 H', ref=UIButton ...
```

若 12 秒后出现 `[ERR] 启动 12 秒仍未找到 KAlert 面板`，说明锚点文案对不上（换了发行版），
把面板里任意三个行标题发我，改 `KLAnchorTexts()` 即可。

## 抓什么

| 来源 | 说明 |
|---|---|
| `NSLog` / stderr | 通过 `_NSSetLogCStringFunction`（私有）+ `dup2(2)` 双路抓，含原 tweak 自己的 `[KAlert XC]` 输出 |
| `NSURLSession` | `dataTask/uploadTask/downloadTask` 的 `…WithRequest/WithURL`（带与不带 completionHandler 共 10 个入口）：方法、URL、请求头摘要、请求体大小与文本预览；completion 回来的状态码、MIME、字节数、响应体预览 |
| 生命周期 | 前台/后台/内存警告 |

每行格式：`HH:mm:ss.SSS [类别] 内容`，类别为 `CORE/APP/NET/LIFE/UI/LOG/NSLog/ERR`。

## 已知边界（不是 bug，是设计取舍）

- 只记录，不修改流量。NSURLProtocol 那种接管式拦截会跟 App 自带的广告协议打架，故意没做。
- 走 QUIC（Tquic SDK）、WebSocket、以及少数自建 socket 的请求不会出现在 `[NET]` 里。
- 响应体只预览前 500 字符、请求体只预览 ≤4KB 的文本，避免把相册上传的二进制灌进日志。
- `_NSSetLogCStringFunction` 是私有 API，将来失效会自动退回只靠 stderr 抓 NSLog。

## 面板按钮怎么定位的

原 dylib 的面板是 `0xf408` 这一个函数一次性搭出来的（`XCFloatTarget onFab` 只切 hidden），
标签文案是硬编码 UTF-16：`假定位/去广告/假时间/相册替拍/改天气` 等。
所以注入器不 hook 任何东西，只按「含 ≥3 个锚点 UILabel 的最深视图」认领卡片，
再向上找最近一个有背景色/圆角/模糊层的祖先当作真卡片，把卡片高度加一行、在底部插入两个按钮。
按钮的字体、圆角、底色、高度全部从现有的 `相册替拍` 按钮上抄，保证视觉一致。
