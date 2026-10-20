# LazyTap · 懒触 1.3.2

TrollStore 环境用的 **注入式悬浮连点器**（无越狱）。核心解决的就一件事：
**设置好点位之后，用开关直接起停，不用"取消 → 重设 → 重启"。**

## 1.3.2：纯 TrollStore 环境的配置共享探测

纯 TrollStore 只能 TrollFools 注入 App，而每个 App 有独立沙盒 —— 逻辑上会变成
「注一个 App 就要标一次点位」。1.3.2 先试着绕开这个：

- 启动时**真写一个探测文件**去试 `/var/mobile/Library/Preferences` 和 `/var/mobile/Library/LazyTap`
  （不能用 `isWritableFileAtPath`，沙盒会把它骗成 YES，真写的时候才拒）。
  写得进去 → 所有注入过的 App 共用同一份 `LazyTap.json`，标一次就够。
- 写不进去 → 退回各自沙盒 Documents，各 App 一套（这时只能各标一次）。
- 兼容升级：共享位置还没有配置、沙盒里留着 1.2.x 老配置时，自动搬过去。

日志里搜 `[LazyTap] 配置走` 就知道自己落在哪一档。

## 1.3.1：会不会白苹果？不会，但要把「桌面崩溃循环」防住

先说结论：**这个 dylib 不可能造成白苹果。**

白苹果（卡在苹果 logo 起不来）的成因只有一类：**系统分区或启动链被改坏** ——
改 `/System` 下的二进制、改 `LaunchDaemons`、装内核扩展、OTA 升级装一半断电。
这个工程全部代码都在一个 dylib 里，只活在 SpringBoard 进程的内存中，
不写系统分区、不碰 launchd、不碰内核，进程一退全部消失。

但「不会白苹果」不等于「没风险」，要分清三种后果：

| 发生什么 | 你会看到 | 严重度 |
|---|---|---|
| dylib 运行时崩一次 | 黑屏转圈 3~10 秒，回锁屏（respring） | 可忽略 |
| dylib 在启动期崩，反复崩 | 屏幕一直黑/转圈，进不去桌面（崩溃循环） | 要动手恢复 |
| hitTest 判断错，吞掉触摸 | 桌面点不动（软砖），其他功能正常 | 强制重启 |
| 私有 IOHID 参数严重错乱 | 理论上可能内核 panic 重启 | 极罕见 |

**唯一的真麻烦是第二行：崩溃循环。** 因为 launchd 会不停把 SpringBoard 拉起来，
用户会以为系统坏了。1.3.1 专门为它做了闸门。

### 1.3.1 做的四道保险

1. **启动闸门**（`src/LTSafety.m`）——
   每次 dylib 加载先把计数 +1 并落盘；悬浮条装好且**存活满 6 秒**才清零。
   计数超过 3 判定「上次是启动期崩溃」，**本次只写日志，什么都不装**。
   崩溃循环到这里就断了，桌面一定能起来。
2. **入口全包 `@try`** —— constructor 里抛异常会直接把进程带走，现在兜住并安静退出。
3. **tick 异常自停** —— 引擎 tick 抛异常时停掉自己，不是把 SpringBoard 一起带走。
4. **干掉了一处真死锁** —— `lt_screen_points()` 原来在后台线程会
   `dispatch_sync` 回主队列，而主线程可能正 `dispatch_sync` 到引擎队列，
   两个队列互等 → 桌面整个卡死 → 30 秒后 watchdog 杀进程。
   现在后台线程只读缓存，永不 sync 回主队列。

### 进了安全模式怎么恢复

安全模式的表现就是：**装上之后桌面什么也没出现，但系统一切正常**。

```bash
# 删掉计数文件（Filza / SSH 都行），下次注入就恢复正常
rm -f /var/mobile/Library/Preferences/LazyTap.boot
killall -9 SpringBoard
```

### 彻底卸载（三条路，按你的环境选一条）

| 环境 | 怎么卸 |
|---|---|
| 越狱 + Sileo / Zebra | 包列表里卸载 `com.xt.lazytap`，自动 respring |
| TrollStore + TrollFools | 打开 TrollFools → SpringBoard → 移除 `LazyTap` 注入 |
| 什么都进不去 | Filza / SSH 删 `/Library/MobileSubstrate/DynamicLibraries/LazyTap.dylib` 和同名 `.plist`，然后 `killall -9 SpringBoard` |

只要还能进安全模式（Filza/SSH 可用），就一定救得回来，不存在「只能刷机」。

## 1.3.0：注入桌面，一次装好，所有 App 通用

1.2.0 是注入到**某个 App** 里的，只能在那个 App 内点。想全局用就得给每个 App 注入一遍，不现实。
1.3.0 改成注入 **SpringBoard（桌面进程）**：竖条浮在所有 App 之上，点击走内核 HID 直接打进系统。

| 项 | 注入普通 App（1.2.0） | 注入 SpringBoard（1.3.0） |
|---|---|---|
| 生效范围 | 只有被注入的那个 App | **所有 App**，切过去竖条还在 |
| 悬浮条 | 挂在宿主 App 窗口上，App 一退就没 | 窗口层级 `10000000`，压过 App / 状态栏 / 键盘 / 控制中心 |
| 触摸通道 | 进程内合成 `UITouch`（不需权限） | 内核 HID（SpringBoard 自带权限） |
| 标点 | 只能在宿主 App 里标 | **在游戏里直接点 ＋ 就能加、拖着点位走** |
| 配置 | 每个 App 一套 `Documents/LazyTap.json` | 全局一套 `/var/mobile/Library/Preferences/LazyTap.json` |

必须这么做的几个技术点（都是踩过的）：

- SpringBoard 不用 `UIApplication` 管自己的窗口，`app.windows` 常年是空的。
  老代码「等宿主窗口就绪」在这里会死等 —— 全局模式直接跳过并自建窗口。
- iOS 13 起没挂 `UIWindowScene` 的窗口不显示。建窗时先取 SpringBoard 自己的 scene
  （`_SBWindowScene`，按 `UIWindowScene` 基类取），取不到才退回 `initWithFrame:`。
- **全屏窗口压在所有 App 之上，一旦它认领了触摸，前台 App 就收不到了。**
  所以 `hitTest` 只在竖条 / 小球 / 面板真正所在的位置返回视图，其余一律返回 `nil`；
  **运行中连点位标记也返回 `nil`**（它只负责显示），否则 HID 打在自己的点位上会被这层窗吞掉，
  表现就是「计数在涨、游戏没反应」。
- 全局模式窗口锁竖屏。HID 的 digitizer 坐标以竖屏为基准，窗口跟着设备转的话，
  标点位置和实际落点会错开 90°。
- 全局模式不看面板里的通道设置，一律走 HID —— 进程内合成在 SpringBoard 里只能点到自己。
- 开跑时自动把竖条折成小球、并收掉参数面板，免得挡住游戏。

## 1.2.0 改动

| 项 | 改动 |
|---|---|
| **＋ / － 竖排** | 两个键从并排改成上下各一行、水平居中，误按概率明显下降 |
| **拖动不再触发开关** | 拖动竖条或光球时，手指起落即使都落在电源键上也不会切换。两道保险：pan 一识别就 `cancelsTouchesInView`，同时拖动期间 `dragLocked` 屏蔽所有按钮，抬手后 0.15s 才解除 |
| **点＋直接中心加点** | 不再进入「点屏幕选位置」的拾取模式和提示条，点一下 ＋ 屏幕正中就出现一个点位；中心已被占则按 8 方向往外错开一格 |
| **拖点位不再误切开关** | 点位上的点击/长按手势都加了「等拖动失败」，拖着点位走不会顺手把它关掉或删掉 |

## 1.1.0 修的头号问题：点了没反应

1.0.1 只走 IOHID 一条通道。而 `IOHIDEventSystemClientDispatchEvent` 是内核 HID 通道，
内核校验的是**宿主进程主二进制**的 `com.apple.private.hid.client.event-dispatch`。
TrollStore / ESign 往 App Store 应用里注入 dylib 时，宿主二进制没有这条权限，
dylib 自己签名里的 entitlements 不生效 —— 派发被静默丢弃。

表现就是：**圆环在、计数在涨、屏幕毫无反应**。

1.1.0 改成三条通道，默认走不依赖权限的那条：

| 通道 | 实现 | 需要权限 |
|---|---|---|
| **进程内（默认）** | 宿主窗口 `hitTest` 找到落点视图后直接派发 | 不需要 |
| **WebView**（自动判断） | 命中 WKWebView 时用 `evaluateJavaScript` 在元素上派发 mouse/click | 不需要 |
| **HID** | IOHID 事件派发（1.0.1 那条路） | 宿主需要 HID entitlement |

具体分流：

- 落点祖先里有 `WKWebView` → 走 JS（`elementFromPoint` → `mousedown`/`mouseup`/`click`）。
  WKWebView 的触摸由内部手势识别器驱动，程序化 UITouch 喂不进去，所以这里**只走 JS**，
  避免和原生触摸叠加成双触发。
- 落点祖先里有 `UIControl`（按钮/分段控件）→ `sendActionsForControlEvents:`
- 其余视图 → 构造 `UITouch` 子类，调 `touchesBegan:` / `touchesEnded:`

面板里可以手动切「自动 / 进程内 / HID」，切完立刻生效。

## 1.1.0 其余改动

| 项 | 改动 |
|---|---|
| **减号键** | 竖条新增 `－`：点一下删掉最后一个点位，没点位时自动变灰 |
| **光球开关** | 折叠成圆钮后**整颗球单击就是起停**，长按 0.45s 展开。拖动时 pan 手势先接管，不会误触发开关 |
| **性能** | 引擎从 `NSTimer` 换成 `dispatch_source`（6ms 节拍）跑在专用串行队列，只有到点才回主线程派发 |
| | 每个点位的下次触发时间存 C 数组，不再每 tick 装箱 `NSNumber` |
| | 落后时不补点（卡顿恢复后不会瞬间连击，WebView 尤其明显） |
| | 计数标签只在数值变化时写 `text` |
| | 脉冲动画复用 `CAShapeLayer`，不再每次点击 alloc 新图层 |
| | 拖动点位/竖条时合并成 0.8s 一次写盘，松手才落盘 |
| | 配置改成临时文件 + rename 的原子写 |

## 它长什么样

右侧一条竖向玻璃条（可拖动、可折叠成一颗圆钮）：

```
  ┌──────┐
  │  ⏻   │  ← 电源：绿=运行中，灰=停止。点一下就切
  │  ＋  │  ← 加点：屏幕正中直接生成一个点位
  │  －  │  ← 删点：删掉最后一个点位
  │  ⚙   │  ← 参数：间隔 / 点按·长按·滑动 / 通道 / Y轴翻转
  │ 1.2k │  ← 实时点击计数
  │  ›   │  ← 折叠
  └──────┘
```

- **点位标记**：蓝色圆环 + 编号。拖 = 移动，点 = 单独启用/停用，长按 = 删除。
  新增的点落在屏幕正中，直接用手指拖到你要点的位置即可。
- **多点**：想加几个加几个，每个点独立开关，共享或独立间隔都行。
- **开关就是那个电源键**：运行 → 停 → 再运行，点位一直在，不用重新设。
- **折叠后**：单击圆钮起停、长按展开，不挡视线也不误触。

`preview.html` 是可交互预览，点开就能试所有交互。

## 三种点击模式

| 模式 | 行为 | 典型用途 |
|---|---|---|
| 点按 | 按下 20ms 抬起 | 领奖、确认、签到 |
| 长按 | 按住 0.1–2 秒再抬 | 需要长按识别的按钮 |
| 滑动 | 从点位向上滑 `swipeDistance` | 翻页、刷视频 |

坐标空间默认是**屏幕点**。若真机上发现点击整体偏移（比如落在 1/3 处），
说明该机型要像素坐标：改 `Documents/LazyTap.json` 里的 `coordScale` 为 `3`。

## 怎么装（按环境选，别硬试）

### A. 纯 TrollStore（不越狱）—— 只能注入 App，注入不了桌面

**先把话说清楚**：SpringBoard.app 位于 **SSV 只读系统卷**，纯 TrollStore 没有任何手段写进去
（写 SSV 要么越狱，要么依赖特定版本的内核漏洞）。所以「装一次、所有 App 生效」在纯 TrollStore 下
**不存在**——不是我偷懒，是文件系统层面就堵死了。

能做到的是：**用 TrollFools 批量注入你要用的 App**，注过的 App 里都有悬浮条。

1. 把 `LazyTap.dylib` 存到「文件」App（AirDrop / 微信传过来都行）
2. 打开 **TrollFools**（在 TrollStore 里搜装）
3. 点右上角 `＋` → **多选**要连点的 App（游戏、抖音…一次可以选多个）
4. 注入项选 `LazyTap.dylib` → 确认，它会自动重签重装
5. 打开其中任意一个 App，右侧出现竖条 → 长按展开、点 ＋ 加点、点电源开跑

**这一档的局限（物理限制）**

| 项 | 情况 |
|---|---|
| 没注入过的 App | 用不了 |
| 配置共享 | 看 TrollFools 有没有给 App 留 `no-sandbox`。1.3.2 启动时会探测，日志里是「配置走共享位置」就全 App 共用一套点位；是「配置走沙盒」就每个 App 各自一套，得各标一次 |
| App 更新 | 注入会丢，得重新注一次 |
| 触摸通道 | 走**进程内合成**（不需要权限，1.2.0 真机验证过），点的是当前 App 自己 |

### B. 越狱（有 Sileo / Zebra）—— 一次装好，全局生效

把 `com.xt.lazytap_1.3.2_iphoneos-arm64.deb` 用 Sileo / Zebra 打开安装，自动 respring。
dylib 装到 `Library/MobileSubstrate/DynamicLibraries/`，配套 plist 的 Filter 只匹配
`com.apple.springboard`，只进桌面进程。

### C. TrollFools 里能选到 SpringBoard 的话

个别 iOS 15.x（有 MDC / Fugu 一类漏洞）在纯 TrollStore 下**有可能**写到系统卷。
TrollFools → 打开「显示系统应用」→ 看 **SpringBoard** 能不能选、注入后是否提示成功。
成功就按 B 的用法走（全局生效）；报错/闪退就说明你的系统盘是只读的，老老实实用 A。

### 装好之后（B / C 生效时的样子）

1. 桌面右侧出现一颗绿色小球（默认折叠）
2. **长按小球展开** → ＋ 加点（点在屏幕正中，可拖）、－ 减点、齿轮调间隔/模式
3. 点竖向的电源键（或折叠后单击小球）开始 → 自动折成小球
4. 直接打开游戏 / 微信 / 任何 App —— 小球还在，点位继续按间隔点
5. 想停：点小球（折叠态单击即停）

点位位置、间隔、模式都存全局，重启桌面不会丢。

## 怎么出包（没有 Mac）

仓库 `github.com/54894334/lazytap` 的 Actions 会自动构建。
本地改完代码跑 `node gh_deploy.js`，一条命令完成推送 + 等构建 + 下载产物。

```
Actions → Artifacts → LazyTap-dylib
或 dist 分支里的 LazyTap.dylib / LazyTap.dylib.b64
```

## 已验证 / 未验证

- 已验证编译：GitHub Actions macos-14 + Theos，产物为 fat 双架构
  arm64 + arm64e，两个 slice 均 `MH_DYLIB`，`LC_CODE_SIGNATURE` 含 entitlements，
  依赖含 WebKit，符号 `LTUITouchAtWindowPoint` / `LTTapSetChannel` / `LTSyntheticTouch` 均在位。
- 未验证：真机实际点击效果（需要你在设备上注入后试）。
- 已知限制：全局模式依赖内核 HID 通道，需要 SpringBoard 自带权限（TrollStore 环境天然满足）；
  普通自签 / AltStore 环境装不了这类注入。
- 横屏游戏：窗口锁竖屏保证落点准确，但竖条本身不会跟着转（视觉上侧着，位置是对的）。
