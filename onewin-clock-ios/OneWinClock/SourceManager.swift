import Foundation
import CoreFoundation
import Network
import Security

struct RoundSample: Codable, Equatable {
    let id: String
    let coefficient: Double
    let timestamp: Date?
    var source: String? = nil
    var estimated: Bool? = nil
}

struct DataSource: Codable {
    let id: String
    let name: String
    let url: String
    let type: String
    let enabled: Bool
    let priority: Int
    let timeout: Double
}
struct SourcesConfig: Codable {
    let poll_seconds: Double
    let full_sync_seconds: Double
    let stale_seconds: Double
    let retry_seconds: [Double]
    let sources: [DataSource]
    static func load() -> SourcesConfig {
        guard let url = Bundle.main.url(forResource: "sources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SourcesConfig.self, from: data) else {
            return SourcesConfig(poll_seconds: 1, full_sync_seconds: 30, stale_seconds: 120, retry_seconds: [1,2,5,10,30], sources: [])
        }
        return config
    }
}
struct SourceHealth {
    var status = "OFFLINE"
    var lastSuccess: Date?
    var lastError: String?
    var latency: Double = 0
    var lastNewRound: Date?
    var lastIDs: Set<String> = []
    var failures = 0
    var retryAt = Date.distantPast
    var httpStatus: Int?
}
enum SessionVault {
    private static let account = "LuckyJet.user.session"
    static var value: String {
        get {
            let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrAccount as String:account]
            SecItemDelete(query as CFDictionary)
            guard !newValue.isEmpty else { return }
            var insert = query
            insert[kSecValueData as String] = Data(newValue.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}

// All mutable state and callbacks are confined to the main queue. URLSession does I/O off it.
final class SourceManager {
    let config: SourcesConfig
    private(set) var health: [String: SourceHealth] = [:]
    private(set) var activeID = "local"
    private(set) var networkAvailable = true
    private(set) var lastDeliveryCached = false
    var onLog: ((String) -> Void)?
    var selection: String {
        get { UserDefaults.standard.string(forKey: "kiborg.source.v37") ?? "AUTO" }
        set { UserDefaults.standard.set(newValue, forKey: "kiborg.source.v37"); reset() }
    }
    private let session: URLSession
    private let monitor = NWPathMonitor()
    private var generation = 0
    private var busy = false
    private var task: URLSessionDataTask?
    private var callbacks: [(Result<[RoundSample], Error>) -> Void] = []
    private var cache: [RoundSample] = []
    private var histories: [String: [RoundSample]] = [:]
    private var lastFull: [String: Date] = [:]
    init(config: SourcesConfig = .load(), session: URLSession? = nil, monitorNetwork: Bool = true) {
        self.config = config
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 8
            c.timeoutIntervalForResource = 10
            c.waitsForConnectivity = false
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: c)
        }
        for s in config.sources { health[s.id] = SourceHealth() }
        if monitorNetwork {
            monitor.pathUpdateHandler = { [weak self] path in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let was = self.networkAvailable
                    self.networkAvailable = path.status == .satisfied
                    if !was && self.networkAvailable {
                        self.onLog?("Соединение восстановлено • повтор MAIN")
                        for key in Array(self.health.keys) { self.health[key]?.retryAt = .distantPast }
                        self.reset()
                    }
                }
            }
            monitor.start(queue: DispatchQueue(label: "kiborg.network"))
        }
    }
    deinit { monitor.cancel(); task?.cancel() }
    func setCache(_ rows: [RoundSample]) { cache = rows }
    func reset() {
        generation += 1
        task?.cancel(); task = nil
        busy = false
        let waiting = callbacks; callbacks = []
        for cb in waiting { cb(.failure(URLError(.cancelled))) }
        lastFull = [:]
    }
    func suspend() { reset() }
    func summary() -> String {
        config.sources.map { s in
            let h = health[s.id] ?? SourceHealth()
            let marker = s.id == activeID ? "✅ " : ""
            let fresh = h.lastNewRound.map { " • новый раунд \(Int(Date().timeIntervalSince($0)))с назад" } ?? " • свежесть не подтверждена"
            return "\(marker)\(s.name): \(h.status) • \(Int(h.latency * 1000))ms\(fresh)\n\(h.lastError ?? "")"
        }.joined(separator: "\n")
    }
    func fetch(force: Bool = false, only: String? = nil, completion: @escaping (Result<[RoundSample], Error>) -> Void) {
        if busy { callbacks.append(completion); return }
        busy = true; callbacks = [completion]
        let id = only ?? (selection == "AUTO" ? nil : selection)
        let candidates = config.sources.filter { s in
            s.enabled && s.type != "cache" && (id == nil || id == s.id) && (force || (health[s.id]?.retryAt ?? .distantPast) <= Date())
        }.sorted { $0.priority < $1.priority }
        attempt(candidates, index: 0, generation: generation, allowCache: only == nil)
    }
    private func finish(_ result: Result<[RoundSample], Error>, generation g: Int) {
        guard generation == g else { return }
        busy = false; task = nil
        let waiting = callbacks; callbacks = []
        for cb in waiting { cb(result) }
    }
    private func attempt(_ candidates: [DataSource], index: Int, generation g: Int, allowCache: Bool) {
        guard generation == g else { return }
        guard index < candidates.count else {
            if allowCache && !cache.isEmpty {
                activeID = "local"; lastDeliveryCached = true
                health["local"]?.status = "ONLINE"
                finish(.success(cache), generation: g)
            } else { finish(.failure(URLError(.notConnectedToInternet)), generation: g) }
            return
        }
        let source = candidates[index]
        if source.type == "session" && SessionVault.value.isEmpty {
            health[source.id]?.status = "AUTH_REQUIRED"
            health[source.id]?.lastError = "Укажите свою SESSION в настройках"
            health[source.id]?.retryAt = Date().addingTimeInterval(30)
            attempt(candidates, index: index+1, generation: g, allowCache: allowCache); return
        }
        let full = lastFull[source.id] == nil || Date().timeIntervalSince(lastFull[source.id]!) >= config.full_sync_seconds
        var collected: [RoundSample] = []
        let started = Date()
        func fail(_ status: String, _ message: String, _ code: Int? = nil) {
            guard self.generation == g else { return }
            var h = self.health[source.id] ?? SourceHealth()
            h.status = status; h.lastError = message; h.httpStatus = code; h.failures += 1
            let delays = self.config.retry_seconds.isEmpty ? [1,2,5,10,30] : self.config.retry_seconds
            h.retryAt = Date().addingTimeInterval(delays[min(h.failures-1,delays.count-1)])
            self.health[source.id] = h
            self.onLog?("\(source.name): \(message) • резерв / cache")
            self.attempt(candidates,index:index+1,generation:g,allowCache:allowCache)
        }
        func page(_ offset: Int) {
            guard self.generation == g else { return }
            guard var components = URLComponents(string: source.url) else { fail("ERROR","Некорректный URL"); return }
            if source.type == "snapshot" {
                var q = components.queryItems ?? []
                q.removeAll { ["limit","offset","t"].contains($0.name) }
                q += [URLQueryItem(name:"limit",value:"1000"),URLQueryItem(name:"offset",value:String(offset)),URLQueryItem(name:"t",value:String(Int(Date().timeIntervalSince1970*1000)))]
                components.queryItems = q
            }
            guard let url = components.url else { fail("ERROR","Некорректный URL"); return }
            var request = URLRequest(url:url, cachePolicy:.reloadIgnoringLocalCacheData, timeoutInterval:source.timeout)
            request.setValue("application/json",forHTTPHeaderField:"Accept")
            if source.type == "session" {
                request.setValue(SessionVault.value,forHTTPHeaderField:"session-id")
                request.setValue("077dee8d-c923-4c02-9bee-757573662e69",forHTTPHeaderField:"customer-id")
            }
            self.task = self.session.dataTask(with:request) { data,response,error in
                // Parsing and date normalization can be expensive for 5000 rows; keep it off the UI queue.
                let object: Any? = data.flatMap { bytes in
                    guard bytes.count <= 16_000_000 else { return nil }
                    return try? JSONSerialization.jsonObject(with:bytes)
                }
                let pageRows = object.map { Self.normalize($0,source:source.id) } ?? []
                DispatchQueue.main.async {
                    guard self.generation == g else { return }
                    if let error = error as? URLError { fail("OFFLINE", "Сетевая ошибка \(error.code.rawValue)"); return }
                    guard error == nil, let response = response as? HTTPURLResponse, let data else { fail("OFFLINE","Нет ответа"); return }
                    guard (200...299).contains(response.statusCode) else {
                        fail([401,403].contains(response.statusCode) ? "AUTH_REQUIRED" : "ERROR", "HTTP \(response.statusCode)",response.statusCode); return
                    }
                    guard let object else { fail("ERROR","Ответ не JSON / превышен лимит",response.statusCode); return }
                    let rows = pageRows
                    guard !rows.isEmpty || offset > 0 else { fail("ERROR","Нет валидных раундов с ID",response.statusCode); return }
                    collected += rows
                    let dict = object as? [String:Any]
                    if full && source.type == "snapshot", let next = dict?["nextOffset"] as? Int, next > offset, next < 5000, dict?["hasMore"] as? Bool == true, !rows.isEmpty {
                        page(next); return
                    }
                    var seen = Set<String>()
                    let all = collected.filter { seen.insert($0.id).inserted }
                    var h = self.health[source.id] ?? SourceHealth()
                    let ids = Set(all.map(\.id))
                    if h.lastSuccess == nil || !ids.subtracting(h.lastIDs).isEmpty { h.lastNewRound = Date() }
                    // Keep a bounded union so full syncs do not masquerade as live freshness.
                    h.lastIDs.formUnion(ids)
                    if h.lastIDs.count > 10000 { h.lastIDs = ids }
                    h.latency = Date().timeIntervalSince(started)
                    h.httpStatus = response.statusCode; h.lastSuccess = Date(); h.lastError = nil; h.failures = 0; h.retryAt = .distantPast
                    let stale = h.lastNewRound.map { Date().timeIntervalSince($0) > self.config.stale_seconds } ?? false
                    h.status = stale || h.latency > 5 ? "SLOW" : "ONLINE"
                    self.health[source.id] = h
                    if stale {
                        h.lastError = "HTTP доступен, новых раундов нет >120с"
                        h.retryAt = Date().addingTimeInterval(30); self.health[source.id] = h
                        self.attempt(candidates,index:index+1,generation:g,allowCache:allowCache); return
                    }
                    if self.activeID != source.id { self.onLog?("Источник: \(source.name) подключён") }
                    let old = self.histories[source.id] ?? []
                    let delivered = Array((all + old.filter { !ids.contains($0.id) }).prefix(5000))
                    self.histories[source.id] = delivered
                    self.activeID = source.id; self.lastDeliveryCached = false; self.cache = delivered
                    if full { self.lastFull[source.id] = Date() }
                    self.finish(.success(delivered),generation:g)
                }
            }
            self.task?.resume()
        }
        page(0)
    }
    static func normalize(_ object: Any, source: String) -> [RoundSample] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        func unwrap(_ x: Any) -> [[String:Any]] {
            if let a = x as? [[String:Any]] { return a }
            if let d = x as? [String:Any] {
                for key in ["history","rounds","items","results","data","coefficients"] {
                    if let v = d[key] { let a = unwrap(v); if !a.isEmpty { return a } }
                }
            }
            return []
        }
        func number(_ v: Any?) -> Double? {
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
            if let s = v as? String { return Double(s.replacingOccurrences(of:",",with:".")) }
            return nil
        }
        func date(_ v: Any?) -> Date? {
            if let n = number(v), n.isFinite { return Date(timeIntervalSince1970:n > 1e11 ? n/1000 : n) }
            guard let s = v as? String else { return nil }
            return fractional.date(from:s) ?? standard.date(from:s)
        }
        var seen = Set<String>()
        return unwrap(object).compactMap { row in
            let keys = ["id","round_id","roundId","gameId","game_id","uuid","hash"]
            guard let id = keys.compactMap({ key -> String? in
                if let s = row[key] as? String, !s.isEmpty { return s }
                if let n = row[key] as? NSNumber { return n.stringValue }
                return nil
            }).first else { return nil }
            var coefficient = ["topCoefficient","coefficient","coef","multiplier","value"].compactMap { number(row[$0]) }.first
            if coefficient == nil, let finals = row["finalValues"] as? [Any] { coefficient = finals.reversed().compactMap { number($0) }.first }
            guard let c = coefficient, c.isFinite, c >= 1, seen.insert(id).inserted else { return nil }
            let ts = ["round_timestamp","timestamp","createdAt","created_at","time","endedAt","ended_at"].compactMap { date(row[$0]) }.first
            let uncertain = row["estimated"] as? Bool == true || ts == nil || (ts?.timeIntervalSinceNow ?? 0) > 120
            return RoundSample(id:id,coefficient:c,timestamp:ts,source:source,estimated:uncertain)
        }
    }
}
