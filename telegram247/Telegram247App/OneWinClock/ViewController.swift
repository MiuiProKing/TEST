import UIKit
import CryptoKit
import Security

private enum PairConfig {
    static let baseURL = "https://ntfy.sh"
    static let commandTopic = "__TG247H_CMD_TOPIC__"
    static let eventTopic = "__TG247H_EVT_TOPIC__"
    static let pairSecret = "__TG247H_PAIR_SECRET__"
}

private struct NtfyEnvelope: Decodable {
    let id: String?
    let event: String?
    let message: String?
}

private struct ServerEvent {
    let id: String
    let kind: String
    let text: String
    let state: String?
}

private enum BridgeError: LocalizedError {
    case invalidConfig, crypto, transport, keychain
    var errorDescription: String? {
        switch self {
        case .invalidConfig: return "Неверная конфигурация защищённой пары"
        case .crypto: return "Ошибка защищённого канала"
        case .transport: return "Сервер связи недоступен"
        case .keychain: return "Не удалось открыть защищённый Keychain"
        }
    }
}

private enum KeychainStore {
    private static let service = "com.miuiproking.telegram247hardened"
    static func load(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    @discardableResult static func save(_ data: Data, account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

private final class DeviceIdentity {
    private let privateKey: P256.Signing.PrivateKey
    let deviceID: String
    let vaultKey: Data

    init() throws {
        if let stored = KeychainStore.load("p256_signing_private"), let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) {
            privateKey = key
        } else {
            let key = P256.Signing.PrivateKey()
            guard KeychainStore.save(key.rawRepresentation, account: "p256_signing_private") else { throw BridgeError.keychain }
            privateKey = key
        }
        if let stored = KeychainStore.load("device_id"), let text = String(data: stored, encoding: .utf8), !text.isEmpty {
            deviceID = text
        } else {
            let text = UUID().uuidString.lowercased()
            guard KeychainStore.save(Data(text.utf8), account: "device_id") else { throw BridgeError.keychain }
            deviceID = text
        }
        if let stored = KeychainStore.load("vault_key"), stored.count == 32 {
            vaultKey = stored
        } else {
            var data = Data(count: 32)
            let result = data.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, 32, base)
            }
            guard result == errSecSuccess, KeychainStore.save(data, account: "vault_key") else { throw BridgeError.keychain }
            vaultKey = data
        }
    }

    var publicKeyBase64: String { privateKey.publicKey.x963Representation.base64EncodedString() }
    var fingerprint: String {
        SHA256.hash(data: privateKey.publicKey.x963Representation).map { String(format: "%02x", $0) }.joined()
    }
    func sign(_ data: Data) throws -> Data { try privateKey.signature(for: data).derRepresentation }
    func saveAPICredentials(apiID: Int, apiHash: String, phone: String) {
        let obj: [String: Any] = ["api_id": apiID, "api_hash": apiHash, "phone": phone]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { _ = KeychainStore.save(data, account: "api_credentials") }
    }
    func loadAPICredentials() -> (Int, String, String)? {
        guard let data = KeychainStore.load("api_credentials"), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let apiID = obj["api_id"] as? Int, let apiHash = obj["api_hash"] as? String, let phone = obj["phone"] as? String else { return nil }
        return (apiID, apiHash, phone)
    }
    func deleteAPICredentials() { KeychainStore.delete("api_credentials") }
}

private final class SecureBridge {
    private let session: URLSession
    private let identity: DeviceIdentity
    private var seenEventIDs = Set<String>()
    private var isPolling = false

    init(identity: DeviceIdentity) {
        self.identity = identity
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 18
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    private var bridgeKey: SymmetricKey {
        let digest = SHA256.hash(data: Data(("bridge:" + PairConfig.pairSecret).utf8))
        return SymmetricKey(data: Data(digest))
    }
    private func encrypt(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        let sealed = try AES.GCM.seal(data, using: bridgeKey)
        guard let combined = sealed.combined else { throw BridgeError.crypto }
        return combined.base64EncodedString()
    }
    private func decrypt(_ encoded: String) throws -> [String: Any] {
        guard let combined = Data(base64Encoded: encoded) else { throw BridgeError.crypto }
        let clear = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: bridgeKey)
        guard let json = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else { throw BridgeError.crypto }
        return json
    }

    func send(action: String, fields: [String: Any] = [:], completion: @escaping (Result<Void, Error>) -> Void) {
        guard !PairConfig.commandTopic.contains("__TG247H_"), !PairConfig.pairSecret.contains("__TG247H_"), let url = URL(string: "\(PairConfig.baseURL)/\(PairConfig.commandTopic)") else { completion(.failure(BridgeError.invalidConfig)); return }
        var secureFields = fields
        if action == "pair" { secureFields["public_key"] = identity.publicKeyBase64 }
        let payload: [String: Any] = ["action": action, "request_id": UUID().uuidString.lowercased(), "ts_ms": Int64(Date().timeIntervalSince1970 * 1000), "device_id": identity.deviceID, "fields": secureFields]
        do {
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            let envelope: [String: Any] = ["payload": payloadData.base64EncodedString(), "signature": try identity.sign(payloadData).base64EncodedString()]
            let body = try encrypt(envelope)
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = Data(body.utf8)
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type"); req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            session.dataTask(with: req) { _, response, error in
                if let error { completion(.failure(error)); return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { completion(.failure(BridgeError.transport)); return }
                completion(.success(()))
            }.resume()
        } catch { completion(.failure(error)) }
    }

    func poll(completion: @escaping (Result<[ServerEvent], Error>) -> Void) {
        guard !isPolling else { return }
        isPolling = true
        var components = URLComponents(string: "\(PairConfig.baseURL)/\(PairConfig.eventTopic)/json")!
        components.queryItems = [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: "20s")]
        guard let url = components.url else { isPolling = false; completion(.failure(BridgeError.invalidConfig)); return }
        var req = URLRequest(url: url); req.httpMethod = "GET"; req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.isPolling = false }
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else { completion(.failure(BridgeError.transport)); return }
            let text = String(data: data, encoding: .utf8) ?? ""
            var events: [ServerEvent] = []
            for line in text.split(separator: "\n") {
                guard let raw = String(line).data(using: .utf8), let env = try? JSONDecoder().decode(NtfyEnvelope.self, from: raw), env.event == "message", let id = env.id, let message = env.message else { continue }
                if self.seenEventIDs.contains(id) { continue }
                self.seenEventIDs.insert(id)
                if self.seenEventIDs.count > 250 { self.seenEventIDs.removeAll(keepingCapacity: true) }
                if let json = try? self.decrypt(message) {
                    events.append(ServerEvent(id: id, kind: json["kind"] as? String ?? "message", text: json["text"] as? String ?? "", state: json["state"] as? String))
                }
            }
            completion(.success(events))
        }.resume()
    }
}

final class ViewController: UIViewController, UITextFieldDelegate {
    private let identity: DeviceIdentity
    private let bridge: SecureBridge
    private let bg = UIColor.black
    private let panel = UIColor(white: 0.08, alpha: 1)
    private let secondary = UIColor(white: 0.15, alpha: 1)
    private let green = UIColor(red: 0.36, green: 0.80, blue: 0.42, alpha: 1)
    private let blue = UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1)
    private let red = UIColor(red: 0.95, green: 0.28, blue: 0.28, alpha: 1)
    private let statusLabel = UILabel(), outputView = UITextView(), apiIdField = UITextField(), apiHashField = UITextField(), phoneField = UITextField(), codeField = UITextField(), passwordField = UITextField(), clockLabel = UILabel()
    private var pollTimer: Timer?, clockTimer: Timer?, lastServerEvent = Date.distantPast
    private var didRequestUnlock = false

    required init?(coder: NSCoder) {
        do { let id = try DeviceIdentity(); identity = id; bridge = SecureBridge(identity: id); super.init(coder: coder) } catch { return nil }
    }
    init() { let id = try! DeviceIdentity(); identity = id; bridge = SecureBridge(identity: id); super.init(nibName: nil, bundle: nil) }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = bg; UIApplication.shared.isIdleTimerDisabled = true
        buildUI(); restoreAPIFields(); startTimers()
        append("🛡 HARDENED V2. Приватный ключ команд и ключ шифрования сессии находятся в Keychain этого iPhone.")
        append("📱 Отпечаток устройства: \(identity.fingerprint.prefix(16))")
        bootstrapSecurity()
    }
    deinit { pollTimer?.invalidate(); clockTimer?.invalidate() }

    private func buildUI() {
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        let content = UIStackView(); content.axis = .vertical; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false; content.isLayoutMarginsRelativeArrangement = true; content.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 24, right: 14); scroll.addSubview(content)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)])
        let titleRow = UIStackView(); titleRow.axis = .horizontal; titleRow.alignment = .center
        let title = UILabel(); title.text = "TELEGRAM 24/7 🔐"; title.textColor = .white; title.font = .systemFont(ofSize: 25, weight: .black); titleRow.addArrangedSubview(title); titleRow.addArrangedSubview(UIView())
        clockLabel.textColor = .white; clockLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold); titleRow.addArrangedSubview(clockLabel); content.addArrangedSubview(titleRow)
        statusLabel.text = "● ЗАЩИТА: подключение…"; statusLabel.font = .systemFont(ofSize: 16, weight: .bold); statusLabel.textColor = .systemOrange; content.addArrangedSubview(statusLabel)

        let securityPanel = panelStack(title: "🛡 ПРИВЯЗКА И ЗАЩИТА")
        let fp = UILabel(); fp.text = "iPhone key: \(identity.fingerprint.prefix(16))…"; fp.textColor = .lightGray; fp.font = .monospacedSystemFont(ofSize: 12, weight: .medium); securityPanel.addArrangedSubview(fp)
        securityPanel.addArrangedSubview(actionButton("🔓 РАЗБЛОКИРОВАТЬ СЕРВЕР ЭТИМ IPHONE", color: blue, selector: #selector(unlockServer)))
        securityPanel.addArrangedSubview(actionButton("🛡 ПРОВЕРИТЬ ЗАЩИТУ", color: secondary, selector: #selector(checkSecurity))); content.addArrangedSubview(securityPanel)

        let loginPanel = panelStack(title: "🔐 ВХОД В TELEGRAM")
        loginPanel.addArrangedSubview(field(apiIdField, placeholder: "API ID", keyboard: .numberPad)); loginPanel.addArrangedSubview(field(apiHashField, placeholder: "API HASH", secure: true)); loginPanel.addArrangedSubview(field(phoneField, placeholder: "+380… номер телефона", keyboard: .phonePad)); loginPanel.addArrangedSubview(actionButton("1. 📩 ПОЛУЧИТЬ КОД", color: blue, selector: #selector(requestCode))); loginPanel.addArrangedSubview(field(codeField, placeholder: "Код Telegram", secure: true, keyboard: .numberPad)); loginPanel.addArrangedSubview(actionButton("2. ✅ ПОДТВЕРДИТЬ КОД", color: green, selector: #selector(confirmCode))); loginPanel.addArrangedSubview(field(passwordField, placeholder: "Облачный пароль 2FA", secure: true)); loginPanel.addArrangedSubview(actionButton("3. 🔒 ПОДТВЕРДИТЬ 2FA", color: secondary, selector: #selector(confirm2FA))); loginPanel.addArrangedSubview(actionButton("🗑 УДАЛИТЬ API ИЗ KEYCHAIN", color: secondary, selector: #selector(deleteStoredAPI))); content.addArrangedSubview(loginPanel)

        let controlPanel = panelStack(title: "⚙️ УПРАВЛЕНИЕ")
        controlPanel.addArrangedSubview(actionButton("🟢 ВКЛЮЧИТЬ ОНЛАЙН 24/7", color: green, selector: #selector(startOnline))); controlPanel.addArrangedSubview(actionButton("⏸ ВЫКЛЮЧИТЬ ОНЛАЙН", color: secondary, selector: #selector(stopOnline))); controlPanel.addArrangedSubview(actionButton("🧪 ПРОВЕРИТЬ ПОДКЛЮЧЕНИЕ", color: blue, selector: #selector(checkStatus))); controlPanel.addArrangedSubview(actionButton("🔐 ПОКАЗАТЬ СЕССИИ TELEGRAM", color: secondary, selector: #selector(showSessions))); controlPanel.addArrangedSubview(actionButton("🚨 ОТКЛЮЧИТЬ ЭТУ СЕРВЕРНУЮ СЕССИЮ", color: red, selector: #selector(revokeServerSession))); content.addArrangedSubview(controlPanel)

        let note = UILabel(); note.numberOfLines = 0; note.textColor = .lightGray; note.font = .systemFont(ofSize: 12); note.text = "API ID/HASH и номер сохраняются только в Keychain этого iPhone. Код Telegram и 2FA не сохраняются. Команды подписаны ключом iPhone; зашифрованная Telegram-сессия на сервере привязана к этому ключу и не расшифруется после перезапуска, пока ты не откроешь приложение."; content.addArrangedSubview(note)
        outputView.backgroundColor = panel; outputView.textColor = .white; outputView.font = .monospacedSystemFont(ofSize: 13, weight: .regular); outputView.isEditable = false; outputView.isScrollEnabled = true; outputView.layer.cornerRadius = 16; outputView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12); outputView.heightAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true; content.addArrangedSubview(outputView)
    }

    private func panelStack(title: String) -> UIStackView { let box = UIStackView(); box.axis = .vertical; box.spacing = 9; box.backgroundColor = panel; box.layer.cornerRadius = 16; box.isLayoutMarginsRelativeArrangement = true; box.layoutMargins = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12); let label = UILabel(); label.text = title; label.textColor = .white; label.font = .systemFont(ofSize: 17, weight: .bold); box.addArrangedSubview(label); return box }
    private func field(_ tf: UITextField, placeholder: String, secure: Bool = false, keyboard: UIKeyboardType = .default) -> UITextField { tf.placeholder = placeholder; tf.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.systemGray]); tf.backgroundColor = secondary; tf.textColor = .white; tf.tintColor = .white; tf.font = .systemFont(ofSize: 16, weight: .medium); tf.layer.cornerRadius = 11; tf.isSecureTextEntry = secure; tf.keyboardType = keyboard; tf.autocapitalizationType = .none; tf.autocorrectionType = .no; tf.clearButtonMode = .whileEditing; tf.delegate = self; tf.heightAnchor.constraint(equalToConstant: 48).isActive = true; tf.setLeftPaddingPoints(12); tf.setRightPaddingPoints(12); return tf }
    private func actionButton(_ title: String, color: UIColor, selector: Selector) -> UIButton { let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.setTitleColor(color == green ? .black : .white, for: .normal); b.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold); b.titleLabel?.adjustsFontSizeToFitWidth = true; b.titleLabel?.minimumScaleFactor = 0.72; b.backgroundColor = color; b.layer.cornerRadius = 12; b.heightAnchor.constraint(equalToConstant: 50).isActive = true; b.addTarget(self, action: selector, for: .touchUpInside); return b }

    private func restoreAPIFields() { if let saved = identity.loadAPICredentials() { apiIdField.text = String(saved.0); apiHashField.text = saved.1; phoneField.text = saved.2 } }
    private func bootstrapSecurity() { bridge.send(action: "pair") { [weak self] result in DispatchQueue.main.async { if case .failure(let error) = result { self?.append("❌ Привязка: \(error.localizedDescription)") } } }; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.sendUnlock() }; DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.send("status") } }
    private func sendUnlock() { didRequestUnlock = true; bridge.send(action: "unlock", fields: ["vault_key": identity.vaultKey.base64EncodedString()]) { [weak self] result in DispatchQueue.main.async { if case .failure(let error) = result { self?.append("❌ Разблокировка: \(error.localizedDescription)") } } } }
    @objc private func unlockServer() { sendUnlock() }
    @objc private func checkSecurity() { send("security") }

    @objc private func requestCode() { view.endEditing(true); let apiText = (apiIdField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines); let hash = (apiHashField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines); let phone = (phoneField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines); guard let apiId = Int(apiText), apiId > 0, hash.count >= 20, phone.count >= 7 else { append("❌ Заполни API ID, API HASH и номер телефона."); return }; identity.saveAPICredentials(apiID: apiId, apiHash: hash, phone: phone); send("login_start", fields: ["api_id": apiId, "api_hash": hash, "phone": phone]); append("🔐 API ID/HASH сохранены в Keychain этого iPhone. Запрос кода отправлен.") }
    @objc private func confirmCode() { view.endEditing(true); let code = (codeField.text ?? "").replacingOccurrences(of: " ", with: ""); guard !code.isEmpty else { append("❌ Введи код Telegram."); return }; send("login_code", fields: ["code": code]); codeField.text = "" }
    @objc private func confirm2FA() { view.endEditing(true); let password = passwordField.text ?? ""; guard !password.isEmpty else { append("❌ Введи облачный пароль 2FA."); return }; send("login_2fa", fields: ["password": password]); passwordField.text = "" }
    @objc private func deleteStoredAPI() { let alert = UIAlertController(title: "Удалить API из iPhone?", message: "API ID, API HASH и номер будут удалены из Keychain. Ключ привязки iPhone и ключ шифрования Telegram-сессии останутся.", preferredStyle: .alert); alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in self?.identity.deleteAPICredentials(); self?.apiIdField.text = ""; self?.apiHashField.text = ""; self?.phoneField.text = ""; self?.append("🗑 API-данные удалены из Keychain.") }); present(alert, animated: true) }
    @objc private func startOnline() { send("online_start") }
    @objc private func stopOnline() { send("online_stop") }
    @objc private func checkStatus() { send("status") }
    @objc private func showSessions() { send("sessions") }
    @objc private func revokeServerSession() { let alert = UIAlertController(title: "Отключить сервер?", message: "Telegram отзовёт эту серверную авторизацию. Зашифрованный файл сессии будет удалён с сервера.", preferredStyle: .alert); alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); alert.addAction(UIAlertAction(title: "Отключить", style: .destructive) { [weak self] _ in self?.send("logout_server") }); present(alert, animated: true) }
    private func send(_ action: String, fields: [String: Any] = [:]) { bridge.send(action: action, fields: fields) { [weak self] result in DispatchQueue.main.async { if case .failure(let error) = result { self?.append("❌ \(error.localizedDescription)") } } } }

    private func startTimers() { updateClock(); clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateClock() }; pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }; poll() }
    private func updateClock() { let df = DateFormatter(); df.dateFormat = "HH:mm:ss"; df.timeZone = TimeZone(identifier: "Europe/Kyiv"); clockLabel.text = df.string(from: Date()) }
    private func poll() { bridge.poll { [weak self] result in DispatchQueue.main.async { guard let self else { return }; switch result { case .success(let events): for event in events { self.lastServerEvent = Date(); self.handle(event) }; if Date().timeIntervalSince(self.lastServerEvent) > 45 { self.statusLabel.text = "● СЕРВЕР: нет ответа"; self.statusLabel.textColor = .systemOrange }; case .failure: break } } } }
    private func handle(_ event: ServerEvent) { if event.kind == "paired" && !didRequestUnlock { sendUnlock() }; if let state = event.state { switch state { case "online": statusLabel.text = "● TELEGRAM: ONLINE 24/7 • 🔐"; statusLabel.textColor = green; case "authorized": statusLabel.text = "● TELEGRAM: авторизован • 🔐"; statusLabel.textColor = blue; case "offline": statusLabel.text = "● TELEGRAM: офлайн • 🔐"; statusLabel.textColor = .systemOrange; case "logged_out": statusLabel.text = "● TELEGRAM: сервер отключён"; statusLabel.textColor = red; default: statusLabel.text = "● СЕРВЕР: защищённое соединение"; statusLabel.textColor = green } } else { statusLabel.text = "● СЕРВЕР: защищённое соединение"; statusLabel.textColor = green }; if !event.text.isEmpty { append(event.text) } }
    private func append(_ text: String) { let df = DateFormatter(); df.dateFormat = "HH:mm:ss"; df.timeZone = TimeZone(identifier: "Europe/Kyiv"); outputView.text += "[\(df.string(from: Date()))] \(text)\n"; let range = NSRange(location: max(outputView.text.count - 1, 0), length: 1); outputView.scrollRangeToVisible(range) }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
}

private extension UITextField {
    func setLeftPaddingPoints(_ amount: CGFloat) { let v = UIView(frame: CGRect(x: 0, y: 0, width: amount, height: frame.height)); leftView = v; leftViewMode = .always }
    func setRightPaddingPoints(_ amount: CGFloat) { let v = UIView(frame: CGRect(x: 0, y: 0, width: amount, height: frame.height)); rightView = v; rightViewMode = .always }
}
