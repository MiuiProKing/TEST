import UIKit
import WebKit
import AudioToolbox

private struct RoundSample: Codable, Equatable {
    let id: String
    let coefficient: Double
}

private enum EngineMode: Int, CaseIterable {
    case fusion
    case allPredictor
    case babelAuto
    case petit
    case petitGrid
    case grand
    case duo
    case aiPro
    case pro4
    case pro4Range
    case twoTime
    case bigTime
    case killer
    case montante
    case watch

    var title: String {
        switch self {
        case .fusion: return "🧠 FUSION AUTO"
        case .allPredictor: return "⚡ ALLPREDICTOR"
        case .babelAuto: return "🤖 BABEL AUTO"
        case .petit: return "🟢 BABEL PETIT"
        case .petitGrid: return "🔢 PETIT GRID 22"
        case .grand: return "🔴 GRAND + СТРАХОВКА"
        case .duo: return "🟣 BABEL DUO"
        case .aiPro: return "🧬 AI PRO v6.1"
        case .pro4: return "🎯 BABEL PRO 4"
        case .pro4Range: return "🔥 PRO 4 RANGE"
        case .twoTime: return "🕒 BABEL 2X TIME"
        case .bigTime: return "🚀 10X–100X LIVE"
        case .killer: return "🧪 KILLER MONITOR"
        case .montante: return "📶 MONTANTE MONITOR"
        case .watch: return "📊 WATCH / РЫНОК"
        }
    }

    var key: String {
        switch self {
        case .fusion: return "fusion"
        case .allPredictor: return "allpredictor"
        case .babelAuto: return "babel_auto"
        case .petit: return "petit"
        case .petitGrid: return "petit_grid"
        case .grand: return "grand"
        case .duo: return "duo"
        case .aiPro: return "ai_pro"
        case .pro4: return "pro4"
        case .pro4Range: return "pro4_range"
        case .twoTime: return "two_time"
        case .bigTime: return "big_time"
        case .killer: return "killer"
        case .montante: return "montante"
        case .watch: return "watch"
        }
    }
}

private struct Forecast {
    let mode: EngineMode
    let title: String
    let target: Double?
    let insurance: Double?
    let confidence: Int
    let waitRounds: Int
    let attempts: Int
    let ready: Bool
    let reason: String
    let detail: String
}

private struct BotStats: Codable {
    var wins = 0
    var insuranceWins = 0
    var losses = 0

    var total: Int { wins + insuranceWins + losses }
    var successRate: Int {
        guard total > 0 else { return 0 }
        return Int(round(Double(wins + insuranceWins) / Double(total) * 100))
    }
}

private struct PendingSignal {
    let mode: EngineMode
    let target: Double
    let insurance: Double?
    var waitRemaining: Int
    var attemptsRemaining: Int
    let attemptsTotal: Int
    var maxObserved: Double
}

private struct PatternStats {
    let low: Double
    let middle: Double
    let high: Double
    let support: Int
}

private struct MarketMetrics {
    let average: Double
    let volatility: Double
    let p2: Double
    let p3: Double
    let p5: Double
    let p10: Double
    let p20: Double
    let middle3to10: Double
    let lowUnder15: Double
    let lowStreak: Int
    let under5Streak: Int
    let gap5: Int
    let gap10: Int
    let gap20: Int
    let gap50: Int
    let patternHigh: Double
    let patternSupport: Int
    let timeScore: Double
}

private struct FusionEstimate {
    let raw: Double
    let baseline: Double
    let recent: Double
    let pattern: Double
    let context: Double
    let patternSupport: Int
    let contextSupport: Int
    let gap10: Int
    let medianGap10: Double
    let intervalProximity: Double
    let volatility: Double
}

private struct FusionCandidate {
    let name: String
    let target: Double
    let insurance: Double?
    let horizon: Int
    let waitRounds: Int
    let probability: Double
    let baseline: Double
    let quality: Double
    let ready: Bool
    let reason: String
}

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let api = URL(string: "https://crash-gateway-grm-cr.100hp.app/history")!
    private let customerID = "077dee8d-c923-4c02-9bee-757573662e69"
    private let sessionID = "783ee79a-dafc-479e-bf22-834336380cdf"
    private let allPredictorURL = URL(string: "https://miuiproking.github.io/luckyjet-telegram-mini-app/index.html?v=20260823-3")!
    private let gameURL = URL(string: "https://1w-ftend.life/")!

    private let selectedTabKey = "onewinclock.selectedTab.v3"
    private let selectedModeKey = "onewinclock.selectedMode.v3"
    private let autoBotKey = "onewinclock.autoBot.v3"
    private let statsKey = "onewinclock.botStats.v3"
    private let roundCacheKey = "onewinclock.roundCache.v3"
    private let soundKey = "onewinclock.signalSound.v3"

    private let processPool = WKProcessPool()
    private let tabs = UISegmentedControl(items: ["BABEL", "ПРОГНОЗЫ", "1WIN"])
    private let modeButton = UIButton(type: .system)
    private let status = UILabel()
    private let output = UITextView()
    private let signalButton = UIButton(type: .system)
    private let autoButton = UIButton(type: .system)
    private let soundButton = UIButton(type: .system)
    private let checkButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let clockLabel = UILabel()
    private let liveLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let webContainer = UIView()
    private let botActions = UIStackView()

    private var allPredictorWebView: WKWebView!
    private var gameWebView: WKWebView!
    private var currentMode: EngineMode = .fusion
    private var autoBotEnabled = true
    private var soundEnabled = true
    private var clockTimer: Timer?
    private var liveTimer: Timer?
    private var liveRequestInFlight = false
    private var latestRounds: [RoundSample] = []
    private var lastProcessedRoundID: String?
    private var pendingSignal: PendingSignal?
    private var botStats: [String: BotStats] = [:]
    private var activityLog: [String] = []
    private var lastSettlement = ""

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

        loadSavedState()
        buildUI()
        buildPersistentWebViews()
        installLifecycleObservers()
        startTimers()

        let savedTab = UserDefaults.standard.integer(forKey: selectedTabKey)
        tabs.selectedSegmentIndex = (0...2).contains(savedTab) ? savedTab : 0
        applySelectedTab()
        renderWelcome()
    }

    deinit {
        clockTimer?.invalidate()
        liveTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func loadSavedState() {
        let savedMode = UserDefaults.standard.integer(forKey: selectedModeKey)
        currentMode = EngineMode(rawValue: savedMode) ?? .fusion
        if UserDefaults.standard.object(forKey: autoBotKey) != nil {
            autoBotEnabled = UserDefaults.standard.bool(forKey: autoBotKey)
        }
        if UserDefaults.standard.object(forKey: soundKey) != nil {
            soundEnabled = UserDefaults.standard.bool(forKey: soundKey)
        }
        if let data = UserDefaults.standard.data(forKey: statsKey),
           let saved = try? JSONDecoder().decode([String: BotStats].self, from: data) {
            botStats = saved
        }
        if let data = UserDefaults.standard.data(forKey: roundCacheKey),
           let saved = try? JSONDecoder().decode([RoundSample].self, from: data) {
            latestRounds = Array(saved.prefix(500))
        }
    }

    private func saveStats() {
        if let data = try? JSONEncoder().encode(botStats) {
            UserDefaults.standard.set(data, forKey: statsKey)
        }
    }

    private func saveRoundCache() {
        if let data = try? JSONEncoder().encode(Array(latestRounds.prefix(500))) {
            UserDefaults.standard.set(data, forKey: roundCacheKey)
        }
    }

    @discardableResult
    private func mergeHistory(_ fetched: [RoundSample]) -> [RoundSample] {
        let fetchedIDs = Set(fetched.map(\.id))
        latestRounds = Array((fetched + latestRounds.filter { !fetchedIDs.contains($0.id) }).prefix(500))
        saveRoundCache()
        return latestRounds
    }

    private func buildUI() {
        let topBar = UIStackView(arrangedSubviews: [clockLabel, liveLabel, backButton, reloadButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        clockLabel.textColor = .white
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .heavy)
        clockLabel.setContentHuggingPriority(.required, for: .horizontal)

        liveLabel.text = "LIVE —"
        liveLabel.textAlignment = .center
        liveLabel.textColor = .black
        liveLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .heavy)
        liveLabel.backgroundColor = UIColor(red: 0.72, green: 1.0, blue: 0.18, alpha: 1)
        liveLabel.layer.borderColor = UIColor.white.cgColor
        liveLabel.layer.borderWidth = 2
        liveLabel.layer.cornerRadius = 9
        liveLabel.clipsToBounds = true
        liveLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        backButton.setTitle("‹", for: .normal)
        backButton.setTitleColor(.black, for: .normal)
        backButton.backgroundColor = .white
        backButton.layer.cornerRadius = 9
        backButton.titleLabel?.font = .systemFont(ofSize: 25, weight: .bold)
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        backButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

        reloadButton.setTitle("↻", for: .normal)
        reloadButton.setTitleColor(.black, for: .normal)
        reloadButton.backgroundColor = .white
        reloadButton.layer.cornerRadius = 9
        reloadButton.titleLabel?.font = .systemFont(ofSize: 21, weight: .bold)
        reloadButton.addTarget(self, action: #selector(reloadSelectedPage), for: .touchUpInside)
        reloadButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

        tabs.selectedSegmentIndex = 0
        tabs.backgroundColor = .white
        tabs.selectedSegmentTintColor = UIColor(red: 1.0, green: 0.77, blue: 0.06, alpha: 1)
        tabs.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 14, weight: .heavy)
        ], for: .normal)
        tabs.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 15, weight: .black)
        ], for: .selected)
        tabs.layer.borderWidth = 2
        tabs.layer.borderColor = UIColor.white.cgColor
        tabs.layer.cornerRadius = 11
        tabs.clipsToBounds = true
        tabs.addTarget(self, action: #selector(tabChanged(_:)), for: .valueChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabs)

        modeButton.backgroundColor = UIColor(red: 1.0, green: 0.83, blue: 0.10, alpha: 1)
        modeButton.setTitleColor(.black, for: .normal)
        modeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .black)
        modeButton.layer.borderWidth = 2
        modeButton.layer.borderColor = UIColor.white.cgColor
        modeButton.layer.cornerRadius = 11
        modeButton.showsMenuAsPrimaryAction = true
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeButton)
        rebuildModeMenu()

        status.text = "● BABEL LIVE • подключение…"
        status.textColor = .systemOrange
        status.font = .systemFont(ofSize: 13, weight: .bold)
        status.numberOfLines = 1
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        signalButton.setTitle("🎯 СИГНАЛ СЕЙЧАС", for: .normal)
        signalButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        signalButton.backgroundColor = .systemGreen
        signalButton.setTitleColor(.black, for: .normal)
        signalButton.layer.cornerRadius = 12
        signalButton.addTarget(self, action: #selector(getSignal), for: .touchUpInside)
        signalButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(signalButton)

        configureSmallButton(autoButton, title: "АВТО: ВКЛ", selector: #selector(toggleAutoBot))
        configureSmallButton(soundButton, title: "🔊 ЗВУК", selector: #selector(toggleSound))
        configureSmallButton(checkButton, title: "API", selector: #selector(checkConnection))
        configureSmallButton(resetButton, title: "СБРОС", selector: #selector(resetStatistics))
        botActions.axis = .horizontal
        botActions.distribution = .fillEqually
        botActions.spacing = 5
        botActions.addArrangedSubview(autoButton)
        botActions.addArrangedSubview(soundButton)
        botActions.addArrangedSubview(checkButton)
        botActions.addArrangedSubview(resetButton)
        botActions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(botActions)
        updateAutoButton()
        updateSoundButton()
        checkButton.backgroundColor = .white
        checkButton.setTitleColor(.black, for: .normal)
        resetButton.backgroundColor = .systemOrange
        resetButton.setTitleColor(.black, for: .normal)

        output.backgroundColor = UIColor(white: 0.055, alpha: 1)
        output.textColor = .white
        output.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        output.isEditable = false
        output.isSelectable = true
        output.alwaysBounceVertical = true
        output.textContainerInset = UIEdgeInsets(top: 13, left: 11, bottom: 13, right: 11)
        output.layer.cornerRadius = 12
        output.layer.borderWidth = 1
        output.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        output.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(output)

        webContainer.backgroundColor = .black
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainer)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 3),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 38),
            liveLabel.heightAnchor.constraint(equalToConstant: 32),

            tabs.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 5),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabs.heightAnchor.constraint(equalToConstant: 44),

            modeButton.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 9),
            modeButton.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            modeButton.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            modeButton.heightAnchor.constraint(equalToConstant: 46),

            status.topAnchor.constraint(equalTo: modeButton.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),

            signalButton.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            signalButton.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            signalButton.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            signalButton.heightAnchor.constraint(equalToConstant: 48),

            botActions.topAnchor.constraint(equalTo: signalButton.bottomAnchor, constant: 7),
            botActions.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            botActions.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            botActions.heightAnchor.constraint(equalToConstant: 40),

            output.topAnchor.constraint(equalTo: botActions.bottomAnchor, constant: 7),
            output.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            output.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            output.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),

            webContainer.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureSmallButton(_ button: UIButton, title: String, selector: Selector) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 10, weight: .black)
        button.backgroundColor = UIColor(white: 0.11, alpha: 1)
        button.layer.cornerRadius = 9
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.white.cgColor
        button.addTarget(self, action: selector, for: .touchUpInside)
    }

    private func rebuildModeMenu() {
        let actions = EngineMode.allCases.map { mode in
            UIAction(
                title: mode.title,
                state: mode == currentMode ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.currentMode = mode
                UserDefaults.standard.set(mode.rawValue, forKey: self.selectedModeKey)
                self.rebuildModeMenu()
                self.renderCurrentMode(armSignal: false, origin: "режим выбран")
            }
        }
        modeButton.setTitle("\(currentMode.title)  ▾", for: .normal)
        modeButton.menu = UIMenu(
            title: "15 режимов из присланных версий",
            options: .singleSelection,
            children: actions
        )
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

        // Обе страницы загружаются один раз и остаются живыми при переключении вкладок.
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
        if let clockTimer { RunLoop.main.add(clockTimer, forMode: .common) }
        if let liveTimer { RunLoop.main.add(liveTimer, forMode: .common) }
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
                case .success(let rounds):
                    self.acceptLiveRounds(rounds)
                case .failure:
                    self.liveLabel.text = "LIVE —"
                    self.liveLabel.textColor = .black
                    self.liveLabel.backgroundColor = .systemOrange
                    self.status.text = "● LuckyJet API • повтор подключения…"
                    self.status.textColor = .systemOrange
                }
            }
        }
    }

    private func acceptLiveRounds(_ fetched: [RoundSample]) {
        guard let newest = fetched.first else { return }
        let rounds = mergeHistory(fetched)
        liveLabel.text = String(format: "LIVE %.2fx", newest.coefficient)
        liveLabel.textColor = .black
        liveLabel.backgroundColor = newest.coefficient >= 10
            ? UIColor(red: 1.0, green: 0.24, blue: 0.18, alpha: 1)
            : UIColor(red: 0.72, green: 1.0, blue: 0.18, alpha: 1)
        let autoState = autoBotEnabled ? "ВКЛ" : "ВЫКЛ"
        status.text = "● LuckyJet LIVE • \(rounds.count) раундов • авто \(autoState)"
        status.textColor = .white

        guard let previousID = lastProcessedRoundID else {
            lastProcessedRoundID = newest.id
            recordEvent("LIVE подключён: \(rounds.count) раундов")
            if autoBotEnabled {
                renderCurrentMode(armSignal: true, origin: "автостарт")
            } else {
                renderCurrentMode(armSignal: false, origin: "LIVE")
            }
            return
        }

        guard newest.id != previousID else { return }
        let newRounds: [RoundSample]
        if let previousIndex = rounds.firstIndex(where: { $0.id == previousID }), previousIndex > 0 {
            newRounds = Array(rounds[..<previousIndex]).reversed()
        } else {
            newRounds = [newest]
        }

        for round in newRounds {
            settlePendingSignal(with: round)
        }
        lastProcessedRoundID = newest.id

        if autoBotEnabled && pendingSignal == nil {
            renderCurrentMode(armSignal: true, origin: "новый раунд")
        } else {
            renderCurrentMode(armSignal: false, origin: "обновление")
        }
    }

    @objc private func tabChanged(_ sender: UISegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: selectedTabKey)
        applySelectedTab()
    }

    private func applySelectedTab() {
        let isBabel = tabs.selectedSegmentIndex == 0
        let isAllPredictor = tabs.selectedSegmentIndex == 1

        modeButton.isHidden = !isBabel
        status.isHidden = !isBabel
        output.isHidden = !isBabel
        signalButton.isHidden = !isBabel
        botActions.isHidden = !isBabel

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

    @objc private func toggleAutoBot() {
        autoBotEnabled.toggle()
        UserDefaults.standard.set(autoBotEnabled, forKey: autoBotKey)
        updateAutoButton()
        recordEvent("Автобот \(autoBotEnabled ? "включён" : "выключен")")
        if autoBotEnabled && !latestRounds.isEmpty && pendingSignal == nil {
            renderCurrentMode(armSignal: true, origin: "автобот включён")
        } else {
            renderCurrentMode(armSignal: false, origin: "настройка")
        }
    }

    private func updateAutoButton() {
        autoButton.setTitle(autoBotEnabled ? "АВТО: ВКЛ" : "АВТО: ВЫКЛ", for: .normal)
        autoButton.setTitleColor(autoBotEnabled ? .black : .white, for: .normal)
        autoButton.backgroundColor = autoBotEnabled ? .systemGreen : UIColor(white: 0.11, alpha: 1)
    }

    @objc private func toggleSound() {
        soundEnabled.toggle()
        UserDefaults.standard.set(soundEnabled, forKey: soundKey)
        updateSoundButton()
        recordEvent("Звук сигнала \(soundEnabled ? "включён" : "выключен")")
        if soundEnabled {
            playSignalReadyAlert()
        }
        renderCurrentMode(armSignal: false, origin: "настройка звука")
    }

    private func updateSoundButton() {
        soundButton.setTitle(soundEnabled ? "🔊 ВКЛ" : "🔇 ВЫКЛ", for: .normal)
        soundButton.setTitleColor(soundEnabled ? .black : .white, for: .normal)
        soundButton.backgroundColor = soundEnabled ? .systemCyan : UIColor(white: 0.11, alpha: 1)
    }

    private func playSignalReadyAlert() {
        guard soundEnabled else { return }
        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        feedback.notificationOccurred(.success)
        AudioServicesPlaySystemSound(SystemSoundID(1007))

        signalButton.setTitle("🚨 СИГНАЛ ГОТОВ", for: .normal)
        signalButton.backgroundColor = .systemRed
        signalButton.setTitleColor(.white, for: .normal)
        UIView.animateKeyframes(withDuration: 0.72, delay: 0, options: [.allowUserInteraction]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.34) {
                self.signalButton.transform = CGAffineTransform(scaleX: 1.035, y: 1.035)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.34, relativeDuration: 0.66) {
                self.signalButton.transform = .identity
            }
        }
    }

    @objc private func resetStatistics() {
        let alert = UIAlertController(title: "Сбросить статистику?", message: "Будут очищены победы, страховки и поражения всех режимов. LIVE-подключение не изменится.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Сбросить", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.botStats = [:]
            self.pendingSignal = nil
            self.lastSettlement = "Статистика очищена"
            self.activityLog = []
            self.saveStats()
            self.renderCurrentMode(armSignal: false, origin: "сброс")
        })
        present(alert, animated: true)
    }

    @objc private func checkConnection() {
        status.text = "● проверка LuckyJet API…"
        status.textColor = .systemOrange
        requestHistory { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let rounds):
                    let history = self.mergeHistory(rounds)
                    self.status.text = "● LIVE OK • API \(rounds.count), накоплено \(history.count)"
                    self.status.textColor = .systemGreen
                    let values = history.prefix(14).map { String(format: "%.2fx", $0.coefficient) }.joined(separator: " • ")
                    self.output.text = "✅ LuckyJet подключён\n✅ session-id принят сервером\n✅ API вернул: \(rounds.count)\n✅ Накоплено в приложении: \(history.count)/500\n\nПоследние:\n\(values)\n\nRocket Queen не проверялась и не изменялась."
                case .failure(let error):
                    self.status.text = "● ошибка LuckyJet API"
                    self.status.textColor = .systemRed
                    self.output.text = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func getSignal() {
        guard !latestRounds.isEmpty else {
            status.text = "● получаю историю…"
            pollLiveCoefficient()
            return
        }
        renderCurrentMode(armSignal: true, origin: "ручной запрос")
    }

    private func renderWelcome() {
        output.text = """
        🚀 BABEL FUSION LIVE

        Подключаю историю LuckyJet и запускаю выбранный движок.

        • 15 режимов из 9 присланных Python-версий
        • новый раунд определяется по уникальному ID
        • коэффициенты обновляются каждые 2.5 секунды
        • сигнал проверяется в следующих завершённых раундах
        • при новом готовом сигнале звучит короткий звонок и вибрация
        • вкладки ПРОГНОЗЫ и 1WIN остаются загруженными

        KILLER и MONTANTE сохранены как мониторы: в исходниках для них нет опубликованной формулы, поэтому приложение не рисует выдуманные сигналы.
        """
    }

    private func requestHistory(completion: @escaping (Result<[RoundSample], Error>) -> Void) {
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
                let object = try JSONSerialization.jsonObject(with: data)
                let rawRows: [[String: Any]]
                if let rows = object as? [[String: Any]] {
                    rawRows = rows
                } else if let dictionary = object as? [String: Any] {
                    rawRows = ["history", "data", "results", "items", "rounds"]
                        .compactMap { dictionary[$0] as? [[String: Any]] }
                        .first ?? []
                } else {
                    rawRows = []
                }

                var rounds: [RoundSample] = []
                var seen = Set<String>()
                for (index, row) in rawRows.enumerated() {
                    var coefficient = Self.num(row["topCoefficient"])
                        ?? Self.num(row["coefficient"])
                        ?? Self.num(row["coef"])
                        ?? Self.num(row["multiplier"])
                    if coefficient == nil, let finals = row["finalValues"] as? [Any] {
                        for value in finals.reversed() {
                            if let number = Self.num(value) {
                                coefficient = number
                                break
                            }
                        }
                    }
                    guard var value = coefficient, value > 0 else { continue }
                    if value == 1 { value = 1.01 }

                    let identifier = Self.roundIdentifier(row, index: index, coefficient: value)
                    guard !seen.contains(identifier) else { continue }
                    seen.insert(identifier)
                    rounds.append(RoundSample(id: identifier, coefficient: value))
                }

                guard !rounds.isEmpty else {
                    throw NSError(domain: "BABEL", code: 1, userInfo: [NSLocalizedDescriptionKey: "История LuckyJet пустая или имеет неизвестный формат"])
                }
                completion(.success(rounds))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func roundIdentifier(_ row: [String: Any], index: Int, coefficient: Double) -> String {
        for key in ["id", "roundId", "round_id", "gameId", "game_id", "uuid", "hash", "createdAt", "created_at", "timestamp"] {
            if let value = row[key], let string = stringValue(value), !string.isEmpty {
                return string
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(format: "fallback-%d-%.4f", index, coefficient)
    }

    private static func stringValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func num(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private func settlePendingSignal(with round: RoundSample) {
        guard var pending = pendingSignal else { return }

        if pending.waitRemaining > 0 {
            pending.waitRemaining -= 1
            pendingSignal = pending
            recordEvent("\(pending.mode.title): ожидание, осталось \(pending.waitRemaining)")
            return
        }

        pending.maxObserved = max(pending.maxObserved, round.coefficient)
        let attempt = pending.attemptsTotal - pending.attemptsRemaining + 1
        if round.coefficient >= pending.target {
            var stats = botStats[pending.mode.key] ?? BotStats()
            stats.wins += 1
            botStats[pending.mode.key] = stats
            saveStats()
            lastSettlement = String(format: "✅ %@ подтверждён: %.2fx ≥ %.2fx (попытка %d/%d)", pending.mode.title, round.coefficient, pending.target, attempt, pending.attemptsTotal)
            recordEvent(lastSettlement)
            pendingSignal = nil
            return
        }

        pending.attemptsRemaining -= 1
        if pending.attemptsRemaining > 0 {
            pendingSignal = pending
            recordEvent(String(format: "⏳ %.2fx ниже цели %.2fx, осталось %d", round.coefficient, pending.target, pending.attemptsRemaining))
            return
        }

        var stats = botStats[pending.mode.key] ?? BotStats()
        if let insurance = pending.insurance, pending.maxObserved >= insurance {
            stats.insuranceWins += 1
            lastSettlement = String(format: "🛡 %@ — страховка %.2fx сработала, максимум %.2fx", pending.mode.title, insurance, pending.maxObserved)
        } else {
            stats.losses += 1
            lastSettlement = String(format: "❌ %@ не подтверждён, максимум %.2fx при цели %.2fx", pending.mode.title, pending.maxObserved, pending.target)
        }
        botStats[pending.mode.key] = stats
        saveStats()
        recordEvent(lastSettlement)
        pendingSignal = nil
    }

    private func recordEvent(_ text: String) {
        let entry = "\(clockFormatter.string(from: Date()))  \(text)"
        activityLog.insert(entry, at: 0)
        if activityLog.count > 8 { activityLog.removeLast(activityLog.count - 8) }
    }

    private func renderCurrentMode(armSignal: Bool, origin: String) {
        guard !latestRounds.isEmpty else {
            renderWelcome()
            return
        }
        let forecast = evaluate(currentMode, values: latestRounds.map(\.coefficient))
        if armSignal, pendingSignal == nil, forecast.ready, let target = forecast.target {
            pendingSignal = PendingSignal(
                mode: forecast.mode,
                target: target,
                insurance: forecast.insurance,
                waitRemaining: max(0, forecast.waitRounds),
                attemptsRemaining: max(1, forecast.attempts),
                attemptsTotal: max(1, forecast.attempts),
                maxObserved: 0
            )
            recordEvent(String(format: "%@ запущен: цель %.2fx", forecast.mode.title, target))
            playSignalReadyAlert()
        }
        render(forecast, origin: origin)
    }

    private func render(_ forecast: Forecast, origin: String) {
        var lines: [String] = [
            forecast.title,
            "━━━━━━━━━━━━━━━━━━━━",
            forecast.ready ? "✅ СТАТУС: ГОТОВ" : "⏳ СТАТУС: НАБЛЮДЕНИЕ"
        ]

        if let target = forecast.target {
            lines.append(String(format: "🎯 Цель: %.2fx", target))
        } else {
            lines.append("🎯 Цель: не создаётся")
        }
        if let insurance = forecast.insurance {
            lines.append(String(format: "🛡 Страховка: %.2fx", insurance))
        }
        lines.append("⚡ Оценка: \(forecast.confidence)%")
        if forecast.target != nil {
            lines.append("⏱ Вход: \(forecast.waitRounds == 0 ? "следующий раунд" : "через \(forecast.waitRounds) раунд(а)")")
            lines.append("🔎 Проверка: до \(forecast.attempts) раунд(а/ов)")
        }
        lines.append("\n📐 \(forecast.reason)")
        if !forecast.detail.isEmpty { lines.append("ℹ️ \(forecast.detail)") }

        if let pending = pendingSignal {
            lines.append("\n📡 АКТИВНЫЙ СИГНАЛ")
            lines.append(String(format: "%@ • цель %.2fx • ожидание %d • попыток %d", pending.mode.title, pending.target, pending.waitRemaining, pending.attemptsRemaining))
            signalButton.setTitle("🚨 СИГНАЛ АКТИВЕН", for: .normal)
            signalButton.backgroundColor = .systemRed
            signalButton.setTitleColor(.white, for: .normal)
        } else {
            lines.append("\n📡 Активного сигнала нет")
            signalButton.setTitle("🎯 СИГНАЛ СЕЙЧАС", for: .normal)
            signalButton.backgroundColor = .systemGreen
            signalButton.setTitleColor(.black, for: .normal)
        }

        let stats = botStats[currentMode.key] ?? BotStats()
        lines.append("\n📊 СТАТИСТИКА РЕЖИМА")
        lines.append("✅ \(stats.wins)  🛡 \(stats.insuranceWins)  ❌ \(stats.losses)  • \(stats.successRate)%")
        lines.append("🤖 Автобот: \(autoBotEnabled ? "ВКЛ" : "ВЫКЛ") • звук: \(soundEnabled ? "ВКЛ" : "ВЫКЛ") • \(origin)")

        if !lastSettlement.isEmpty {
            lines.append("\n\(lastSettlement)")
        }

        let recent = latestRounds.prefix(14).map { String(format: "%.2fx", $0.coefficient) }.joined(separator: " • ")
        lines.append("\nLIVE КОЭФФИЦИЕНТЫ\n\(recent)")

        if !activityLog.isEmpty {
            lines.append("\nЖУРНАЛ\n" + activityLog.prefix(4).joined(separator: "\n"))
        }
        lines.append("\n⚠️ Статистическая модель, результат не гарантируется.")
        output.text = lines.joined(separator: "\n")
        status.text = "● LuckyJet LIVE • \(latestRounds.count) раундов • авто \(autoBotEnabled ? "ВКЛ" : "ВЫКЛ")"
        status.textColor = .white
    }

    private func evaluate(_ mode: EngineMode, values: [Double]) -> Forecast {
        switch mode {
        case .fusion: return fusionForecast(values)
        case .allPredictor: return allPredictorForecast(values)
        case .babelAuto: return babelAutoForecast(values)
        case .petit: return petitForecast(values)
        case .petitGrid: return petitGridForecast(values)
        case .grand: return grandForecast(values)
        case .duo: return duoForecast(values)
        case .aiPro: return aiProForecast(values)
        case .pro4: return pro4Forecast(values)
        case .pro4Range: return pro4RangeForecast(values)
        case .twoTime: return twoTimeForecast(values)
        case .bigTime: return bigTimeForecast(values)
        case .killer: return unavailableForecast(mode, reason: "В присланной версии функция KILLER намеренно отключена: подтверждённой формулы нет.")
        case .montante: return unavailableForecast(mode, reason: "В присланных версиях MONTANTE указан как отдельный бот, но его формула отсутствует.")
        case .watch: return watchForecast(values)
        }
    }

    private func unavailableForecast(_ mode: EngineMode, reason: String) -> Forecast {
        Forecast(mode: mode, title: mode.title, target: nil, insurance: nil, confidence: 0, waitRounds: 0, attempts: 0, ready: false, reason: reason, detail: "Режим следит за LIVE, но не создаёт выдуманную цель.")
    }

    private func waitingForecast(_ mode: EngineMode, reason: String) -> Forecast {
        Forecast(mode: mode, title: mode.title, target: nil, insurance: nil, confidence: 0, waitRounds: 0, attempts: 0, ready: false, reason: reason, detail: "Продолжаю собирать историю LIVE.")
    }

    private func marketMetrics(_ values: [Double]) -> MarketMetrics {
        let recent20 = Array(values.prefix(20))
        let recent50 = Array(values.prefix(50))
        let recent100 = Array(values.prefix(100))
        let clipped = recent50.map { min($0, 50) }
        let average = mean(clipped)
        let volatility = standardDeviation(clipped) / max(average, 1)
        let pattern = patternProbabilities(Array(values.prefix(160).reversed()))
        return MarketMetrics(
            average: average,
            volatility: volatility,
            p2: rate(recent50) { $0 >= 2 },
            p3: rate(recent50) { $0 >= 3 },
            p5: rate(recent50) { $0 >= 5 },
            p10: rate(recent100) { $0 >= 10 },
            p20: rate(recent100) { $0 >= 20 },
            middle3to10: rate(recent50) { $0 >= 3 && $0 < 10 },
            lowUnder15: rate(recent20) { $0 < 1.5 },
            lowStreak: streak(values) { $0 < 2 },
            under5Streak: streak(values) { $0 < 5 },
            gap5: gap(values, target: 5),
            gap10: gap(values, target: 10),
            gap20: gap(values, target: 20),
            gap50: gap(values, target: 50),
            patternHigh: pattern.high,
            patternSupport: pattern.support,
            timeScore: babelTimeScore()
        )
    }

    private func petitComponents(_ metrics: MarketMetrics) -> (target: Double, confidence: Int, strength: Double) {
        let lowMarket = clamp(metrics.lowUnder15 / 0.50, 0, 1)
        let p2 = clamp(metrics.p2 / 0.55, 0, 1)
        let calm = 1 - clamp(metrics.volatility / 1.20, 0, 1)
        let nearRecovery = clamp(Double(metrics.lowStreak) / 4, 0, 1)
        let strength = clamp(p2 * 0.34 + calm * 0.25 + nearRecovery * 0.20 + (1 - lowMarket) * 0.13 + metrics.timeScore * 0.08, 0, 1)
        let publicCenter = 1.88 * 0.30 + 2.14 * 0.70
        var target = (1.50 + strength * 0.78) * 0.82 + publicCenter * 0.18
        var confidence = (51 + strength * 15) * 0.90 + 57 * 0.10
        target = clamp(target, 1.50, 2.35)
        confidence = clamp(confidence, 51, 67)
        return (round2(target), Int(round(confidence)), strength)
    }

    private func grandComponents(_ metrics: MarketMetrics) -> (target: Double, insurance: Double, confidence: Int, power: Double, insuranceStrength: Double) {
        let gapPressure = clamp(Double(metrics.gap10) / 14, 0, 1) * 0.42
            + clamp(Double(metrics.gap20) / 30, 0, 1) * 0.28
            + clamp(Double(metrics.gap50) / 80, 0, 1) * 0.10
        let burst = clamp(metrics.p5 / 0.22, 0, 1) * 0.55
            + clamp(metrics.p10 / 0.11, 0, 1) * 0.30
            + clamp(metrics.p20 / 0.05, 0, 1) * 0.15
        let power = clamp(gapPressure * 0.32
            + burst * 0.22
            + clamp(metrics.patternHigh, 0, 1) * 0.18
            + clamp(metrics.volatility / 1.25, 0, 1) * 0.14
            + clamp(Double(metrics.under5Streak) / 8, 0, 1) * 0.08
            + metrics.timeScore * 0.06, 0, 1)
        let target = round2(clamp((15 + 35 * pow(power, 1.28)) * 0.82 + 25.48 * 0.18, 15, 50))

        let stable = 1 - clamp(abs(metrics.volatility - 0.72) / 0.90, 0, 1)
        let insuranceStrength = clamp(clamp(metrics.middle3to10 / 0.28, 0, 1) * 0.34
            + stable * 0.22
            + clamp(Double(metrics.lowStreak) / 5, 0, 1) * 0.18
            + clamp(metrics.patternHigh, 0, 1) * 0.18
            + metrics.timeScore * 0.08, 0, 1)
        let insurance = round2(clamp((4.20 + insuranceStrength * 1.30) * 0.86 + 4.86 * 0.14, 4.20, 5.50))

        let support = clamp(Double(metrics.patternSupport) / 6, 0, 1)
        let agreement = 1 - abs(power - insuranceStrength)
        let balance = 1 - clamp(abs(metrics.p2 - 0.42) / 0.42, 0, 1)
        let quality = clamp(agreement * 0.30 + support * 0.18 + metrics.patternHigh * 0.18 + balance * 0.14 + metrics.timeScore * 0.10 + clamp(metrics.p5 / 0.25, 0, 1) * 0.10, 0, 1)
        let confidence = Int(round(clamp((58 + quality * 21) * 0.90 + 73 * 0.10, 58, 79)))
        return (target, insurance, confidence, power, insuranceStrength)
    }

    private func petitForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.petit, reason: "Для PETIT нужно минимум 20 раундов") }
        let metrics = marketMetrics(values)
        let result = petitComponents(metrics)
        let ready = result.confidence >= 58 && result.strength >= 0.48
        return Forecast(mode: .petit, title: EngineMode.petit.title, target: result.target, insurance: nil, confidence: result.confidence, waitRounds: ready ? 0 : 1, attempts: 2, ready: ready, reason: String(format: "PETIT strength %.3f • ≥2x %.0f%% • vol %.2f • low-streak %d", result.strength, metrics.p2 * 100, metrics.volatility, metrics.lowStreak), detail: "Объединены PETIT V24, архив GRAND/PETIT и Lineage V27.")
    }

    private func grandForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.grand, reason: "Для GRAND нужно минимум 20 раундов") }
        let metrics = marketMetrics(values)
        let result = grandComponents(metrics)
        let ready = result.confidence >= 62 && result.power >= 0.54 && metrics.gap10 >= 6
        return Forecast(mode: .grand, title: EngineMode.grand.title, target: result.target, insurance: result.insurance, confidence: result.confidence, waitRounds: ready ? 0 : 1, attempts: 3, ready: ready, reason: String(format: "power %.3f • gap 10/20/50: %d/%d/%d • time %.2f", result.power, metrics.gap10, metrics.gap20, metrics.gap50, metrics.timeScore), detail: "Основная цель и страховка рассчитываются независимыми моделями.")
    }

    private func babelAutoForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.babelAuto, reason: "BABEL AUTO собирает минимум 20 раундов") }
        let metrics = marketMetrics(values)
        let grand = grandComponents(metrics)
        if grand.power >= 0.54 || (metrics.gap10 >= 10 && metrics.timeScore >= 0.72 && grand.power >= 0.46) {
            let ready = grand.confidence >= 62 && metrics.gap10 >= 6
            return Forecast(mode: .babelAuto, title: "🤖 BABEL AUTO → GRAND", target: grand.target, insurance: grand.insurance, confidence: grand.confidence, waitRounds: ready ? 0 : 1, attempts: 3, ready: ready, reason: String(format: "AUTO выбрал GRAND • power %.3f • gap10 %d", grand.power, metrics.gap10), detail: "Динамический выбор GRAND/PETIT из Lineage V27.")
        }
        let petit = petitComponents(metrics)
        let ready = petit.confidence >= 58 && petit.strength >= 0.48
        return Forecast(mode: .babelAuto, title: "🤖 BABEL AUTO → PETIT", target: petit.target, insurance: nil, confidence: petit.confidence, waitRounds: ready ? 0 : 1, attempts: 2, ready: ready, reason: String(format: "AUTO выбрал PETIT • strength %.3f • gap10 %d", petit.strength, metrics.gap10), detail: "Динамический выбор GRAND/PETIT из Lineage V27.")
    }

    private func duoForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.duo, reason: "DUO собирает минимум 20 раундов") }
        let metrics = marketMetrics(values)
        let grand = grandComponents(metrics)
        let petit = petitComponents(metrics)
        let grandStrength = Double(grand.confidence - 68)
        let petitStrength = Double(petit.confidence - 58)
        if grandStrength >= petitStrength && grand.confidence >= 68 {
            return Forecast(mode: .duo, title: "🟣 BABEL DUO → GRAND", target: grand.target, insurance: grand.insurance, confidence: grand.confidence, waitRounds: grand.power >= 0.54 ? 0 : 1, attempts: 2, ready: grand.power >= 0.50, reason: String(format: "DUO: GRAND %.0f против PETIT %.0f", grandStrength, petitStrength), detail: "DUO не смешивает цели — выбирает более подтверждённую ветку.")
        }
        let ready = petit.confidence >= 58
        return Forecast(mode: .duo, title: "🟣 BABEL DUO → PETIT", target: petit.target, insurance: nil, confidence: petit.confidence, waitRounds: ready ? 0 : 1, attempts: 2, ready: ready, reason: String(format: "DUO: PETIT %.0f против GRAND %.0f", petitStrength, grandStrength), detail: "DUO не смешивает цели — выбирает более подтверждённую ветку.")
    }

    private func petitGridForecast(_ values: [Double]) -> Forecast {
        let targets = [2.00, 2.17, 2.05, 2.28, 2.12, 2.21, 2.03, 2.30, 2.14, 2.08, 2.25, 2.10, 2.19, 2.06, 2.23, 2.01, 2.27, 2.13, 2.09, 2.29, 2.16, 2.04]
        let slot = Int(Date().timeIntervalSince1970 / 130) % targets.count
        let metrics = marketMetrics(values)
        let confidence = Int(round(clamp(54 + (1 - clamp(metrics.volatility / 1.2, 0, 1)) * 10, 54, 64)))
        return Forecast(mode: .petitGrid, title: EngineMode.petitGrid.title, target: targets[slot], insurance: nil, confidence: confidence, waitRounds: 0, attempts: 2, ready: values.count >= 20, reason: "позиция \(slot + 1)/22 • шаг 130 секунд • LIVE-фильтр vol \(String(format: "%.2f", metrics.volatility))", detail: "22 архивные PETIT-цели 2.00x–2.30x дополнены проверкой текущего рынка.")
    }

    private func aiProForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.aiPro, reason: "AI PRO собирает минимум 20 раундов") }
        let chrono = Array(values.prefix(200).reversed())
        let average = mean(chrono)
        let freq2 = rate(chrono) { $0 >= 2 }
        let recent5 = Array(chrono.suffix(5))
        let previous5 = chrono.count >= 10 ? Array(chrono[(chrono.count - 10)..<(chrono.count - 5)]) : recent5
        let avg5 = mean(recent5)
        let previousAverage = mean(previous5)
        let trend: Int = avg5 > previousAverage * 1.08 ? 1 : (avg5 < previousAverage * 0.92 ? -1 : 0)
        let lowStreak = streak(values) { $0 < 1.5 }
        let recent50 = values.prefix(50).map { min($0, 25) }
        let volatility = standardDeviation(recent50) / max(mean(recent50), 1)
        let gap10 = gap(values, target: 10)

        var score = 50
        var reasons: [String] = []
        if average >= 2 { score += 8; reasons.append("среднее ≥2x") }
        if freq2 >= 0.45 { score += 8; reasons.append("частота ≥2x хорошая") }
        if trend > 0 { score += 7; reasons.append("краткий рост") }
        if (2...5).contains(lowStreak) { score += 8; reasons.append("серия низких") }
        if lowStreak >= 7 { score -= 12; reasons.append("длинная низкая серия") }
        if volatility <= 0.9 { score += 8; reasons.append("умеренная vol") }
        else if volatility >= 1.35 { score -= 10; reasons.append("высокая vol") }
        if gap10 >= 10 { score += 5; reasons.append("давно нет 10x") }
        score = Int(clamp(Double(score), 0, 100))

        let base = mean(values.prefix(20).map { min($0, 8) })
        var target = base * (base >= 2.2 ? 0.66 : 0.78)
        if volatility > 1 { target *= 0.92 }
        if lowStreak >= 3 { target *= 1.03 }
        target = round2(clamp(target, 1.35, 2.60))
        let ready = score >= 58
        return Forecast(mode: .aiPro, title: EngineMode.aiPro.title, target: target, insurance: nil, confidence: score, waitRounds: score >= 72 ? 1 : 2, attempts: 3, ready: ready, reason: reasons.prefix(4).joined(separator: " • "), detail: String(format: "AI PRO SQLite-версия: avg %.2f • vol %.2f • gap10 %d", average, volatility, gap10))
    }

    private func allPredictorForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.allPredictor, reason: "ALLPREDICTOR собирает минимум 20 раундов") }
        let chrono = Array(values.prefix(120).reversed())
        let recent = Array(chrono.suffix(50))
        let clipped = recent.map { min($0, 25) }
        let average = mean(clipped)
        let volatility = standardDeviation(clipped) / max(average, 1)
        let pattern = patternProbabilities(chrono)
        let intervals = tenIntervals(chrono)
        let typicalGap = intervals.intervals.isEmpty ? 18 : mean(intervals.intervals.map(Double.init).suffix(12))
        let sample = Array(recent.suffix(16))
        let lowRatio = rate(sample) { $0 < 1.5 }
        let midRatio = rate(sample) { $0 >= 1.5 && $0 < 3 }
        let highRatio = rate(sample) { $0 >= 3 }
        let pressure = clamp(Double(intervals.gap) / max(typicalGap, 5), 0, 1.8) / 1.8
        let calm = 1 - clamp(volatility / 1.25, 0, 1)

        let highScore = 0.44 * pattern.high + 0.28 * pressure + 0.16 * highRatio + 0.12 * (1 - calm)
        let midScore = 0.46 * pattern.middle + 0.24 * midRatio + 0.18 * calm + 0.12 * (1 - abs(pressure - 0.55))
        let lowScore = 0.48 * pattern.low + 0.30 * lowRatio + 0.22 * calm
        let scores = [("H", highScore), ("M", midScore), ("B", lowScore)].sorted { $0.1 > $1.1 }
        let best = scores[0]
        let margin = scores[0].1 - scores[1].1
        let confidence = Int(round(clamp(42 + best.1 * 42 + margin * 70, 35, 88)))
        let target: Double = best.0 == "H" ? (pressure > 0.72 && confidence >= 74 ? 5 : 3) : (best.0 == "M" ? 2 : 1.5)
        let wait = confidence >= 72 ? 0 : (confidence >= 60 ? 1 : 2)
        return Forecast(mode: .allPredictor, title: EngineMode.allPredictor.title, target: target, insurance: nil, confidence: confidence, waitRounds: wait, attempts: 3, ready: confidence >= 52, reason: String(format: "zone %@ • pattern %.2f • vol %.2f • gap10 %d/%.1f", best.0, best.1, volatility, intervals.gap, typicalGap), detail: "Реконструированный ALLPREDICTOR из BABEL PRO4 v7.")
    }

    private func fusionForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.fusion, reason: "FUSION требует минимум 20 завершённых раундов") }
        let safe = fusionCandidate(values: values, name: "SAFE", choices: [(2.00, 0.50), (1.80, 0.56), (1.50, 0.60)], probabilityThreshold: 0.58, qualityThreshold: 51, horizon: 1, insurance: nil)
        let pro = fusionCandidate(values: values, name: "PRO", choices: [(5.00, 0.31), (3.00, 0.52), (2.50, 0.58)], probabilityThreshold: 0.46, qualityThreshold: 52, horizon: 3, insurance: 2.0)
        let ten = fusionCandidate(values: values, name: "TEN", choices: [(10.00, 0.0)], probabilityThreshold: 0.23, qualityThreshold: 53, horizon: 3, insurance: 3.0)
        let candidates = [safe, pro, ten]
        let ready = candidates.filter(\.ready)
        let pool = ready.isEmpty ? candidates : ready
        let selected = pool.max { lhs, rhs in
            fusionDecisionScore(lhs) < fusionDecisionScore(rhs)
        } ?? safe
        let confidence = Int(round(clamp(selected.probability * 100, 1, 99)))
        return Forecast(mode: .fusion, title: "🧠 FUSION AUTO → \(selected.name)", target: selected.target, insurance: selected.insurance, confidence: confidence, waitRounds: selected.waitRounds, attempts: selected.horizon, ready: selected.ready, reason: selected.reason, detail: String(format: "AUTO сравнил SAFE/PRO/TEN • quality %.1f • история %d/500", selected.quality, values.count))
    }

    private func fusionCandidate(values: [Double], name: String, choices: [(Double, Double)], probabilityThreshold: Double, qualityThreshold: Double, horizon: Int, insurance: Double?) -> FusionCandidate {
        var selectedTarget = choices.last?.0 ?? 1.5
        var selectedEstimate = fusionEstimate(values, target: selectedTarget, horizon: horizon, tenMode: name == "TEN")
        for (target, minimum) in choices {
            let estimate = fusionEstimate(values, target: target, horizon: horizon, tenMode: name == "TEN")
            selectedTarget = target
            selectedEstimate = estimate
            if estimate.raw >= minimum { break }
        }

        let stats = botStats[EngineMode.fusion.key] ?? BotStats()
        var probability = selectedEstimate.raw
        if stats.total > 0 {
            let observed = (Double(stats.wins) + 1) / (Double(stats.total) + 2)
            let weight = min(0.45, Double(stats.total) / 60 * 0.45)
            probability = clamp(probability * (1 - weight) + observed * weight, 0.01, 0.99)
        }
        let support = selectedEstimate.patternSupport + selectedEstimate.contextSupport
        let edge = probability - selectedEstimate.baseline
        let quality = clamp(50 + edge * 180 + Double(min(support, 30)) * 0.35, 0, 100)
        let ready = probability >= probabilityThreshold && quality >= qualityThreshold
        let wait: Int
        if name == "SAFE" { wait = 0 }
        else if name == "PRO" { wait = probability >= probabilityThreshold + 0.07 ? 0 : 1 }
        else { wait = probability >= probabilityThreshold + 0.06 ? 0 : 1 }
        let reason = String(format: "база %.1f%% • recent %.1f%% • pattern %.1f%%/%d • context %.1f%%/%d • gap10 %d • vol %.2f", selectedEstimate.baseline * 100, selectedEstimate.recent * 100, selectedEstimate.pattern * 100, selectedEstimate.patternSupport, selectedEstimate.context * 100, selectedEstimate.contextSupport, selectedEstimate.gap10, selectedEstimate.volatility)
        return FusionCandidate(name: name, target: selectedTarget, insurance: insurance, horizon: horizon, waitRounds: wait, probability: probability, baseline: selectedEstimate.baseline, quality: quality, ready: ready, reason: reason)
    }

    private func fusionEstimate(_ values: [Double], target: Double, horizon: Int, tenMode: Bool) -> FusionEstimate {
        let newest = Array(values.prefix(500))
        let chrono = Array(newest.reversed())
        let baseline = horizonEventRate(chrono, target: target, horizon: horizon).rate
        let recentChrono = Array(chrono.suffix(min(100, chrono.count)))
        let recent = horizonEventRate(recentChrono, target: target, horizon: horizon).rate
        let pattern = patternEventRate(chrono, target: target, horizon: horizon)
        let context = contextEventRate(chrono, target: target, horizon: horizon)
        let patternWeight = min(0.28, Double(pattern.support) / 20 * 0.28)
        let contextWeight = min(0.24, Double(context.support) / 35 * 0.24)
        let recentWeight = 0.22
        let interval = tenIntervals(chrono)
        let medianGap = interval.intervals.isEmpty ? 18 : median(interval.intervals.map(Double.init).suffix(20))
        let proximity = 1 - min(abs(Double(interval.gap) - medianGap) / max(medianGap, 5), 1)
        let intervalWeight = tenMode ? 0.08 : 0
        let intervalAdjusted = tenMode ? clamp(baseline * (0.90 + 0.20 * proximity), 0, 1) : baseline
        let patternRate = pattern.support > 0 ? pattern.rate : baseline
        let contextRate = context.support > 0 ? context.rate : baseline
        let baseWeight = max(0.18, 1 - patternWeight - contextWeight - recentWeight - intervalWeight)
        let weightSum = baseWeight + patternWeight + contextWeight + recentWeight + intervalWeight
        let raw = clamp((baseline * baseWeight + patternRate * patternWeight + contextRate * contextWeight + recent * recentWeight + intervalAdjusted * intervalWeight) / weightSum, 0.01, 0.99)
        let clipped20 = newest.prefix(20).map { min($0, 25) }
        let volatility = standardDeviation(clipped20) / max(mean(clipped20), 1)
        return FusionEstimate(raw: raw, baseline: baseline, recent: recent, pattern: patternRate, context: contextRate, patternSupport: pattern.support, contextSupport: context.support, gap10: interval.gap, medianGap10: medianGap, intervalProximity: proximity, volatility: volatility)
    }

    private func fusionDecisionScore(_ candidate: FusionCandidate) -> Double {
        let threshold: Double = candidate.name == "SAFE" ? 0.58 : (candidate.name == "PRO" ? 0.46 : 0.23)
        let probabilityRatio = candidate.probability / max(threshold, 0.01)
        let edge = candidate.probability - candidate.baseline
        let targetBonus = log10(max(candidate.target, 1)) * 0.08
        return probabilityRatio + edge * 2 + targetBonus
    }

    private func pro4Forecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.pro4, reason: "PRO4 собирает минимум 20 раундов") }
        let since10 = gap(values, target: 10)
        let recent = Array(values.prefix(24))
        let low = rate(recent) { $0 < 1.5 }
        let middle = rate(recent) { $0 >= 1.5 && $0 < 3 }
        let high = rate(recent) { $0 >= 3 }
        let waitScore: Double
        if (5...7).contains(since10) { waitScore = 1 }
        else if (4...8).contains(since10) { waitScore = 0.72 }
        else { waitScore = max(0, 1 - abs(Double(since10 - 6)) / 12) }
        let time = babelTimeScore()
        let compression = min(low * 0.75 + middle * 0.35, 1)
        let score = 0.44 * waitScore + 0.24 * compression + 0.18 * time + 0.14 * high
        let confidence = Int(round(clamp(48 + score * 44, 40, 93)))
        let target: Double = confidence >= 84 && time >= 0.75 ? 20 : (confidence >= 77 ? 15 : 14)
        let wait = since10 < 5 ? min(2, max(0, 5 - since10)) : 0
        return Forecast(mode: .pro4, title: EngineMode.pro4.title, target: target, insurance: target >= 20 ? 4 : 3, confidence: confidence, waitRounds: wait, attempts: 3, ready: confidence >= 60, reason: String(format: "since10 %d • wait-score %.2f • compression %.2f • time %.2f", since10, waitScore, compression, time), detail: "Окно 5–7 игр после 10x; цели 14x/15x/20x.")
    }

    private func pro4RangeForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.pro4Range, reason: "PRO4 RANGE собирает минимум 20 раундов") }
        let since10 = gap(values, target: 10)
        let recent = Array(values.prefix(30))
        let low = rate(recent) { $0 < 1.5 }
        let big = rate(recent) { $0 >= 5 }
        let time = babelTimeScore()
        let mature = clamp(Double(since10 - 5) / 8, 0, 1)
        let score = 0.38 * mature + 0.28 * time + 0.22 * low + 0.12 * big
        let confidence = Int(round(clamp(46 + score * 46, 40, 92)))
        let target: Double = confidence >= 84 && mature >= 0.72 ? 50 : 30
        let insurance: Double = target >= 50 ? 10 : 5
        return Forecast(mode: .pro4Range, title: EngineMode.pro4Range.title, target: target, insurance: insurance, confidence: confidence, waitRounds: time >= 0.75 ? 1 : 2, attempts: 4, ready: confidence >= 74, reason: String(format: "since10 %d • mature %.2f • low %.2f • big %.2f • time %.2f", since10, mature, low, big, time), detail: "Расширенное крупное окно PRO4 RANGE.")
    }

    private func twoTimeForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.twoTime, reason: "2X TIME собирает минимум 20 раундов") }
        let recent = Array(values.prefix(20))
        let around2 = rate(recent) { $0 >= 1.8 && $0 <= 2.5 }
        let lows = rate(recent) { $0 < 1.5 }
        let clipped = recent.map { min($0, 8) }
        let volatility = standardDeviation(clipped) / max(mean(clipped), 1)
        let score = 0.52 * around2 + 0.28 * lows + 0.20 * (1 - clamp(volatility / 1.2, 0, 1))
        let confidence = Int(round(clamp(46 + score * 48, 40, 90)))
        let target = round2(clamp(2 + around2 * 0.28, 2, 2.3))
        return Forecast(mode: .twoTime, title: EngineMode.twoTime.title, target: target, insurance: nil, confidence: confidence, waitRounds: 1, attempts: 3, ready: confidence >= 60, reason: String(format: "около 2x %.0f%% • low %.0f%% • vol %.2f", around2 * 100, lows * 100, volatility), detail: "Точный закрытый тайминг не выдумывается; используется LIVE-фильтр версии v7.")
    }

    private func bigTimeForecast(_ values: [Double]) -> Forecast {
        guard values.count >= 20 else { return waitingForecast(.bigTime, reason: "10X–100X собирает минимум 20 раундов") }
        let chrono = Array(values.prefix(180).reversed())
        let intervals = tenIntervals(chrono)
        guard !intervals.intervals.isEmpty else { return waitingForecast(.bigTime, reason: "Нужно накопить минимум два события 10x+") }
        let typical = median(intervals.intervals.map(Double.init).suffix(12))
        let recent = Array(chrono.suffix(20))
        let low = rate(recent) { $0 < 1.5 }
        let middle = rate(recent) { $0 >= 1.5 && $0 < 3 }
        let high = rate(recent) { $0 >= 3 }
        let proximity = 1 - min(abs(Double(intervals.gap) - typical) / max(typical, 5), 1)
        let pressure = min(Double(intervals.gap) / max(typical, 5), 1.8) / 1.8
        let compression = min(low * 1.15 + middle * 0.25, 1)
        let time = babelTimeScore()
        let score = 0.34 * proximity + 0.26 * pressure + 0.16 * compression + 0.08 * high + 0.16 * time
        let confidence = Int(round(clamp(45 + score * 45, 40, 90)))
        let target: Double = pressure > 0.84 && confidence >= 84 ? 30 : (pressure > 0.70 ? 20 : 10)
        let insurance: Double = target >= 30 ? 5 : 3
        let wait = Double(intervals.gap) >= typical ? 0 : (Double(intervals.gap) >= max(0, typical - 2) ? 1 : 2)
        return Forecast(mode: .bigTime, title: EngineMode.bigTime.title, target: target, insurance: insurance, confidence: confidence, waitRounds: wait, attempts: 3, ready: confidence >= 60, reason: String(format: "gap10 %d • typical %.1f • proximity %.2f • pressure %.2f • time %.2f", intervals.gap, typical, proximity, pressure, time), detail: "HEURE DE GROSSE CÔTE: история 10x+ и BABEL time-grid; диапазон наблюдения 10x–100x.")
    }

    private func watchForecast(_ values: [Double]) -> Forecast {
        let metrics = marketMetrics(values)
        let confidence = Int(round(clamp(45 + Double(min(metrics.gap10, 20)) + Double(min(metrics.lowStreak, 5)) * 3, 40, 90)))
        return Forecast(mode: .watch, title: EngineMode.watch.title, target: nil, insurance: nil, confidence: confidence, waitRounds: 0, attempts: 0, ready: false, reason: String(format: "avg %.2fx • vol %.2f • ≥2x %.0f%% • ≥10x %.0f%% • gap10 %d", metrics.average, metrics.volatility, metrics.p2 * 100, metrics.p10 * 100, metrics.gap10), detail: "Наблюдение рынка без создания сигнала.")
    }

    private func horizonEventRate(_ chronological: [Double], target: Double, horizon: Int) -> (rate: Double, support: Int) {
        guard horizon > 0, chronological.count >= horizon else { return (0, 0) }
        var hits = 0
        let total = chronological.count - horizon + 1
        for start in 0..<total {
            if chronological[start..<(start + horizon)].max() ?? 0 >= target { hits += 1 }
        }
        return ((Double(hits) + 1) / (Double(total) + 2), total)
    }

    private func patternEventRate(_ chronological: [Double], target: Double, horizon: Int, order: Int = 4) -> (rate: Double, support: Int) {
        guard chronological.count >= order + horizon + 1 else { return (0, 0) }
        let zones = chronological.map(zone)
        let key = Array(zones.suffix(order))
        var hits = 0
        var matches = 0
        let lastStart = zones.count - order - horizon
        if lastStart < 0 { return (0, 0) }
        for start in 0...lastStart {
            if Array(zones[start..<(start + order)]) != key { continue }
            matches += 1
            if chronological[(start + order)..<(start + order + horizon)].max() ?? 0 >= target { hits += 1 }
        }
        guard matches > 0 else { return (0, 0) }
        return ((Double(hits) + 1) / (Double(matches) + 2), matches)
    }

    private func contextEventRate(_ chronological: [Double], target: Double, horizon: Int, contextSize: Int = 6) -> (rate: Double, support: Int) {
        guard chronological.count >= contextSize + horizon + 1 else { return (0, 0) }
        let current = Array(chronological.suffix(contextSize))
        let currentLow = current.filter { $0 < 1.5 }.count
        let currentMiddle = current.filter { $0 >= 1.5 && $0 < 3 }.count
        var hits = 0
        var matches = 0
        let upper = chronological.count - horizon
        for end in contextSize...upper {
            let window = chronological[(end - contextSize)..<end]
            let low = window.filter { $0 < 1.5 }.count
            let middle = window.filter { $0 >= 1.5 && $0 < 3 }.count
            if abs(low - currentLow) > 1 || abs(middle - currentMiddle) > 1 { continue }
            matches += 1
            if chronological[end..<(end + horizon)].max() ?? 0 >= target { hits += 1 }
        }
        guard matches > 0 else { return (0, 0) }
        return ((Double(hits) + 1) / (Double(matches) + 2), matches)
    }

    private func patternProbabilities(_ chronological: [Double]) -> PatternStats {
        let zones = chronological.map(zone)
        guard zones.count >= 10 else { return PatternStats(low: 1.0 / 3, middle: 1.0 / 3, high: 1.0 / 3, support: 0) }
        let key = Array(zones.suffix(4))
        var low = 0
        var middle = 0
        var high = 0
        var matches = 0
        for index in 0..<(zones.count - 4) {
            guard Array(zones[index..<(index + 4)]) == key else { continue }
            matches += 1
            switch zones[index + 4] {
            case "B": low += 1
            case "M": middle += 1
            default: high += 1
            }
        }
        guard matches >= 2 else { return PatternStats(low: 1.0 / 3, middle: 1.0 / 3, high: 1.0 / 3, support: matches) }
        return PatternStats(low: Double(low) / Double(matches), middle: Double(middle) / Double(matches), high: Double(high) / Double(matches), support: matches)
    }

    private func zone(_ value: Double) -> String {
        if value < 1.5 { return "B" }
        if value < 3 { return "M" }
        return "H"
    }

    private func tenIntervals(_ chronological: [Double]) -> (intervals: [Int], gap: Int) {
        let positions = chronological.indices.filter { chronological[$0] >= 10 }
        let intervals = positions.indices.dropFirst().map { positions[$0] - positions[$0 - 1] }
        let gap = positions.last.map { chronological.count - 1 - $0 } ?? chronological.count
        return (intervals, gap)
    }

    private func babelTimeScore() -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let goodHour = (1...2).contains(hour) || (11...13).contains(hour) || (16...19).contains(hour) || (21...23).contains(hour)
        let goodMinute = minute >= 59 || minute <= 2 || (4...10).contains(minute) || (13...20).contains(minute) || (27...33).contains(minute) || (45...47).contains(minute) || (50...52).contains(minute) || (57...59).contains(minute)
        if goodHour && goodMinute { return 1 }
        if goodMinute { return 0.75 }
        if goodHour { return 0.55 }
        return 0.20
    }

    private func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    private func rate<S: Sequence>(_ values: S, _ predicate: (Double) -> Bool) -> Double where S.Element == Double {
        let array = Array(values)
        guard !array.isEmpty else { return 0 }
        return Double(array.filter(predicate).count) / Double(array.count)
    }

    private func gap(_ values: [Double], target: Double) -> Int {
        values.firstIndex(where: { $0 >= target }) ?? values.count
    }

    private func streak(_ values: [Double], predicate: (Double) -> Bool) -> Int {
        var count = 0
        for value in values {
            if predicate(value) { count += 1 } else { break }
        }
        return count
    }

    private func mean<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        let array = Array(values)
        guard !array.isEmpty else { return 0 }
        return array.reduce(0, +) / Double(array.count)
    }

    private func standardDeviation<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        let array = Array(values)
        guard array.count >= 2 else { return 0 }
        let average = mean(array)
        return sqrt(array.map { pow($0 - average, 2) }.reduce(0, +) / Double(array.count))
    }

    private func median<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        let sorted = Array(values).sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
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
        liveLabel.textColor = .black
        liveLabel.backgroundColor = .systemOrange
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
