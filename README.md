# LazyTap · 懒触 1.2.0

TrollStore 环境用的 **注入式悬浮连点器**（无越狱）。核心解决的就一件事：
**设置好点位之后，用开关直接起停，不用"取消 → 重设 → 重启"。**

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

用 TrollFools / ESign 把 `LazyTap.dylib` 注入目标 App 后重签。

- 走默认的「进程内」通道**不需要任何额外权限**，正常重签即可。
- 只有手动切到「HID」通道时才需要宿主带上 `entitlements.plist` 里的 HID 权限
  （ESign 的「导入 entitlements」那一步）。

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
- 已知限制：`iohid` 通道受宿主权限约束；进程内通道只作用于被注入的这个 App。
