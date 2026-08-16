#ifdef __cplusplus
extern "C" {
#endif
typedef void *id; typedef void *Class; typedef void *SEL; typedef void *IMP; typedef void *Method;
typedef signed char BOOL; typedef unsigned long NSUInteger; typedef unsigned long size_t; typedef long NSInteger; typedef double CGFloat;
extern id objc_msgSend(id,SEL,...); extern Class objc_getClass(const char *); extern SEL sel_registerName(const char *);
extern Class objc_allocateClassPair(Class,const char *,size_t); extern void objc_registerClassPair(Class);
extern BOOL class_addMethod(Class,SEL,IMP,const char *); extern Method class_getInstanceMethod(Class,SEL);
extern IMP method_getImplementation(Method); extern IMP method_setImplementation(Method,IMP);
#ifdef __cplusplus
}
#endif
#define S(x) sel_registerName(x)
#define C(x) ((id)objc_getClass(x))
#define M0(r,o,s) ((r(*)(id,SEL))objc_msgSend)((id)(o),S(s))
#define M1(r,o,s,t1,a1) ((r(*)(id,SEL,t1))objc_msgSend)((id)(o),S(s),(a1))
#define M2(r,o,s,t1,a1,t2,a2) ((r(*)(id,SEL,t1,t2))objc_msgSend)((id)(o),S(s),(a1),(a2))
#define M3(r,o,s,t1,a1,t2,a2,t3,a3) ((r(*)(id,SEL,t1,t2,t3))objc_msgSend)((id)(o),S(s),(a1),(a2),(a3))

static void (*orig_present)(id,SEL,id,BOOL,id)=0;
static void (*orig_viewDidAppear)(id,SEL,BOOL)=0;
static id g_controller=0;
static int g_busy=0;

static id ns(const char *s){ return M1(id,C("NSString"),"stringWithUTF8String:",const char*,s); }
static BOOL eq(id s,const char *c){ return s?M1(BOOL,s,"isEqualToString:",id,ns(c)):0; }

static void swizzle(Class c,const char *n,IMP r,IMP *old){ if(!c)return; Method m=class_getInstanceMethod(c,S(n)); if(!m)return; if(old)*old=method_getImplementation(m); method_setImplementation(m,r); }

static BOOL hasText(id v,const char *w){
    if(!v)return 0;
    if(M1(BOOL,v,"isKindOfClass:",Class,objc_getClass("UILabel"))){ id t=M0(id,v,"text"); if(eq(t,w))return 1; }
    if(M1(BOOL,v,"isKindOfClass:",Class,objc_getClass("UIButton"))){ id t=M1(id,v,"titleForState:",NSUInteger,0); if(eq(t,w))return 1; }
    id a=M0(id,v,"subviews"); NSUInteger n=a?M0(NSUInteger,a,"count"):0;
    for(NSUInteger i=0;i<n;i++){ id x=M1(id,a,"objectAtIndex:",NSUInteger,i); if(hasText(x,w))return 1; }
    return 0;
}

static BOOL isNeonSheet(id vc){
    if(!vc)return 0; id v=M0(id,vc,"view"); if(!v)return 0;
    return hasText(v,"Обычный") && hasText(v,"Бас") && hasText(v,"Глубокий бас");
}

static id topVC(void){
    id app=M0(id,C("UIApplication"),"sharedApplication"); id win=M0(id,app,"keyWindow");
    if(!win){ id ws=M0(id,app,"windows"); win=ws?M0(id,ws,"lastObject"):0; }
    id vc=win?M0(id,win,"rootViewController"):0;
    for(int i=0;vc&&i<10;i++){
        id x=M0(id,vc,"presentedViewController"); if(x){vc=x;continue;}
        if(M1(BOOL,vc,"respondsToSelector:",SEL,S("visibleViewController"))){ x=M0(id,vc,"visibleViewController"); if(x&&x!=vc){vc=x;continue;} }
        if(M1(BOOL,vc,"respondsToSelector:",SEL,S("selectedViewController"))){ x=M0(id,vc,"selectedViewController"); if(x&&x!=vc){vc=x;continue;} }
        break;
    }
    return vc;
}

static void postChanged(void){ id c=M0(id,C("NSNotificationCenter"),"defaultCenter"); if(c)M2(void,c,"postNotificationName:object:",id,ns("SwiftgramNeonAudioSettingsChanged"),id,0); }

static void setValues(const char *raw,int sp,int hp,int loud,const char *shown){
    id d=M0(id,C("NSUserDefaults"),"standardUserDefaults");
    M2(void,d,"setObject:forKey:",id,ns(raw),id,ns("neonAudioPreset"));
    M2(void,d,"setInteger:forKey:",NSInteger,(NSInteger)sp,id,ns("neonAudioSpeakerBass"));
    M2(void,d,"setInteger:forKey:",NSInteger,(NSInteger)hp,id,ns("neonAudioHeadphonesBass"));
    M2(void,d,"setInteger:forKey:",NSInteger,(NSInteger)loud,id,ns("neonAudioLoudness"));
    if(shown) M2(void,d,"setObject:forKey:",id,ns(shown),id,ns("NeonAudioSelectedName")); else M1(void,d,"removeObjectForKey:",id,ns("NeonAudioSelectedName"));
    M0(void,d,"synchronize"); postChanged();
}

static void replaceLabel(id v,id rep){
    if(!v)return;
    if(M1(BOOL,v,"isKindOfClass:",Class,objc_getClass("UILabel"))){ id t=M0(id,v,"text"); if(eq(t,"Обычный")||eq(t,"Бас")||eq(t,"Глубокий бас"))M1(void,v,"setText:",id,rep); }
    id a=M0(id,v,"subviews"); NSUInteger n=a?M0(NSUInteger,a,"count"):0;
    for(NSUInteger i=0;i<n;i++)replaceLabel(M1(id,a,"objectAtIndex:",NSUInteger,i),rep);
}

static void refresh(id self,SEL cmd){
    (void)self;(void)cmd; id d=M0(id,C("NSUserDefaults"),"standardUserDefaults"); id shown=M1(id,d,"stringForKey:",id,ns("NeonAudioSelectedName")); if(!shown)return;
    id vc=topVC(); if(!vc)return; id v=M0(id,vc,"view"); if(!v)return;
    if(hasText(v,"Аудио Neon")||hasText(v,"Audio Neon")) replaceLabel(v,shown);
}
static void later(void){ if(!g_controller)return; M3(void,g_controller,"performSelector:withObject:afterDelay:",SEL,S("refresh"),id,0,CGFloat,0.25); M3(void,g_controller,"performSelector:withObject:afterDelay:",SEL,S("refresh"),id,0,CGFloat,0.8); }

static id action(const char *title,int sp,int hp,int loud,const char *shown,const char *raw){
    void (^h)(id)=^(id a){(void)a; setValues(raw,sp,hp,loud,shown); later();};
    return M3(id,C("UIAlertAction"),"actionWithTitle:style:handler:",id,ns(title),NSInteger,0,id,(id)h);
}

static id customAction(const char *title,int sp,int hp,int loud){ return action(title,sp,hp,loud,title,"deepBass"); }

static id menu(void){
    id a=M3(id,C("UIAlertController"),"alertControllerWithTitle:message:preferredStyle:",id,0,id,0,NSInteger,0);
    M1(void,a,"addAction:",id,action("Обычный",0,0,0,0,"normal"));
    M1(void,a,"addAction:",id,action("Бас",55,65,45,0,"bass"));
    M1(void,a,"addAction:",id,action("Глубокий бас",70,80,65,0,"deepBass"));
    M1(void,a,"addAction:",id,customAction("Killsound 4",66,72,58));
    M1(void,a,"addAction:",id,customAction("Killsound 5 + V4A",78,90,76));
    M1(void,a,"addAction:",id,customAction("Killsound 6",72,82,68));
    M1(void,a,"addAction:",id,customAction("Stereo Full XRN5",58,66,60));
    M1(void,a,"addAction:",id,customAction("Dual Speaker v5.1",76,86,80));
    M1(void,a,"addAction:",id,customAction("Manual Stereo Whyred v3",60,68,56));
    M1(void,a,"addAction:",id,customAction("aptX HD EQ",45,62,48));
    M1(void,a,"addAction:",id,customAction("Interface Mod",55,75,55));
    void (^c)(id)=^(id x){(void)x;}; id ca=M3(id,C("UIAlertAction"),"actionWithTitle:style:handler:",id,ns("Отмена"),NSInteger,1,id,(id)c); M1(void,a,"addAction:",id,ca);
    return a;
}

static void hookPresent(id self,SEL cmd,id vc,BOOL anim,id completion){
    if(!orig_present)return;
    if(!g_busy && isNeonSheet(vc)){
        g_busy=1; id m=menu(); orig_present(self,cmd,m,anim,completion); g_busy=0; return;
    }
    orig_present(self,cmd,vc,anim,completion);
}
static void hookAppear(id self,SEL cmd,BOOL a){ if(orig_viewDidAppear)orig_viewDidAppear(self,cmd,a); later(); }

__attribute__((constructor)) static void initFix(void){
    Class base=objc_getClass("NSObject"); Class cls=objc_allocateClassPair(base,"NeonPresetFixController",0);
    if(cls){ class_addMethod(cls,S("refresh"),(IMP)refresh,"v@:"); objc_registerClassPair(cls); } else cls=objc_getClass("NeonPresetFixController");
    if(cls)g_controller=M0(id,(id)cls,"new");
    swizzle(objc_getClass("UIViewController"),"presentViewController:animated:completion:",(IMP)hookPresent,(IMP*)&orig_present);
    swizzle(objc_getClass("UIViewController"),"viewDidAppear:",(IMP)hookAppear,(IMP*)&orig_viewDidAppear);
}
