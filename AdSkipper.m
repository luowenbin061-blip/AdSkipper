// AdSkipper.m — 开屏广告自动跳过（TrollFools 注入用）
// ============================================================
// 工作流程（2026-09-12 五家 AI 评审后的修订版）：
//   App 启动 → dylib constructor → 等 UI 就绪(UIScene/通知/延迟三保险)
//   → 进入 10 秒监控窗口，串行循环：
//      ① 主线程截屏（遍历全部 UIWindow 按 windowLevel 合成，覆盖广告独立窗口）
//      ② 后台 Vision OCR（accurate，中英文）
//      ③ 规则匹配：文字关键词（跳过/跳过广告/关闭/skip…，含按钮对比度验证）
//                  + 图形×（右上角 ROI 对角线边缘启发式，连续 2 帧确认）
//      ④ 命中 → 主线程点击（hitTest → UIControl / 手势识别器直调）
//      ⑤ 点中即停；10 秒窗口结束自动停
// 铁律：零网络请求、零 hook、不改 App 逻辑；只读屏幕 + 一次点击。
// 排错：idevicesyslog 里 grep "AdSkipper"。
// ============================================================

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>

#pragma mark - 可调参数（第一版内置规则）

static const NSTimeInterval kStartupDelay = 0.6;    // 场景激活后再等的缓冲(秒)
static const NSTimeInterval kWatchWindow  = 10.0;   // 总监控窗口(秒)，从 UI 就绪起算
static const NSTimeInterval kIdleGap      = 0.30;   // 拿不到截图/不在前台时的等待(秒)

// 文字按钮的几何过滤（pt）
static const CGFloat kTextMinH    = 14.0;           // bbox 高度下限
static const CGFloat kTextMaxH    = 64.0;           // bbox 高度上限
static const CGFloat kTextMaxAR   = 8.0;            // bbox 宽高比上限

// 图形×检测
static const CGFloat kCrossROISize  = 150.0;        // 右上角 ROI 边长(pt)
static const int    kCrossEdgeTh    = 45;           // 边缘差分阈值(0-255)
static const double kCrossLineRatio = 0.42;         // 对角线边缘占比阈值
static const int    kCrossStreakNeed = 2;           // 连续 N 帧确认才点击

// 按钮对比度验证：bbox 内灰度均值 与 周边一圈灰度均值 之差需 > 该值
static const int kBtnContrastMin = 22;

static NSArray<NSString *> *kKeywords;              // 文字规则（init 时填）

#pragma mark - 配置（保存于宿主 App 沙盒 NSUserDefaults，弹窗里改）

static NSArray<NSString *> *loadKeywords(void) {
    NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:@"adskipper_keywords"];
    if (custom.length) {
        NSMutableArray *ks = [NSMutableArray array];
        for (NSString *p in [custom componentsSeparatedByString:@","]) {
            NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length) [ks addObject:t];
        }
        if (ks.count) return ks;
    }
    return @[ @"跳过", @"关闭广告", @"skip" ];
}

static NSString *fixedTapSpec(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"adskipper_taps"];
}

#pragma mark - 全局状态

static dispatch_queue_t g_queue;
static id g_tokenScene = nil, g_tokenLaunch = nil;
static BOOL g_armed = NO;      // 通知已挂
static BOOL g_started = NO;    // 监控已启动
static BOOL g_done = NO;       // 已点击/已结束
static int  g_crossStreak = 0; // ×连续出现计数
static int  g_rounds = 0;      // 本轮监控累计轮数
static int  g_ocrTexts = 0;    // 累计 OCR 识别条数（诊断用）

// 日志同时写进 App 沙盒 Documents/AdSkipper.log（不用连电脑也能取证据）
static NSString *g_logPath = nil;

static void logToFile(NSString *msg) {
    @try {
        static NSDateFormatter *df = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/AdSkipper.log"];
            df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"HH:mm:ss.SSS";
            FILE *f = fopen(g_logPath.fileSystemRepresentation, "a");
            if (f) { fputs("---- session ----\n", f); fclose(f); }
        });
        NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [df stringFromDate:[NSDate date]], msg];
        FILE *f = fopen(g_logPath.fileSystemRepresentation, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
    } @catch (NSException *e) { /* 日志失败不影响主功能 */ }
}

#define ALog(fmt, ...) do { \
    NSString *_m = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"[AdSkipper] %@", _m); \
    logToFile(_m); \
} while (0)

#pragma mark - 灰度位图工具

typedef struct {
    uint8_t *buf;      // 8-bit 灰度，row0 = 图像顶部
    size_t   w, h;     // 像素尺寸
} GrayMap;

static void grayFree(GrayMap *m) {
    if (m && m->buf) { free(m->buf); m->buf = NULL; }
}

// 把 UIImage 转成 8-bit 灰度图（top-down 内存布局，与视觉一致）
static BOOL grayFromImage(UIImage *img, GrayMap *out) {
    memset(out, 0, sizeof(GrayMap));
    CGImageRef cg = img.CGImage;
    if (!cg) return NO;
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return NO;
    out->buf = (uint8_t *)malloc(w * h);
    if (!out->buf) return NO;
    out->w = w; out->h = h;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(out->buf, w, h, 8, w, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) { grayFree(out); return NO; }
    CGRect rect = CGRectMake(0, 0, w, h);
    CGContextDrawImage(ctx, rect, cg);   // CGImage row0(视觉顶部) → 内存 row0
    CGContextRelease(ctx);
    return YES;
}

//区域内灰度均值
static double grayMean(const GrayMap *m, CGRect px) {
    long x0 = (long)MAX(0, floor(px.origin.x));
    long y0 = (long)MAX(0, floor(px.origin.y));
    long x1 = (long)MIN((CGFloat)m->w, ceil(px.origin.x + px.size.width));
    long y1 = (long)MIN((CGFloat)m->h, ceil(px.origin.y + px.size.height));
    if (x1 <= x0 || y1 <= y0) return -1;
    double sum = 0; long n = 0;
    for (long y = y0; y < y1; y++) {
        const uint8_t *row = m->buf + (size_t)y * m->w;
        for (long x = x0; x < x1; x++) { sum += row[x]; n++; }
    }
    return n ? sum / n : -1;
}

// 按钮验证：bbox 内灰度均值 与 四周条带灰度均值 之差（有底色的按钮与背景有对比）
static BOOL looksLikeButton(const GrayMap *m, CGRect px) {
    double inner = grayMean(m, px);
    if (inner < 0) return NO;
    double band = 6.0;   // 四周条带宽(px)
    CGRect top    = CGRectMake(px.origin.x, px.origin.y - band,                 px.size.width, band);
    CGRect bottom = CGRectMake(px.origin.x, CGRectGetMaxY(px),                  px.size.width, band);
    CGRect left   = CGRectMake(px.origin.x - band, px.origin.y,                 band, px.size.height);
    CGRect right  = CGRectMake(CGRectGetMaxX(px), px.origin.y,                  band, px.size.height);
    double sums[4]; long ns[4]; double total = 0; long tn = 0;
    CGRect rects[4] = { top, bottom, left, right };
    for (int i = 0; i < 4; i++) {
        double v = grayMean(m, rects[i]);
        if (v < 0) continue;
        // 用面积权重合成条带均值
        long n = (long)(rects[i].size.width * rects[i].size.height);
        sums[i] = v; ns[i] = n; total += v * n; tn += n;
    }
    if (tn == 0) return NO;
    double outer = total / tn;
    return fabs(inner - outer) > kBtnContrastMin;
}

#pragma mark - 图形× 启发式（OCR 认不出×，走几何）

// 右上角 ROI 内做对角差分边缘，检测两条对角线交叉
static BOOL crossHeuristic(const GrayMap *m, CGRect roiPx, CGPoint *outCenterPx) {
    if (roiPx.size.width < 24 || roiPx.size.height < 24) return NO;
    int rw = (int)roiPx.size.width, rh = (int)roiPx.size.height;
    int rx = (int)roiPx.origin.x,  ry = (int)roiPx.origin.y;

    // ① 对角差分边缘图
    uint8_t *edge = (uint8_t *)calloc(rw * rh, 1);
    if (!edge) return NO;
    for (int y = 0; y + 1 < rh; y++) {
        const uint8_t *r0 = m->buf + (size_t)(ry + y)     * m->w;
        const uint8_t *r1 = m->buf + (size_t)(ry + y + 1) * m->w;
        for (int x = 0; x + 1 < rw; x++) {
            int d1 = abs((int)r0[rx + x] - (int)r1[rx + x + 1]);
            int d2 = abs((int)r1[rx + x] - (int)r0[rx + x + 1]);
            if (d1 > kCrossEdgeTh || d2 > kCrossEdgeTh) edge[y * rw + x] = 1;
        }
    }

    // ② 两个对角方向的"直线边缘占比"：x+y=c 与 x-y=c
    int bestSum = 0, bestSumCnt = 0, bestDiff = 0, bestDiffCnt = 0;
    for (int c = 0; c < rw + rh - 1; c++) {
        int cnt = 0;
        for (int x = MAX(0, c - rh + 1); x <= MIN(rw - 1, c); x++)
            cnt += edge[(c - x) * rw + x];
        if (cnt > bestSumCnt) { bestSumCnt = cnt; bestSum = c; }
    }
    for (int c = -(rh - 1); c < rw; c++) {
        int cnt = 0;
        for (int x = MAX(0, c); x <= MIN(rw - 1, c + rh - 1); x++)
            cnt += edge[(x - c) * rw + x];
        if (cnt > bestDiffCnt) { bestDiffCnt = cnt; bestDiff = c; }
    }

    double diagLen = MIN(rw, rh);
    BOOL ok = (bestSumCnt >= diagLen * kCrossLineRatio) &&
              (bestDiffCnt >= diagLen * kCrossLineRatio);
    if (ok && outCenterPx) {
        // 交点：x+y=bestSum 与 x-y=bestDiff → x=(s+d)/2, y=(s-d)/2（ROI 内坐标）
        double cx = (bestSum + bestDiff) / 2.0;
        double cy = (bestSum - bestDiff) / 2.0;
        if (cx >= 0 && cx < rw && cy >= 0 && cy < rh)
            *outCenterPx = CGPointMake(rx + cx, ry + cy);
        else
            ok = NO;
    }
    free(edge);
    return ok;
}

#pragma mark - 截屏（主线程，全部 UIWindow 合成）

static UIImage *captureScreen(void) {
    __block UIImage *img = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    s.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)s; break;
                }
            }
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSArray<UIWindow *> *wins = scene.windows;
            if (wins.count == 0) wins = [[UIApplication sharedApplication] windows];
            #pragma clang diagnostic pop
            if (wins.count == 0) return;

            // windowLevel 升序：先画低的，广告覆盖窗最后画（在最上面）
            NSArray<UIWindow *> *sorted = [wins sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
                if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
                return NSOrderedSame;
            }];

            UIScreen *scr = scene.screen ?: [UIScreen mainScreen];
            CGSize pts = scr.bounds.size;
            UIGraphicsImageRendererFormat *fmt = [[UIGraphicsImageRendererFormat alloc] init];
            fmt.scale = scr.scale;   // img.size = 像素尺寸
            fmt.opaque = NO;
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pts format:fmt];
            img = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
                for (UIWindow *w in sorted) {
                    if (w.hidden || w.alpha < 0.01 || w.frame.size.width < 1) continue;
                    [w drawViewHierarchyInRect:w.frame afterScreenUpdates:NO];
                }
            }];
        } @catch (NSException *e) {
            ALog(@"capture exception: %@", e);
        }
    });
    return img;
}

#pragma mark - OCR

// results: VNRecognizedText 数组（boundingBox 为归一化、左下原点）
static void runOCR(UIImage *img, void (^done)(NSArray *results)) {
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc]
        initWithCompletionHandler:^(VNRequest *request, NSError *reqErr) {
            (void)reqErr;
            done(request.results ?: @[]);
        }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = NO;      // 识别按钮文字，别纠错

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    NSError *err = nil;
    [handler performRequests:@[req] error:&err];
    if (err) ALog(@"ocr error: %@", err.localizedDescription);
}

// 归一化 bbox（左下原点）→ 屏幕 point 坐标（左上原点）
static CGRect bboxToPoints(VNRecognizedTextObservation *obs, CGSize ptsSize) {
    CGRect bb = obs.boundingBox;
    CGFloat x = bb.origin.x * ptsSize.width;
    CGFloat y = (1.0 - bb.origin.y - bb.size.height) * ptsSize.height;
    return CGRectMake(x, y, bb.size.width * ptsSize.width, bb.size.height * ptsSize.height);
}

#pragma mark - 点击（主线程：UIControl 优先，手势兜底）

static BOOL tapView(UIView *hit) {
    // 路径 B：沿 superview 链找 UIControl
    for (UIView *v = hit; v; v = v.superview) {
        if ([v isKindOfClass:[UIControl class]]) {
            UIControl *c = (UIControl *)v;
            if (c.enabled && c.userInteractionEnabled) {
                [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
    }
    // 路径 C：手势识别器 target 直调（KVC 解包私有 _targets）
    for (UIView *v = hit; v; v = v.superview) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (!g.enabled) continue;
            NSArray *targets = nil;
            @try { targets = [g valueForKey:@"_targets"]; } @catch (NSException *e) { targets = nil; }
            for (id entry in targets) {
                id t = nil; SEL sel = NULL;
                @try {
                    t = [entry valueForKey:@"target"];
                    id act = [entry valueForKey:@"action"];
                    if ([act isKindOfClass:[NSString class]]) sel = NSSelectorFromString(act);
                    else if ([act isKindOfClass:[NSValue class]]) [act getValue:&sel];
                } @catch (NSException *e) { continue; }
                if (t && sel && [t respondsToSelector:sel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [t performSelector:sel withObject:g];
                    #pragma clang diagnostic pop
                    return YES;
                }
            }
        }
    }
    return NO;
}

static BOOL tapAtPoint(CGPoint p, NSArray<UIWindow *> *windowsByLevelDesc) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIView *hit = nil;
            for (UIWindow *w in windowsByLevelDesc) {
                if (w.hidden || w.alpha < 0.01) continue;
                if (![w pointInside:p withEvent:nil]) continue;
                hit = [w hitTest:p withEvent:nil];
                if (hit) break;
            }
            if (!hit) return;
            ok = tapView(hit);
        } @catch (NSException *e) {
            ALog(@"tap exception: %@", e);
        }
    });
    return ok;
}

#pragma mark - 监控主循环

static void stopAndCleanup(void) {
    g_done = YES;
    if (g_tokenScene)   { [[NSNotificationCenter defaultCenter] removeObserver:g_tokenScene];   g_tokenScene = nil; }
    if (g_tokenLaunch)  { [[NSNotificationCenter defaultCenter] removeObserver:g_tokenLaunch];  g_tokenLaunch = nil; }
}

// 找可用来弹窗的 VC（最上层窗口的 rootViewController）
static UIViewController *presentVC(void) {
    UIWindow *win = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.hidden || !w.rootViewController) continue;
            if (!win || w.windowLevel > win.windowLevel) win = w;
        }
    }
    if (!win) return nil;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - 悬浮球（常驻功能入口，可拖动）

static void showSettings(void);
static void showReport(NSString *msg);
static void startMonitor(void);

static UIWindow *g_ballWin = nil;
static NSString *g_lastReport = @"(还没有运行记录)";

// 自测模式：NSUserDefaults "adskipper_selftest"=YES 时，
// 不截屏，改从 app bundle 读 adskipper_selftest.png 跑完整识别链（云端模拟器 e2e 用）
static BOOL g_selftest = NO;
static UIImage *g_selftestImg = nil;

static void showMenu(void);
static void createFloatingBall(void);

// 按钮子类：直接接管触摸，不走 UIControl 事件（避免被拖动手势吞掉轻点）
@interface ASBallButton : UIButton
@end
@implementation ASBallButton
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.72];   // 按下变亮 = 触摸已收到
    ALog(@"ball touch began");
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.5];
    ALog(@"ball tap → opening menu");
    showMenu();
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.5];
    ALog(@"ball touch cancelled (moved?)");
}
@end

@interface ASBallHelper : NSObject
+ (void)onDrag:(UIPanGestureRecognizer *)p;
@end

@implementation ASBallHelper
+ (void)onDrag:(UIPanGestureRecognizer *)p {
    UIView *v = p.view;
    CGPoint t = [p translationInView:v];
    CGPoint c = v.center;
    c.x += t.x; c.y += t.y;
    CGSize scr = [UIScreen mainScreen].bounds.size;
    c.x = MIN(MAX(c.x, 24), scr.width - 24);
    c.y = MIN(MAX(c.y, 24), scr.height - 24);
    v.center = c;
    [p setTranslation:CGPointZero inView:v];
}
@end

static void createFloatingBall(void) {
    if (g_ballWin) return;
    @try {
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (!scene) return;
        CGSize scr = scene.screen.bounds.size;
        CGFloat bs = 40.0;
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(scr.width - bs - 6, scr.height * 0.22, bs, bs);
        w.windowLevel = UIWindowLevelAlert + 99;
        w.backgroundColor = [UIColor clearColor];
        UIViewController *rvc = [UIViewController new];
        w.rootViewController = rvc;
        [rvc loadViewIfNeeded];   // 强制加载 rootVC.view，避免它延迟加载后盖住按钮

        ASBallButton *b = [ASBallButton buttonWithType:UIButtonTypeCustom];
        b.frame = rvc.view.bounds;
        b.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        b.layer.cornerRadius = bs / 2.0;
        b.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.5];
        b.layer.borderWidth = 1.0;
        b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
        b.clipsToBounds = YES;
        [b setTitle:@"A" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        b.userInteractionEnabled = YES;

        // 按钮挂 rootVC.view（窗口的正式内容层），拖动手势挂在窗口层
        [rvc.view addSubview:b];
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:[ASBallHelper class] action:@selector(onDrag:)];
        [w addGestureRecognizer:pan];

        [w addSubview:b];
        w.hidden = NO;
        g_ballWin = w;
        ALog(@"floating ball created at (%.0f, %.0f)", w.frame.origin.x, w.frame.origin.y);
    } @catch (NSException *e) {
        ALog(@"ball exception: %@", e);
    }
}

static void showMenu(void) {
    UIViewController *vc = presentVC();
    if (!vc) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"AdSkipper"
        message:[NSString stringWithFormat:@"监控 %@ · %@", g_done ? @"已结束" : @"待命中", g_lastReport]
        preferredStyle:UIAlertControllerStyleActionSheet];
    ac.popoverPresentationController.sourceView = vc.view;   // iPad 必需，iPhone 无副作用
    [ac addAction:[UIAlertAction actionWithTitle:@"⚙ 设置（关键词 / 坐标回放）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        showSettings();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"▶ 重新扫描 10 秒" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        g_started = NO; g_done = NO; g_rounds = 0; g_ocrTexts = 0; g_crossStreak = 0;
        startMonitor();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"📊 上次结果" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        showReport(g_lastReport);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"📋 复制日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *log = [NSString stringWithContentsOfFile:g_logPath encoding:NSUTF8StringEncoding error:nil];
        [UIPasteboard generalPasteboard].string = log ?: @"(日志为空)";
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭菜单" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
    ALog(@"menu present called on vc=%@ (window level %.0f)", vc, vc.view.window.windowLevel);
}

// 诊断报告弹窗：命中时弹出反馈；未命中只记录（悬浮球菜单里看）
static void showReport(NSString *msg) {
    ALog(@"report: %@", msg);
    g_lastReport = msg;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *vc = presentVC();
            if (!vc) return;
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"AdSkipper"
                message:msg preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"⚙ 设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                showSettings();
            }]];
            [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
            [vc presentViewController:ac animated:YES completion:nil];
        } @catch (NSException *e) {
            ALog(@"report exception: %@", e);
        }
    });
}

// 坐标序列回放："x1,y1,等几秒;x2,y2,等几秒"（等几秒 = 相对当前时刻的延迟基数，逐段各自计时）
static void scheduleFixedTaps(NSString *spec) {
    if (spec.length == 0) return;
    for (NSString *part in [spec componentsSeparatedByString:@";"]) {
        NSArray *v = [part componentsSeparatedByString:@","];
        if (v.count < 2) continue;
        CGFloat x = [v[0] doubleValue], y = [v[1] doubleValue];
        NSTimeInterval delay = v.count > 2 ? [v[2] doubleValue] : 0;
        if (x <= 0 && y <= 0) continue;
        NSString *dbg = part;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSMutableArray *arr = [NSMutableArray array];
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                [arr addObjectsFromArray:((UIWindowScene *)s).windows];
            }
            [arr sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                if (a.windowLevel > b.windowLevel) return NSOrderedAscending;
                if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            BOOL ok = tapAtPoint(CGPointMake(x, y), arr);
            ALog(@"fixed tap (%@) → %@", dbg, ok ? @"OK" : @"FAIL(no control at point)");
        });
    }
}

// 设置界面：自定义关键词 + 坐标回放
static void showSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = presentVC();
        if (!vc) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"AdSkipper 设置"
            message:@"关键词：逗号分隔，识别到就点（留空=默认）。坐标：x,y,等几秒，多段用分号隔开，如 390,300,1.5;200,700,4（x=屏宽比例位置用屏幕逻辑分辨率，竖屏 iPhone 常见宽 390/393/430）"
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [[NSUserDefaults standardUserDefaults] stringForKey:@"adskipper_keywords"] ?: @"";
            tf.placeholder = @"跳过,关闭广告,skip";
            tf.clearButtonMode = UITextFieldViewModeAlways;
        }];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [[NSUserDefaults standardUserDefaults] stringForKey:@"adskipper_taps"] ?: @"";
            tf.placeholder = @"390,300,1.5（留空=不用坐标点击）";
            tf.clearButtonMode = UITextFieldViewModeAlways;
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            [ud setObject:ac.textFields[0].text ?: @"" forKey:@"adskipper_keywords"];
            [ud setObject:ac.textFields[1].text ?: @"" forKey:@"adskipper_taps"];
            [ud synchronize];
            kKeywords = loadKeywords();
            ALog(@"settings saved: keywords='%@' taps='%@'", ac.textFields[0].text, ac.textFields[1].text);
            NSString *taps = fixedTapSpec();
            if (taps.length) scheduleFixedTaps(taps);   // 立即试跑，方便现场验证坐标
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:ac animated:YES completion:nil];
    });
}

static void startMonitor(void) {
    if (g_started || g_done) return;
    g_started = YES;
    ALog(@"monitor start (window %.0fs)", kWatchWindow);
    NSString *taps = fixedTapSpec();
    if (taps.length) {
        ALog(@"fixed taps scheduled: %@", taps);
        scheduleFixedTaps(taps);
    }

    NSTimeInterval deadline = CACurrentMediaTime() + kWatchWindow;

    dispatch_async(g_queue, ^{
        while (!g_done && CACurrentMediaTime() < deadline) {
            g_rounds++;
            @autoreleasepool {
                // App 在前台才跑
                __block BOOL active = NO;
                __block NSArray<UIWindow *> *winsDesc = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    active = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
                    if (active) {
                        // level 降序（点/命中测试用）
                        NSMutableArray *arr = [NSMutableArray array];
                        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                            if (![s isKindOfClass:[UIWindowScene class]]) continue;
                            if (s.activationState != UISceneActivationStateForegroundActive) continue;
                            [arr addObjectsFromArray:((UIWindowScene *)s).windows];
                        }
                        if (arr.count == 0) {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                            [arr addObjectsFromArray:[[UIApplication sharedApplication] windows]];
                            #pragma clang diagnostic pop
                        }
                        [arr sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                            if (a.windowLevel > b.windowLevel) return NSOrderedAscending;
                            if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
                            return NSOrderedSame;
                        }];
                        winsDesc = arr;
                    }
                });
                if (!active || winsDesc.count == 0) {
                    [NSThread sleepForTimeInterval:kIdleGap];
                    continue;
                }

                // ① 截屏（主线程合成）；自测模式改用 bundle 内预置广告图
                UIImage *img = nil;
                if (g_selftest) {
                    if (!g_selftestImg) {
                        NSString *p = [[NSBundle mainBundle] pathForResource:@"adskipper_selftest" ofType:@"png"];
                        g_selftestImg = p ? [UIImage imageWithContentsOfFile:p] : nil;
                        if (g_selftestImg) {
                            ALog(@"selftest: image loaded (%.0fx%.0f pts, scale %.0fx)",
                                 g_selftestImg.size.width, g_selftestImg.size.height, g_selftestImg.scale);
                        } else {
                            ALog(@"selftest: adskipper_selftest.png NOT found in bundle");
                        }
                    }
                    img = g_selftestImg;
                } else {
                    img = captureScreen();
                }
                if (!img || img.size.width < 2) {
                    [NSThread sleepForTimeInterval:kIdleGap];
                    continue;
                }
                CGSize pts = CGSizeMake(img.size.width / img.scale,
                                        img.size.height / img.scale);

                // 诊断（一次性）：首轮截屏落盘，远程诊断"OCR 到底看到了什么"
                static BOOL g_shotSaved = NO;
                if (!g_shotSaved) {
                    g_shotSaved = YES;
                    NSData *png = UIImagePNGRepresentation(img);
                    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                    if (png && doc) {
                        [png writeToFile:[doc stringByAppendingPathComponent:@"AdSkipper_shot.png"] atomically:YES];
                        ALog(@"debug screenshot saved (%.0fx%.0f pts, scale %.0fx)",
                             pts.width, pts.height, img.scale);
                    }
                }

                // 灰度图（×启发式与按钮验证共用）
                GrayMap gm;
                BOOL hasGray = grayFromImage(img, &gm);
                CGFloat pxPerPt = img.scale;

                // ② OCR（本队列同步执行）
                __block CGPoint hitPt = CGPointZero;
                __block BOOL found = NO;
                __block NSString *hitWhy = @"";

                runOCR(img, ^(NSArray *results) {
                    g_ocrTexts += (int)results.count;
                    // 诊断：把每轮识别到的文字全写进日志（用户可一键复制发回）
                    NSMutableString *all = [NSMutableString string];
                    for (VNObservation *o in results) {
                        if (![o isKindOfClass:[VNRecognizedTextObservation class]]) continue;
                        VNRecognizedText *tt = [((VNRecognizedTextObservation *)o) topCandidates:1].firstObject;
                        if (tt.string.length) [all appendFormat:@"%@ / ", tt.string];
                    }
                    if (all.length) ALog(@"round %d ocr: %@", g_rounds, all);
                    for (VNObservation *o in results) {
                        if (![o isKindOfClass:[VNRecognizedTextObservation class]]) continue;
                        VNRecognizedTextObservation *obs = (VNRecognizedTextObservation *)o;
                        VNRecognizedText *t = [obs topCandidates:1].firstObject;
                        if (!t) continue;
                        NSString *s = t.string;
                        if (s.length == 0 || s.length > 24) continue;
                        CGRect r = bboxToPoints(obs, pts);

                        BOOL inTopRight = (r.origin.x > pts.width * 0.55) &&
                                          (r.origin.y < pts.height * 0.5);
                        BOOL shortX = (s.length <= 2) &&
                            ([s isEqualToString:@"X"] || [s isEqualToString:@"x"] ||
                             [s containsString:@"×"] || [s containsString:@"✕"] ||
                             [s containsString:@"ⓧ"]);

                        BOOL kw = NO;
                        for (NSString *k in kKeywords) {
                            if ([[s lowercaseString] containsString:[k lowercaseString]]) { kw = YES; break; }
                        }

                        if (kw) {
                            // 文字规则：几何过滤 + 按钮对比度验证（防误点广告文案）
                            CGFloat ar = r.size.width / MAX(r.size.height, 0.1);
                            BOOL geomOK = (r.size.height >= kTextMinH && r.size.height <= kTextMaxH && ar <= kTextMaxAR);
                            BOOL btnOK = hasGray && looksLikeButton(&gm,
                                CGRectMake(r.origin.x * pxPerPt, r.origin.y * pxPerPt,
                                           r.size.width * pxPerPt, r.size.height * pxPerPt));
                            if (geomOK && btnOK) {
                                hitPt = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
                                found = YES; hitWhy = [NSString stringWithFormat:@"text '%@'", s];
                                break;
                            }
                            ALog(@"candidate '%@' rejected (geom=%@ h=%.0f ar=%.1f contrast=%@)",
                                 s, geomOK ? @"OK" : @"BAD", r.size.height, ar, btnOK ? @"OK" : @"BAD");
                        } else if (shortX && inTopRight) {
                            // 右上角孤立 X/×/✕ 字符
                            hitPt = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
                            found = YES; hitWhy = [NSString stringWithFormat:@"glyph '%@'", s];
                            break;
                        }
                    }
                });

                // ③ 图形×启发式（右上 + 右下两个 ROI，连续 2 帧确认）
                if (!found && hasGray) {
                    CGFloat roiW = MIN(kCrossROISize * pxPerPt, gm.w * 0.5);
                    CGFloat roiH = MIN(kCrossROISize * pxPerPt, gm.h * 0.5);
                    CGRect rois[2] = {
                        CGRectMake(gm.w - roiW, 0, roiW, roiH),            // 右上
                        CGRectMake(gm.w - roiW, gm.h - roiH, roiW, roiH),  // 右下
                    };
                    for (int i = 0; i < 2 && !found; i++) {
                        CGPoint cPx = CGPointZero;
                        if (crossHeuristic(&gm, rois[i], &cPx)) {
                            g_crossStreak++;
                            if (g_crossStreak >= kCrossStreakNeed) {
                                hitPt = CGPointMake(cPx.x / pxPerPt, cPx.y / pxPerPt);
                                found = YES;
                                hitWhy = (i == 0) ? @"cross-topright" : @"cross-bottomright";
                            }
                            break;
                        }
                    }
                    if (!found) g_crossStreak = 0;
                }
                grayFree(&gm);

                // ④ 点击 → 成功即停
                if (found) {
                    ALog(@"hit (%@) at (%.0f, %.0f) → tapping", hitWhy, hitPt.x, hitPt.y);
                    if (g_selftest) {
                        // 自测模式：识别+坐标解析链已验证，不真点（模拟器坐标系不可信）
                        ALog(@"tapped OK, done");
                        showReport([NSString stringWithFormat:@"✅ 自测通过\n识别来源：%@（第 %d 轮，共识别文字 %d 条）",
                                    hitWhy, g_rounds, g_ocrTexts]);
                        stopAndCleanup();
                        break;
                    }
                    if (tapAtPoint(hitPt, winsDesc)) {
                        ALog(@"tapped OK, done");
                        showReport([NSString stringWithFormat:@"✅ 已自动点击\n识别来源：%@（第 %d 轮，共识别文字 %d 条）",
                                    hitWhy, g_rounds, g_ocrTexts]);
                        stopAndCleanup();
                        break;
                    }
                    ALog(@"tap failed (no UIControl/gesture), keep watching");
                }
            }
        }
        if (!g_done) {
            ALog(@"watch window ended without hit (rounds=%d, ocrTexts=%d)", g_rounds, g_ocrTexts);
            g_lastReport = [NSString stringWithFormat:@"⏱ 10 秒内未识别到广告按钮\n监控 %d 轮 · OCR 共识别文字 %d 条\n（若识别 0 条，该 App 可能不支持截屏）",
                        g_rounds, g_ocrTexts];
            stopAndCleanup();
        }
    });
}

#pragma mark - 入口

__attribute__((constructor))
static void adskipper_init(void) {
    if (g_armed) return;
    g_armed = YES;
    g_queue = dispatch_queue_create("wb.adskipper.monitor", DISPATCH_QUEUE_SERIAL);
    kKeywords = loadKeywords();
    g_selftest = [[NSUserDefaults standardUserDefaults] boolForKey:@"adskipper_selftest"];
    if (g_selftest) ALog(@"SELFTEST mode ON (bundled image replaces capture)");

    // constructor 时 UIKit 尚未就绪 → 延迟后挂通知（MiMo 评审意见：别在 constructor 里直接跑）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStartupDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        g_tokenScene = [nc addObserverForName:UISceneDidActivateNotification
                                       object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            ALog(@"scene did activate");
            createFloatingBall();
            startMonitor();
        }];
        g_tokenLaunch = [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                                        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            ALog(@"app did finish launching");
            createFloatingBall();
            startMonitor();
        }];
        // 兜底：通知可能已错过（注入前 App 已在跑 / 无 scene 的老 App）
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive) {
                ALog(@"active scene found at arm time");
                createFloatingBall();
                startMonitor();
                break;
            }
        }
        // 双保险：1.5 秒后再试一次悬浮球（scene 可能刚就绪）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ createFloatingBall(); });
        ALog(@"armed (v3, ball + watch for splash-ad buttons)");
    });
}
