import UIKit
import CryptoKit

private enum PairConfig {
    static let baseURL = "https://ntfy.sh"
    static let commandTopic = "__TG247_CMD_TOPIC__"
    static let eventTopic = "__TG247_EVT_TOPIC__"
    static let pairSecret = "__TG247_PAIR_SECRET__"
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
    case invalidConfig
    case crypto
    case transport
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig: return "Неверная конфигурация пары"
        case .crypto: return "Ошибка защищённого канала"
        case .transport: return "Сервер связи недоступен"
        case .server(let text): return text
        }
    }
}

private final class SecureBridge {
    private let session: URLSession
    private var seenEventIDs = Set<String>()
    private var isPolling = false

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 18
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    private var key: SymmetricKey {
        let digest = SHA256.hash(data: Data(PairConfig.pairSecret.utf8))
        return SymmetricKey(data: Data(digest))
    }

    private func encrypt(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw BridgeError.crypto }
        return combined.base64EncodedString()
    }

    private func decrypt(_ encoded: String) throws -> [String: Any] {
        guard let combined = Data(base64Encoded: encoded) else { throw BridgeError.crypto }
        let box = try AES.GCM.SealedBox(combined: combined)
        let clear = try AES.GCM.open(box, using: key)
        guard let json = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else {
            throw BridgeError.crypto
        }
        return json
    }

    func send(action: String, fields: [String: Any] = [:], completion: @escaping (Result<Void, Error>) -> Void) {
        guard !PairConfig.commandTopic.contains("__"), !PairConfig.pairSecret.contains("__"),
              let url = URL(string: "\(PairConfig.baseURL)/\(PairConfig.commandTopic)") else {
            completion(.failure(BridgeError.invalidConfig)); return
        }
        var payload: [String: Any] = [
            "action": action,
            "request_id": UUID().uuidString.lowercased(),
            "ts": Date().timeIntervalSince1970,
            "client": "ios"
        ]
        for (k, v) in fields { payload[k] = v }
        do {
            let body = try encrypt(payload)
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = Data(body.utf8)
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            session.dataTask(with: req) { _, response, error in
                if let error { completion(.failure(error)); return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    completion(.failure(BridgeError.transport)); return
                }
                completion(.success(()))
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    func poll(completion: @escaping (Result<[ServerEvent], Error>) -> Void) {
        guard !isPolling else { return }
        isPolling = true
        var components = URLComponents(string: "\(PairConfig.baseURL)/\(PairConfig.eventTopic)/json")!
        components.queryItems = [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: "20s")
        ]
        guard let url = components.url else {
            isPolling = false
            completion(.failure(BridgeError.invalidConfig)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.isPolling = false }
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                completion(.failure(BridgeError.transport)); return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            var events: [ServerEvent] = []
            for line in text.split(separator: "\n") {
                guard let raw = String(line).data(using: .utf8),
                      let env = try? JSONDecoder().decode(NtfyEnvelope.self, from: raw),
                      env.event == "message", let id = env.id, let message = env.message else { continue }
                if self.seenEventIDs.contains(id) { continue }
                self.seenEventIDs.insert(id)
                if self.seenEventIDs.count > 250 { self.seenEventIDs.removeAll(keepingCapacity: true) }
                do {
                    let json = try self.decrypt(message)
                    events.append(ServerEvent(
                        id: id,
                        kind: json["kind"] as? String ?? "message",
                        text: json["text"] as? String ?? "",
                        state: json["state"] as? String
                    ))
                } catch {
                    continue
                }
            }
            completion(.success(events))
        }.resume()
    }
}

final class ViewController: UIViewController, UITextFieldDelegate {
    private let bridge = SecureBridge()
    private let bg = UIColor.black
    private let panel = UIColor(white: 0.08, alpha: 1)
    private let secondary = UIColor(white: 0.15, alpha: 1)
    private let green = UIColor(red: 0.36, green: 0.80, blue: 0.42, alpha: 1)
    private let blue = UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1)
    private let red = UIColor(red: 0.95, green: 0.28, blue: 0.28, alpha: 1)

    private let statusLabel = UILabel()
    private let outputView = UITextView()
    private let apiIdField = UITextField()
    private let apiHashField = UITextField()
    private let phoneField = UITextField()
    private let codeField = UITextField()
    private let passwordField = UITextField()
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private let clockLabel = UILabel()
    private var lastServerEvent = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        UIApplication.shared.isIdleTimerDisabled = true
        buildUI()
        startTimers()
        append("Готово. Данные API, код и 2FA не сохраняются в приложении. Серверная Telegram-сессия хранится только в зашифрованном виде.")
        send("status")
    }

    deinit {
        pollTimer?.invalidate()
        clockTimer?.invalidate()
    }

    private func buildUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 24, right: 14)
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])

        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        let title = UILabel()
        title.text = "TELEGRAM 24/7"
        title.textColor = .white
        title.font = .systemFont(ofSize: 27, weight: .black)
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(UIView())
        clockLabel.textColor = .white
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        titleRow.addArrangedSubview(clockLabel)
        content.addArrangedSubview(titleRow)

        statusLabel.text = "● СЕРВЕР: проверка…"
        statusLabel.font = .systemFont(ofSize: 16, weight: .bold)
        statusLabel.textColor = .systemOrange
        content.addArrangedSubview(statusLabel)

        let loginPanel = panelStack(title: "🔐 ВХОД В TELEGRAM")
        loginPanel.addArrangedSubview(field(apiIdField, placeholder: "API ID", keyboard: .numberPad))
        loginPanel.addArrangedSubview(field(apiHashField, placeholder: "API HASH", secure: true))
        loginPanel.addArrangedSubview(field(phoneField, placeholder: "+380… номер телефона", keyboard: .phonePad))
        loginPanel.addArrangedSubview(actionButton("1. 📩 ПОЛУЧИТЬ КОД", color: blue, selector: #selector(requestCode)))
        loginPanel.addArrangedSubview(field(codeField, placeholder: "Код Telegram", keyboard: .numberPad))
        loginPanel.addArrangedSubview(actionButton("2. ✅ ПОДТВЕРДИТЬ КОД", color: green, selector: #selector(confirmCode)))
        loginPanel.addArrangedSubview(field(passwordField, placeholder: "Пароль 2FA — только если попросит", secure: true))
        loginPanel.addArrangedSubview(actionButton("3. 🔒 ПОДТВЕРДИТЬ 2FA", color: secondary, selector: #selector(confirm2FA)))
        content.addArrangedSubview(loginPanel)

        let controlPanel = panelStack(title: "⚙️ УПРАВЛЕНИЕ")
        controlPanel.addArrangedSubview(actionButton("🟢 ВКЛЮЧИТЬ ОНЛАЙН 24/7", color: green, selector: #selector(startOnline)))
        controlPanel.addArrangedSubview(actionButton("⏸ ВЫКЛЮЧИТЬ ОНЛАЙН", color: secondary, selector: #selector(stopOnline)))
        controlPanel.addArrangedSubview(actionButton("🧪 ПРОВЕРИТЬ ПОДКЛЮЧЕНИЕ", color: blue, selector: #selector(checkStatus)))
        controlPanel.addArrangedSubview(actionButton("🔐 ПОКАЗАТЬ СЕССИИ TELEGRAM", color: secondary, selector: #selector(showSessions)))
        controlPanel.addArrangedSubview(actionButton("🚨 ОТКЛЮЧИТЬ ЭТУ СЕРВЕРНУЮ СЕССИЮ", color: red, selector: #selector(revokeServerSession)))
        content.addArrangedSubview(controlPanel)

        let note = UILabel()
        note.numberOfLines = 0
        note.textColor = .lightGray
        note.font = .systemFont(ofSize: 12)
        note.text = "Код подтверждения и пароль 2FA передаются по зашифрованному AES‑GCM каналу и не записываются в журнал. После успешного входа приложение можно закрыть — онлайн держит сервер."
        content.addArrangedSubview(note)

        outputView.backgroundColor = panel
        outputView.textColor = .white
        outputView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        outputView.isEditable = false
        outputView.isScrollEnabled = true
        outputView.layer.cornerRadius = 16
        outputView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        outputView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        content.addArrangedSubview(outputView)
    }

    private func panelStack(title: String) -> UIStackView {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = 9
        box.backgroundColor = panel
        box.layer.cornerRadius = 16
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .bold)
        box.addArrangedSubview(label)
        return box
    }

    private func field(_ tf: UITextField, placeholder: String, secure: Bool = false, keyboard: UIKeyboardType = .default) -> UITextField {
        tf.placeholder = placeholder
        tf.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.systemGray])
        tf.backgroundColor = secondary
        tf.textColor = .white
        tf.tintColor = .white
        tf.font = .systemFont(ofSize: 16, weight: .medium)
        tf.layer.cornerRadius = 11
        tf.isSecureTextEntry = secure
        tf.keyboardType = keyboard
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.clearButtonMode = .whileEditing
        tf.delegate = self
        tf.heightAnchor.constraint(equalToConstant: 48).isActive = true
        tf.setLeftPaddingPoints(12)
        tf.setRightPaddingPoints(12)
        return tf
    }

    private func actionButton(_ title: String, color: UIColor, selector: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(color == green ? .black : .white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        b.backgroundColor = color
        b.layer.cornerRadius = 12
        b.heightAnchor.constraint(equalToConstant: 50).isActive = true
        b.addTarget(self, action: selector, for: .touchUpInside)
        return b
    }

    @objc private func requestCode() {
        view.endEditing(true)
        let apiText = (apiIdField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = (apiHashField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = (phoneField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiId = Int(apiText), apiId > 0, hash.count >= 20, phone.count >= 7 else {
            append("❌ Заполни API ID, API HASH и номер телефона.")
            return
        }
        send("login_start", fields: ["api_id": apiId, "api_hash": hash, "phone": phone])
        append("📩 Запрос кода отправлен. Жду Telegram…")
    }

    @objc private func confirmCode() {
        view.endEditing(true)
        let code = (codeField.text ?? "").replacingOccurrences(of: " ", with: "")
        guard !code.isEmpty else { append("❌ Введи код Telegram."); return }
        send("login_code", fields: ["code": code])
        codeField.text = ""
    }

    @objc private func confirm2FA() {
        view.endEditing(true)
        let password = passwordField.text ?? ""
        guard !password.isEmpty else { append("❌ Введи пароль двухэтапной защиты."); return }
        send("login_2fa", fields: ["password": password])
        passwordField.text = ""
    }

    @objc private func startOnline() { send("online_start") }
    @objc private func stopOnline() { send("online_stop") }
    @objc private func checkStatus() { send("status") }
    @objc private func showSessions() { send("sessions") }

    @objc private func revokeServerSession() {
        let alert = UIAlertController(title: "Отключить сервер?", message: "Telegram отзовёт только эту серверную авторизацию, а зашифрованная сессия будет удалена с сервера.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Отключить", style: .destructive) { [weak self] _ in self?.send("logout_server") })
        present(alert, animated: true)
    }

    private func send(_ action: String, fields: [String: Any] = [:]) {
        bridge.send(action: action, fields: fields) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result { self?.append("❌ \(error.localizedDescription)") }
            }
        }
    }

    private func startTimers() {
        updateClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateClock() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func updateClock() {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        df.timeZone = TimeZone(identifier: "Europe/Kyiv")
        clockLabel.text = df.string(from: Date())
    }

    private func poll() {
        bridge.poll { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let events):
                    for event in events {
                        self.lastServerEvent = Date()
                        self.handle(event)
                    }
                    if Date().timeIntervalSince(self.lastServerEvent) > 45 {
                        self.statusLabel.text = "● СЕРВЕР: нет ответа"
                        self.statusLabel.textColor = .systemOrange
                    }
                case .failure:
                    break
                }
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        if let state = event.state {
            switch state {
            case "online":
                statusLabel.text = "● TELEGRAM: ONLINE 24/7"
                statusLabel.textColor = green
            case "authorized":
                statusLabel.text = "● TELEGRAM: авторизован"
                statusLabel.textColor = blue
            case "offline":
                statusLabel.text = "● TELEGRAM: офлайн"
                statusLabel.textColor = .systemOrange
            case "logged_out":
                statusLabel.text = "● TELEGRAM: сервер отключён"
                statusLabel.textColor = red
            default:
                statusLabel.text = "● СЕРВЕР: подключён"
                statusLabel.textColor = green
            }
        } else {
            statusLabel.text = "● СЕРВЕР: подключён"
            statusLabel.textColor = green
        }
        if !event.text.isEmpty { append(event.text) }
    }

    private func append(_ text: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        df.timeZone = TimeZone(identifier: "Europe/Kyiv")
        let line = "[\(df.string(from: Date()))] \(text)\n"
        outputView.text += line
        let range = NSRange(location: max(outputView.text.count - 1, 0), length: 1)
        outputView.scrollRangeToVisible(range)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder(); return true
    }
}

private extension UITextField {
    func setLeftPaddingPoints(_ amount: CGFloat) {
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: amount, height: frame.height))
        leftView = paddingView
        leftViewMode = .always
    }
    func setRightPaddingPoints(_ amount: CGFloat) {
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: amount, height: frame.height))
        rightView = paddingView
        rightViewMode = .always
    }
}
