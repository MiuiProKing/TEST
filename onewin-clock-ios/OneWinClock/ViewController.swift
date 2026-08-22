import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let startURL = URL(string: "https://1w-ftend.life/")!
    private var webView: WKWebView!
    private let clockLabel = UILabel()
    private var timer: Timer?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .current
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = true
        view.addSubview(webView)

        let clockBar = UIView()
        clockBar.translatesAutoresizingMaskIntoConstraints = false
        clockBar.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        clockBar.layer.cornerRadius = 6
        clockBar.clipsToBounds = true
        clockBar.isUserInteractionEnabled = false
        view.addSubview(clockBar)

        clockLabel.translatesAutoresizingMaskIntoConstraints = false
        clockLabel.textAlignment = .center
        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        clockLabel.textColor = .white
        clockLabel.adjustsFontSizeToFitWidth = true
        clockLabel.minimumScaleFactor = 0.8
        clockBar.addSubview(clockLabel)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            clockBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            clockBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            clockBar.widthAnchor.constraint(equalToConstant: 78),
            clockBar.heightAnchor.constraint(equalToConstant: 18),

            clockLabel.leadingAnchor.constraint(equalTo: clockBar.leadingAnchor, constant: 4),
            clockLabel.trailingAnchor.constraint(equalTo: clockBar.trailingAnchor, constant: -4),
            clockLabel.topAnchor.constraint(equalTo: clockBar.topAnchor),
            clockLabel.bottomAnchor.constraint(equalTo: clockBar.bottomAnchor)
        ])

        updateClock()
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateClock), userInfo: nil, repeats: true)
        if let timer { RunLoop.main.add(timer, forMode: .common) }

        var request = URLRequest(url: startURL)
        request.cachePolicy = .reloadRevalidatingCacheData
        webView.load(request)
    }

    deinit { timer?.invalidate() }

    @objc private func updateClock() {
        clockLabel.text = formatter.string(from: Date())
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error.localizedDescription)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Не удалось открыть страницу", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Повторить", style: .default) { [weak self] _ in
            guard let self else { return }
            self.webView.load(URLRequest(url: self.startURL))
        })
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        if presentedViewController == nil { present(alert, animated: true) }
    }
}
