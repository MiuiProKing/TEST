// NeonAudioMods.m — arm64 iOS runtime audio profile injector for Swiftgram Neon.
// No private APIs are used; the hook only adjusts AVAudioUnitEQ parameters created by the app.

#ifdef __cplusplus
extern "C" {
#endif

typedef void *id;
typedef void *Class;
typedef void *SEL;
typedef void *IMP;
typedef void *Method;
typedef signed char BOOL;
typedef unsigned long NSUInteger;
typedef unsigned long size_t;
typedef long NSInteger;
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

extern id objc_msgSend(id, SEL, ...);
extern Class objc_getClass(const char *);
extern SEL sel_registerName(const char *);
extern Class objc_allocateClassPair(Class, const char *, size_t);
extern void objc_registerClassPair(Class);
extern BOOL class_addMethod(Class, SEL, IMP, const char *);
extern Method class_getInstanceMethod(Class, SEL);
extern IMP method_getImplementation(Method);
extern IMP method_setImplementation(Method, IMP);

#ifdef __cplusplus
}
#endif

#define S(x) sel_registerName(x)
#define C(x) ((id)objc_getClass(x))
#define M0(ret,o,s) ((ret(*)(id,SEL))objc_msgSend)((id)(o),S(s))
#define M1(ret,o,s,t1,a1) ((ret(*)(id,SEL,t1))objc_msgSend)((id)(o),S(s),(a1))
#define M2(ret,o,s,t1,a1,t2,a2) ((ret(*)(id,SEL,t1,t2))objc_msgSend)((id)(o),S(s),(a1),(a2))
#define M3(ret,o,s,t1,a1,t2,a2,t3,a3) ((ret(*)(id,SEL,t1,t2,t3))objc_msgSend)((id)(o),S(s),(a1),(a2),(a3))
#define M4(ret,o,s,t1,a1,t2,a2,t3,a3,t4,a4) ((ret(*)(id,SEL,t1,t2,t3,t4))objc_msgSend)((id)(o),S(s),(a1),(a2),(a3),(a4))

static int g_profile = 2;
static id g_controller = 0;
static id g_button = 0;

static void (*orig_eq_setGain)(id,SEL,float) = 0;
static void (*orig_eq_setGlobalGain)(id,SEL,float) = 0;
static void (*orig_mixer_setOutputVolume)(id,SEL,float) = 0;
static void (*orig_player_setVolume)(id,SEL,float) = 0;

static float clampf2(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

typedef struct {
    float master;
    float bass;
    float lowmid;
    float mid;
    float treble;
    const char *name;
} Profile;

static Profile profile_for(int p) {
    switch (p) {
        case 1: return (Profile){2.5f, 7.0f, 4.0f, 1.5f, 2.0f, "Killsound 4"};
        case 2: return (Profile){4.0f,11.0f, 6.0f, 2.5f, 3.0f, "Killsound 5 + V4A"};
        case 3: return (Profile){3.0f, 8.5f, 4.5f, 2.0f, 2.5f, "Killsound 6"};
        case 4: return (Profile){2.0f, 5.0f, 3.0f, 1.0f, 2.5f, "Stereo Full XRN5"};
        case 5: return (Profile){4.0f, 9.5f, 5.0f, 2.0f, 3.0f, "Dual Speaker v5.1"};
        case 6: return (Profile){2.0f, 4.5f, 2.5f, 1.0f, 1.5f, "Manual Stereo Whyred v3"};
        case 7: return (Profile){1.0f, 2.0f, 0.5f, 0.0f, 4.0f, "aptX HD EQ"};
        case 8: return (Profile){0.0f, 0.0f, 0.0f, 0.0f, 0.0f, "Interface Mod"};
        default:return (Profile){0.0f, 0.0f, 0.0f, 0.0f, 0.0f, "Off"};
    }
}

static id nsstr(const char *s) { return M1(id,C("NSString"),"stringWithUTF8String:",const char*,s); }

static void load_profile(void) {
    id defs = M0(id,C("NSUserDefaults"),"standardUserDefaults");
    NSInteger p = M1(NSInteger,defs,"integerForKey:",id,nsstr("NeonAudioModProfile"));
    if (p < 0 || p > 8) p = 2;
    g_profile = (int)p;
}

static void save_profile(int p) {
    g_profile = p;
    id defs = M0(id,C("NSUserDefaults"),"standardUserDefaults");
    M2(void,defs,"setInteger:forKey:",NSInteger,(NSInteger)p,id,nsstr("NeonAudioModProfile"));
    M0(void,defs,"synchronize");
}

static float band_boost(float freq) {
    Profile p = profile_for(g_profile);
    if (freq <= 180.0f) return p.bass;
    if (freq <= 650.0f) return p.lowmid;
    if (freq <= 2600.0f) return p.mid;
    return p.treble;
}

static void hook_eq_setGain(id self, SEL cmd, float value) {
    float freq = 1000.0f;
    if (M1(BOOL,self,"respondsToSelector:",SEL,S("frequency"))) {
        freq = M0(float,self,"frequency");
    }
    float out = clampf2(value + band_boost(freq), -96.0f, 24.0f);
    if (orig_eq_setGain) orig_eq_setGain(self, cmd, out);
}

static void hook_eq_setGlobalGain(id self, SEL cmd, float value) {
    Profile p = profile_for(g_profile);
    float out = clampf2(value + p.master, -96.0f, 24.0f);
    if (orig_eq_setGlobalGain) orig_eq_setGlobalGain(self, cmd, out);
}

static float volume_factor(void) {
    Profile p = profile_for(g_profile);
    float f = 1.0f + p.master * 0.035f;
    return clampf2(f, 1.0f, 1.35f);
}

static void hook_mixer_setOutputVolume(id self, SEL cmd, float value) {
    float out = clampf2(value * volume_factor(), 0.0f, 1.0f);
    if (orig_mixer_setOutputVolume) orig_mixer_setOutputVolume(self, cmd, out);
}
static void hook_player_setVolume(id self, SEL cmd, float value) {
    float out = clampf2(value * volume_factor(), 0.0f, 1.0f);
    if (orig_player_setVolume) orig_player_setVolume(self, cmd, out);
}

static void swizzle(Class cls, const char *name, IMP replacement, IMP *storage) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, S(name));
    if (!m) return;
    if (storage) *storage = method_getImplementation(m);
    method_setImplementation(m, replacement);
}

static void install_audio_hooks(void) {
    swizzle(objc_getClass("AVAudioUnitEQFilterParameters"), "setGain:", (IMP)hook_eq_setGain, (IMP*)&orig_eq_setGain);
    swizzle(objc_getClass("AVAudioUnitEQ"), "setGlobalGain:", (IMP)hook_eq_setGlobalGain, (IMP*)&orig_eq_setGlobalGain);
    swizzle(objc_getClass("AVAudioMixerNode"), "setOutputVolume:", (IMP)hook_mixer_setOutputVolume, (IMP*)&orig_mixer_setOutputVolume);
    swizzle(objc_getClass("AVAudioPlayerNode"), "setVolume:", (IMP)hook_player_setVolume, (IMP*)&orig_player_setVolume);
}

static id top_controller(void) {
    id app = M0(id,C("UIApplication"),"sharedApplication");
    id win = M0(id,app,"keyWindow");
    if (!win) {
        id wins = M0(id,app,"windows");
        win = M0(id,wins,"lastObject");
    }
    id vc = win ? M0(id,win,"rootViewController") : 0;
    for (int i=0; vc && i<8; i++) {
        id next = M0(id,vc,"presentedViewController");
        if (next) { vc = next; continue; }
        if (M1(BOOL,vc,"respondsToSelector:",SEL,S("visibleViewController"))) {
            next = M0(id,vc,"visibleViewController");
            if (next && next != vc) { vc = next; continue; }
        }
        if (M1(BOOL,vc,"respondsToSelector:",SEL,S("selectedViewController"))) {
            next = M0(id,vc,"selectedViewController");
            if (next && next != vc) { vc = next; continue; }
        }
        break;
    }
    return vc;
}

static void update_button_title(void) {
    if (!g_button) return;
    const char *labels[] = {"🎧0","🎧1","🎧2","🎧3","🎧4","🎧5","🎧6","🎧7","🎨8"};
    int p = g_profile; if (p < 0 || p > 8) p = 0;
    M2(void,g_button,"setTitle:forState:",id,nsstr(labels[p]),NSUInteger,0);
}

static void set_profile_and_refresh(int p) {
    save_profile(p);
    update_button_title();
}

static void show_profile_menu(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    id alert = M3(id,C("UIAlertController"),"alertControllerWithTitle:message:preferredStyle:",id,nsstr("🎧 Audio Mod Pack"),id,nsstr("Выбери профиль. Новые настройки применяются к аудио Swiftgram."),NSInteger,0);
    const char *names[] = {
        "Выкл.","Killsound 4","Killsound 5 + V4A","Killsound 6","Stereo Full XRN5",
        "Dual Speaker v5.1","Manual Stereo Whyred v3","aptX HD EQ","Interface Mod (визуальный)"
    };
    for (int i=0;i<=8;i++) {
        int idx = i;
        void (^handler)(id) = ^(id action) { (void)action; set_profile_and_refresh(idx); };
        id a = M3(id,C("UIAlertAction"),"actionWithTitle:style:handler:",id,nsstr(names[i]),NSInteger,0,id,(id)handler);
        M1(void,alert,"addAction:",id,a);
    }
    void (^cancelHandler)(id) = ^(id action) { (void)action; };
    id cancel = M3(id,C("UIAlertAction"),"actionWithTitle:style:handler:",id,nsstr("Закрыть"),NSInteger,1,id,(id)cancelHandler);
    M1(void,alert,"addAction:",id,cancel);
    id vc = top_controller();
    if (vc) M3(void,vc,"presentViewController:animated:completion:",id,alert,BOOL,1,id,0);
}

static void install_button(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    if (g_button) return;
    id app = M0(id,C("UIApplication"),"sharedApplication");
    id win = M0(id,app,"keyWindow");
    if (!win) {
        id wins = M0(id,app,"windows");
        win = M0(id,wins,"lastObject");
    }
    if (!win) return;
    id screen = M0(id,C("UIScreen"),"mainScreen");
    CGRect bounds = M0(CGRect,screen,"bounds");
    id button = M1(id,C("UIButton"),"buttonWithType:",NSInteger,0);
    CGRect f = {{bounds.size.width - 58.0, 96.0},{50.0,50.0}};
    M1(void,button,"setFrame:",CGRect,f);
    id color = M4(id,C("UIColor"),"colorWithRed:green:blue:alpha:",CGFloat,0.08,CGFloat,0.08,CGFloat,0.10,CGFloat,0.86);
    M1(void,button,"setBackgroundColor:",id,color);
    id layer = M0(id,button,"layer");
    M1(void,layer,"setCornerRadius:",CGFloat,16.0);
    M3(void,button,"addTarget:action:forControlEvents:",id,g_controller,SEL,S("showProfileMenu"),NSUInteger,1UL<<6);
    M1(void,win,"addSubview:",id,button);
    g_button = button;
    update_button_title();
}

__attribute__((constructor)) static void neon_audio_mods_init(void) {
    load_profile();
    install_audio_hooks();
    Class base = objc_getClass("NSObject");
    Class cls = objc_allocateClassPair(base, "NeonAudioModController", 0);
    if (cls) {
        class_addMethod(cls, S("showProfileMenu"), (IMP)show_profile_menu, "v@:");
        class_addMethod(cls, S("installButton"), (IMP)install_button, "v@:");
        objc_registerClassPair(cls);
    } else cls = objc_getClass("NeonAudioModController");
    g_controller = M0(id,(id)cls,"new");
    M3(void,g_controller,"performSelector:withObject:afterDelay:",SEL,S("installButton"),id,0,CGFloat,2.0);
}
