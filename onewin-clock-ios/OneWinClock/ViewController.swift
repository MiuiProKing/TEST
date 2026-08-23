import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let api = URL(string: "https://crash-gateway-grm-cr.100hp.app/history")!
    private let customerID = "077dee8d-c923-4c02-9bee-757573662e69"
    private let sessionID = "783ee79a-dafc-479e-bf22-834336380cdf"
    private let allPredictorURL = URL(string: "https://miuiproking.github.io/luckyjet-telegram-mini-app/index.html?v=20260823-2")!
    private let gameURL = URL(string: "https://1w-ftend.life/")!
    private let selectedTabKey = "onewinclock.selectedTab.v2"

    private let processPool = WKProcessPool()
    private let tabs = UISegmentedControl(items: ["BABEL", "ПРОГНОЗЫ", "1WIN"])
    private let modeControl = UISegmentedControl(items: ["PETIT", "GRID", "GRAND", "10–100x", "AUTO"])
    private let status = UILabel()
    private let output = UITextView()
    private let signalButton = UIButton(type: .system)
    private let checkButton = UIButton(type: .system)
    private let clockLabel = UILabel()
    private let liveLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let webContainer = UIView()

    private var allPredictorWebView: WKWebView!
    private var gameWebView: WKWebView!
    private var currentMode = 4
    private var clockTimer: Timer?
    private var liveTimer: Timer?
    private var liveRequestInFlight = false
    private var latestHistory: [Double] = []

    private lazy var clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: "Europe/Kyiv")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true
        buildUI()
        buildPersistentWebViews()
        installLifecycleObservers()
        startTimers()

        let savedTab = UserDefaults.standard.integer(forKey: selectedTabKey)
        tabs.selectedSegmentIndex = (0...2).contains(savedTab) ? savedTab : 0
        applySelectedTab()
    }

    deinit {
        clockTimer?.invalidate()
        liveTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func buildUI() {
        let topBar = UIStackView(arrangedSubviews: [clockLabel, liveLabel, backButton, reloadButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        clockLabel.textColor = .white
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .bold)
        clockLabel.setContentHuggingPriority(.required, for: .horizontal)

        liveLabel.text = "LIVE —"
        liveLabel.textAlignment = .center
        liveLabel.textColor = .systemGreen
        liveLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        liveLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)
        liveLabel.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.42).cgColor
        liveLabel.layer.borderWidth = 1
        liveLabel.layer.cornerRadius = 9
        liveLabel.clipsToBounds = true
        liveLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        backButton.setTitle("‹", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 25, weight: .bold)
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        backButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

        reloadButton.setTitle("↻", for: .normal)
        reloadButton.titleLabel?.font = .systemFont(ofSize: 21, weight: .bold)
        reloadButton.addTarget(self, action: #selector(reloadSelectedPage), for: .touchUpInside)
        reloadButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

        tabs.selectedSegmentIndex = 0
        tabs.addTarget(self, action: #selector(tabChanged(_:)), for: .valueChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabs)

        modeControl.selectedSegmentIndex = 4
        modeControl.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeControl)

        status.text = "● BABEL • готов"
        status.textColor = .systemGreen
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        signalButton.setTitle("🎯 ПОЛУЧИТЬ СИГНАЛ", for: .normal)
        signalButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        signalButton.backgroundColor = .systemGreen
        signalButton.setTitleColor(.black, for: .normal)
        signalButton.layer.cornerRadius = 12
        signalButton.addTarget(self, action: #selector(getSignal), for: .touchUpInside)
        signalButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(signalButton)

        checkButton.setTitle("🧪 ПРОВЕРИТЬ ПОДКЛЮЧЕНИЕ", for: .normal)
        checkButton.addTarget(self, action: #selector(checkConnection), for: .touchUpInside)
        checkButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(checkButton)

        output.backgroundColor = UIColor(white: 0.06, alpha: 1)
        output.textColor = .white
        output.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        output.isEditable = false
        output.layer.cornerRadius = 12
        output.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(output)

        webContainer.backgroundColor = .black
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainer)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 3),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 34),
            liveLabel.heightAnchor.constraint(equalToConstant: 28),

            tabs.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 5),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            modeControl.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            modeControl.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            modeControl.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            status.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            signalButton.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            signalButton.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            signalButton.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            signalButton.heightAnchor.constraint(equalToConstant: 48),
            checkButton.topAnchor.constraint(equalTo: signalButton.bottomAnchor, constant: 5),
            checkButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            output.topAnchor.constraint(equalTo: checkButton.bottomAnchor, constant: 5),
            output.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            output.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            output.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),

            webContainer.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }

    private func buildPersistentWebViews() {
        allPredictorWebView = makeWebView()
        gameWebView = makeWebView()

        for webView in [allPredictorWebView!, gameWebView!] {
            webContainer.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
            ])
        }

        // Both pages are loaded exactly once and stay in the view hierarchy.
        // Using alpha instead of isHidden keeps their WebKit processes warm while switching tabs.
        allPredictorWebView.load(URLRequest(url: allPredictorURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        gameWebView.load(URLRequest(url: gameURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    private func installLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    private func startTimers() {
        updateClock()
        pollLiveCoefficient()
        clockTimer?.invalidate()
        liveTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateClock), userInfo: nil, repeats: true)
        liveTimer = Timer.scheduledTimer(timeInterval: 2.5, target: self, selector: #selector(pollLiveCoefficient), userInfo: nil, repeats: true)
        RunLoop.main.add(clockTimer!, forMode: .common)
        RunLoop.main.add(liveTimer!, forMode: .common)
    }

    @objc private func appDidBecomeActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        startTimers()
    }

    @objc private func appDidEnterBackground() {
        clockTimer?.invalidate()
        liveTimer?.invalidate()
    }

    @objc private func updateClock() {
        clockLabel.text = clockFormatter.string(from: Date())
    }

    @objc private func pollLiveCoefficient() {
        guard !liveRequestInFlight else { return }
        liveRequestInFlight = true
        requestHistory { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.liveRequestInFlight = false
                switch result {
                case .success(let values):
                    self.latestHistory = values
                    if let coefficient = values.first {
                        self.liveLabel.text = String(format: "LIVE %.2fx", coefficient)
                        self.liveLabel.textColor = coefficient >= 10 ? .systemRed : .systemGreen
                        self.liveLabel.backgroundColor = (coefficient >= 10 ? UIColor.systemRed : UIColor.systemGreen).withAlphaComponent(0.12)
                    }
                case .failure:
                    self.liveLabel.text = "LIVE —"
                    self.liveLabel.textColor = .systemOrange
                    self.liveLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
                }
            }
        }
    }

    @objc private func tabChanged(_ sender: UISegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: selectedTabKey)
        applySelectedTab()
    }

    private func applySelectedTab() {
        let isBabel = tabs.selectedSegmentIndex == 0
        let isAllPredictor = tabs.selectedSegmentIndex == 1

        modeControl.isHidden = !isBabel
        status.isHidden = !isBabel
        output.isHidden = !isBabel
        signalButton.isHidden = !isBabel
        checkButton.isHidden = !isBabel

        webContainer.alpha = isBabel ? 0.01 : 1
        webContainer.isUserInteractionEnabled = !isBabel
        webContainer.accessibilityElementsHidden = isBabel

        allPredictorWebView.alpha = isAllPredictor ? 1 : 0.01
        allPredictorWebView.isUserInteractionEnabled = isAllPredictor
        allPredictorWebView.accessibilityElementsHidden = !isAllPredictor

        let isGame = tabs.selectedSegmentIndex == 2
        gameWebView.alpha = isGame ? 1 : 0.01
        gameWebView.isUserInteractionEnabled = isGame
        gameWebView.accessibilityElementsHidden = !isGame

        if isAllPredictor { webContainer.bringSubviewToFront(allPredictorWebView) }
        if isGame { webContainer.bringSubviewToFront(gameWebView) }

        backButton.isEnabled = !isBabel && (selectedWebView?.canGoBack ?? false)
        reloadButton.isEnabled = !isBabel
    }

    private var selectedWebView: WKWebView? {
        if tabs.selectedSegmentIndex == 1 { return allPredictorWebView }
        if tabs.selectedSegmentIndex == 2 { return gameWebView }
        return nil
    }

    @objc private func goBack() {
        guard let webView = selectedWebView, webView.canGoBack else { return }
        webView.goBack()
    }

    @objc private func reloadSelectedPage() {
        selectedWebView?.reload()
    }

    @objc private func modeChanged(_ sender: UISegmentedControl) {
        currentMode = sender.selectedSegmentIndex
        output.text = "Режим переключён: \(sender.titleForSegment(at: currentMode) ?? "")\nНажми «ПОЛУЧИТЬ СИГНАЛ»."
    }

    @objc private func checkConnection() {
        requestHistory { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let values):
                    self.latestHistory = values
                    self.status.text = "● LIVE • получено \(values.count) раундов"
                    self.status.textColor = .systemGreen
                    self.output.text = "✅ Подключение работает\nПоследние: " + values.prefix(12).map { String(format: "%.2fx", $0) }.joined(separator: " • ")
                case .failure(let error):
                    self.status.text = "● ошибка подключения"
                    self.status.textColor = .systemRed
                    self.output.text = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func getSignal() {
        status.text = "● анализ LIVE…"
        if !latestHistory.isEmpty {
            render(latestHistory)
            return
        }
        requestHistory { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let values):
                    self.latestHistory = values
                    self.render(values)
                case .failure(let error):
                    self.output.text = "❌ Ошибка: \(error.localizedDescription)"
                }
            }
        }
    }

    private func requestHistory(completion: @escaping (Result<[Double], Error>) -> Void) {
        var request = URLRequest(url: api)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(customerID, forHTTPHeaderField: "customer-id")
        request.setValue(sessionID, forHTTPHeaderField: "session-id")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                completion(.failure(NSError(domain: "BABEL", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "LuckyJet API HTTP \(response.statusCode)"])))
                return
            }
            guard let data else {
                completion(.failure(NSError(domain: "BABEL", code: 2, userInfo: [NSLocalizedDescriptionKey: "LuckyJet API не вернул данные"])))
                return
            }
            do {
                let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
                var values: [Double] = []
                for row in raw {
                    var coefficient = Self.num(row["topCoefficient"])
                    if coefficient == nil, let finals = row["finalValues"] as? [Any] {
                        for value in finals.reversed() {
                            if let number = Self.num(value) {
                                coefficient = number
                                break
                            }
                        }
                    }
                    if let coefficient, coefficient > 0 {
                        values.append(coefficient == 1 ? 1.01 : coefficient)
                    }
                }
                if values.isEmpty {
                    throw NSError(domain: "BABEL", code: 1, userInfo: [NSLocalizedDescriptionKey: "История LuckyJet пустая"])
                }
                completion(.success(values))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func num(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    private func rate(_ values: [Double], _ predicate: (Double) -> Bool) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter(predicate).count) / Double(values.count)
    }

    private func gap(_ values: [Double], _ target: Double) -> Int {
        values.firstIndex(where: { $0 >= target }) ?? values.count
    }

    private func timeScore() -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .current
        let date = Date()
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let goodHour = (1...2).contains(hour) || (11...13).contains(hour) || (16...19).contains(hour) || (21...23).contains(hour)
        let goodMinute = (minute >= 59 || minute <= 2) || (4...10).contains(minute) || (13...20).contains(minute) || (27...33).contains(minute) || (45...47).contains(minute) || (50...52).contains(minute) || (55...59).contains(minute)
        return goodHour && goodMinute ? 1 : goodMinute ? 0.72 : goodHour ? 0.55 : 0.20
    }

    private func render(_ values: [Double]) {
        let recent20 = Array(values.prefix(20))
        let recent50 = Array(values.prefix(50))
        let recent100 = Array(values.prefix(100))
        let p2 = rate(recent50) { $0 >= 2 }
        let p5 = rate(recent50) { $0 >= 5 }
        let p10 = rate(recent100) { $0 >= 10 }
        let p20 = rate(recent100) { $0 >= 20 }
        let low = rate(recent20) { $0 < 1.5 }
        let gap10 = gap(values, 10)
        let gap20 = gap(values, 20)
        let gap50 = gap(values, 50)
        let clipped = recent50.map { min($0, 50) }
        let average = clipped.reduce(0, +) / Double(max(clipped.count, 1))
        let volatility = sqrt(clipped.map { pow($0 - average, 2) }.reduce(0, +) / Double(max(clipped.count, 1))) / max(average, 1)
        let timing = timeScore()

        var under5 = 0
        for value in values { if value < 5 { under5 += 1 } else { break } }
        var lowStreak = 0
        for value in values { if value < 2 { lowStreak += 1 } else { break } }

        let gapPressure = clamp(Double(gap10) / 14, 0, 1) * 0.42 + clamp(Double(gap20) / 30, 0, 1) * 0.28 + clamp(Double(gap50) / 80, 0, 1) * 0.10
        let burst = clamp(p5 / 0.22, 0, 1) * 0.55 + clamp(p10 / 0.11, 0, 1) * 0.30 + clamp(p20 / 0.05, 0, 1) * 0.15
        let power = clamp(gapPressure * 0.32 + burst * 0.22 + 0.33 * 0.18 + clamp(volatility / 1.25, 0, 1) * 0.14 + clamp(Double(under5) / 8, 0, 1) * 0.08 + timing * 0.06, 0, 1)
        let grand = clamp((15 + 35 * pow(power, 1.28)) * 0.82 + 25.48 * 0.18, 15, 50)
        let middle = rate(recent50) { $0 >= 3 && $0 < 10 }
        let insuranceStrength = clamp(clamp(middle / 0.28, 0, 1) * 0.34 + (1 - clamp(abs(volatility - 0.72) / 0.90, 0, 1)) * 0.22 + clamp(Double(lowStreak) / 5, 0, 1) * 0.18 + 0.33 * 0.18 + timing * 0.08, 0, 1)
        let insurance = clamp((4.2 + insuranceStrength * 1.3) * 0.86 + 4.86 * 0.14, 4.2, 5.5)
        let quality = clamp((1 - abs(power - insuranceStrength)) * 0.30 + 0.33 * 0.18 + (1 - clamp(abs(p2 - 0.42) / 0.42, 0, 1)) * 0.14 + timing * 0.10 + clamp(p5 / 0.25, 0, 1) * 0.10, 0, 1)
        let confidence = Int(round(clamp((58 + quality * 21) * 0.90 + 73 * 0.10, 58, 79)))
        let petitStrength = clamp(clamp(p2 / 0.55, 0, 1) * 0.34 + (1 - clamp(volatility / 1.20, 0, 1)) * 0.25 + clamp(Double(lowStreak) / 4, 0, 1) * 0.20 + (1 - clamp(low / 0.50, 0, 1)) * 0.13 + timing * 0.08, 0, 1)
        let petit = clamp((1.5 + petitStrength * 0.78) * 0.82 + 2.062 * 0.18, 1.5, 2.35)
        let petitConfidence = Int(round(clamp((51 + petitStrength * 15) * 0.90 + 57 * 0.10, 51, 67)))
        let mode = currentMode == 4 ? (power >= 0.52 ? 2 : 0) : currentMode
        var text = ""

        if mode == 0 {
            text = String(format: "🚀 BABEL — PETIT LIVE\n\n🎯 Цель: %.2fx\n⚡ Уверенность: %d%%\n📊 Сила PETIT: %.3f", petit, petitConfidence, petitStrength)
        } else if mode == 1 {
            let targets = [2.00, 2.17, 2.05, 2.28, 2.12, 2.21, 2.03, 2.30, 2.14, 2.08, 2.25, 2.10, 2.19, 2.06, 2.23, 2.01, 2.27, 2.13, 2.09, 2.29, 2.16, 2.04]
            let slot = Int(Date().timeIntervalSince1970 / 130) % 22
            text = String(format: "🟢 BABEL — PETIT GRID\n\n🎯 Цель: %.2fx\n🔢 Позиция: %d/22\n⏱ Шаг сетки: 130 сек.", targets[slot], slot + 1)
        } else if mode == 2 {
            text = String(format: "🎯 BABEL — GRAND + СТРАХОВКА\n\n🎯 Основная цель: %.2fx\n🛡 Страховка: %.2fx\n⚡ Уверенность: %d%%\n📈 Сила GRAND: %.3f\n10x / 20x не было: %d / %d раундов", grand, insurance, confidence, power, gap10, gap20)
        } else {
            let allowed = timing >= 0.72
            text = allowed
                ? String(format: "🔥 BABEL — GROSSE CÔTE PRO\n\n🎯 Диапазон: 10x–100x\n⚡ Уверенность: %d%%\n📈 Сила: %.3f\nПосле 10x / 20x / 50x: %d / %d / %d", confidence, power, gap10, gap20, gap50)
                : String(format: "🔥 BABEL — GROSSE CÔTE 10–100x\n\n⏳ Сейчас ожидаем разрешённое временное окно.\n⚡ Оценка: %d%%\nПосле 10x: %d раундов", confidence, gap10)
        }

        if currentMode == 4 {
            text = "🧠 BABEL AUTO\n🤖 Автовыбор движка\n━━━━━━━━━━━━━━━\n" + text
        }
        text += "\n\nПоследние:\n" + values.prefix(12).map { String(format: "%.2fx", $0) }.joined(separator: " • ")
        output.text = text
        status.text = "● LIVE • анализ завершён"
        status.textColor = .systemGreen
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === selectedWebView { backButton.isEnabled = webView.canGoBack }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showWebError(error, for: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showWebError(error, for: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showWebError(_ error: Error, for webView: WKWebView) {
        guard webView === selectedWebView else { return }
        liveLabel.text = "СЕТЬ ⚠︎"
        liveLabel.textColor = .systemOrange
        liveLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, animated: true)
    }
}
