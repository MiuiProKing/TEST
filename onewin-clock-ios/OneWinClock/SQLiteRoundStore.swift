import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteRoundStore {
    private var connection: OpaquePointer?
    private(set) var lastError: String?
    let path: String
    var available: Bool { connection != nil && lastError == nil }
    init(directory: URL? = nil) {
        let fm = FileManager.default
        let folder = directory ?? ((try? fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)) ?? fm.temporaryDirectory)
        try? fm.createDirectory(at:folder,withIntermediateDirectories:true)
        path = folder.appendingPathComponent("v0xff3-rounds.sqlite3").path
        guard sqlite3_open_v2(path,&connection,SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {
            lastError = "SQLite: не удалось открыть базу"
            if let connection { sqlite3_close(connection) }; connection = nil
            return
        }
        sqlite3_busy_timeout(connection,2000)
        _ = execute("PRAGMA journal_mode=WAL"); _ = execute("PRAGMA synchronous=NORMAL")
        guard execute("CREATE TABLE IF NOT EXISTS rounds (seq INTEGER PRIMARY KEY AUTOINCREMENT, round_id TEXT NOT NULL UNIQUE, coefficient REAL NOT NULL, timestamp REAL)") else { return }
        var statement: OpaquePointer?
        var columns = Set<String>()
        if sqlite3_prepare_v2(connection,"PRAGMA table_info(rounds)",-1,&statement,nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let c = sqlite3_column_text(statement,1) { columns.insert(String(cString:c)) }
            }
        }
        sqlite3_finalize(statement)
        for (name,type) in [("id","TEXT"),("source","TEXT NOT NULL DEFAULT 'legacy'"),("created_at","REAL"),("estimated","INTEGER NOT NULL DEFAULT 0")] where !columns.contains(name) {
            guard execute("ALTER TABLE rounds ADD COLUMN \(name) \(type)") else { return }
        }
        _ = execute("UPDATE rounds SET id=round_id WHERE id IS NULL")
        _ = execute("CREATE INDEX IF NOT EXISTS idx_rounds_seq ON rounds(seq DESC)")
        _ = execute("CREATE INDEX IF NOT EXISTS idx_rounds_source ON rounds(source)")
        _ = execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_rounds_id ON rounds(id)")
    }
    deinit { if let connection { sqlite3_close(connection) } }
    @discardableResult private func execute(_ sql: String) -> Bool {
        guard sqlite3_exec(connection,sql,nil,nil,nil) == SQLITE_OK else { lastError = "SQLite: ошибка операции \(sqlite3_errcode(connection))"; return false }
        return true
    }
    func upsert(_ rounds: [RoundSample]) {
        guard let connection, !rounds.isEmpty else { return }
        lastError = nil
        guard execute("BEGIN IMMEDIATE") else { return }
        var statement: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO rounds(round_id, coefficient, timestamp, source, created_at, estimated, id) VALUES(?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(connection,sql,-1,&statement,nil) == SQLITE_OK else { _ = execute("ROLLBACK"); lastError = "SQLite: несовместимая таблица"; return }
        defer { sqlite3_finalize(statement) }
        for round in rounds.reversed() {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement,1,(round.id as NSString).utf8String,-1,sqliteTransient)
            sqlite3_bind_double(statement,2,round.coefficient)
            if let timestamp = round.timestamp { sqlite3_bind_double(statement,3,timestamp.timeIntervalSince1970) } else { sqlite3_bind_null(statement,3) }
            sqlite3_bind_text(statement,4,((round.source ?? "legacy") as NSString).utf8String,-1,sqliteTransient)
            sqlite3_bind_double(statement,5,Date().timeIntervalSince1970)
            sqlite3_bind_int(statement,6,round.estimated == true ? 1 : 0)
            sqlite3_bind_text(statement,7,(round.id as NSString).utf8String,-1,sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                _ = execute("ROLLBACK"); lastError = "SQLite: запись не сохранена"; return
            }
        }
        _ = execute("COMMIT")
    }
    func load(limit: Int = 5000) -> [RoundSample] {
        guard let connection else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection,"SELECT round_id, coefficient, timestamp, source, estimated FROM rounds ORDER BY seq DESC LIMIT ?",-1,&statement,nil) == SQLITE_OK else { lastError = "SQLite: не удалось прочитать историю"; return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement,1,Int32(max(1,min(limit,10000))))
        var rows: [RoundSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement,0) else { continue }
            let timestamp: Date? = sqlite3_column_type(statement,2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970:sqlite3_column_double(statement,2))
            let source = sqlite3_column_text(statement,3).map { String(cString:$0) }
            rows.append(RoundSample(id:String(cString:id),coefficient:sqlite3_column_double(statement,1),timestamp:timestamp,source:source,estimated:sqlite3_column_int(statement,4) != 0))
        }
        return rows
    }
    func stats() -> (total: Int, x30: Int, x100: Int, x140: Int) {
        guard let connection else { return (0,0,0,0) }
        func count(_ whereClause: String = "") -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection,"SELECT COUNT(*) FROM rounds \(whereClause)",-1,&statement,nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement,0))
        }
        return (count(),count("WHERE coefficient>=30"),count("WHERE coefficient>=100"),count("WHERE coefficient>=140"))
    }
}
