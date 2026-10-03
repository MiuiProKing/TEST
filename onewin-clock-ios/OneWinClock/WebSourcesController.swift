import UIKit
import WebKit

struct WebSource: Codable {
    let id: String
    let name: String
    let url: String
    let enabled: Bool
}
struct WebGroup: Codable { let name: String; let sources: [WebSource] }
struct WebCatalog: Codable {
    let groups: [WebGroup]
    static func load() -> WebCatalog {
        guard let url = Bundle.main.url(forResource:"web_sources",withExtension:"json"), let data = try? Data(contentsOf:url),
              let catalog = try? JSONDecoder().decode(WebCatalog.self,from:data) else { return WebCatalog(groups:[]) }
        return catalog
    }
    func source(_ id: String) -> WebSource? { groups.flatMap(\.sources).first { $0.id == id } }
}


// Keep a bounded set of opened pages. Cookies use the persistent WK data store;
// page history and scroll position survive switches while a page is resident.
final class WebBrowserPool {
    private var browsers: [String: ManagedBrowserController] = [:]
    private var recent: [String] = []
    func browser(for source: WebSource, group: WebGroup) -> ManagedBrowserController {
        let browser = browsers[source.id] ?? ManagedBrowserController(source:source,group:group)
        browser.resumeHomeIfNeeded()
        browsers[source.id] = browser
        recent.removeAll { $0 == source.id }; recent.insert(source.id,at:0)
        while recent.count > 4 { browsers.removeValue(forKey:recent.removeLast()) }
        return browser
    }
    func releaseInactive() {
        guard let current = recent.first else { return }
        browsers = browsers.filter { $0.key == current }; recent = [current]
    }
}

final class WebSourcesController: UITableViewController, UISearchResultsUpdating {
    private let manager: SourceManager
    private let pool: WebBrowserPool
    private let catalog = WebCatalog.load()
    private var checks: [String: String] = [:]
    private var tasks: [String: URLSessionDataTask] = [:]
    private var settingsExpanded = false
    #if DEBUG
    private var auditTimer: Timer?
    private var auditResults: [String: Bool] = [:]
    private var auditInitialBrowser: ManagedBrowserController?
    #endif
    private let search = UISearchController(searchResultsController:nil)
    private var groups: [WebGroup] {
        let query = settingsExpanded ? "" : (search.searchBar.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return catalog.groups.compactMap { group in
            let sources = group.sources.filter { source in
                source.enabled && (query.isEmpty || (source.name + " " + source.url + " " + group.name).localizedCaseInsensitiveContains(query))
            }
            return sources.isEmpty ? nil : WebGroup(name:group.name,sources:sources)
        }
    }
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 10; c.waitsForConnectivity = false
        return URLSession(configuration:c)
    }()
    init(manager: SourceManager, pool: WebBrowserPool = WebBrowserPool()) {
        self.manager = manager; self.pool = pool; super.init(style:.insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        checks = UserDefaults.standard.dictionary(forKey:"kiborg.web.health") as? [String:String] ?? [:]
        title = "WEB • Сайты"
        overrideUserInterfaceStyle = .dark
        navigationItem.backButtonTitle = "Сайты"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"Готово",style:.done,target:self,action:#selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"Настройки",style:.plain,target:self,action:#selector(toggleSettings))
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Найти сайт или страницу"
        navigationItem.searchController = search; navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self,action:#selector(refresh),for:.valueChanged)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-navigation") { startNavigationAudit() }
        #endif
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    override func didReceiveMemoryWarning() { super.didReceiveMemoryWarning(); pool.releaseInactive() }
    deinit {
        session.invalidateAndCancel()
        #if DEBUG
        auditTimer?.invalidate()
        #endif
    }
    func updateSearchResults(for searchController: UISearchController) { tableView.reloadData() }
    @objc private func close() { dismiss(animated:true) }
    @objc private func toggleSettings() {
        settingsExpanded.toggle()
        search.isActive = false; search.searchBar.text = ""
        navigationItem.searchController = settingsExpanded ? nil : search
        tableView.reloadData()
        if settingsExpanded {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [weak self] in
                guard let self, self.settingsExpanded else { return }
                self.tableView.scrollToRow(at:IndexPath(row:0,section:self.groups.count),at:.top,animated:false)
            }
        }
    }
    @objc private func refresh() {
        tableView.reloadData(); refreshControl?.endRefreshing()
        for s in catalog.groups.flatMap(\.sources).filter(\.enabled) { check(s) }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count + 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == groups.count ? (settingsExpanded ? 3 : 0) : groups[section].sources.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == groups.count ? (settingsExpanded ? "⚙️ Источник коэффициентов" : nil) : groups[section].name
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == groups.count {
            return settingsExpanded ? "API и WEB выбираются независимо. SESSION хранится в Keychain. HTTP 200 не подтверждает прогнозы сайта." : (groups.isEmpty ? "Ничего не найдено. Измените поиск." : "Нажмите сайт, чтобы открыть. Кнопка ⓘ — адрес и проверка. Потяните список вниз для проверки доступности.")
        }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        cell.detailTextLabel?.numberOfLines = 2; cell.textLabel?.numberOfLines = 2
        if indexPath.section == groups.count {
            cell.accessoryType = .disclosureIndicator
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "API: \(manager.selection)"
                let h = manager.health[manager.activeID] ?? SourceHealth()
                cell.detailTextLabel?.text = "\(manager.activeID.uppercased()) • \(h.status) • \(Int(h.latency*1000))ms\nПереключение и статус API"
            case 1: cell.textLabel?.text = "SESSION • свой session-id"; cell.detailTextLabel?.text = SessionVault.value.isEmpty ? "Не настроен • прямой API требует входа" : "Сохранён в Keychain • значение скрыто"
            default: cell.textLabel?.text = "1WIN: \(UserDefaults.standard.bool(forKey:"kiborg.1win.auto") ? "AUTO" : "РУЧНОЙ")"; cell.detailTextLabel?.text = "Автоматический резерв при сетевой ошибке / HTTP 5xx"
            }
        } else {
            let group = groups[indexPath.section], source = group.sources[indexPath.row]
            let active = UserDefaults.standard.string(forKey:"kiborg.web.selected." + group.name) == source.id
            cell.textLabel?.text = source.name
            let host = URL(string:source.url)?.host ?? source.url
            let status = checks[source.id]?.components(separatedBy:" • ").first ?? "Не проверен"
            cell.detailTextLabel?.text = "\(active ? "✓ Выбран • " : "")\(host)\n\(status)"
            cell.accessoryType = .detailButton
            cell.accessibilityIdentifier = "web.site." + source.id
            cell.accessibilityHint = "Открыть сайт. Дополнительная кнопка показывает адрес и проверку."
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        if indexPath.section == groups.count {
            if indexPath.row == 0 { selectAPI() }
            else if indexPath.row == 1 { setSession() }
            else {
                let defaults = UserDefaults.standard
                defaults.set(!defaults.bool(forKey:"kiborg.1win.auto"),forKey:"kiborg.1win.auto")
                tableView.reloadData()
            }
            return
        }
        let group = groups[indexPath.section]
        open(group.sources[indexPath.row],group:group)
    }
    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard indexPath.section < groups.count else { return }
        let group = groups[indexPath.section], source = group.sources[indexPath.row]
        let menu = UIAlertController(title:source.name,message:source.url + "\n\n" + (checks[source.id] ?? "Доступность ещё не проверена"),preferredStyle:.actionSheet)
        menu.addAction(UIAlertAction(title:"Открыть",style:.default) { [weak self] _ in self?.open(source,group:group) })
        menu.addAction(UIAlertAction(title:"Выбрать для группы",style:.default) { [weak self] _ in
            UserDefaults.standard.set(source.id,forKey:"kiborg.web.selected."+group.name); self?.tableView.reloadData()
        })
        menu.addAction(UIAlertAction(title:"Проверить доступность",style:.default) { [weak self] _ in self?.check(source) })
        menu.addAction(UIAlertAction(title:"Обновить страницу",style:.default) { [weak self] _ in
            guard let self else { return }; self.open(source,group:group); self.pool.browser(for:source,group:group).refreshPage()
        })
        menu.addAction(UIAlertAction(title:"Отмена",style:.cancel)); anchor(menu,indexPath:indexPath); present(menu,animated:true)
    }
    private func anchor(_ menu: UIAlertController, indexPath: IndexPath? = nil) {
        menu.popoverPresentationController?.sourceView = tableView
        menu.popoverPresentationController?.sourceRect = indexPath.map { tableView.rectForRow(at:$0) } ?? CGRect(x:20,y:20,width:1,height:1)
    }
    private func selectAPI() {
        let menu = UIAlertController(title:"Источник коэффициентов",message:"AUTO: MAIN → RESERVE → SESSION → SQLite",preferredStyle:.actionSheet)
        for (id,name) in [("AUTO","AUTO")] + manager.config.sources.filter { $0.enabled }.map({ ($0.id,$0.name) }) {
            menu.addAction(UIAlertAction(title:name,style:.default) { [weak self] _ in
                guard let self else { return }; self.manager.selection = id
                self.tableView.reloadData()
            })
        }
        menu.addAction(UIAlertAction(title:"Проверить выбранный",style:.default) { [weak self] _ in
            guard let self else { return }; self.manager.check(self.manager.selection == "AUTO" ? "main" : self.manager.selection) { self.tableView.reloadData() }
        })
        menu.addAction(UIAlertAction(title:"Статус всех API",style:.default) { [weak self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(APIHealthController(manager:self.manager),animated:true)
        })
        menu.addAction(UIAlertAction(title:"Отмена",style:.cancel)); anchor(menu); present(menu,animated:true)
    }
    private func setSession() {
        let alert = UIAlertController(title:"Своя SESSION LuckyJet",message:"Введите session-id своей авторизованной сессии. Пустое поле удаляет сохранённый SESSION. Значение не попадает в лог.",preferredStyle:.alert)
        alert.addTextField { field in field.isSecureTextEntry = true; field.placeholder = "session-id"; field.autocapitalizationType = .none; field.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title:"Сохранить",style:.default) { [weak self, weak alert] _ in
            SessionVault.value = alert?.textFields?.first?.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            self?.manager.reset(); self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title:"Отмена",style:.cancel)); present(alert,animated:true)
    }

    private func open(_ source: WebSource, group: WebGroup) {
        guard source.enabled else { return }
        search.isActive = false
        UserDefaults.standard.set(source.id,forKey:"kiborg.web.selected."+group.name)
        // Search narrows visible rows, never the list of fallback sites.
        let completeGroup = catalog.groups.first { $0.name == group.name } ?? group
        let browser = pool.browser(for:source,group:completeGroup)
        browser.onSites = { [weak self] in
            guard let self else { return }; self.navigationController?.popToViewController(self,animated:true)
        }
        browser.onSwitch = { [weak self] source,group in self?.open(source,group:group) }
        browser.onClose = { [weak self] in self?.close() }
        if navigationController?.topViewController === self { navigationController?.pushViewController(browser,animated:true) }
        else { navigationController?.setViewControllers([self,browser],animated:false) }
        tableView.reloadData()
    }
    private func check(_ source: WebSource) {
        guard tasks[source.id] == nil, let url = URL(string:source.url) else { return }
        checks[source.id] = "Проверяется…"; tableView.reloadData()
        let start = Date()
        let task = session.dataTask(with:URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:8)) { [weak self] _,response,error in
            DispatchQueue.main.async {
                guard let self else { return }
                let code = (response as? HTTPURLResponse)?.statusCode
                let status: String
                if error != nil { status = "🔴 OFFLINE" }
                else if let code, [401,403].contains(code) { status = "AUTH_REQUIRED" }
                else if let code, (200...399).contains(code) { status = Date().timeIntervalSince(start) > 5 ? "🟡 SLOW" : "🟢 ONLINE" }
                else { status = "ERROR" }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                self.checks[source.id] = "\(status) • HTTP \(code.map(String.init) ?? "—") • \(Int(Date().timeIntervalSince(start)*1000))ms • \(f.string(from:Date()))"
                UserDefaults.standard.set(self.checks,forKey:"kiborg.web.health")
                self.tasks.removeValue(forKey:source.id); self.tableView.reloadData()
            }
        }
        tasks[source.id] = task; task.resume()
    }
}

final class APIHealthController: UITableViewController {
    private let manager: SourceManager
    init(manager: SourceManager) { self.manager = manager; super.init(style:.insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() { super.viewDidLoad(); title = "Статус API" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { manager.config.sources.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let source = manager.config.sources[indexPath.row]
        let h = manager.health[source.id] ?? SourceHealth()
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        cell.textLabel?.text = (manager.activeID == source.id ? "✅ " : "") + source.name
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let success = h.lastSuccess.map { formatter.string(from:$0) } ?? "NOT VERIFIED"
        let fresh = h.lastNewRound.map { formatter.string(from:$0) } ?? "NOT VERIFIED"
        cell.detailTextLabel?.text = "\(source.url)\n\(h.status) • HTTP \(h.httpStatus.map(String.init) ?? "—") • \(Int(h.latency*1000))ms\nУспешный ответ: \(success)\nНовый ID: \(fresh)\n\(h.lastError ?? "Нажмите для проверки")"
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        let source = manager.config.sources[indexPath.row]
        guard source.enabled, source.type != "cache" else { return }
        manager.check(source.id) { [weak self] in self?.tableView.reloadData() }
    }
}


final class ManagedBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var source: WebSource
    private let homeSource: WebSource
    private let group: WebGroup
    var onSites: (() -> Void)?
    var onSwitch: ((WebSource,WebGroup) -> Void)?
    var onClose: (() -> Void)?
    var homeURL: String { homeSource.url }
    func resumeHomeIfNeeded() { if isViewLoaded && source.id != homeSource.id { home() } }
    func navigateBack() { back() }
    func refreshPage() { loadViewIfNeeded(); reload() }
    private let web: WKWebView
    private let spinner = UIActivityIndicatorView(style:.large)
    private let errorPanel = UIStackView()
    private let sourceButton = UIButton(type:.system)
    private let addressLabel = UILabel()
    private let chips = UIStackView()
    private let chipScroll = UIScrollView()
    private let backButton = UIButton(type:.system), forwardButton = UIButton(type:.system)
    private var observations: [NSKeyValueObservation] = []
    private var fallbackTried = Set<String>()
    private var timeout: DispatchWorkItem?
    private var availableGroups: [WebGroup] { onSwitch == nil ? [group] : WebCatalog.load().groups }
    init(source: WebSource, group: WebGroup) {
        self.source = source; homeSource = source; self.group = group
        let c = WKWebViewConfiguration(); c.websiteDataStore = .default(); c.allowsInlineMediaPlayback = true
        web = WKWebView(frame:.zero,configuration:c)
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    deinit { timeout?.cancel(); web.stopLoading() }
    override func viewDidLoad() {
        super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = .systemBackground; title = source.name
        web.navigationDelegate = self; web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        sourceButton.titleLabel?.font = .boldSystemFont(ofSize:14)
        sourceButton.titleLabel?.lineBreakMode = .byTruncatingTail
        sourceButton.contentHorizontalAlignment = .leading
        sourceButton.accessibilityIdentifier = "web.switch"
        addressLabel.font = .systemFont(ofSize:11); addressLabel.textColor = .secondaryLabel
        addressLabel.lineBreakMode = .byTruncatingMiddle
        chipScroll.showsHorizontalScrollIndicator = false
        chips.axis = .horizontal; chips.spacing = 8
        chipScroll.addSubview(chips); chips.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.leadingAnchor,constant:10),
            chips.trailingAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.trailingAnchor,constant:-10),
            chips.topAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.topAnchor),chips.bottomAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.bottomAnchor),
            chips.heightAnchor.constraint(equalTo:chipScroll.frameLayoutGuide.heightAnchor)
        ])
        let heading = UIStackView(arrangedSubviews:[sourceButton,addressLabel,chipScroll])
        heading.axis = .vertical; heading.spacing = 3; heading.layoutMargins = UIEdgeInsets(top:4,left:10,bottom:6,right:10); heading.isLayoutMarginsRelativeArrangement = true
        sourceButton.heightAnchor.constraint(equalToConstant:30).isActive = true
        chipScroll.heightAnchor.constraint(equalToConstant:34).isActive = true
        let toolbar = UIStackView(); toolbar.distribution = .fillEqually; toolbar.spacing = 3
        let controls: [(UIButton,String,String,Selector)] = [
            (UIButton(type:.system),"Сайты","square.grid.2x2",#selector(sites)),
            (backButton,"Назад","chevron.left",#selector(back)),
            (forwardButton,"Вперёд","chevron.right",#selector(forward)),
            (UIButton(type:.system),"Обновить","arrow.clockwise",#selector(reload)),
            (UIButton(type:.system),"Домой","house",#selector(home)),
            (UIButton(type:.system),"Снаружи","arrow.up.right.square",#selector(external))
        ]
        for (button,title,icon,selector) in controls {
            var configuration = UIButton.Configuration.plain()
            configuration.title = title; configuration.image = UIImage(systemName:icon)
            configuration.imagePlacement = .top; configuration.imagePadding = 4
            configuration.contentInsets = NSDirectionalEdgeInsets(top:6,leading:0,bottom:6,trailing:0)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attributes = incoming; attributes.font = .systemFont(ofSize:10,weight:.medium); return attributes
            }
            button.configuration = configuration; button.backgroundColor = .secondarySystemBackground; button.layer.cornerRadius = 8
            button.accessibilityIdentifier = "web.control." + title
            button.accessibilityLabel = title == "Назад" ? "Назад внутри страницы" : (title == "Сайты" ? "Вернуться к списку сайтов" : title)
            button.addTarget(self,action:selector,for:.touchUpInside); toolbar.addArrangedSubview(button)
        }
        let sections: [UIView] = [heading,web,toolbar]
        for item in sections { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),heading.leadingAnchor.constraint(equalTo:view.leadingAnchor),heading.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            toolbar.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:6),toolbar.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-6),
            toolbar.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-4),toolbar.heightAnchor.constraint(equalToConstant:58),
            web.topAnchor.constraint(equalTo:heading.bottomAnchor),web.leadingAnchor.constraint(equalTo:view.leadingAnchor),web.trailingAnchor.constraint(equalTo:view.trailingAnchor),web.bottomAnchor.constraint(equalTo:toolbar.topAnchor,constant:-4)
        ])
        spinner.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo:web.centerXAnchor),spinner.centerYAnchor.constraint(equalTo:web.centerYAnchor)])
        errorPanel.axis = .vertical; errorPanel.spacing = 20; errorPanel.backgroundColor = .systemBackground
        let label = UILabel(); label.text = "Сайт временно недоступен\nМожно повторить загрузку или выбрать другой сайт сверху."; label.textAlignment = .center; label.numberOfLines = 0
        errorPanel.addArrangedSubview(label)
        for (title,action) in [("Повторить",#selector(reload)),("Резервный источник",#selector(reserve))] {
            let button = UIButton(type:.system); button.setTitle(title,for:.normal); button.addTarget(self,action:action,for:.touchUpInside); errorPanel.addArrangedSubview(button)
        }
        errorPanel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(errorPanel); errorPanel.isHidden = true
        NSLayoutConstraint.activate([errorPanel.centerYAnchor.constraint(equalTo:web.centerYAnchor),errorPanel.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),errorPanel.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16)])
        observations = [web.observe(\.canGoBack,options:[.new]) { [weak self] _,_ in self?.updateControls() },
                        web.observe(\.canGoForward,options:[.new]) { [weak self] _,_ in self?.updateControls() },
                        web.observe(\.url,options:[.new]) { [weak self] _,_ in self?.updateControls() }]
        updatePicker(); updateControls(); load()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); updatePicker(); updateControls()
        navigationItem.rightBarButtonItem = onClose == nil ? nil : UIBarButtonItem(title:"Готово",style:.done,target:self,action:#selector(closeBrowser))
    }
    private func updatePicker() {
        let menus = availableGroups.map { group in
            UIMenu(title:group.name,children:group.sources.filter(\.enabled).map { destination in
                UIAction(title:destination.name,state:destination.id == source.id ? .on : .off) { [weak self] _ in self?.switchTo(destination,group:group) }
            })
        }
        sourceButton.setTitle((group.name == "1WIN" ? "1WIN • " : "") + source.name + "  ▾ Сменить",for:.normal)
        sourceButton.menu = UIMenu(title:"Выберите сайт",children:menus); sourceButton.showsMenuAsPrimaryAction = true
        for item in chips.arrangedSubviews { chips.removeArrangedSubview(item); item.removeFromSuperview() }
        var selected: UIView?
        for group in availableGroups {
            for destination in group.sources.filter(\.enabled) {
                let button = UIButton(type:.system)
                var configuration = UIButton.Configuration.filled()
                configuration.title = (group.name == "1WIN" ? "1WIN • " : "") + destination.name
                configuration.baseBackgroundColor = destination.id == source.id ? .systemBlue : .secondarySystemBackground
                configuration.baseForegroundColor = destination.id == source.id ? .white : .label
                configuration.contentInsets = NSDirectionalEdgeInsets(top:6,leading:10,bottom:6,trailing:10)
                configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var attributes = incoming; attributes.font = .systemFont(ofSize:12,weight:.medium); return attributes
                }
                button.configuration = configuration; button.accessibilityIdentifier = "web.quick." + destination.id
                button.addAction(UIAction { [weak self] _ in self?.switchTo(destination,group:group) },for:.touchUpInside)
                chips.addArrangedSubview(button); if destination.id == source.id { selected = button }
            }
        }
        if let selected { view.layoutIfNeeded(); chipScroll.scrollRectToVisible(selected.convert(selected.bounds,to:chips).insetBy(dx:-10,dy:0),animated:false) }
    }
    private func switchTo(_ destination: WebSource, group: WebGroup) {
        if destination.id == source.id { return }
        if let onSwitch { onSwitch(destination,group) }
        else {
            source = destination; fallbackTried = []
            UserDefaults.standard.set(destination.id,forKey:"kiborg.web.selected."+group.name)
            updatePicker(); load()
        }
    }
    private func updateControls() {
        backButton.isEnabled = web.canGoBack; forwardButton.isEnabled = web.canGoForward
        addressLabel.text = web.url?.host ?? URL(string:source.url)?.host ?? source.url
    }
    private func load() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-navigation") {
            let directory = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("web-audit")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let file = directory.appendingPathComponent(source.id + ".html")
            try? "<html><meta charset='utf-8'><meta name='viewport' content='width=device-width'><body style='background:#101827;color:white;font:22px -apple-system;padding:24px'><h1>\(source.name)</h1><p>Локальная проверка WEB-навигации</p><a href='detail.html'>Открыть следующую страницу</a><div style='height:1600px'></div></body></html>".write(to:file,atomically:true,encoding:.utf8)
            try? "<html><meta charset='utf-8'><meta name='viewport' content='width=device-width'><body style='background:#101827;color:white;font:22px -apple-system;padding:24px'><h1>Вторая страница</h1><p>Кнопка «Назад» возвращает внутри сайта.</p></body></html>".write(to:directory.appendingPathComponent("detail.html"),atomically:true,encoding:.utf8)
            web.loadFileURL(file,allowingReadAccessTo:directory); return
        }
        #endif
        guard let url = URL(string:source.url) else { failure(network:false); return }
        errorPanel.isHidden = true; title = source.name; updatePicker()
        web.load(URLRequest(url:url,cachePolicy:.reloadRevalidatingCacheData,timeoutInterval:10))
    }
    @objc private func sites() { onSites?() }
    @objc private func closeBrowser() { onClose?() }
    @objc private func back() { if web.canGoBack { web.goBack() } }
    @objc private func forward() { if web.canGoForward { web.goForward() } }
    @objc private func reload() {
        fallbackTried = []; errorPanel.isHidden = true
        if web.url == nil { load() } else { web.reload() }
    }
    @objc private func home() { source = homeSource; fallbackTried = []; updatePicker(); load() }
    @objc private func external() { if let url = web.url ?? URL(string:source.url), ["https","http"].contains(url.scheme ?? "") { UIApplication.shared.open(url) } }
    @objc private func reserve() {
        fallbackTried.insert(source.id)
        guard let next = group.sources.first(where: { $0.enabled && !fallbackTried.contains($0.id) }) else { errorPanel.isHidden = false; return }
        source = next
        UserDefaults.standard.set(next.id,forKey:"kiborg.web.selected."+group.name)
        updatePicker(); load()
    }
    private func failure(network: Bool) {
        timeout?.cancel(); spinner.stopAnimating(); updateControls()
        if network && group.name == "1WIN" && UserDefaults.standard.bool(forKey:"kiborg.1win.auto") { reserve() }
        else { errorPanel.isHidden = false }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorPanel.isHidden = true; spinner.startAnimating(); timeout?.cancel(); updateControls()
        let work = DispatchWorkItem { [weak self] in guard let self, self.web.isLoading else { return }; self.web.stopLoading(); self.failure(network:true) }
        timeout = work; DispatchQueue.main.asyncAfter(deadline:.now()+20,execute:work)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { timeout?.cancel(); spinner.stopAnimating(); errorPanel.isHidden = true; updateControls() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failure(network:true) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failure(network:true) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure(network:false) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            decisionHandler(.cancel); failure(network:response.statusCode >= 500)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { web.load(navigationAction.request) }; return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title:nil,message:message,preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"OK",style:.default) { _ in completionHandler() })
        present(alert,animated:true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title:nil,message:message,preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"Отмена",style:.cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title:"OK",style:.default) { _ in completionHandler(true) })
        present(alert,animated:true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title:nil,message:prompt,preferredStyle:.alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title:"Отмена",style:.cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title:"OK",style:.default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert,animated:true)
    }
}
#if DEBUG
// Simulator-only checks use local pages and the same row/button actions as the UI.
// Nothing is injected into third-party pages; Release has no audit command handler.
extension WebSourcesController {
    private var auditDirectory: URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0] }
    private func auditWrite(_ stage: String, _ result: Bool) {
        auditResults[stage] = result
        let data = try! JSONSerialization.data(withJSONObject:["stage":stage,"checks":auditResults],options:[.prettyPrinted,.sortedKeys])
        try? data.write(to:auditDirectory.appendingPathComponent("navigation-audit.json"),options:.atomic)
    }
    private func startNavigationAudit() {
        auditWrite("list",catalog.groups.flatMap(\.sources).count == 12 && groups.count == 3 && !settingsExpanded)
        auditTimer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in self?.auditReadCommand() }
    }
    private func auditReadCommand() {
        let file = auditDirectory.appendingPathComponent("navigation-command.txt")
        guard let command = try? String(contentsOf:file,encoding:.utf8) else { return }
        try? FileManager.default.removeItem(at:file)
        guard let group = catalog.groups.first, let first = group.sources.first, group.sources.count > 1 else { auditWrite(command,false); return }
        let current = navigationController?.topViewController as? ManagedBrowserController
        switch command.trimmingCharacters(in:.whitespacesAndNewlines) {
        case "open":
            tableView(tableView,didSelectRowAt:IndexPath(row:0,section:0))
            let browser = navigationController?.topViewController as? ManagedBrowserController
            auditInitialBrowser = browser
            auditWait(browser:browser,file:first.id + ".html",stage:"open")
        case "detail":
            current?.auditDetail()
            auditWait(browser:current,file:"detail.html",stage:"detail",extra:{ current?.auditCanBack == true })
        case "back":
            current?.auditBack()
            auditWait(browser:current,file:first.id + ".html",stage:"back")
        case "forward":
            current?.auditForward()
            auditWait(browser:current,file:"detail.html",stage:"forward")
        case "reload":
            current?.refreshPage()
            auditWait(browser:current,file:"detail.html",stage:"reload")
        case "home":
            current?.auditHome()
            auditWait(browser:current,file:first.id + ".html",stage:"home")
        case "switch":
            current?.auditMarkAndSwitch(group.sources[1],group:group) { [weak self] in
                guard let self else { return }
                self.auditWait(browser:self.navigationController?.topViewController as? ManagedBrowserController,file:group.sources[1].id + ".html",stage:"switch")
            }
        case "restore":
            current?.auditChoose(first,group:group)
            let restored = navigationController?.topViewController as? ManagedBrowserController
            restored?.auditMarker { [weak self] preserved in self?.auditWrite("restore",preserved && restored === self?.auditInitialBrowser) }
        case "sites":
            current?.auditSites()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in
                guard let self else { return }; self.auditWrite("sites",self.navigationController?.topViewController === self)
            }
        case "search":
            search.searchBar.text = "ХИЩНИК"; updateSearchResults(for:search)
            auditWrite("search",groups.count == 1 && groups.first?.sources.map(\.id) == ["bog"])
        case "settings":
            toggleSettings()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in
                guard let self else { return }
                let row = IndexPath(row:0,section:self.groups.count)
                let visible = self.tableView.indexPathsForVisibleRows?.contains(row) == true
                self.auditWrite("settings",self.settingsExpanded && self.groups.count == 3 && visible && self.navigationItem.searchController == nil)
            }
        case "picker":
            auditWrite("picker",auditInitialBrowser?.auditPickerCount == 12)
        case "reserve":
            guard let win = catalog.groups.first(where: { $0.name == "1WIN" }), win.sources.count > 1 else { auditWrite("reserve",false); return }
            search.searchBar.text = "one-vv7109.com"; updateSearchResults(for:search)
            tableView(tableView,didSelectRowAt:IndexPath(row:0,section:0))
            let browser = navigationController?.topViewController as? ManagedBrowserController
            browser?.auditReserve()
            auditWait(browser:browser,file:win.sources[1].id + ".html",stage:"reserve")
        case "reserve-home":
            guard let win = catalog.groups.first(where: { $0.name == "1WIN" }), let main = win.sources.first else { auditWrite("reserve-home",false); return }
            current?.auditChoose(main,group:win)
            auditWait(browser:navigationController?.topViewController as? ManagedBrowserController,file:main.id + ".html",stage:"reserve-home")
        default: auditWrite(command,false)
        }
    }
    private func auditWait(browser: ManagedBrowserController?, file: String, stage: String, attempts: Int = 80, extra: @escaping () -> Bool = { true }) {
        guard let browser else { auditWrite(stage,false); return }
        if browser.auditReady(file:file) { auditWrite(stage,extra()); return }
        if attempts == 0 { auditWrite(stage,false); return }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in self?.auditWait(browser:browser,file:file,stage:stage,attempts:attempts-1,extra:extra) }
    }
}
extension ManagedBrowserController {
    fileprivate var auditCanBack: Bool { web.canGoBack && backButton.isEnabled }
    fileprivate var auditPickerCount: Int { chips.arrangedSubviews.count }
    fileprivate func auditReady(file: String) -> Bool { !web.isLoading && web.url?.lastPathComponent == file && errorPanel.isHidden }
    fileprivate func auditDetail() {
        guard let directory = web.url?.deletingLastPathComponent() else { return }
        web.loadFileURL(directory.appendingPathComponent("detail.html"),allowingReadAccessTo:directory)
    }
    fileprivate func auditBack() { backButton.sendActions(for:.touchUpInside) }
    fileprivate func auditForward() { forwardButton.sendActions(for:.touchUpInside) }
    fileprivate func auditHome() { home() }
    fileprivate func auditSites() { sites() }
    fileprivate func auditReserve() { reserve() }
    fileprivate func auditChoose(_ source: WebSource, group: WebGroup) { switchTo(source,group:group) }
    fileprivate func auditMarkAndSwitch(_ destination: WebSource, group: WebGroup, completion: @escaping () -> Void) {
        web.evaluateJavaScript("window.kiborgNavigationMarker='preserved'; window.scrollTo(0,150);") { [weak self] _,_ in
            self?.switchTo(destination,group:group); completion()
        }
    }
    fileprivate func auditMarker(_ completion: @escaping (Bool) -> Void) {
        web.evaluateJavaScript("window.kiborgNavigationMarker==='preserved' && window.scrollY>=100") { value,error in completion(error == nil && value as? Bool == true) }
    }
}
#endif
