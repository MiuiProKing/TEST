#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static NSString * const HomeURL = @"https://miuiproking.github.io/luckyjet-telegram-mini-app/index.html";
@interface WebController : UIViewController <WKNavigationDelegate, WKUIDelegate>
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,strong) UIProgressView *progress;
@property(nonatomic,strong) UIView *errorPanel;
@end
@implementation WebController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AllPredictor";
    self.view.backgroundColor = UIColor.blackColor;
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    config.allowsInlineMediaPlayback = YES;
    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.web.translatesAutoresizingMaskIntoConstraints = NO;
    self.web.navigationDelegate = self; self.web.UIDelegate = self;
    self.web.allowsBackForwardNavigationGestures = YES;
    self.web.opaque = NO; self.web.backgroundColor = UIColor.blackColor;
    self.web.scrollView.backgroundColor = UIColor.blackColor;
    [self.view addSubview:self.web];
    [NSLayoutConstraint activateConstraints:@[
      [self.web.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      [self.web.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
      [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
      [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"] style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    self.navigationItem.rightBarButtonItems = @[
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(reloadPage)],
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"house"] style:UIBarButtonItemStylePlain target:self action:@selector(home)]];
    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;
    self.progress.progressTintColor = UIColor.systemOrangeColor;
    [self.view addSubview:self.progress];
    [NSLayoutConstraint activateConstraints:@[[self.progress.topAnchor constraintEqualToAnchor:self.web.topAnchor], [self.progress.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.progress.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    [self.web addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:NULL];
    [self home];
}
- (void)dealloc { [self.web removeObserver:self forKeyPath:@"estimatedProgress"]; }
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == self.web) { self.progress.progress = self.web.estimatedProgress; self.progress.hidden = self.web.estimatedProgress >= 1; }
    else { [super observeValueForKeyPath:path ofObject:object change:change context:context]; }
}
- (void)home { [self.errorPanel removeFromSuperview]; [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:HomeURL]]]; }
- (void)back { if (self.web.canGoBack) [self.web goBack]; }
- (void)reloadPage { [self.errorPanel removeFromSuperview]; if (self.web.URL) [self.web reload]; else [self home]; }
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation { [self.errorPanel removeFromSuperview]; self.progress.hidden = NO; }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { self.progress.hidden = YES; }
- (void)showError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    [self.errorPanel removeFromSuperview]; self.progress.hidden = YES;
    UIView *panel = [UIView new]; panel.backgroundColor = UIColor.blackColor; panel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:panel]; self.errorPanel = panel;
    [NSLayoutConstraint activateConstraints:@[[panel.topAnchor constraintEqualToAnchor:self.web.topAnchor], [panel.bottomAnchor constraintEqualToAnchor:self.web.bottomAnchor], [panel.leadingAnchor constraintEqualToAnchor:self.web.leadingAnchor], [panel.trailingAnchor constraintEqualToAnchor:self.web.trailingAnchor]]];
    UILabel *label = [UILabel new]; label.text = @"Не удалось открыть сайт.\nПроверьте интернет и попробуйте снова."; label.numberOfLines = 0; label.textAlignment = NSTextAlignmentCenter; label.textColor = UIColor.whiteColor;
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem]; [retry setTitle:@"Повторить" forState:UIControlStateNormal]; retry.tintColor = UIColor.systemOrangeColor; [retry addTarget:self action:@selector(reloadPage) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, retry]]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = NO; [panel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor], [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:24], [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-24]]];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self showError:error]; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self showError:error]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [webView reload]; }
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL; NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"about"] || [scheme isEqualToString:@"blob"]) { decisionHandler(WKNavigationActionPolicyAllow); return; }
    decisionHandler(WKNavigationActionPolicyCancel);
    if ([@[@"tg", @"mailto", @"tel"] containsObject:scheme]) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame) [webView loadRequest:action.request]; return nil;
}
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AllPredictor" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ completionHandler(); }]]; [self presentViewController:alert animated:YES completion:nil];
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AllPredictor" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a){ completionHandler(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ completionHandler(YES); }]]; [self presentViewController:alert animated:YES completion:nil];
}
@end
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[WebController new]];
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new]; [appearance configureWithOpaqueBackground]; appearance.backgroundColor = UIColor.blackColor; appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    nav.navigationBar.standardAppearance = appearance; nav.navigationBar.scrollEdgeAppearance = appearance; nav.navigationBar.tintColor = UIColor.systemOrangeColor;
    self.window.rootViewController = nav; [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); } }
