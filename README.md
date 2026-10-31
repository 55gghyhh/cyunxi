# KXUniversal —— 通用版（解除 App 限制）+ 运行日志

从 `TG：ioskuka.dylib` 逆向后重写：**不再绑定 `com.xhey.XCamera`**，装到任何 App 都能用；
并内置运行日志（查看 / 清空 / 导出 txt）。

## 为什么不能"把字符串改一改就通用"

原 dylib 的生效判定确实只是字符串比较：

```
0x74D98  com.xhey.XCamera
0x74DA9  xcamera / 0x74DB1 xhey
```

但**判定后面挂的钩子全是 XCamera 私有类**：

```
XCameraCommonBiz.XHLocationManager   0x74DBC
XHLocationManager                    0x74DDF
MSLocationManager                    0x74DF1
XHCameraKit / XHMultiCameraKit       0x74E1C
XCameraMixture.XHWatermarkView       0x75087
```

别的 App 里 `objc_getClass("XHCameraKit")` 返回 nil，钩子静默跳过 —— 判定解了也没功能。
所以通用化只能是**换实现**：把钩子改成系统 API。

## 能力对照

| 功能 | 原实现（仅 XCamera） | 本工程（通用） | 状态 |
|---|---|---|---|
| 定位伪造 | 钩 `XHLocationManager -latestLocation` | 钩 `CLLocationManager -location` + `startUpdatingLocation` 投递 delegate | ✅ |
| 广告拦截 | `XCAdProtocol`（NSURLProtocol） | 同思路，钩 `NSURLSessionConfiguration` 注入 protocol | ✅ |
| 相机换图 | 钩 `XHCameraKit -capturedImage` 改 CVPixelBuffer | 钩 `AVCaptureVideoDataOutput` 的 delegate，原地绘制 CVPixelBuffer | ⚠️ 需真机调 |
| 水印剥离 | `XHWatermarkView.setImage` | 未做（各 App 水印实现差异太大） | — |
| 相册换图 | `XCPhotoProxy` | 未做（需要接管 `UIImagePickerController` 回调，风险高） | — |
| 时间/天气伪造 | `NSDate` swizzle | 未做（会影响 App 自身逻辑，容易崩） | — |
| **运行日志** | 无 | **查看 / 清空 / 导出 txt** | ✅ |

## 配置（每个 App 独立）

配置走 `NSUserDefaults`，用 Filza 编辑目标 App 的
`Library/Preferences/<bundleid>.plist`：

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `KX.enable` | bool | YES | 总开关 |
| `KX.enableLoc` | bool | NO | 开启定位伪造 |
| `KX.lat` | real | — | 纬度，例如 `39.9087` |
| `KX.lng` | real | — | 经度，例如 `116.3975` |
| `KX.enableAdblock` | bool | NO | 开启广告拦截 |
| `KX.enablePhoto` | bool | NO | 开启相机换图 |
| `KX.photoPath` | string | — | 替换图绝对路径，如 `/var/mobile/DCIM/a.jpg` |
| `KX.logOnly` | bool | NO | 只记日志、不改行为（调试用） |

改完重启对应 App 生效。

## 运行日志

启动后右边缘出现 **LOG** 圆球 → 点击打开面板：

- **查看**：等宽字体滚动列表，标签分类（`LOC` / `ADBLOCK` / `PHOTO` / `HOOK` / `CLEAR` / `EXPORT`）
- **清空**：清空缓冲，只留一条 `[CLEAR]`
- **导出 TXT**：写到 App 的 `Documents/KXLog_yyyyMMdd_HHmmss.txt`，同时弹系统分享面板
- 常驻落盘：`Library/Caches/KXLog.txt`

UI 配色直接取自已逆向的 `KAlertSheet` 常量：

```
primaryFill       暗 white(0.95)          亮 white(0.11)
primaryFillText   暗 white(0.11)          亮 whiteColor
cardBackground    暗 rgb(0.11,0.11,0.13)  亮 whiteColor
titleColor        暗 rgb(0.83,0.69,0.47)  亮 rgb(0.72,0.53,0.28)
卡片圆角 20，按钮圆角 12，蒙层 black 0.45
```

## 编译（GitHub Actions，不需要 Mac）

```bash
cd kuka-universal
git init && git add . && git commit -m "KXUniversal"
git branch -M main
git remote add origin https://github.com/<你>/kuka-universal.git
git push -u origin main
```

仓库 → **Actions** → `build` → 跑完在 Artifacts 下载 `KXUniversal-dylib.zip`。

本地有 Mac 时：

```bash
./build.sh     # 产物 build/KXUniversal.dylib
```

不需要 Theos、不需要 codesign（TrollFools 会重新签名）。

## 注入

TrollFools → 选中目标 App → 注入 `KXUniversal.dylib`。想全局生效就对每个 App 注入一次；
越狱设备也可以用 `MobileSubstrate` 的 `Filters` 让它自动注入所有进程。

## 文件

```
kuka-universal/
├─ src/KXLog.h         日志接口
├─ src/KXLog.m         日志缓冲 + 面板 UI + 导出
├─ src/KXUniversal.m   通用钩子（定位 / 广告 / 相机）
├─ build.sh            本地编译
├─ .github/workflows/build.yml
└─ README.md
```

## 已知限制

- **相机换图需要真机调试**：不同 App 的取景/拍照路径不同（`AVCaptureVideoDataOutput` 还是
  `AVCapturePhotoOutput`）。当前实现覆盖前者（预览与多数扫码/视频类 App）；用 `AVCapturePhotoOutput`
  出静态照片的 App 需要另加一层 `capturePhotoWithSettings:delegate:` 的代理委派。
- 水印 / 相册换图 / 时间天气伪造没有移植：它们在原实现里强依赖 XCamera 的内部数据结构，
  通用化后每接一个 App 都要单独适配，收益远低于维护成本。
- 广告拦截是**域名黑名单 + 路径关键词**，对自建域名的广告无效；需要的话往 `KXAdHosts()` 里加。
