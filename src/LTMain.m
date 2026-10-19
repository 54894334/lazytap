//
//  LTMain.m  —  dylib 入口
//  注入后 0.3~0.5 秒（等宿主 App 建好窗口）自动挂上悬浮条
//
#import "LT.h"

__attribute__((constructor))
static void lt_entry(void) {
    @autoreleasepool {
        if (!NSClassFromString(@"UIApplication")) return;   // 非 GUI 进程直接跳过

        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[LTManager shared] installWhenReady];
            });
        });
    }
}
