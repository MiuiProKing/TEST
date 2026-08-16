#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSInteger gProfile = 0;
static UIButton *gModesButton = nil;
static __weak UIWindow *gModesWindow = nil;
static NSTimer *gScanTimer = nil;

static void (*origEQGain)(id, SEL, float) = NULL;
static void (*origEQGlobal)(id, SEL, float) = NULL;
static void (*origMixerVol)(id, SEL, float) = NULL;
static void (*origPlayerVol)(id, SEL, float) = NULL;

typedef struct {
    float master;
    float bass;
    float lowmid;
    float mid;
    float treble;
    __unsafe_unretained NSString *name;
    __unsafe_unretained NSString *shortName;
} NeonProfile;

static NeonProfile NeonProfileFor(NSInteger p) {
    switch (p) {
        case 1: return (NeonProfile){2.8f, 7.5f, 4.2f, 1.5f, 2.0f, @"Killsound 4", @"KS4"};
        case 2: return (NeonProfile){4.8f,12.5f, 6.5f, 2.5f, 3.2f, @"Killsound 5 + V4A", @"KS5+V4A"};
        case 3: return (NeonProfile){3.5f, 9.5f, 5.0f, 2.0f, 2.7f, @"Killsound 6", @"KS6"};
        case 4: return (NeonProfile){2.5f, 5.5f, 3.2f, 1.2f, 3.0f, @"Stereo Full XRN5", @"Stereo"};
        case 5: return (NeonProfile){4.5f,10.5f, 5.5f, 2.2f, 3.0f, @"Dual Speaker v5.1", @"Dual v5.1"};
        case 6: return (NeonProfile){2.2f, 5.0f, 2.8f, 1.0f, 1.8f, @"Manual Stereo Whyred v3", @"Whyred v3"};
        case 7: return (NeonProfile){1.5f, 2.5f, 0.8f, 0.0f, 4.5f, @"aptX HD EQ", @"aptX EQ"};
        case 8: return (NeonProfile){0.8f, 1.2f, 0.8f, 0.0f, 1.8f, @"Interface Mod Audio", @"Interface"};
        default:return (NeonProfile){0,0,0,0,0,@"Выкл.",@"МОДЫ +8"};
    }
}

static float ClampF(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static float BoostForFreq(float freq) {
    NeonProfile p = NeonProfileFor(gProfile);
    if (freq <= 180.0f) return p.bass;
    if (freq <= 650.0f) return p.lowmid;
    if (freq <= 2600.0f) return p.mid;
    return p.treble;
}

static void HookEQGain(id self, SEL _cmd, float value) {
    float freq = 1000.0f;
    if ([self respondsToSelector:@selector(frequency)]) {
        freq = ((float(*)(id,SEL))objc_msgSend)(self, @selector(frequency));
    }
    float out = ClampF(value + BoostForFreq(freq), -96.0f, 24.0f);
    if (origEQGain) origEQGain(self, _cmd, out);
}

static void HookEQGlobal(id self, SEL _cmd, float value) {
    NeonProfile p = NeonProfileFor(gProfile);
    float out = ClampF(value + p.master, -96.0f, 24.0f);
    if (origEQGlobal) origEQGlobal(self, _cmd, out);
}

static float VolFactor(void) {
    NeonProfile p = NeonProfileFor(gProfile);
    return ClampF(1.0f + p.master * 0.04f, 1.0f, 1.38f);
}

static void HookMixerVol(id self, SEL _cmd, float value) {
    if (origMixerVol) origMixerVol(self, _cmd, ClampF(value * VolFactor(), 0.0f, 1.0f));
}
static void HookPlayerVol(id self, SEL _cmd, float value) {
    if (origPlayerVol) origPlayerVol(self, _cmd, ClampF(value * VolFactor(), 0.0f, 1.0f));
}

static void Swizzle(Class cls, SEL sel, IMP replacement, IMP *oldOut) {
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) return;
    if (oldOut) *oldOut = method_getImplementation(m);
    method_setImplementation(m, replacement);
}

static UIWindow *ActiveWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
        for (UIWindow *w in ws.windows) if (!w.hidden && w.alpha > 0.0) return w;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.lastObject;
#pragma clang diagnostic pop
}

static UIViewController *TopController(void) {
    UIWindow *w = ActiveWindow();
    UIViewController *vc = w.rootViewController;
    for (NSInteger i = 0; vc && i < 12; i++) {
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *n = ((UINavigationController *)vc).visibleViewController;
            if (n && n != vc) { vc = n; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *n = ((UITabBarController *)vc).selectedViewController;
            if (n && n != vc) { vc = n; continue; }
        }
        break;
    }
    return vc;
}

static BOOL TextLooksLikeAudioNeon(NSString *s) {
    if (s.length == 0) return NO;
    NSString *l = s.lowercaseString;
    return ([l containsString:@"аудио neon"] || [l containsString:@"audio neon"] ||
            [l containsString:@"sgneonaudioselector"] || [l containsString:@"sgneonaudioslider"]);
}

static UIView *FindSelectorView(UIView *v, BOOL *screenDetected) {
    if (!v) return nil;
    NSString *aid = v.accessibilityIdentifier;
    NSString *al = v.accessibilityLabel;
    NSString *av = v.accessibilityValue;
    if (TextLooksLikeAudioNeon(aid) || TextLooksLikeAudioNeon(al) || TextLooksLikeAudioNeon(av)) *screenDetected = YES;
    if ([aid isEqualToString:@"SGNeonAudioSelector"] || [al isEqualToString:@"SGNeonAudioSelector"]) return v;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (TextLooksLikeAudioNeon(t)) *screenDetected = YES;
    } else if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)v titleForState:UIControlStateNormal];
        if (TextLooksLikeAudioNeon(t)) *screenDetected = YES;
    } else if ([v respondsToSelector:NSSelectorFromString(@"text")]) {
        @try {
            id t = [v valueForKey:@"text"];
            if ([t isKindOfClass:[NSString class]] && TextLooksLikeAudioNeon(t)) *screenDetected = YES;
        } @catch (__unused NSException *e) {}
    }
    for (UIView *c in v.subviews) {
        UIView *r = FindSelectorView(c, screenDetected);
        if (r) return r;
    }
    return nil;
}

static void UpdateButtonTitle(void) {
    if (!gModesButton) return;
    NeonProfile p = NeonProfileFor(gProfile);
    NSString *t = gProfile == 0 ? @"🎛 МОДЫ +8" : [NSString stringWithFormat:@"🎛 %@", p.shortName];
    [gModesButton setTitle:t forState:UIControlStateNormal];
}

static void SelectProfile(NSInteger idx) {
    gProfile = MAX(0, MIN(8, idx));
    [[NSUserDefaults standardUserDefaults] setInteger:gProfile forKey:@"NeonAudioExtraProfileV4"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    UpdateButtonTitle();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"sgNeonAudioChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SGNeonAudioChanged" object:nil];
}

@interface NeonModesController : NSObject
+ (instancetype)shared;
- (void)showMenu;
- (void)scan;
@end

@implementation NeonModesController
+ (instancetype)shared { static id x; static dispatch_once_t once; dispatch_once(&once, ^{ x = [self new]; }); return x; }

- (void)showMenu {
    UIViewController *vc = TopController();
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"🎛 Расширенные пресеты"
                                                               message:@"Дополнительные режимы для Аудио Neon. Родные Обычный / Бас / Глубокий бас остаются слева в строке Пресет."
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *names = @[@"Выкл. дополнительный мод", @"Killsound 4", @"Killsound 5 + V4A", @"Killsound 6", @"Stereo Full XRN5", @"Dual Speaker v5.1", @"Manual Stereo Whyred v3", @"aptX HD EQ", @"Interface Mod Audio"];
    for (NSInteger i=0; i<names.count; i++) {
        UIAlertAction *act = [UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { SelectProfile(i); }];
        [a addAction:act];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    if (a.popoverPresentationController) {
        a.popoverPresentationController.sourceView = gModesButton ?: vc.view;
        a.popoverPresentationController.sourceRect = gModesButton ? gModesButton.bounds : vc.view.bounds;
    }
    [vc presentViewController:a animated:YES completion:nil];
}

- (void)scan {
    UIWindow *w = ActiveWindow();
    if (!w) return;
    BOOL detected = NO;
    UIView *selector = FindSelectorView(w, &detected);
    if (!selector) {
        if (gModesButton) gModesButton.hidden = YES;
        return;
    }
    CGRect r = [selector convertRect:selector.bounds toView:w];
    if (CGRectIsEmpty(r) || r.size.width < 180 || r.size.height < 34) return;

    if (!gModesButton || gModesWindow != w) {
        [gModesButton removeFromSuperview];
        gModesButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gModesButton.accessibilityIdentifier = @"SGNeonAudioExtraModes";
        gModesButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        [gModesButton setTitleColor:UIColor.systemBlueColor forState:UIControlStateNormal];
        gModesButton.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.10];
        gModesButton.layer.cornerRadius = 14.0;
        gModesButton.layer.masksToBounds = YES;
        [gModesButton addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:gModesButton];
        gModesWindow = w;
        UpdateButtonTitle();
    }
    CGFloat bw = MIN(135.0, MAX(105.0, r.size.width * 0.37));
    CGFloat bh = MIN(36.0, MAX(30.0, r.size.height - 14.0));
    gModesButton.frame = CGRectMake(CGRectGetMaxX(r) - bw - 38.0, CGRectGetMidY(r) - bh/2.0, bw, bh);
    gModesButton.hidden = NO;
    [w bringSubviewToFront:gModesButton];
}
@end

__attribute__((constructor)) static void NeonModesInit(void) {
    @autoreleasepool {
        NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:@"NeonAudioExtraProfileV4"];
        gProfile = (saved >= 0 && saved <= 8) ? saved : 0;

        Swizzle(NSClassFromString(@"AVAudioUnitEQFilterParameters"), @selector(setGain:), (IMP)HookEQGain, (IMP *)&origEQGain);
        Swizzle(NSClassFromString(@"AVAudioUnitEQ"), @selector(setGlobalGain:), (IMP)HookEQGlobal, (IMP *)&origEQGlobal);
        Swizzle(NSClassFromString(@"AVAudioMixerNode"), @selector(setOutputVolume:), (IMP)HookMixerVol, (IMP *)&origMixerVol);
        Swizzle(NSClassFromString(@"AVAudioPlayerNode"), @selector(setVolume:), (IMP)HookPlayerVol, (IMP *)&origPlayerVol);

        dispatch_async(dispatch_get_main_queue(), ^{
            gScanTimer = [NSTimer scheduledTimerWithTimeInterval:0.45 target:[NeonModesController shared] selector:@selector(scan) userInfo:nil repeats:YES];
            [[NeonModesController shared] scan];
        });
    }
}
