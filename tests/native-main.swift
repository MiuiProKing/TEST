import Foundation
import SQLite3

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS " + message)
}
let rows = SourceManager.normalize(["history":[
    ["id":"a","coefficient":1],
    ["id":"a","coefficient":1],
    ["id":"b","coefficient":1],
    ["id":"future","coefficient":100,"timestamp":"2099-01-01T00:00:00.123Z"],
    ["id":"bad","coefficient":"nan"],
    ["coefficient":2],
    ["id":"final","finalValues":[1,9.8]],
    ["id":"time","coefficient":3,"timestamp":1700000000123]
]],source:"main")
check(rows.count == 5,"valid rows retained, ID dedup, invalid values rejected")
check(rows[0].coefficient == 1,"1.00 is not rewritten")
check(rows[1].id == "b","equal coefficients from distinct rounds survive")
check(rows.first(where:{$0.id=="future"})?.estimated == true,"future clock is flagged; coefficient is retained")
check(rows.first(where:{$0.id=="final"})?.coefficient == 9.8,"finalValues parsed")
check(rows.first(where:{$0.id=="time"})?.timestamp != nil,"millisecond timestamp parsed")
let old = "[{\"id\":\"saved\",\"coefficient\":2,\"timestamp\":0}]".data(using:.utf8)!
check((try? JSONDecoder().decode([RoundSample].self,from:old))?.first?.id == "saved","3.6 JSON cache remains readable")

final class MockProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var offline = false
    static var pagination = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        MockProtocol.requests.append(request)
        if MockProtocol.offline || request.url!.host == "main.invalid" {
            client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return
        }
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        let body: String
        if MockProtocol.pagination {
            let offset = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="offset"})?.value ?? "0"
            body = offset == "0" ? "{\"history\":[{\"id\":\"a\",\"coefficient\":1}],\"hasMore\":true,\"nextOffset\":1000}" : "{\"history\":[{\"id\":\"b\",\"coefficient\":2}],\"hasMore\":false}"
        } else { body = "{\"history\":[{\"id\":\"new\",\"coefficient\":4.2}]}" }
        client?.urlProtocol(self,didLoad:body.data(using:.utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let cfg = SourcesConfig(poll_seconds:1,full_sync_seconds:30,stale_seconds:120,retry_seconds:[1,2,5,10,30],sources:[
    DataSource(id:"main",name:"MAIN",url:"https://main.invalid/",type:"snapshot",enabled:true,priority:0,timeout:5),
    DataSource(id:"reserve",name:"RESERVE",url:"https://reserve.invalid/",type:"snapshot",enabled:true,priority:1,timeout:5),
    DataSource(id:"local",name:"SQLite",url:"local://cache",type:"cache",enabled:true,priority:99,timeout:0)
])
let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [MockProtocol.self]
let manager = SourceManager(config:cfg,session:URLSession(configuration:sessionConfig),monitorNetwork:false)
manager.selection = "AUTO"
func fetch(_ force: Bool = false, using target: SourceManager = manager) -> [RoundSample] {
    var finished = false; var output: [RoundSample] = []
    target.fetch(force:force) { result in output = (try? result.get()) ?? []; finished = true }
    let deadline = Date().addingTimeInterval(5)
    while !finished && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    check(finished,"async fetch completed within bound")
    return output
}
check(fetch().first?.coefficient == 4.2,"native fallback returns reserve round")
check(manager.activeID == "reserve","native reserve selected")
check(MockProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField:"session-id") == nil },"SESSION never sent to public source")
MockProtocol.offline = true
check(fetch(true).first?.id == "new" && manager.lastDeliveryCached,"offline serves labelled cache")
MockProtocol.offline = false
check(fetch(true).first?.id == "new" && !manager.lastDeliveryCached,"connection recovery restores HTTP source")
manager.selection = "AUTO"
MockProtocol.pagination = true
let paginated = SourceManager(config:cfg,session:URLSession(configuration:sessionConfig),monitorNetwork:false)
paginated.selection = "reserve"
check(fetch(using:paginated).map(\.id) == ["a","b"],"native pagination returns complete unique history")
check(fetch(using:paginated).map(\.id) == ["a","b"],"fast head retains earlier pages; no phantom later backfill")
paginated.selection = "AUTO"
MockProtocol.pagination = false
print("Native transport checks passed")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:directory) }
var db: OpaquePointer?
check(sqlite3_open(directory.appendingPathComponent("v0xff3-rounds.sqlite3").path,&db) == SQLITE_OK,"legacy database created")
sqlite3_exec(db,"CREATE TABLE rounds (seq INTEGER PRIMARY KEY AUTOINCREMENT,round_id TEXT NOT NULL UNIQUE,coefficient REAL NOT NULL,timestamp REAL)",nil,nil,nil)
sqlite3_exec(db,"INSERT INTO rounds(round_id,coefficient,timestamp) VALUES('legacy',100,1700000000)",nil,nil,nil)
sqlite3_close(db)
let store = SQLiteRoundStore(directory:directory)
check(store.available && store.load().first?.id == "legacy","native migration retains real 3.6 schema and history")
store.upsert([RoundSample(id:"new",coefficient:1,timestamp:nil,source:"main",estimated:true)])
store.upsert([RoundSample(id:"new",coefficient:1,timestamp:nil,source:"reserve")])
check(store.stats().total == 2,"native INSERT OR IGNORE deduplicates source switch")
check(store.stats().x100 == 1,"legacy high-coefficient statistics retained")
check(store.load().first?.estimated == true,"clock-quality metadata stored")
let reopened = SQLiteRoundStore(directory:directory)
check(reopened.available && reopened.stats().total == 2,"second migration and reopen retain both rounds")
print("Native SQLite checks passed")
