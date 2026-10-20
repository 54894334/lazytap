//
//  LTSafety.h  —  崩溃自愈闸门
//
//  注入 SpringBoard 最怕的不是「崩一次」，是「起来就崩、崩了又起」的循环：
//  launchd 会一直把桌面拉起来，用户看到的就是黑屏转圈、进不去系统。
//  这里用「连续 N 次启动未完成 → 本次不装载」的办法把循环切断：
//
//    · 每次 dylib 加载，启动计数 +1
//    · 悬浮条装好并存活 6 秒，计数清零
//    · 计数超过 3，判定上次是启动期崩溃，本次只写日志、不装任何东西
//
//  这样最坏情况是「装上后第一次没反应」，删一个文件就恢复，永远不会卡在循环里。
//
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// dylib 加载时调用。返回 NO 表示应当进入安全模式（本次不装载任何 UI）。
BOOL LTBootGuardShouldInstall(void);

/// 悬浮条装好且进程稳定存活后调用，清零计数。
void LTBootGuardMarkHealthy(void);

/// 当前是否处于安全模式（装载被跳过）。
BOOL LTInSafeMode(void);

/// 手动解除安全模式并恢复默认配置（桌面崩到没法用时用「设置 → 恢复」或删文件）。
void LTRecoverFromSafeMode(void);

/// 安全模式相关的状态文件名，日志/文档里引用
NSString *LTBootGuardFilePath(void);

#ifdef __cplusplus
}
#endif
