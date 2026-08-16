// NeonAudioMods.m — Swiftgram Neon audio profiles integrated into the existing Preset action sheet.
// arm64 iOS runtime injector. Audio processing uses public AVFAudio classes.

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

extern id objc_msgSend(id, SEL, ...);
extern Class objc_getClass(const char *);
extern SEL sel_registerName(const char *);
extern Class objc_allocateClassPair(Class, const char *, size_t);
extern void objc_registerClassPair(Class);
extern BOOL class_addMethod(Class, SEL, IMP, const char *);
extern Method class_getInstanceMethod(Class, SEL);
extern Method class_getClassMethod(Class, SEL);
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

static int g_profile = 0;
static id g_controller = 0;

static void (*orig_eq_setGain)(id,SEL,float) = 0;
static void (*orig_eq_setGlobalGain)(id,SEL,float) = 0;
static void (*orig_mixer_setOutputVolume)(id,SEL,float) = 0;
static void (*orig_player_setVolume)(id,SEL,float) = 0;
static void (*orig_present)(id,SEL,id,BOOL,id) = 0;
static void (*orig_viewDidAppear)(id,SEL,BOOL) = 0;
static id (*orig_actionFactory)(id,SEL,id,NSInteger,id) = 0;

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
        case 1: return (Profile){2.8f, 7.5f, 4.2f, 1.5f, 2.0f, "Killsound 4"};
        case 2: return (Profile){4.8f,12.5f, 6.5f, 2.5f, 3.2f, "Killsound 5 + V4A"};
        case 3: return (Profile){3.5f, 9.5f, 5.0f, 2.0f, 2.7f, "Killsound 6"};
        case 4: return (Profile){2.5f, 5.5f, 3.2f, 1.2f, 3.0f, "Stereo Full XRN5"};
        case 5: return (Profile){4.5f,10.5f, 5.5f, 2.2f, 3.0f, "Dual Speaker v5.1"};
        case 6: return (Profile){2.2f, 5.0f, 2.8f, 1.0f, 1.8f, "Manual Stereo Whyred v3"};
        case 7: return (Profile){1.5f, 2.5f, 0.8f, 0.0f, 4.5f, "aptX HD EQ"};
        case 8: return (Profile){0.0f, 0.0f, 0.0f, 0.0f, 0.0f, "Interface Mod"};
        default:return (Profile){0.0f, 0.0f, 0.0f, 0.0f, 0.0f, "Off"};
    }
}

static id nsstr(const char *s) { return M1(id,C("NSString"),"stringWithUTF8String:",const char*,s); }
static BOOL str_eq(id s, const char *c) { return s ? M1(BOOL,s,"isEqualToString:",id,nsstr(c)) : 0; }

static void load_profile(void) {
    id defs = M0(id,C("NSUserDefaults"),"standardUserDefaults");
    NSInteger p = M1(NSInteger,defs,"integerForKey:",id,nsstr("NeonAudioModProfile"));
    if (p < 0 || p > 8) p = 0;
    g_profile = (int)p;
}

static void save_profile(int p) {
    if (p < 0 || p > 8) p = 0;
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
    if (M1(BOOL,self,"respondsToSelector:",SEL,S("frequency"))) freq = M0(float,self,"frequency");
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
    float f = 1.0f + p.master * 0.04f;
    return clampf2(f, 1.0f, 1.38f);
}

static void hook_mixer_setOutputVolume(id self, SEL cmd, float value) {
    float out = clampf2(value * volume_factor(), 0.0f, 1.0f);
    if (orig_mixer_setOutputVolume) orig_mixer_setOutputVolume(self, cmd, out);
}
static void hook_player_setVolume(id self, SEL cmd, float value) {
    float out = clampf2(value * volume_factor(), 0.0f, 1.0f);
    if (orig_player_setVolume) orig_player_setVolume(self, cmd, out);
}

static void swizzle_instance(Class cls, const char *name, IMP replacement, IMP *storage) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, S(name));
    if (!m) return;
    if (storage) *storage = method_getImplementation(m);
    method_setImplementation(m, replacement);
}

static BOOL action_sheet_has_title(id alert, const char *wanted) {
    id actions = M0(id,alert,"actions");
    NSUInteger count = M0(NSUInteger,actions,"count");
    for (NSUInteger i = 0; i < count; i++) {
        id action = M1(id,actions,"objectAtIndex:",NSUInteger,i);
        id title = M0(id,action,"title");
        if (str_eq(title, wanted)) return 1;
    }
    return 0;
}

static BOOL is_neon_preset_sheet(id alert) {
    if (!alert || !M1(BOOL,alert,"isKindOfClass:",Class,objc_getClass("UIAlertController"))) return 0;
    return action_sheet_has_title(alert, "Обычный") &&
           action_sheet_has_title(alert, "Бас") &&
           action_sheet_has_title(alert, "Глубокий бас");
}

static BOOL view_contains_text(id view, const char *wanted) {
    if (!view) return 0;
    if (M1(BOOL,view,"isKindOfClass:",Class,objc_getClass("UILabel"))) {
        id text = M0(id,view,"text");
        if (str_eq(text, wanted)) return 1;
    }
    id subs = M0(id,view,"subviews");
    NSUInteger count = subs ? M0(NSUInteger,subs,"count") : 0;
    for (NSUInteger i=0; i<count; i++) {
        id child = M1(id,subs,"objectAtIndex:",NSUInteger,i);
        if (view_contains_text(child, wanted)) return 1;
    }
    return 0;
}

static void replace_native_preset_label(id view, id replacement) {
    if (!view) return;
    if (M1(BOOL,view,"isKindOfClass:",Class,objc_getClass("UILabel"))) {
        id text = M0(id,view,"text");
        if (str_eq(text,"Обычный") || str_eq(text,"Бас") || str_eq(text,"Глубокий бас")) {
            M1(void,view,"setText:",id,replacement);
        }
    }
    id subs = M0(id,view,"subviews");
    NSUInteger count = subs ? M0(NSUInteger,subs,"count") : 0;
    for (NSUInteger i=0; i<count; i++) {
        id child = M1(id,subs,"objectAtIndex:",NSUInteger,i);
        replace_native_preset_label(child, replacement);
    }
}

static id top_controller(void) {
    id app = M0(id,C("UIApplication"),"sharedApplication");
    id win = M0(id,app,"keyWindow");
    if (!win) {
        id wins = M0(id,app,"windows");
        win = wins ? M0(id,wins,"lastObject") : 0;
    }
    id vc = win ? M0(id,win,"rootViewController") : 0;
    for (int i=0; vc && i<10; i++) {
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

static void refresh_preset_label(id self, SEL cmd) {
    (void)self; (void)cmd;
    if (g_profile <= 0) return;
    id vc = top_controller();
    if (!vc) return;
    id view = M0(id,vc,"view");
    if (!view) return;
    if (!view_contains_text(view,"Аудио Neon") && !view_contains_text(view,"Audio Neon")) return;
    Profile p = profile_for(g_profile);
    replace_native_preset_label(view, nsstr(p.name));
}

static void select_profile(int idx) {
    save_profile(idx);
    if (g_controller) M3(void,g_controller,"performSelector:withObject:afterDelay:",SEL,S("refreshPresetLabel"),id,0,CGFloat,0.30);
}

static void append_profiles_to_sheet(id alert) {
    if (!is_neon_preset_sheet(alert)) return;
    if (action_sheet_has_title(alert,"Killsound 4")) return;

    void (^offHandler)(id) = ^(id action) { (void)action; select_profile(0); };
    id off = M3(id,C("UIAlertAction"),"actionWithTitle:style:handler:",id,nsstr("Доп. аудио-моды: выкл."),NSInteger,0,id,(id)offHandler);
    M1(void,alert,"addAction:",id,off);

    const char *names[] = {
        "Killsound 4",
        "Killsound 5 + V4A",
        "Killsound 6",
        "Stereo Full XRN5",
        "Dual Speaker v5.1",
        "Manual Stereo Whyred v3",
        "aptX HD EQ",
        "Interface Mod"
    };
    for (int i=0; i<8; i++) {
        int idx = i + 1;
        void (^handler)(id) = ^(id action) { (void)action; select_profile(idx); };
        id a = M3(id,C("UIAlertAction"),"actionWithTitle:style:handler:",id,nsstr(names[i]),NSInteger,0,id,(id)handler);
        M1(void,alert,"addAction:",id,a);
    }
}

static void hook_present(id self, SEL cmd, id vc, BOOL animated, id completion) {
    append_profiles_to_sheet(vc);
    if (orig_present) orig_present(self,cmd,vc,animated,completion);
}

static void hook_viewDidAppear(id self, SEL cmd, BOOL animated) {
    if (orig_viewDidAppear) orig_viewDidAppear(self,cmd,animated);
    if (g_profile > 0) {
        id view = M0(id,self,"view");
        if (view && (view_contains_text(view,"Аудио Neon") || view_contains_text(view,"Audio Neon"))) {
            Profile p = profile_for(g_profile);
            replace_native_preset_label(view,nsstr(p.name));
        }
    }
}

static BOOL is_native_neon_title(id title) {
    return str_eq(title,"Обычный") || str_eq(title,"Бас") || str_eq(title,"Глубокий бас") ||
           str_eq(title,"Normal") || str_eq(title,"Bass") || str_eq(title,"Deep Bass");
}

static id hook_actionFactory(id cls, SEL cmd, id title, NSInteger style, id handlerObj) {
    if (handlerObj && is_native_neon_title(title)) {
        void (^originalHandler)(id) = (void (^)(id))handlerObj;
        void (^wrapped)(id) = ^(id action) {
            save_profile(0);
            originalHandler(action);
        };
        return orig_actionFactory ? orig_actionFactory(cls,cmd,title,style,(id)wrapped) : 0;
    }
    return orig_actionFactory ? orig_actionFactory(cls,cmd,title,style,handlerObj) : 0;
}

static void install_audio_hooks(void) {
    swizzle_instance(objc_getClass("AVAudioUnitEQFilterParameters"), "setGain:", (IMP)hook_eq_setGain, (IMP*)&orig_eq_setGain);
    swizzle_instance(objc_getClass("AVAudioUnitEQ"), "setGlobalGain:", (IMP)hook_eq_setGlobalGain, (IMP*)&orig_eq_setGlobalGain);
    swizzle_instance(objc_getClass("AVAudioMixerNode"), "setOutputVolume:", (IMP)hook_mixer_setOutputVolume, (IMP*)&orig_mixer_setOutputVolume);
    swizzle_instance(objc_getClass("AVAudioPlayerNode"), "setVolume:", (IMP)hook_player_setVolume, (IMP*)&orig_player_setVolume);
}

static void install_ui_hooks(void) {
    swizzle_instance(objc_getClass("UIViewController"), "presentViewController:animated:completion:", (IMP)hook_present, (IMP*)&orig_present);
    swizzle_instance(objc_getClass("UIViewController"), "viewDidAppear:", (IMP)hook_viewDidAppear, (IMP*)&orig_viewDidAppear);

    Class actionClass = objc_getClass("UIAlertAction");
    Method cm = actionClass ? class_getClassMethod(actionClass,S("actionWithTitle:style:handler:")) : 0;
    if (cm) {
        orig_actionFactory = (id(*)(id,SEL,id,NSInteger,id))method_getImplementation(cm);
        method_setImplementation(cm,(IMP)hook_actionFactory);
    }
}

__attribute__((constructor)) static void neon_audio_mods_init(void) {
    load_profile();
    install_audio_hooks();

    Class base = objc_getClass("NSObject");
    Class cls = objc_allocateClassPair(base, "NeonAudioModController", 0);
    if (cls) {
        class_addMethod(cls,S("refreshPresetLabel"),(IMP)refresh_preset_label,"v@:");
        objc_registerClassPair(cls);
    } else {
        cls = objc_getClass("NeonAudioModController");
    }
    if (cls) g_controller = M0(id,(id)cls,"new");

    install_ui_hooks();
}
