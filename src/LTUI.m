//
//  LTUI.m  —  v1.2 悬浮竖条 / 点位标记 / 参数面板 / 点击引擎
//
//  v1.2 变更：
//    · ＋ / － 改为竖排（各自一行、水平居中）
//    · 修「拖动竖条仍触发开关」：pan 取消子按钮触摸跟踪 + 拖动期间 dragLocked 双保险
//    · 点 ＋ 直接在屏幕中心生成点位，去掉选点模式与提示条
//
//  v1.1 变更：
//    · 竖条新增「减号」按钮：点一下删最后一个点位，长按清空
//    · 折叠成光球后：单击直接起停，长按展开（不再需要双击，也不会误触）
//    · 引擎从 NSTimer 换成 dispatch_source，tick 放后台串行队列，点击回主线程
//    · 计数标签只在数值变化时更新；脉冲动画复用 layer；拖动时合并写盘
//
#import "LT.h"
#import "LTSafety.h"
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>

#pragma mark - 主题

static UIColor *LTBlue(void)     { return [UIColor colorWithRed:0.29 green:0.72 blue:1.00 alpha:1]; }
static UIColor *LTGreen(void)    { return [UIColor colorWithRed:0.19 green:0.82 blue:0.45 alpha:1]; }
static UIColor *LTRed(void)      { return [UIColor colorWithRed:1.00 green:0.36 blue:0.34 alpha:1]; }
static UIColor *LTGlass(void)    { return [UIColor colorWithWhite:0.09 alpha:0.90]; }
static UIColor *LTIcon(void)     { return [UIColor colorWithWhite:0.86 alpha:1]; }
static UIColor *LTDim(void)      { return [UIColor colorWithWhite:0.45 alpha:1]; }

static const CGFloat kBarW  = 66;
static const CGFloat kBtn   = 46;
static const CGFloat kMini  = 30;
static const CGFloat kPad   = 8;
static const CGFloat kGap   = 5;
static const CGFloat kTight = 2;   // ＋ / － 竖排时的窄间距（视觉上成一组）
static const CGFloat kMark  = 42;

// 竖条高度：两处（LTBarView / LTManager）共用，避免改布局时漏改一处导致拖动越界
static CGFloat LTBarHeightFor(BOOL collapsed) {
    if (collapsed) return kBarW;
    // pad · power · gap · ＋ · tight · － · gap · gear · gap · count · gap · chevron · pad
    return kPad * 2 + kBtn + kGap + kMini + kTight + kMini + kGap + kBtn + kGap + 13 + kGap + kMini;
}

static void LTHaptic(UInt32 sid) {
    if ([LTConfig shared].haptic) AudioServicesPlaySystemSound(sid);
}

#pragma mark - 穿透窗口

@interface LTOverlayWindow : UIWindow
@end

@implementation LTOverlayWindow
// 空白处返回 nil → 交给下层窗口，绝不抢触摸。
// 全局模式（SpringBoard）下这条更重要：我们这层窗压在所有 App 之上，
// 一旦它认领了事件，前台 App 就再也收不到那一次点击。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;
    if (hit == self.rootViewController.view) return nil;

    // 运行中点位标记只负责显示，不能吃触摸：HID 打在自己的点位上时，
    // 命中判定会先落到这一层，被吃掉就表现为「计数在涨、游戏没反应」。
    if (LTIsSpringBoard() && [LTConfig shared].running) {
        Class mk = NSClassFromString(@"LTMarkerView");
        for (UIView *v = hit; v; v = v.superview) {
            if (mk && [v isKindOfClass:mk]) return nil;
        }
    }
    return hit;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return YES; }
@end

@interface LTRootVC : UIViewController
@end

@implementation LTRootVC
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
// 全局模式下必须锁竖屏：HID 的 digitizer 坐标是以竖屏为基准的绝对坐标，
// 窗口要是跟着设备转，标点位置就会和实际落点错开 90°。锁竖屏后一一对应。
- (BOOL)shouldAutorotate { return LTIsSpringBoard() ? NO : YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return LTIsSpringBoard() ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskAll;
}
@end

#pragma mark - 点位标记

@interface LTMarkerView : UIView
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) BOOL on;
@property (nonatomic, strong) UILabel *num;
@property (nonatomic, strong) CAShapeLayer *ring;
- (void)pulse;
@end

@implementation LTMarkerView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:CGRectMake(0, 0, kMark, kMark)])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
        self.layer.cornerRadius = kMark / 2.0;
        self.layer.borderWidth = 2.0;
        self.layer.borderColor = LTBlue().CGColor;
        self.layer.shadowColor = LTBlue().CGColor;
        self.layer.shadowOpacity = 0.65;
        self.layer.shadowRadius = 7;
        self.layer.shadowOffset = CGSizeZero;
        self.userInteractionEnabled = YES;

        _num = [[UILabel alloc] initWithFrame:self.bounds];
        _num.textAlignment = NSTextAlignmentCenter;
        _num.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
        _num.textColor = [UIColor whiteColor];
        _num.userInteractionEnabled = NO;
        [self addSubview:_num];

        // 脉冲环复用，避免每次点击都新建图层
        _ring = [CAShapeLayer layer];
        _ring.frame = self.bounds;
        _ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, 1, 1)].CGPath;
        _ring.fillColor = [UIColor clearColor].CGColor;
        _ring.strokeColor = LTGreen().CGColor;
        _ring.lineWidth = 2.0;
        _ring.hidden = YES;
        [self.layer addSublayer:_ring];
    }
    return self;
}

- (void)setOn:(BOOL)on {
    _on = on;
    self.alpha = on ? 1.0 : 0.32;
    self.layer.borderColor = (on ? LTBlue() : LTDim()).CGColor;
}

- (void)pulse {
    if (self.ring.hidden) self.ring.hidden = NO;
    [self.ring removeAllAnimations];

    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @(1.0);
    scale.toValue = @(2.0);

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(0.95);
    fade.toValue = @(0.0);

    CAAnimationGroup *g = [CAAnimationGroup animation];
    g.animations = @[ scale, fade ];
    g.duration = 0.40;
    g.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

    __weak typeof(self) ws = self;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ ws.ring.hidden = YES; }];
    [self.ring addAnimation:g forKey:@"pulse"];
    [CATransaction commit];
}

@end

#pragma mark - 竖条工具栏

@interface LTBarView : UIView
@property (nonatomic, copy) void (^onPower)(void);
@property (nonatomic, copy) void (^onPlus)(void);
@property (nonatomic, copy) void (^onMinus)(void);
@property (nonatomic, copy) void (^onGear)(void);
@property (nonatomic, copy) void (^onCollapse)(void);
@property (nonatomic, strong) UIButton *power;
@property (nonatomic, strong) UIButton *plus;
@property (nonatomic, strong) UIButton *minus;
@property (nonatomic, strong) UIButton *gear;
@property (nonatomic, strong) UIButton *chevron;
@property (nonatomic, strong) UILabel *count;
@property (nonatomic, assign) BOOL dragLocked;   // 正在拖动竖条 → 期间屏蔽所有按钮，防误触
- (void)refresh;
- (void)setCountText:(NSUInteger)n;
- (CGFloat)barHeight;
@end

@implementation LTBarView

- (UIButton *)button:(NSString *)icon action:(SEL)sel size:(CGFloat)size {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, size, size);
    [b setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
    b.tintColor = LTIcon();
    b.imageView.contentMode = UIViewContentModeScaleAspectFit;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = LTGlass();
        self.layer.cornerRadius = 24;
        self.layer.borderWidth = 0.8;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 14;
        self.layer.shadowOffset = CGSizeMake(0, 6);

        _power   = [self button:@"power"                action:@selector(tapPower)    size:kBtn];
        _plus    = [self button:@"plus"                 action:@selector(tapPlus)     size:kMini];
        _minus   = [self button:@"minus"                action:@selector(tapMinus)    size:kMini];
        _gear    = [self button:@"slider.horizontal.3"  action:@selector(tapGear)     size:kBtn];
        _chevron = [self button:@"chevron.right"        action:@selector(tapChevron)  size:kMini];

        _power.layer.cornerRadius = kBtn / 2.0;
        _power.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];

        _count = [[UILabel alloc] initWithFrame:CGRectZero];
        _count.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];
        _count.textColor = LTDim();
        _count.textAlignment = NSTextAlignmentCenter;
        _count.text = @"0";
        _count.userInteractionEnabled = NO;
        [self addSubview:_count];

        [self refresh];
    }
    return self;
}

// 拖动锁定期间一律不响应：手指按在按钮上拖走再松手，TouchUpInside 仍在按钮内，
// 只靠手势依赖挡不住 UIButton 自己的 tracking，必须显式丢弃这次点击
- (void)tapPower   { if (self.dragLocked) return; if (self.onPower) self.onPower(); }
- (void)tapPlus    { if (self.dragLocked) return; if (self.onPlus) self.onPlus(); }
- (void)tapMinus   { if (self.dragLocked) return; if (self.onMinus) self.onMinus(); }
- (void)tapGear    { if (self.dragLocked) return; if (self.onGear) self.onGear(); }
- (void)tapChevron { if (self.dragLocked) return; if (self.onCollapse) self.onCollapse(); }

- (CGFloat)barHeight {
    return LTBarHeightFor([LTConfig shared].collapsed);
}

- (void)setCountText:(NSUInteger)n {
    NSString *s = (n > 999999) ? @"999k+" : [NSString stringWithFormat:@"%lu", (unsigned long)n];
    if ([self.count.text isEqualToString:s]) return;   // 避免每 tick 都触发重绘
    self.count.text = s;
}

- (void)refresh {
    LTConfig *c = [LTConfig shared];
    BOOL run = c.running;

    self.power.tintColor = run ? [UIColor whiteColor] : LTIcon();
    self.power.backgroundColor = run ? LTGreen() : [UIColor colorWithWhite:1 alpha:0.10];
    self.power.layer.shadowColor = LTGreen().CGColor;
    self.power.layer.shadowOpacity = run ? 0.85 : 0.0;
    self.power.layer.shadowRadius = 10;
    self.power.layer.shadowOffset = CGSizeZero;

    self.plus.hidden = c.collapsed;
    self.minus.hidden = c.collapsed;
    self.gear.hidden = c.collapsed;
    self.count.hidden = c.collapsed;
    self.chevron.hidden = c.collapsed;

    // 折叠态整块光球交给 tap 手势处理，按钮自身关掉交互，避免一次点击触发两次开关
    self.power.userInteractionEnabled = !c.collapsed;

    // 没有点位时减号变灰
    BOOL hasPoint = c.points.count > 0;
    self.minus.enabled = hasPoint;
    self.minus.alpha = hasPoint ? 1.0 : 0.30;

    self.layer.cornerRadius = c.collapsed ? kBarW / 2.0 : 24;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    if ([LTConfig shared].collapsed) {
        self.power.frame = CGRectMake((W - kBtn) / 2.0, (H - kBtn) / 2.0, kBtn, kBtn);
        self.power.layer.cornerRadius = kBtn / 2.0;
        return;
    }

    CGFloat y = kPad;
    self.power.frame = CGRectMake((W - kBtn) / 2.0, y, kBtn, kBtn);
    y += kBtn + kGap;

    // ＋ / － 竖排，各自一行、水平居中
    self.plus.frame  = CGRectMake((W - kMini) / 2.0, y, kMini, kMini);
    y += kMini + kTight;
    self.minus.frame = CGRectMake((W - kMini) / 2.0, y, kMini, kMini);
    y += kMini + kGap;

    self.gear.frame = CGRectMake((W - kBtn) / 2.0, y, kBtn, kBtn);
    y += kBtn + kGap;

    self.count.frame = CGRectMake(0, y, W, 13);
    y += 13 + kGap;

    self.chevron.frame = CGRectMake((W - kMini) / 2.0, y, kMini, kMini);
}

@end

#pragma mark - 参数面板

@interface LTSettingsView : UIView
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, copy) void (^onClear)(void);
@property (nonatomic, strong) UISlider *ivSlider;
@property (nonatomic, strong) UISlider *holdSlider;
@property (nonatomic, strong) UISlider *swipeSlider;
@property (nonatomic, strong) UILabel *ivValue;
@property (nonatomic, strong) UILabel *holdValue;
@property (nonatomic, strong) UILabel *swipeValue;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) UISegmentedControl *chan;
@property (nonatomic, strong) UISwitch *flip;
@property (nonatomic, strong) UISwitch *haptic;
- (void)build;
- (void)refreshValues;
- (void)refreshStatus;
@end

@implementation LTSettingsView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.97];
        self.layer.cornerRadius = 22;
        self.layer.borderWidth = 0.8;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
        [self build];
    }
    return self;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size color:(UIColor *)color bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.font = bold ? [UIFont systemFontOfSize:size weight:UIFontWeightSemibold]
                  : [UIFont systemFontOfSize:size];
    l.textColor = color;
    return l;
}

- (UISlider *)sliderAt:(CGFloat)y width:(CGFloat)w pad:(CGFloat)pad min:(float)a max:(float)b value:(float)v {
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(pad, y, w - pad * 2, 28)];
    s.minimumValue = a;
    s.maximumValue = b;
    s.value = v;
    s.minimumTrackTintColor = LTBlue();
    [s addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:s];
    return s;
}

- (void)build {
    LTConfig *c = [LTConfig shared];
    CGFloat w = self.bounds.size.width;
    CGFloat pad = 20;
    CGFloat y = 16;

    UILabel *title = [self label:@"参数" size:17 color:[UIColor whiteColor] bold:YES];
    title.frame = CGRectMake(pad, y, 120, 22);
    [self addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - pad - 50, y - 4, 50, 30);
    [close setTitle:@"完成" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    close.tintColor = LTBlue();
    [close addTarget:self action:@selector(tapClose) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:close];

    y += 34;

    // 间隔
    UILabel *ivTitle = [self label:@"点击间隔" size:14 color:LTDim() bold:NO];
    ivTitle.frame = CGRectMake(pad, y, 90, 20);
    [self addSubview:ivTitle];
    self.ivValue = [self label:@"" size:14 color:LTBlue() bold:YES];
    self.ivValue.textAlignment = NSTextAlignmentRight;
    self.ivValue.frame = CGRectMake(w - pad - 80, y, 80, 20);
    [self addSubview:self.ivValue];

    y += 24;
    self.ivSlider = [self sliderAt:y width:w pad:pad min:0.05f max:2.0f value:c.globalInterval];
    y += 38;

    // 模式
    self.seg = [[UISegmentedControl alloc] initWithItems:@[ @"点按", @"长按", @"滑动" ]];
    self.seg.frame = CGRectMake(pad, y, w - pad * 2, 32);
    self.seg.selectedSegmentIndex = c.mode;
    self.seg.selectedSegmentTintColor = LTBlue();
    [self.seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.seg];
    y += 44;

    // 长按时长
    UILabel *holdTitle = [self label:@"按住时长" size:14 color:LTDim() bold:NO];
    holdTitle.frame = CGRectMake(pad, y, 90, 20);
    [self addSubview:holdTitle];
    self.holdValue = [self label:@"" size:14 color:LTBlue() bold:YES];
    self.holdValue.textAlignment = NSTextAlignmentRight;
    self.holdValue.frame = CGRectMake(w - pad - 80, y, 80, 20);
    [self addSubview:self.holdValue];

    y += 24;
    self.holdSlider = [self sliderAt:y width:w pad:pad min:0.1f max:2.0f value:c.holdDuration];
    y += 38;

    // 滑动距离
    UILabel *swipeTitle = [self label:@"滑动距离" size:14 color:LTDim() bold:NO];
    swipeTitle.frame = CGRectMake(pad, y, 90, 20);
    [self addSubview:swipeTitle];
    self.swipeValue = [self label:@"" size:14 color:LTBlue() bold:YES];
    self.swipeValue.textAlignment = NSTextAlignmentRight;
    self.swipeValue.frame = CGRectMake(w - pad - 80, y, 80, 20);
    [self addSubview:self.swipeValue];

    y += 24;
    self.swipeSlider = [self sliderAt:y width:w pad:pad min:0.03f max:0.40f value:c.swipeDistance];
    y += 42;

    // 通道
    UILabel *chanTitle = [self label:@"注入通道" size:14 color:LTDim() bold:NO];
    chanTitle.frame = CGRectMake(pad, y, 120, 20);
    [self addSubview:chanTitle];
    self.chan = [[UISegmentedControl alloc] initWithItems:@[ @"自动", @"进程内", @"HID" ]];
    self.chan.frame = CGRectMake(pad, y + 22, w - pad * 2, 30);
    self.chan.selectedSegmentIndex = c.tapChannel;
    self.chan.selectedSegmentTintColor = LTBlue();
    [self.chan addTarget:self action:@selector(chanChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.chan];
    y += 62;

    // Y 翻转 / 震动
    UILabel *flipTitle = [self label:@"Y 轴翻转（点偏了才开）" size:13 color:LTDim() bold:NO];
    flipTitle.frame = CGRectMake(pad, y + 4, w - pad * 2 - 60, 20);
    [self addSubview:flipTitle];
    self.flip = [[UISwitch alloc] initWithFrame:CGRectMake(w - pad - 51, y, 51, 31)];
    self.flip.on = c.flipY;
    self.flip.onTintColor = LTBlue();
    self.flip.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [self.flip addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.flip];
    y += 40;

    UILabel *hapTitle = [self label:@"震动反馈" size:13 color:LTDim() bold:NO];
    hapTitle.frame = CGRectMake(pad, y + 4, w - pad * 2 - 60, 20);
    [self addSubview:hapTitle];
    self.haptic = [[UISwitch alloc] initWithFrame:CGRectMake(w - pad - 51, y, 51, 31)];
    self.haptic.on = c.haptic;
    self.haptic.onTintColor = LTBlue();
    self.haptic.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [self.haptic addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.haptic];
    y += 42;

    // 清空
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(pad, y, (w - pad * 2 - 10) / 2.0, 38);
    [clear setTitle:@"清空点位" forState:UIControlStateNormal];
    [clear setTitleColor:LTRed() forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    clear.backgroundColor = [LTRed() colorWithAlphaComponent:0.10];
    clear.layer.cornerRadius = 11;
    [clear addTarget:self action:@selector(tapClear) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:clear];

    UIButton *diag = [UIButton buttonWithType:UIButtonTypeSystem];
    diag.frame = CGRectMake(pad + (w - pad * 2 - 10) / 2.0 + 10, y, (w - pad * 2 - 10) / 2.0, 38);
    [diag setTitle:@"重测" forState:UIControlStateNormal];
    [diag setTitleColor:LTBlue() forState:UIControlStateNormal];
    diag.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    diag.backgroundColor = [LTBlue() colorWithAlphaComponent:0.10];
    diag.layer.cornerRadius = 11;
    [diag addTarget:self action:@selector(tapDiag) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:diag];

    y += 46;

    self.status = [self label:@"" size:10 color:LTDim() bold:NO];
    self.status.numberOfLines = 2;
    self.status.frame = CGRectMake(pad, y, w - pad * 2, 26);
    [self addSubview:self.status];

    [self refreshValues];
    [self refreshStatus];
}

- (void)refreshValues {
    LTConfig *c = [LTConfig shared];
    self.ivValue.text = [NSString stringWithFormat:@"%.2f 秒", c.globalInterval];
    self.holdValue.text = [NSString stringWithFormat:@"%.2f 秒", c.holdDuration];
    self.swipeValue.text = [NSString stringWithFormat:@"%.0f%%", c.swipeDistance * 100];
    self.holdSlider.enabled = (c.mode == 1);
    self.holdSlider.alpha = (c.mode == 1) ? 1.0 : 0.35;
    self.swipeSlider.enabled = (c.mode == 2);
    self.swipeSlider.alpha = (c.mode == 2) ? 1.0 : 0.35;
}

- (void)refreshStatus {
    self.status.text = LTTapDiagnose();
}

- (void)sliderMoved:(UISlider *)s {
    LTConfig *c = [LTConfig shared];
    if (s == self.ivSlider)    c.globalInterval = s.value;
    if (s == self.holdSlider)  c.holdDuration = s.value;
    if (s == self.swipeSlider) c.swipeDistance = s.value;
    [c saveSoon];
    [self refreshValues];
    if (s == self.ivSlider) {
        if (self.onChange) self.onChange();
    }
}

- (void)segChanged {
    LTConfig *c = [LTConfig shared];
    c.mode = self.seg.selectedSegmentIndex;
    [c saveSoon];
    [self refreshValues];
    if (self.onChange) self.onChange();
}

- (void)chanChanged {
    LTTapSetChannel((LTTapChannel)self.chan.selectedSegmentIndex);
    [self refreshStatus];
}

- (void)switchChanged {
    LTConfig *c = [LTConfig shared];
    c.flipY = self.flip.on;
    c.haptic = self.haptic.on;
    [c saveSoon];
}

- (void)tapClose  { if (self.onClose) self.onClose(); }
- (void)tapClear  { if (self.onClear) self.onClear(); }
- (void)tapDiag   { [self refreshStatus]; }

@end

#pragma mark - 管理器

@interface LTManager () {
    dispatch_source_t _timer;
    dispatch_queue_t _engineQ;
    double *_nextBuf;          // 每个点位的下次触发时刻（C 数组，省掉 NSNumber 装箱）
    NSInteger _nextCount;
    NSUInteger _taps;
}
@property (nonatomic, assign) BOOL barDragging;
@property (nonatomic, strong) LTOverlayWindow *win;
@property (nonatomic, strong) UIView *root;
@property (nonatomic, strong) LTBarView *bar;
@property (nonatomic, strong) LTSettingsView *panel;
@property (nonatomic, strong) NSMutableArray<LTMarkerView *> *marks;

- (void)relayout;
- (void)buildBar;
- (CGFloat)barHeight;
- (void)barPan:(UIPanGestureRecognizer *)g;
- (void)barTapped:(UITapGestureRecognizer *)g;
- (void)barLongPressed:(UILongPressGestureRecognizer *)g;
- (void)toggleCollapse;
- (void)applyBarFrame;
- (void)clampBarCenter;
- (void)rebuildMarkers;
- (void)layoutMarkers;
- (void)markerTapped:(UITapGestureRecognizer *)g;
- (void)markerPanned:(UIPanGestureRecognizer *)g;
- (void)markerLongPressed:(UILongPressGestureRecognizer *)g;
- (void)addPointAtScreenCenter;
- (void)addPointAt:(CGPoint)p;
- (void)removeLastPoint;
- (void)clearPoints;
- (void)toggleSettings;
- (void)toggleRun;
- (void)restartEngineIfNeeded;
- (void)startEngine;
- (void)stopEngine;
- (void)engineTick;
- (void)fireIndices:(NSArray<NSNumber *> *)list;
@end

@implementation LTManager

+ (instancetype)shared {
    static LTManager *ins;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ins = [LTManager new]; });
    return ins;
}

- (instancetype)init {
    if ((self = [super init])) {
        _marks = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    if (_nextBuf) { free(_nextBuf); _nextBuf = NULL; }
}

- (void)installWhenReady {
    if (self.win) return;

    BOOL sb = LTIsSpringBoard();
    UIApplication *app = [UIApplication sharedApplication];

    // SpringBoard 不用 UIApplication 管自己的窗口，app.windows 常年是空的：
    // 这里要是一直等下去就永远装不上，所以全局模式直接跳过这一步。
    if (!sb && app.windows.count == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self installWhenReady]; });
        return;
    }

    CGRect f = [UIScreen mainScreen].bounds;
    if (f.size.width < 1.0 || f.size.height < 1.0) f = CGRectMake(0, 0, 390, 844);

    LTOverlayWindow *win = nil;
    if (sb) {
        // iOS 13 之后没挂 UIWindowScene 的窗口不显示。SpringBoard 自己的 scene 是
        // _SBWindowScene（UIWindowScene 子类），直接按基类取即可。
        UIWindowScene *scene = nil;
        for (UIScene *s in app.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
        }
        if (!scene) {
            for (UIWindow *w in app.windows) {
                if (w.windowScene) { scene = w.windowScene; break; }
            }
        }
        if (scene) win = [[LTOverlayWindow alloc] initWithWindowScene:scene];
        if (!win)  win = [[LTOverlayWindow alloc] initWithFrame:f];
    } else {
        win = [[LTOverlayWindow alloc] initWithFrame:f];
    }

    self.win = win;
    // 全局模式要压过 SpringBoard 的状态栏、通知、控制中心、键盘（那些都在 2000 上下），
    // 但也不能 makeKeyAndVisible —— 抢了 key window 会让键盘 / 弹窗行为异常。
    self.win.windowLevel = sb ? 10000000.0 : (UIWindowLevelAlert + 1000);
    self.win.backgroundColor = [UIColor clearColor];
    self.win.rootViewController = [LTRootVC new];
    self.win.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.win.hidden = NO;
    self.root = self.win.rootViewController.view;

    [self buildBar];
    [self rebuildMarkers];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(relayout)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];

    NSLog(@"[LazyTap] v%@ 已装载 · %@", LT_VERSION, LTTapDiagnose());

    // 存活 6 秒才算这一次启动成功。装在启动瞬间就崩的情况下，
    // 计数会继续累加，第三次之后进安全模式，不会形成崩溃循环。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.win) LTBootGuardMarkHealthy();
    });
}

- (void)relayout {
    CGRect b = self.win.bounds;
    [self clampBarCenter];
    [self layoutMarkers];
    if (self.panel) {
        CGFloat h = MIN(540, b.size.height - 20);
        self.panel.frame = CGRectMake(12, b.size.height - 20 - h, b.size.width - 24, h);
        [self.panel setNeedsLayout];
    }
}

#pragma mark 竖条

- (void)buildBar {
    CGRect b = self.win.bounds;
    LTConfig *c = [LTConfig shared];

    self.bar = [[LTBarView alloc] initWithFrame:CGRectMake(0, 0, kBarW, [self barHeight])];
    [self.bar refresh];
    self.bar.center = CGPointMake(c.barNorm.x * b.size.width, c.barNorm.y * b.size.height);
    [self.root addSubview:self.bar];

    __weak typeof(self) ws = self;
    self.bar.onPower = ^{
        LTHaptic(1519);
        [ws toggleRun];
    };
    self.bar.onPlus    = ^{ [ws addPointAtScreenCenter]; };
    self.bar.onMinus   = ^{ [ws removeLastPoint]; };
    self.bar.onGear    = ^{ [ws toggleSettings]; };
    self.bar.onCollapse= ^{ [ws toggleCollapse]; };

    // 折叠态：单击 = 起停，长按 = 展开
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(barTapped:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesEnded = NO;
    [self.bar addGestureRecognizer:tap];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(barLongPressed:)];
    lp.minimumPressDuration = 0.45;
    lp.cancelsTouchesInView = NO;
    [self.bar addGestureRecognizer:lp];

    // 拖动整体
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(barPan:)];
    // 关键：拖动接管后必须取消子按钮的触摸跟踪，否则「按住按钮拖走再松手」仍会触发按钮
    pan.cancelsTouchesInView = YES;
    pan.minimumNumberOfTouches = 1;
    [self.bar addGestureRecognizer:pan];

    // 拖动优先于点击：手指一动 pan 就接管，tap 不会误触发
    [tap requireGestureRecognizerToFail:pan];
    [lp requireGestureRecognizerToFail:pan];
}

- (CGFloat)barHeight {
    return LTBarHeightFor([LTConfig shared].collapsed);
}

- (void)barTapped:(UITapGestureRecognizer *)g {
    // 只有在折叠成光球时，整块区域点击才起停；展开态不响应，避免误触
    if (![LTConfig shared].collapsed) return;
    if (self.barDragging) return;
    LTHaptic(1519);
    [self toggleRun];
}

- (void)barLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (![LTConfig shared].collapsed) return;
    [self toggleCollapse];
}

- (void)barPan:(UIPanGestureRecognizer *)g {
    CGRect b = self.win.bounds;
    CGPoint t = [g translationInView:self.root];
    [g setTranslation:CGPointZero inView:self.root];

    if (g.state == UIGestureRecognizerStateBegan) {
        self.barDragging = YES;
        self.bar.dragLocked = YES;      // 拖动期间屏蔽 ＋ － 电源等按钮
    }

    CGPoint c = self.bar.center;
    c.x += t.x;
    c.y += t.y;
    self.bar.center = c;
    [self clampBarCenter];

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {

        if (g.state == UIGestureRecognizerStateEnded) {
            // 松手吸附到最近的左右边缘
            CGPoint p = self.bar.center;
            CGFloat half = kBarW / 2.0 + 2;
            if (p.x < b.size.width / 2.0) p.x = half;
            else p.x = b.size.width - half;
            [UIView animateWithDuration:0.18 animations:^{ self.bar.center = p; }];

            [LTConfig shared].barNorm = CGPointMake(p.x / b.size.width, p.y / b.size.height);
            [[LTConfig shared] saveSoon];
        }

        // 抬手后短暂保持锁定，让同一次触摸里迟到的 TouchUpInside 一并被丢弃
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ws.barDragging = NO;
            ws.bar.dragLocked = NO;
        });
    }
}

- (void)clampBarCenter {
    CGRect b = self.win.bounds;
    CGFloat h = [self barHeight];
    CGPoint c = self.bar.center;
    c.x = MAX(kBarW / 2.0, MIN(b.size.width - kBarW / 2.0, c.x));
    c.y = MAX(h / 2.0, MIN(b.size.height - h / 2.0, c.y));
    self.bar.center = c;

    [LTConfig shared].barNorm = CGPointMake(c.x / b.size.width, c.y / b.size.height);
}

- (void)toggleCollapse {
    LTConfig *c = [LTConfig shared];
    c.collapsed = !c.collapsed;
    [c saveSoon];
    [self applyBarFrame];
    LTHaptic(1519);
}

- (void)applyBarFrame {
    CGPoint c = self.bar.center;
    self.bar.bounds = CGRectMake(0, 0, kBarW, [self barHeight]);
    [self.bar setNeedsLayout];
    [self.bar layoutIfNeeded];
    [self.bar refresh];
    self.bar.center = c;
    [self clampBarCenter];
}

#pragma mark 点位

- (void)rebuildMarkers {
    for (LTMarkerView *m in self.marks) [m removeFromSuperview];
    [self.marks removeAllObjects];

    NSArray<LTPoint *> *pts = [LTConfig shared].points;
    for (NSUInteger i = 0; i < pts.count; i++) {
        LTMarkerView *m = [[LTMarkerView alloc] initWithFrame:CGRectZero];
        m.index = i;
        m.num.text = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        m.on = pts[i].enabled;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(markerTapped:)];
        [m addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(markerPanned:)];
        [m addGestureRecognizer:pan];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                            initWithTarget:self action:@selector(markerLongPressed:)];
        lp.minimumPressDuration = 0.55;
        [m addGestureRecognizer:lp];

        // 拖动点位时不要顺带把点位开关切了 / 删了
        [tap requireGestureRecognizerToFail:pan];
        [lp requireGestureRecognizerToFail:pan];

        [self.root addSubview:m];
        [self.marks addObject:m];
    }
    [self layoutMarkers];
    [self restartEngineIfNeeded];
}

- (void)layoutMarkers {
    CGRect b = self.win.bounds;
    NSArray<LTPoint *> *pts = [LTConfig shared].points;
    for (NSUInteger i = 0; i < self.marks.count && i < pts.count; i++) {
        LTMarkerView *m = self.marks[i];
        m.bounds = CGRectMake(0, 0, kMark, kMark);
        m.center = CGPointMake(pts[i].norm.x * b.size.width, pts[i].norm.y * b.size.height);
        m.num.text = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        m.on = pts[i].enabled;
    }
}

- (void)markerTapped:(UITapGestureRecognizer *)g {
    LTMarkerView *m = (LTMarkerView *)g.view;
    NSArray<LTPoint *> *pts = [LTConfig shared].points;
    if (m.index >= (NSInteger)pts.count) return;
    LTPoint *p = pts[m.index];
    p.enabled = !p.enabled;
    m.on = p.enabled;
    [[LTConfig shared] saveSoon];
    LTHaptic(1519);
    [self.bar refresh];
}

- (void)markerPanned:(UIPanGestureRecognizer *)g {
    LTMarkerView *m = (LTMarkerView *)g.view;
    NSArray<LTPoint *> *pts = [LTConfig shared].points;
    if (m.index >= (NSInteger)pts.count) return;

    CGRect b = self.win.bounds;
    CGPoint t = [g translationInView:self.root];
    [g setTranslation:CGPointZero inView:self.root];

    CGPoint c = m.center;
    c.x += t.x;
    c.y += t.y;
    c.x = MAX(kMark / 2.0, MIN(b.size.width - kMark / 2.0, c.x));
    c.y = MAX(kMark / 2.0, MIN(b.size.height - kMark / 2.0, c.y));
    m.center = c;

    pts[m.index].norm = CGPointMake(c.x / b.size.width, c.y / b.size.height);

    if (g.state == UIGestureRecognizerStateEnded) [[LTConfig shared] saveSoon];
}

- (void)markerLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    LTMarkerView *m = (LTMarkerView *)g.view;
    NSArray<LTPoint *> *pts = [LTConfig shared].points;
    if (m.index >= (NSInteger)pts.count) return;

    [[LTConfig shared].points removeObjectAtIndex:m.index];
    [[LTConfig shared] save];
    LTHaptic(1521);
    [self rebuildMarkers];
    [self.bar refresh];
}

#pragma mark 加点 / 减点

// 点一下 ＋ 直接在屏幕中心生成一个点位，不再进入「点屏幕选位置」的选点模式。
// 中心已经被占时按 8 个方向（每圈 8 个）往外错开一格，避免点和点完全重叠看不出来。
- (void)addPointAtScreenCenter {
    CGRect b = self.win.bounds;
    if (b.size.width < 1 || b.size.height < 1) return;

    CGPoint c = CGPointMake(b.size.width / 2.0, b.size.height / 2.0);

    NSUInteger occupied = 0;
    for (LTPoint *p in [LTConfig shared].points) {
        CGPoint q = CGPointMake(p.norm.x * b.size.width, p.norm.y * b.size.height);
        CGFloat dx = q.x - c.x;
        CGFloat dy = q.y - c.y;
        if (sqrt(dx * dx + dy * dy) < 44.0) occupied++;
    }

    if (occupied > 0) {
        CGFloat ring = (CGFloat)((occupied + 7) / 8);          // 第几圈
        CGFloat radius = 60.0 * ring;
        double ang = (double)((occupied - 1) % 8) * (M_PI / 4.0) - M_PI / 2.0;   // 从正上方顺时针
        c.x += (CGFloat)cos(ang) * radius;
        c.y += (CGFloat)sin(ang) * radius;
    }

    c.x = MAX(kMark / 2.0, MIN(b.size.width  - kMark / 2.0, c.x));
    c.y = MAX(kMark / 2.0, MIN(b.size.height - kMark / 2.0, c.y));

    [self addPointAt:c];
}

- (void)addPointAt:(CGPoint)p {
    CGRect b = self.win.bounds;
    if (b.size.width < 1 || b.size.height < 1) return;

    LTPoint *pt = [LTPoint new];
    pt.norm = CGPointMake(p.x / b.size.width, p.y / b.size.height);
    pt.enabled = YES;
    [[LTConfig shared].points addObject:pt];
    [[LTConfig shared] save];

    LTHaptic(1519);
    [self rebuildMarkers];
    [self.root bringSubviewToFront:self.bar];
    [self.bar refresh];
}

- (void)removeLastPoint {
    NSMutableArray<LTPoint *> *pts = [LTConfig shared].points;
    if (pts.count == 0) {
        LTHaptic(1520);
        return;
    }
    [pts removeLastObject];
    [[LTConfig shared] save];
    LTHaptic(1520);
    [self rebuildMarkers];
    [self.bar refresh];
}

- (void)clearPoints {
    [[LTConfig shared].points removeAllObjects];
    [[LTConfig shared] save];
    [self stopEngine];
    [LTConfig shared].running = NO;
    [self rebuildMarkers];
    [self.bar refresh];
    LTHaptic(1521);
}

#pragma mark 参数面板

- (void)toggleSettings {
    if (self.panel) {
        [self.panel removeFromSuperview];
        self.panel = nil;
        return;
    }
    CGRect b = self.win.bounds;
    CGFloat h = MIN(540, b.size.height - 20);
    self.panel = [[LTSettingsView alloc] initWithFrame:CGRectMake(12, b.size.height, b.size.width - 24, h)];

    __weak typeof(self) ws = self;
    self.panel.onClose = ^{ [ws toggleSettings]; };
    self.panel.onChange = ^{ [ws restartEngineIfNeeded]; };
    self.panel.onClear = ^{ [ws clearPoints]; };
    [self.root addSubview:self.panel];

    [UIView animateWithDuration:0.26 animations:^{
        self.panel.frame = CGRectMake(12, b.size.height - 20 - h, b.size.width - 24, h);
    }];
}

#pragma mark 引擎

- (void)toggleRun {
    LTConfig *c = [LTConfig shared];
    if (!c.running && c.points.count == 0) {
        // 没有点位时给个提示音，不进入运行态
        LTHaptic(1520);
        return;
    }
    c.running = !c.running;

    if (c.running) {
        // 面板挡住半个屏幕，开始前先收掉
        if (self.panel) [self toggleSettings];
        // 全局模式：展开的竖条有 66×200，压在游戏上太挡视线，开跑就折成小球
        if (LTIsSpringBoard() && !c.collapsed) [self toggleCollapse];
        [c saveSoon];
        [self startEngine];
    } else {
        [c saveSoon];
        [self stopEngine];
    }

    [self.bar refresh];
    NSLog(@"[LazyTap] running=%d · %@", c.running, LTTapDiagnose());
}

- (void)restartEngineIfNeeded {
    if ([LTConfig shared].running) {
        [self startEngine];
    }
}

- (void)startEngine {
    [self stopEngine];

    if (!_engineQ) {
        _engineQ = dispatch_queue_create("com.xt.lazytap.engine", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_engineQ,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    }

    LTConfig *c = [LTConfig shared];
    NSArray<LTPoint *> *snapshot = nil;
    @synchronized (c.points) { snapshot = [c.points copy]; }
    NSUInteger n = snapshot.count;

    // buffer 的分配放到引擎队列上做：stopEngine 是异步取消，正在跑的 tick 可能还在读旧 buffer
    dispatch_sync(_engineQ, ^{
        if (self->_nextBuf) { free(self->_nextBuf); self->_nextBuf = NULL; }
        self->_nextCount = (NSInteger)n;
        self->_nextBuf = (double *)calloc((size_t)MAX(n, 1), sizeof(double));
        double t0 = CACurrentMediaTime();
        for (NSUInteger i = 0; i < n; i++) self->_nextBuf[i] = t0;
    });

    _taps = 0;
    [self.bar setCountText:0];

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _engineQ);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              6ull * NSEC_PER_MSEC,
                              2ull * NSEC_PER_MSEC);

    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{
        // tick 抛未捕获异常会直接杀掉 SpringBoard，这里兜住并停掉自己
        @try {
            [ws engineTick];
        } @catch (NSException *e) {
            NSLog(@"[LazyTap] 引擎 tick 异常，自动停止：%@ %@", e.name, e.reason);
            dispatch_async(dispatch_get_main_queue(), ^{ [ws stopEngine]; });
        }
    });
    dispatch_resume(_timer);
}

- (void)stopEngine {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

// 后台队列：只做时间比较与派发，真正的 UI/HID 操作回主线程
- (void)engineTick {
    LTConfig *c = [LTConfig shared];
    if (!c.running) return;

    double now = CACurrentMediaTime();
    NSMutableArray<NSNumber *> *due = nil;

    @synchronized (c.points) {
        NSInteger n = MIN((NSInteger)c.points.count, _nextCount);
        for (NSInteger i = 0; i < n; i++) {
            LTPoint *p = c.points[i];
            if (!p.enabled) continue;
            if (now < _nextBuf[i]) continue;

            double iv = p.interval > 0 ? p.interval : c.globalInterval;
            if (iv < 0.02) iv = 0.02;

            // 累积而不是从 now 起算，避免 tick 粒度造成长期漂移；
            // 但落后太多时不补点（补点会在卡顿恢复后瞬间连击，WebView 会更惨）
            double next = _nextBuf[i] + iv;
            if (next < now) next = now + iv;
            _nextBuf[i] = next;

            if (!due) due = [NSMutableArray arrayWithCapacity:2];
            [due addObject:@(i)];
        }
    }

    if (!due.count) return;

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        LTManager *s = ws;
        if (!s) return;
        [s fireIndices:due];
    });
}

- (void)fireIndices:(NSArray<NSNumber *> *)list {
    LTConfig *c = [LTConfig shared];

    // 锁内只取快照，锁外再做派发（LTTapNormalized 可能跑 JS，不能占着锁）
    NSMutableArray<NSNumber *> *idxs = [NSMutableArray arrayWithCapacity:list.count];
    NSMutableArray<NSValue *> *vals = [NSMutableArray arrayWithCapacity:list.count];
    NSInteger mode = 0;
    BOOL flip = NO;
    double hold = 0.02, swd = 0.10, swdur = 0.25;

    @synchronized (c.points) {
        mode = c.mode;
        flip = c.flipY;
        hold = c.holdDuration;
        swd = c.swipeDistance;
        swdur = c.swipeDuration;
        for (NSNumber *ix in list) {
            NSInteger i = ix.integerValue;
            if (i < 0 || i >= (NSInteger)c.points.count) continue;
            [idxs addObject:@(i)];
            [vals addObject:[NSValue valueWithCGPoint:c.points[i].norm]];
        }
    }

    for (NSUInteger k = 0; k < idxs.count; k++) {
        CGPoint n = [vals[k] CGPointValue];
        if (flip) n.y = 1.0 - n.y;

        if (mode == 2) {
            CGPoint to = CGPointMake(n.x, MAX(0.02, n.y - swd));
            LTSwipeNormalized(n, to, swdur);
        } else {
            LTTapNormalized(n, (mode == 1) ? hold : 0.02);
        }

        NSInteger i = idxs[k].integerValue;
        if (i >= 0 && i < (NSInteger)self.marks.count) [self.marks[i] pulse];
        _taps++;
    }
    [self.bar setCountText:_taps];
}

@end
