//
//  LTSafety.m  —  崩溃自愈闸门
//
#import "LT.h"
#import "LTSafety.h"

// 连续几次启动没活下来就认为上次是启动期崩溃。
// 取 3 而不是 1：偶尔一次卡顿被 watchdog 杀掉不该触发，但真崩循环 3 次一定刹住。
static const NSInteger kLTMaxBootFail = 3;

static BOOL gLTSafeMode = NO;

NSString *LTBootGuardFilePath(void) {
    NSString *base = [LTConfig path];
    NSString *dir = [base stringByDeletingLastPathComponent];
    return [dir stringByAppendingPathComponent:@"LazyTap.boot"];
}

BOOL LTBootGuardShouldInstall(void) {
    @try {
        NSString *f = LTBootGuardFilePath();
        NSInteger n = 0;
        NSString *s = [NSString stringWithContentsOfFile:f
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        if (s.length) n = s.integerValue;
        if (n < 0) n = 0;
        n++;

        // 先落盘再判断：即使这次就是在写盘后崩，下次也能读到累加值
        [[NSString stringWithFormat:@"%ld", (long)n]
            writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        if (n > kLTMaxBootFail) {
            gLTSafeMode = YES;
            NSLog(@"[LazyTap] 连续 %ld 次启动未存活，进入安全模式：本次不装载悬浮条。"
                  @"解除方法：删除 %@ 或调 LTRecoverFromSafeMode()", (long)n, f);
            return NO;
        }
        NSLog(@"[LazyTap] 启动计数 %ld/%ld", (long)n, (long)kLTMaxBootFail);
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[LazyTap] 启动闸门异常：%@，本次放行", e.reason);
        return YES;
    }
}

void LTBootGuardMarkHealthy(void) {
    @try {
        NSString *f = LTBootGuardFilePath();
        [[NSString stringWithFormat:@"0"]
            writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        gLTSafeMode = NO;
        NSLog(@"[LazyTap] 装载完成且存活，启动计数清零");
    } @catch (NSException *e) {
        NSLog(@"[LazyTap] 清零失败：%@", e.reason);
    }
}

BOOL LTInSafeMode(void) {
    return gLTSafeMode;
}

void LTRecoverFromSafeMode(void) {
    @try {
        [[NSFileManager defaultManager] removeItemAtPath:LTBootGuardFilePath() error:NULL];
        [[LTConfig shared] reset];
        gLTSafeMode = NO;
        NSLog(@"[LazyTap] 已解除安全模式并重置配置");
    } @catch (NSException *e) {
        NSLog(@"[LazyTap] 解除失败：%@", e.reason);
    }
}
