# LazyTap · 懒触 1.3.0

TrollStore 环境用的 **注入式悬浮连点器**（无越狱）。核心解决的就一件事：
**设置好点位之后，用开关直接起停，不用"取消 → 重设 → 重启"。**

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

## 怎么装

**必须注入到 SpringBoard（桌面）**，不是某个目标 App。

### 方式一：装 deb（最省事，推荐）

把 `com.xt.lazytap_1.3.0_iphoneos-arm64.deb` 用 **TrollStore** 打开安装。
dylib 安装到 `Library/MobileSubstrate/DynamicLibraries/`，配套 plist 的 Filter 只匹配
`com.apple.springboard`，所以只会进桌面进程，不会污染别的 App。装完自动 respring。

### 方式二：TrollFools 注入

TrollFools → 打开「显示系统应用」→ 选 **SpringBoard**（列表里是「桌面 / Home Screen」）
→ 注入 `LazyTap.dylib` → 它会自动重启桌面。

### 装好之后

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
