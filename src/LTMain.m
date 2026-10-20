//
//  LTMain.m  —  dylib 入口
//
//  注入普通 App：等 0.5 秒（宿主窗口建好）后挂悬浮条，触摸走进程内合成。
//  注入 SpringBoard：桌面进程本来就没有「App 窗口就绪」这一刻，直接 0.3 秒后装，
//  悬浮窗自己造，触摸走 HID —— 这样切到任何 App，竖条都还在最上层。
//
//  这里额外做三件事，都是为了让「崩一次」不等于「桌面起不来」：
//    1. 启动闸门：连续 3 次没存活就本次不装载（切断崩溃循环）
//    2. 整体 @try：constructor 里抛异常会直接把进程带走，必须兜住
//    3. 存活标记：装好后 6 秒还在跑才清零计数
//
#import "LT.h"
#import "LTSafety.h"

__attribute__((constructor))
static void lt_entry(void) {
    @try {
        @autoreleasepool {
            if (!NSClassFromString(@"UIApplication")) return;   // 非 GUI 进程直接跳过

            if (!LTBootGuardShouldInstall()) return;            // 安全模式：什么都不装

            BOOL sb = LTIsSpringBoard();
            double delay = sb ? 0.3 : 0.5;

            dispatch_async(dispatch_get_main_queue(), ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        [[LTManager shared] installWhenReady];
                    } @catch (NSException *e) {
                        NSLog(@"[LazyTap] 装载异常：%@ %@", e.name, e.reason);
                    }
                });
            });
        }
    } @catch (NSException *e) {
        // 连 constructor 都抛异常时，唯一安全的动作是安静退出，让宿主正常起来
        NSLog(@"[LazyTap] 入口异常，已跳过：%@ %@", e.name, e.reason);
    }
}
