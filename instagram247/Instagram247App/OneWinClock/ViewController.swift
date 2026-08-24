import UIKit
import CryptoKit
import Security

private enum SecureStore {
    static let service = "com.miuiproking.instagram247.secure"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class ViewController: UIViewController, UITextFieldDelegate {
    private let commandTopic = "ig247h-cmd-cd4f6a6f08fa8650818cb8846c4a949df59df473fa449904"
    private let eventTopic = "ig247h-evt-cfbd5eef08a5bfd00fee593e573b746a3380dbe5b1b7a1fe"
    private let builtInPairSecret = "__IG247_AUTOPAIR_SECRET__"
    private let ntfyBase = "https://ntfy.sh"

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let statusDot = UIView()
    private let statusTitle = UILabel()
    private let statusDetail = UILabel()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let codeField = UITextField()
    private let logView = UITextView()
    private let connectButton = UIButton(type: .system)
    private let loginButton = UIButton(type: .system)
    private let codeButton = UIButton(type: .system)
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let statusButton = UIButton(type: .system)
    private let securityButton = UIButton(type: .system)
    private let logoutButton = UIButton(type: .system)

    private var pollTimer: Timer?
    private var polling = false
    private var seenEventIDs: [String] = []
    private var seenEventSet = Set<String>()
    private var gradientLayer: CAGradientLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildBackground()
        buildUI()
        loadSavedCredentials()
        startPolling()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.connectAndUnlock() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in self?.sendCommand("status") }
    }

    deinit {
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer?.frame = view.bounds
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func buildBackground() {
        view.backgroundColor = .black
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 0.07, green: 0.01, blue: 0.12, alpha: 1).cgColor,
            UIColor.black.cgColor,
            UIColor(red: 0.05, green: 0.01, blue: 0.09, alpha: 1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        view.layer.insertSublayer(gradient, at: 0)
        gradientLayer = gradient
    }

    private func buildUI() {
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28)
        ])

        let logo = UILabel()
        logo.text = "◎"
        logo.textAlignment = .center
        logo.textColor = UIColor(red: 1.0, green: 0.25, blue: 0.65, alpha: 1)
        logo.font = .systemFont(ofSize: 74, weight: .black)
        logo.layer.shadowColor = UIColor.systemPink.cgColor
        logo.layer.shadowOpacity = 0.85
        logo.layer.shadowRadius = 18
        logo.layer.shadowOffset = .zero
        contentStack.addArrangedSubview(logo)

        let title = makeLabel("INSTAGRAM 24/7", size: 30, weight: .black, color: .white)
        title.textAlignment = .center
        contentStack.addArrangedSubview(title)

        let developer = makeLabel("HARDENED • @V0XFF3", size: 13, weight: .bold, color: .systemPurple)
        developer.textAlignment = .center
        contentStack.addArrangedSubview(developer)

        let statusCard = makeCard()
        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 10
        statusDot.backgroundColor = .systemOrange
        statusDot.layer.cornerRadius = 7
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 14),
            statusDot.heightAnchor.constraint(equalToConstant: 14)
        ])
        statusTitle.text = "СЕРВЕР: ПОДКЛЮЧЕНИЕ…"
        statusTitle.textColor = .white
        statusTitle.font = .systemFont(ofSize: 15, weight: .black)
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusTitle)
        statusCard.addArrangedSubview(statusRow)
        statusDetail.text = "Открой приложение после каждого перезапуска хостинга."
        statusDetail.textColor = UIColor.white.withAlphaComponent(0.72)
        statusDetail.font = .systemFont(ofSize: 12, weight: .medium)
        statusDetail.numberOfLines = 0
        statusCard.addArrangedSubview(statusDetail)
        contentStack.addArrangedSubview(statusCard)

        let credentials = makeCard()
        credentials.addArrangedSubview(sectionTitle("ВХОД INSTAGRAM"))
        configureField(usernameField, placeholder: "Логин Instagram", secure: false)
        usernameField.textContentType = .username
        usernameField.autocapitalizationType = .none
        configureField(passwordField, placeholder: "Пароль — хранится в Keychain", secure: true)
        passwordField.textContentType = .password
        configureField(codeField, placeholder: "Одноразовый код 2FA", secure: false)
        codeField.keyboardType = .numberPad
        credentials.addArrangedSubview(usernameField)
        credentials.addArrangedSubview(passwordField)
        credentials.addArrangedSubview(codeField)
        contentStack.addArrangedSubview(credentials)

        configureButton(connectButton, title: "🔗 АВТОПОДКЛЮЧЕНИЕ СЕРВЕРА", color: .systemPurple, selector: #selector(connectTapped))
        configureButton(loginButton, title: "🔐 ВОЙТИ INSTAGRAM", color: UIColor(red: 0.95, green: 0.16, blue: 0.52, alpha: 1), selector: #selector(loginTapped))
        configureButton(codeButton, title: "📩 ОТПРАВИТЬ КОД 2FA", color: .systemIndigo, selector: #selector(codeTapped))
        contentStack.addArrangedSubview(connectButton)
        contentStack.addArrangedSubview(loginButton)
        contentStack.addArrangedSubview(codeButton)

        let onlineRow = buttonRow()
        configureButton(startButton, title: "🟢 ВКЛ 24/7", color: .systemGreen, selector: #selector(startTapped), compact: true)
        configureButton(stopButton, title: "⏸ ВЫКЛ", color: .systemOrange, selector: #selector(stopTapped), compact: true)
        onlineRow.addArrangedSubview(startButton)
        onlineRow.addArrangedSubview(stopButton)
        contentStack.addArrangedSubview(onlineRow)

        let checkRow = buttonRow()
        configureButton(statusButton, title: "📊 СТАТУС", color: .systemBlue, selector: #selector(statusTapped), compact: true)
        configureButton(securityButton, title: "🛡 ЗАЩИТА", color: .systemTeal, selector: #selector(securityTapped), compact: true)
        checkRow.addArrangedSubview(statusButton)
        checkRow.addArrangedSubview(securityButton)
        contentStack.addArrangedSubview(checkRow)

        let logCard = makeCard()
        logCard.addArrangedSubview(sectionTitle("ОТВЕТ СЕРВЕРА"))
        logView.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        logView.textColor = .white
        logView.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        logView.isEditable = false
        logView.isSelectable = true
        logView.layer.cornerRadius = 12
        logView.text = "Ожидаю сервер…\n\nПароль не попадает в Python-файл или GitHub. После входа он хранится на сервере только в зашифрованном vault."
        logView.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        logCard.addArrangedSubview(logView)
        contentStack.addArrangedSubview(logCard)

        configureButton(logoutButton, title: "🚨 УДАЛИТЬ СЕССИЮ С СЕРВЕРА", color: .systemRed, selector: #selector(logoutTapped))
        contentStack.addArrangedSubview(logoutButton)

        let note = makeLabel(
            "Сервер продолжает Realtime MQTT и keepalive, даже когда IPA закрыто. Instagram самостоятельно определяет отображение зелёной точки.",
            size: 12,
            weight: .medium,
            color: UIColor.white.withAlphaComponent(0.62)
        )
        note.textAlignment = .center
        note.numberOfLines = 0
        contentStack.addArrangedSubview(note)
    }

    private func makeCard() -> UIStackView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        card.backgroundColor = UIColor.white.withAlphaComponent(0.075)
        card.layer.cornerRadius = 17
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.13).cgColor
        return card
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color
        label.font = .systemFont(ofSize: size, weight: weight)
        label.numberOfLines = 0
        return label
    }

    private func sectionTitle(_ text: String) -> UILabel {
        makeLabel(text, size: 13, weight: .black, color: .systemPink)
    }

    private func configureField(_ field: UITextField, placeholder: String, secure: Bool) {
        field.placeholder = placeholder
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.42)]
        )
        field.textColor = .white
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        field.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        field.isSecureTextEntry = secure
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.heightAnchor.constraint(equalToConstant: 49).isActive = true
        field.setLeftPadding(13)
    }

    private func configureButton(_ button: UIButton, title: String, color: UIColor, selector: Selector, compact: Bool = false) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: compact ? 14 : 15, weight: .black)
        button.backgroundColor = color
        button.layer.cornerRadius = 13
        button.layer.shadowColor = color.cgColor
        button.layer.shadowOpacity = 0.32
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = .zero
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: compact ? 48 : 52).isActive = true
    }

    private func buttonRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 9
        return row
    }

    private func loadSavedCredentials() {
        usernameField.text = UserDefaults.standard.string(forKey: "instagram247.username") ?? "vyacheslavvya"
        if let data = SecureStore.read("instagram_password") {
            passwordField.text = String(data: data, encoding: .utf8)
        }
    }

    private func signingKey() throws -> P256.Signing.PrivateKey {
        if let data = SecureStore.read("device_signing_key") {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = P256.Signing.PrivateKey()
        guard SecureStore.save(key.rawRepresentation, account: "device_signing_key") else {
            throw NSError(domain: "Instagram247", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить ключ iPhone"])
        }
        return key
    }

    private func vaultKey() throws -> Data {
        if let data = SecureStore.read("vault_key"), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw NSError(domain: "Instagram247", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать vault key"])
        }
        let data = Data(bytes)
        guard SecureStore.save(data, account: "vault_key") else {
            throw NSError(domain: "Instagram247", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить vault key"])
        }
        return data
    }

    private func deviceID() -> String {
        if let value = UserDefaults.standard.string(forKey: "instagram247.device_id") { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "instagram247.device_id")
        return value
    }

    private func bridgeKey() -> SymmetricKey {
        let digest = SHA256.hash(data: Data(("bridge:" + builtInPairSecret).utf8))
        return SymmetricKey(data: Data(digest))
    }

    private func seal(_ object: [String: Any]) throws -> String {
        let clear = try JSONSerialization.data(withJSONObject: object, options: [])
        let box = try AES.GCM.seal(clear, using: bridgeKey())
        guard let combined = box.combined else { throw NSError(domain: "Instagram247", code: 4) }
        return combined.base64EncodedString()
    }

    private func open(_ value: String) throws -> [String: Any] {
        guard let raw = Data(base64Encoded: value) else { throw NSError(domain: "Instagram247", code: 5) }
        let box = try AES.GCM.SealedBox(combined: raw)
        let clear = try AES.GCM.open(box, using: bridgeKey())
        guard let object = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else {
            throw NSError(domain: "Instagram247", code: 6)
        }
        return object
    }

    private func sendCommand(_ action: String, fields: [String: Any] = [:]) {
        do {
            let key = try signingKey()
            let command: [String: Any] = [
                "action": action,
                "device_id": deviceID(),
                "request_id": UUID().uuidString.lowercased(),
                "ts_ms": Int64(Date().timeIntervalSince1970 * 1000),
                "fields": fields
            ]
            let payload = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
            let signature = try key.signature(for: payload).derRepresentation
            let envelope: [String: Any] = [
                "payload": payload.base64EncodedString(),
                "signature": signature.base64EncodedString()
            ]
            let encrypted = try seal(envelope)
            guard let url = URL(string: "\(ntfyBase)/\(commandTopic)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = Data(encrypted.utf8)
            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                DispatchQueue.main.async {
                    if let error {
                        self?.showLocalError("Не удалось отправить команду: \(error.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        self?.showLocalError("Сервис связи HTTP \(http.statusCode)")
                    }
                }
            }.resume()
        } catch {
            showLocalError(error.localizedDescription)
        }
    }

    private func connectAndUnlock() {
        do {
            let key = try signingKey()
            sendCommand("pair", fields: ["public_key": key.publicKey.x963Representation.base64EncodedString()])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else { return }
                do {
                    self.sendCommand("unlock", fields: ["vault_key": try self.vaultKey().base64EncodedString()])
                } catch {
                    self.showLocalError(error.localizedDescription)
                }
            }
            setStatus(title: "СЕРВЕР: АВТОПОДКЛЮЧЕНИЕ…", detail: "Код из логов не нужен. Привязываю iPhone и разблокирую vault.", color: .systemOrange)
        } catch {
            showLocalError(error.localizedDescription)
        }
    }

    private func startPolling() {
        pollEvents()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(timeInterval: 4, target: self, selector: #selector(pollEvents), userInfo: nil, repeats: true)
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
    }

    @objc private func pollEvents() {
        guard !polling else { return }
        polling = true
        guard let url = URL(string: "\(ntfyBase)/\(eventTopic)/json?poll=1&since=30s") else {
            polling = false
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async { self?.polling = false }
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                guard let raw = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      event["event"] as? String == "message",
                      let message = event["message"] as? String else { continue }
                let eventID = event["id"] as? String ?? UUID().uuidString
                DispatchQueue.main.async {
                    guard !self.seenEventSet.contains(eventID) else { return }
                    self.rememberEvent(eventID)
                    if let payload = try? self.open(message) { self.applyEvent(payload) }
                }
            }
        }.resume()
    }

    private func rememberEvent(_ id: String) {
        seenEventIDs.append(id)
        seenEventSet.insert(id)
        while seenEventIDs.count > 200 {
            let old = seenEventIDs.removeFirst()
            seenEventSet.remove(old)
        }
    }

    private func applyEvent(_ payload: [String: Any]) {
        let text = payload["text"] as? String ?? "Ответ без текста"
        let state = payload["state"] as? String ?? "connected"
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logView.text = "\(time)\n\(text)\n\n" + String(logView.text.prefix(1800))
        switch state {
        case "online":
            setStatus(title: "СЕРВЕР: ONLINE 24/7", detail: "Realtime MQTT работает независимо от IPA.", color: .systemGreen)
        case "authorized":
            setStatus(title: "СЕРВЕР: АВТОРИЗОВАН", detail: "Сессия сохранена, онлайн сейчас выключен.", color: .systemBlue)
        case "offline":
            setStatus(title: "СЕРВЕР: OFFLINE", detail: "Нажми «ВКЛ 24/7», чтобы снова запустить keepalive.", color: .systemOrange)
        case "logged_out":
            setStatus(title: "СЕРВЕР: ВЫПОЛНЕН ВЫХОД", detail: "Зашифрованная сессия удалена.", color: .systemRed)
        default:
            setStatus(title: "СЕРВЕР: СВЯЗЬ ЕСТЬ", detail: "Парный сервер отвечает приложению.", color: .systemTeal)
        }
    }

    private func setStatus(title: String, detail: String, color: UIColor) {
        statusTitle.text = title
        statusDetail.text = detail
        statusDot.backgroundColor = color
        statusDot.layer.shadowColor = color.cgColor
        statusDot.layer.shadowOpacity = 1
        statusDot.layer.shadowRadius = 8
        statusDot.layer.shadowOffset = .zero
    }

    private func showLocalError(_ text: String) {
        setStatus(title: "ОШИБКА СВЯЗИ", detail: text, color: .systemRed)
        logView.text = "❌ \(text)\n\n" + String(logView.text.prefix(1800))
    }

    @objc private func appBecameActive() {
        connectAndUnlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in self?.sendCommand("status") }
    }

    @objc private func connectTapped() { connectAndUnlock() }

    @objc private func loginTapped() {
        view.endEditing(true)
        let username = (usernameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        let password = passwordField.text ?? ""
        guard !username.isEmpty, !password.isEmpty else {
            showLocalError("Введи логин и пароль Instagram")
            return
        }
        UserDefaults.standard.set(username, forKey: "instagram247.username")
        SecureStore.save(Data(password.utf8), account: "instagram_password")
        sendCommand("login_start", fields: ["username": username, "password": password])
        setStatus(title: "INSTAGRAM: ВХОД…", detail: "Ожидаю ответ Instagram. При запросе введи код 2FA.", color: .systemOrange)
    }

    @objc private func codeTapped() {
        view.endEditing(true)
        let code = (codeField.text ?? "").replacingOccurrences(of: " ", with: "")
        guard !code.isEmpty else {
            showLocalError("Введи одноразовый код Instagram")
            return
        }
        sendCommand("login_code", fields: ["code": code])
        codeField.text = ""
    }

    @objc private func startTapped() { sendCommand("online_start") }
    @objc private func stopTapped() { sendCommand("online_stop") }
    @objc private func statusTapped() { sendCommand("status") }
    @objc private func securityTapped() { sendCommand("security") }

    @objc private func logoutTapped() {
        let alert = UIAlertController(
            title: "Удалить серверную сессию?",
            message: "Instagram будет отключён от сервера. Для повторного запуска потребуется новый вход.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
            self?.sendCommand("logout_server")
        })
        present(alert, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

private extension UITextField {
    func setLeftPadding(_ amount: CGFloat) {
        let spacer = UIView(frame: CGRect(x: 0, y: 0, width: amount, height: 1))
        leftView = spacer
        leftViewMode = .always
    }
}
