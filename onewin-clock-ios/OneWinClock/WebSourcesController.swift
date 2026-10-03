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

final class WebSourcesController: UITableViewController {
    private let manager: SourceManager
    private let catalog = WebCatalog.load()
    private var checks: [String: String] = [:]
    private var tasks: [String: URLSessionDataTask] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 10; c.waitsForConnectivity = false
        return URLSession(configuration:c)
    }()
    init(manager: SourceManager) { self.manager = manager; super.init(style:.insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        checks = UserDefaults.standard.dictionary(forKey:"kiborg.web.health") as? [String:String] ?? [:]
        title = "📌 WEB / Источники"
        overrideUserInterfaceStyle = .dark
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"Готово",style:.done,target:self,action:#selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"Обновить",style:.plain,target:self,action:#selector(refresh))
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self,action:#selector(refresh),for:.valueChanged)
    }
    deinit { session.invalidateAndCancel() }
    @objc private func close() { dismiss(animated:true) }
    @objc private func refresh() {
        tableView.reloadData(); refreshControl?.endRefreshing()
        for s in catalog.groups.flatMap(\.sources).filter(\.enabled) { check(s) }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { catalog.groups.count + 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 3 : catalog.groups[section-1].sources.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "⚙️ Источник коэффициентов" : catalog.groups[section-1].name
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "API и WEB выбираются независимо. HTTP 200 страницы не подтверждает её прогнозы. SESSION хранится в Keychain; ключи в IPA не встроены." }
        if catalog.groups[section-1].name == "1WIN" { return "AUTO переключается на резерв только при сетевой ошибке / HTTP 5xx. Обычные redirect разрешены." }
        return "Нажмите строку: Открыть / Выбрать / Проверить / Обновить. Выбор сохраняется после перезапуска."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0: cell.textLabel?.text = "API: \(manager.selection)"; cell.detailTextLabel?.text = manager.summary()
            case 1: cell.textLabel?.text = "SESSION • свой session-id"; cell.detailTextLabel?.text = SessionVault.value.isEmpty ? "Не настроен • прямой API требует входа" : "Сохранён в Keychain • значение скрыто"
            default: cell.textLabel?.text = "1WIN: \(UserDefaults.standard.bool(forKey:"kiborg.1win.auto") ? "AUTO" : "РУЧНОЙ")"; cell.detailTextLabel?.text = "Включить / выключить автоматический резерв"
            }
        } else {
            let s = catalog.groups[indexPath.section-1].sources[indexPath.row]
            let group = catalog.groups[indexPath.section-1].name
            let active = UserDefaults.standard.string(forKey:"kiborg.web.selected." + group) == s.id
            cell.textLabel?.text = (active ? "✅ АКТИВНЫЙ • " : "") + s.name
            cell.detailTextLabel?.text = s.url + "\n" + (checks[s.id] ?? "NOT VERIFIED • ещё не проверен на этом устройстве")
            cell.textLabel?.numberOfLines = 0
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        if indexPath.section == 0 {
            if indexPath.row == 0 { selectAPI() }
            else if indexPath.row == 1 { setSession() }
            else {
                let defaults = UserDefaults.standard
                defaults.set(!defaults.bool(forKey:"kiborg.1win.auto"),forKey:"kiborg.1win.auto")
                tableView.reloadData()
            }
            return
        }
        let group = catalog.groups[indexPath.section-1]
        let source = group.sources[indexPath.row]
        let menu = UIAlertController(title:source.name,message:source.url,preferredStyle:.actionSheet)
        menu.addAction(UIAlertAction(title:"ОТКРЫТЬ",style:.default) { [weak self] _ in self?.open(source,group:group) })
        menu.addAction(UIAlertAction(title:"ВЫБРАТЬ",style:.default) { [weak self] _ in
            UserDefaults.standard.set(source.id,forKey:"kiborg.web.selected."+group.name)
            self?.tableView.reloadData()
        })
        menu.addAction(UIAlertAction(title:"ПРОВЕРИТЬ",style:.default) { [weak self] _ in self?.check(source) })
        menu.addAction(UIAlertAction(title:"ОБНОВИТЬ / ОТКРЫТЬ",style:.default) { [weak self] _ in self?.check(source); self?.open(source,group:group) })
        menu.addAction(UIAlertAction(title:"Отмена",style:.cancel))
        anchor(menu,indexPath:indexPath); present(menu,animated:true)
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
            guard let self else { return }; self.manager.fetch(force:true,only:self.manager.selection == "AUTO" ? "main" : self.manager.selection) { _ in self.tableView.reloadData() }
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
        UserDefaults.standard.set(source.id,forKey:"kiborg.web.selected."+group.name)
        let browser = ManagedBrowserController(source:source,group:group)
        navigationController?.pushViewController(browser,animated:true)
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

final class ManagedBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var source: WebSource
    private let homeSource: WebSource
    private let group: WebGroup
    var homeURL: String { homeSource.url }
    func navigateBack() { back() }
    func refreshPage() { reload() }
    private let web: WKWebView
    private let spinner = UIActivityIndicatorView(style:.large)
    private let errorPanel = UIStackView()
    private var observation: NSKeyValueObservation?
    private var fallbackTried = Set<String>()
    private var timeout: DispatchWorkItem?
    init(source: WebSource, group: WebGroup) {
        self.source = source; homeSource = source; self.group = group
        let c = WKWebViewConfiguration(); c.websiteDataStore = .default(); c.allowsInlineMediaPlayback = true
        web = WKWebView(frame:.zero,configuration:c)
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    deinit { timeout?.cancel(); observation?.invalidate(); web.stopLoading() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black; title = source.name
        web.navigationDelegate = self; web.uiDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(web)
        let controls: [(String,Selector)] = [("‹",#selector(back)),("›",#selector(forward)),("↻",#selector(reload)),("⌂",#selector(home)),("↗",#selector(external))]
        let toolbar = UIStackView(); toolbar.distribution = .fillEqually; toolbar.spacing = 4
        for (title,selector) in controls {
            let button = UIButton(type:.system); button.setTitle(title,for:.normal); button.titleLabel?.font = .boldSystemFont(ofSize:24)
            button.backgroundColor = .secondarySystemBackground; button.addTarget(self,action:selector,for:.touchUpInside); toolbar.addArrangedSubview(button)
        }
        toolbar.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),toolbar.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor),toolbar.heightAnchor.constraint(equalToConstant:48),
            web.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),web.leadingAnchor.constraint(equalTo:view.leadingAnchor),web.trailingAnchor.constraint(equalTo:view.trailingAnchor),web.bottomAnchor.constraint(equalTo:toolbar.topAnchor)
        ])
        spinner.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo:view.centerXAnchor),spinner.centerYAnchor.constraint(equalTo:view.centerYAnchor)])
        errorPanel.axis = .vertical; errorPanel.spacing = 20; errorPanel.backgroundColor = .systemBackground
        let label = UILabel(); label.text = "❌ Сайт временно недоступен"; label.textAlignment = .center; label.numberOfLines = 0
        errorPanel.addArrangedSubview(label)
        for (title,action) in [("ПОВТОРИТЬ",#selector(reload)),("РЕЗЕРВНЫЙ ИСТОЧНИК",#selector(reserve))] {
            let button = UIButton(type:.system); button.setTitle(title,for:.normal); button.addTarget(self,action:action,for:.touchUpInside); errorPanel.addArrangedSubview(button)
        }
        errorPanel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(errorPanel); errorPanel.isHidden = true
        NSLayoutConstraint.activate([errorPanel.centerYAnchor.constraint(equalTo:view.centerYAnchor),errorPanel.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),errorPanel.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16)])
        observation = web.observe(\.estimatedProgress,options:[.new]) { [weak self] _,_ in
            DispatchQueue.main.async { guard let self else { return }; if self.web.isLoading { self.spinner.startAnimating() } else { self.spinner.stopAnimating() } }
        }
        load()
    }
    private func load() {
        guard let url = URL(string:source.url) else { failure(network:false); return }
        errorPanel.isHidden = true; title = source.name
        web.load(URLRequest(url:url,cachePolicy:.reloadRevalidatingCacheData,timeoutInterval:10))
    }
    @objc private func back() { if web.canGoBack { web.goBack() } }
    @objc private func forward() { if web.canGoForward { web.goForward() } }
    @objc private func reload() { fallbackTried = []; load() }
    @objc private func home() { source = homeSource; fallbackTried = []; load() }
    @objc private func external() { if let url = web.url ?? URL(string:source.url) { UIApplication.shared.open(url) } }
    @objc private func reserve() {
        fallbackTried.insert(source.id)
        guard let next = group.sources.first(where: { $0.enabled && !fallbackTried.contains($0.id) }) else { errorPanel.isHidden = false; return }
        source = next; load()
    }
    private func failure(network: Bool) {
        timeout?.cancel(); spinner.stopAnimating()
        if network && group.name == "1WIN" && UserDefaults.standard.bool(forKey:"kiborg.1win.auto") { reserve() }
        else { errorPanel.isHidden = false }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorPanel.isHidden = true; spinner.startAnimating(); timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in guard let self, self.web.isLoading else { return }; self.web.stopLoading(); self.failure(network:true) }
        timeout = work; DispatchQueue.main.asyncAfter(deadline:.now()+20,execute:work)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { timeout?.cancel(); spinner.stopAnimating(); errorPanel.isHidden = true }
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
