import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate {
    private let api = URL(string: "https://crash-gateway-grm-cr.100hp.app/history")!
    private let customerID = "077dee8d-c923-4c02-9bee-757573662e69"
    private let sessionID = "e73dcd35-b12b-4819-b90b-1eaff46b1af2"
    private let dashboardURL = URL(string: "https://allpredictor.com/dashbord")!
    private let gameURL = URL(string: "https://1w-ftend.life/")!
    private let output = UITextView()
    private let modeControl = UISegmentedControl(items: ["PETIT", "GRID", "GRAND", "10–100x", "AUTO"])
    private let status = UILabel()
    private var webView: WKWebView!
    private var currentMode = 4

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        buildUI(); showEngine();
    }

    private func buildUI() {
        let tabs = UISegmentedControl(items: ["BABEL", "AllPredictor", "Игра"])
        tabs.selectedSegmentIndex = 0; tabs.addTarget(self, action: #selector(tabChanged(_:)), for: .valueChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(tabs)

        modeControl.selectedSegmentIndex = 4; modeControl.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(modeControl)

        status.text = "● BABEL V29 • готов"; status.textColor = .systemGreen; status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(status)

        let signal = UIButton(type: .system); signal.setTitle("🎯 ПОЛУЧИТЬ СИГНАЛ", for: .normal); signal.titleLabel?.font = .boldSystemFont(ofSize: 17)
        signal.backgroundColor = .systemGreen; signal.setTitleColor(.black, for: .normal); signal.layer.cornerRadius = 12
        signal.addTarget(self, action: #selector(getSignal), for: .touchUpInside); signal.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(signal)

        let check = UIButton(type: .system); check.setTitle("🧪 ПРОВЕРИТЬ ПОДКЛЮЧЕНИЕ", for: .normal); check.addTarget(self, action: #selector(checkConnection), for: .touchUpInside)
        check.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(check)

        output.backgroundColor = UIColor(white: 0.06, alpha: 1); output.textColor = .white; output.font = .monospacedSystemFont(ofSize: 14, weight: .regular); output.isEditable = false; output.layer.cornerRadius = 12
        output.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(output)

        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .default(); cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg); webView.navigationDelegate = self; webView.isHidden = true; webView.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(webView)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4), tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            modeControl.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10), modeControl.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), modeControl.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            status.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10), status.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            signal.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10), signal.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), signal.trailingAnchor.constraint(equalTo: tabs.trailingAnchor), signal.heightAnchor.constraint(equalToConstant: 48),
            check.topAnchor.constraint(equalTo: signal.bottomAnchor, constant: 5), check.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            output.topAnchor.constraint(equalTo: check.bottomAnchor, constant: 5), output.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), output.trailingAnchor.constraint(equalTo: tabs.trailingAnchor), output.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            webView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6), webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor), webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func tabChanged(_ s: UISegmentedControl) {
        let web = s.selectedSegmentIndex != 0
        webView.isHidden = !web; modeControl.isHidden = web; status.isHidden = web; output.isHidden = web
        for v in view.subviews where v is UIButton { v.isHidden = web }
        if web { webView.load(URLRequest(url: s.selectedSegmentIndex == 1 ? dashboardURL : gameURL)) }
    }
    @objc private func modeChanged(_ s: UISegmentedControl) { currentMode = s.selectedSegmentIndex; output.text = "Режим переключён: \(s.titleForSegment(at: currentMode) ?? "")\nНажми «ПОЛУЧИТЬ СИГНАЛ»." }
    @objc private func checkConnection() { fetchHistory { result in DispatchQueue.main.async { switch result { case .success(let v): self.status.text = "● LIVE • получено \(v.count) раундов"; self.status.textColor = .systemGreen; self.output.text = "✅ Подключение работает\nПоследние: " + v.prefix(12).map{String(format:"%.2fx",$0)}.joined(separator:" • "); case .failure(let e): self.status.text = "● ошибка подключения"; self.status.textColor = .systemRed; self.output.text = "❌ \(e.localizedDescription)" } } } }
    @objc private func getSignal() { status.text = "● анализ LIVE…"; fetchHistory { r in DispatchQueue.main.async { switch r { case .success(let vals): self.render(vals); case .failure(let e): self.output.text = "❌ Ошибка: \(e.localizedDescription)" } } } }

    private func fetchHistory(completion: @escaping (Result<[Double],Error>)->Void) {
        var req = URLRequest(url: api); req.timeoutInterval = 12; req.setValue(customerID, forHTTPHeaderField: "customer-id"); req.setValue(sessionID, forHTTPHeaderField: "session-id"); req.setValue("application/json", forHTTPHeaderField: "accept")
        URLSession.shared.dataTask(with: req) { data,_,err in
            if let err { completion(.failure(err)); return }; guard let data else { return }
            do { let raw = try JSONSerialization.jsonObject(with:data) as? [[String:Any]] ?? []; var out:[Double]=[]
                for x in raw { var c = Self.num(x["topCoefficient"]); if c == nil, let f=x["finalValues"] as? [Any] { for y in f.reversed() { if let z=Self.num(y){ c=z; break } } }; if let c { out.append(c == 1 ? 1.01 : c) } }
                if out.isEmpty { throw NSError(domain:"BABEL",code:1,userInfo:[NSLocalizedDescriptionKey:"История LuckyJet пустая"]) }; completion(.success(out))
            } catch { completion(.failure(error)) }
        }.resume()
    }
    private static func num(_ a:Any?)->Double? { if let n=a as? NSNumber { return n.doubleValue }; if let s=a as? String { return Double(s) }; return nil }
    private func clamp(_ x:Double,_ a:Double,_ b:Double)->Double { min(max(x,a),b) }
    private func rate(_ a:[Double],_ p:(Double)->Bool)->Double { guard !a.isEmpty else{return 0}; return Double(a.filter(p).count)/Double(a.count) }
    private func gap(_ a:[Double],_ t:Double)->Int { a.firstIndex(where:{$0>=t}) ?? a.count }
    private func timeScore()->Double { let cal=Calendar(identifier:.gregorian); let d=Date(); let h=cal.component(.hour,from:d), m=cal.component(.minute,from:d); let ho=(1...2).contains(h)||(11...13).contains(h)||(16...19).contains(h)||(21...23).contains(h); let mo=(m>=59||m<=2)||(4...10).contains(m)||(13...20).contains(m)||(27...33).contains(m)||(45...47).contains(m)||(50...52).contains(m)||(55...59).contains(m); return ho && mo ? 1 : mo ? 0.72 : ho ? 0.55 : 0.20 }
    private func render(_ v:[Double]) {
        let r20=Array(v.prefix(20)), r50=Array(v.prefix(50)), r100=Array(v.prefix(100)); let p2=rate(r50){$0>=2}, p3=rate(r50){$0>=3}, p5=rate(r50){$0>=5}, p10=rate(r100){$0>=10}, p20=rate(r100){$0>=20}; let low=rate(r20){$0<1.5}; let g10=gap(v,10), g20=gap(v,20), g50=gap(v,50); let clipped=r50.map{min($0,50)}; let avg=clipped.reduce(0,+)/Double(max(clipped.count,1)); let vol=sqrt(clipped.map{pow($0-avg,2)}.reduce(0,+)/Double(max(clipped.count,1)))/max(avg,1); let ts=timeScore();
        var under5=0; for x in v { if x<5 {under5+=1}else{break} }; var lowStreak=0; for x in v {if x<2{lowStreak+=1}else{break}}
        let gapPressure=clamp(Double(g10)/14,0,1)*0.42+clamp(Double(g20)/30,0,1)*0.28+clamp(Double(g50)/80,0,1)*0.10; let burst=clamp(p5/0.22,0,1)*0.55+clamp(p10/0.11,0,1)*0.30+clamp(p20/0.05,0,1)*0.15; let power=clamp(gapPressure*0.32+burst*0.22+0.33*0.18+clamp(vol/1.25,0,1)*0.14+clamp(Double(under5)/8,0,1)*0.08+ts*0.06,0,1); let grand=clamp((15+35*pow(power,1.28))*0.82+25.48*0.18,15,50)
        let mid=rate(r50){$0>=3 && $0<10}; let insStrength=clamp(clamp(mid/0.28,0,1)*0.34+(1-clamp(abs(vol-0.72)/0.90,0,1))*0.22+clamp(Double(lowStreak)/5,0,1)*0.18+0.33*0.18+ts*0.08,0,1); let insurance=clamp((4.2+insStrength*1.3)*0.86+4.86*0.14,4.2,5.5); let q=clamp((1-abs(power-insStrength))*0.30+0.33*0.18+(1-clamp(abs(p2-0.42)/0.42,0,1))*0.14+ts*0.10+clamp(p5/0.25,0,1)*0.10,0,1); let conf=Int(round(clamp((58+q*21)*0.90+73*0.10,58,79)))
        let petitStrength=clamp(clamp(p2/0.55,0,1)*0.34+(1-clamp(vol/1.20,0,1))*0.25+clamp(Double(lowStreak)/4,0,1)*0.20+(1-clamp(low/0.50,0,1))*0.13+ts*0.08,0,1); let petit=clamp((1.5+petitStrength*0.78)*0.82+2.062*0.18,1.5,2.35); let petitConf=Int(round(clamp((51+petitStrength*15)*0.90+57*0.10,51,67)))
        let mode = currentMode == 4 ? (power >= 0.52 ? 2 : 0) : currentMode; var text=""
        if mode==0 { text=String(format:"🚀 BABEL — PETIT LIVE\n\n🎯 Цель: %.2fx\n⚡ Уверенность: %d%%\n📊 Сила PETIT: %.3f",petit,petitConf,petitStrength) }
        else if mode==1 { let targets=[2.00,2.17,2.05,2.28,2.12,2.21,2.03,2.30,2.14,2.08,2.25,2.10,2.19,2.06,2.23,2.01,2.27,2.13,2.09,2.29,2.16,2.04]; let slot=Int(Date().timeIntervalSince1970/130)%22; text=String(format:"🟢 BABEL — PETIT GRID\n\n🎯 Цель: %.2fx\n🔢 Позиция: %d/22\n⏱ Шаг сетки: 130 сек.",targets[slot],slot+1) }
        else if mode==2 { text=String(format:"🎯 BABEL — GRAND + СТРАХОВКА\n\n🎯 Основная цель: %.2fx\n🛡 Страховка: %.2fx\n⚡ Уверенность: %d%%\n📈 Сила GRAND: %.3f\n10x / 20x не было: %d / %d раундов",grand,insurance,conf,power,g10,g20) }
        else { let allowed=ts>=0.72; text=allowed ? String(format:"🔥 BABEL — GROSSE CÔTE PRO\n\n🎯 Диапазон: 10x–100x\n⚡ Уверенность: %d%%\n📈 Сила: %.3f\nПосле 10x / 20x / 50x: %d / %d / %d",conf,power,g10,g20,g50) : String(format:"🔥 BABEL — GROSSE CÔTE 10–100x\n\n⏳ Сейчас ожидаем разрешённое временное окно.\n⚡ Оценка: %d%%\nПосле 10x: %d раундов",conf,g10) }
        if currentMode==4 { text="🧠 BABEL V2 AUTO\n🤖 Автовыбор движка\n━━━━━━━━━━━━━━━\n"+text }; text += "\n\nПоследние:\n"+v.prefix(12).map{String(format:"%.2fx",$0)}.joined(separator:" • "); output.text=text; status.text="● LIVE • анализ завершён"; status.textColor=.systemGreen
    }
}
