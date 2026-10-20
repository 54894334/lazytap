//
//  LTHost.m  —  宿主环境判定
//
//  同一份 dylib 要能吃两种宿主：
//    · 普通 App（老用法：注入某个目标 App，进程内触摸合成）
//    · SpringBoard（新用法：注入桌面，悬浮窗浮在所有 App 之上，点击走内核 HID）
//  这里只负责把「我是谁」判准，窗口与通道的差异都在 LTUI.m / LTHID.m 里分支。
//
#import "LT.h"

BOOL LTIsSpringBoard(void) {
    static int cache = -1;
    if (cache >= 0) return cache == 1;

    cache = 0;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.springboard"] ||
        [bid hasSuffix:@".SpringBoard"]) {
        cache = 1;
        return YES;
    }

    // 极少数注入方式拿不到 bundleIdentifier，用 SpringBoard 独有类兜底。
    // 这几个类只在 SpringBoard 进程里存在，普通 App 里 NSClassFromString 返回 nil。
    if (NSClassFromString(@"SBIconController") ||
        NSClassFromString(@"SBApplicationController") ||
        NSClassFromString(@"SBMainWorkspace")) {
        cache = 1;
        return YES;
    }
    return NO;
}
