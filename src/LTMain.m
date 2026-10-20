//
//  LTMain.m  —  dylib 入口
//
//  注入普通 App：等 0.5 秒（宿主窗口建好）后挂悬浮条，触摸走进程内合成。
//  注入 SpringBoard：桌面进程本来就没有「App 窗口就绪」这一刻，直接 0.3 秒后装，
//  悬浮窗自己造，触摸走 HID —— 这样切到任何 App，竖条都还在最上层。
//
#import "LT.h"

__attribute__((constructor))
static void lt_entry(void) {
    @autoreleasepool {
        if (!NSClassFromString(@"UIApplication")) return;   // 非 GUI 进程直接跳过

        BOOL sb = LTIsSpringBoard();
        double delay = sb ? 0.3 : 0.5;

        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[LTManager shared] installWhenReady];
            });
        });
    }
}
