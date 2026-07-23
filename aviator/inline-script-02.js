
  // === Exact browser port of analys.py decision flow ===
  const apiURL = "https://crash-gateway-grm-cr.100hp.app/state";
  const headers = {
    "customer-id": "077dee8d-c923-4c02-9bee-757573662e69",
    "session-id": "ba47ba53-8ac6-4ed5-9bda-3d7d033acffc",
    "accept": "application/json"
  };

  const TZ_LABEL = "Europe/Kyiv";
  const POLL_SECONDS = 5;
  const PAUSE_AFTER_LOSSES = 2;
  const PAUSE_SECONDS = 5 * 60;
  const SETTINGS = { mode:"PRO", goal:"balance", range:{ min:2.0, max:5.0 } };
  const STORAGE_KEY = "lumorax_aviator_live_v2";
  const FETCH_TIMEOUT_MS = 8000;
  const TRAINED_V3 = {
    name:"TRAINED V3",
    target:2.0,
    minTarget:1.8,
    maxTarget:2.15,
    triggerBelow:1.5,
    minLiveRounds:8,
    historyRounds:1123,
    testHits:68,
    testTotal:128,
    testRate:0.531,
    baseHits:162,
    baseTotal:337,
    baseRate:0.481,
    rule:"после последнего коэффициента ниже 1.50x"
  };

  let coefs = [];
  let last5 = [];
  let grandEvents = [];
  let results = [];
  let stats = { ok:0, ko:0 };
  let history = [];
  let lastNoSignal = "Пока идет сбор данных.";
  let pausedLossStreak = 0;
  let pauseUntil = 0;
  let pendingMode = null;
  let autoSignal = false;
  let activeSignal = null;
  let lastRoundKey = "";
  let lastPolledAt = 0;
  let pollingNow = false;
  let mainTimer = null;
  let entryTimer = null;
  let countdownTimer = null;
  let signalPollTimer = null;
  const aviatorMode = true;
  let aviatorRoundsReceived = 0;
  let aviatorBridgeReady = false;
  let lastAviatorMessageAt = 0;

  const multEl  = document.getElementById("multiplier");
  const circle  = document.getElementById("circle");
  const spin    = document.getElementById("spin");
  const btn     = document.getElementById("generateButton");
  const autoBtn = document.getElementById("autoButton");
  const grandBtn = document.getElementById("grandButton");
  const trainedBtn = document.getElementById("trainedButton");
  const roundEl = document.getElementById("roundStatus");
  const lastEl  = document.getElementById("lastCoef");
  const status  = document.getElementById("verifyStatus");
  const analysisReasonEl = document.getElementById("analysisReason");
  const analysisStatsEl = document.getElementById("analysisStats");
  const betTimeEl = document.getElementById("betTime");
  const countOkEl = document.getElementById("countOk");
  const countKoEl = document.getElementById("countKo");
  const countTotalEl = document.getElementById("countTotal");
  const apiStateEl = document.getElementById("apiState");
  const rate2xEl = document.getElementById("rate2x");
  const rate10xEl = document.getElementById("rate10x");
  const exportCsvBtn = document.getElementById("exportCsv");
  const aviatorBtn = document.getElementById("aviatorButton");

  const openHistoryBtn = document.getElementById("openHistory");
  const closeHistoryBtn = document.getElementById("closeHistory");
  const historyPanel = document.getElementById("historyPanel");
  const chipsContainer = document.getElementById("chipsContainer");
  const historyFilterEl = document.getElementById("historyFilter");
  const openSettingsBtn = document.getElementById("openSettings");
  const closeSettingsBtn = document.getElementById("closeSettings");
  const settingsPanel = document.getElementById("settingsPanel");
  const resetStatsBtn = document.getElementById("resetStats");
  const resetHistoryBtn = document.getElementById("resetHistory");
  const settingsMsg = document.getElementById("settingsMsg");

  const fmt2 = n => (n < 10 ? "0" + n : "" + n);
  const hhmm = d => fmt2(d.getHours()) + ":" + fmt2(d.getMinutes());
  const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));
  const avg = arr => arr.reduce((sum, value) => sum + value, 0) / Math.max(1, arr.length);

  function normalizeCoef(value){
    if(value == null || value === "") return null;
    const n = Number(typeof value === "string" ? value.toLowerCase().replace("x", "").trim() : value);
    if(!Number.isFinite(n) || n < 1) return null;
    return Number((n === 1 ? 1.01 : n).toFixed(2));
  }

  function setApiState(text, kind){
    if(!apiStateEl) return;
    apiStateEl.textContent = text || "WAIT";
    apiStateEl.className = "value " + (kind === "ok" ? "api-ok" : kind === "ko" ? "api-ko" : "api-wait");
  }

  function pctText(hits, total){
    if(!total) return "--";
    return Math.round(hits / total * 100) + "%";
  }

  function renderAnalytics(){
    const recent20 = coefs.slice(-20);
    const recent120 = coefs.slice(-120);
    if(rate2xEl){
      const hits = recent20.filter(x => x >= 2).length;
      rate2xEl.textContent = recent20.length ? pctText(hits, recent20.length) : "--";
    }
    if(rate10xEl){
      const hits = recent120.filter(x => x >= 10).length;
      rate10xEl.textContent = recent120.length ? pctText(hits, recent120.length) : "--";
    }
  }

  function saveState(){
    try{
      localStorage.setItem(STORAGE_KEY, JSON.stringify({
        coefs: coefs.slice(-120),
        last5: last5.slice(-5),
        grandEvents: grandEvents.slice(-50),
        results: results.slice(-10),
        stats,
        history: history.slice(0, 200),
        lastRoundKey,
        pausedLossStreak,
        pauseUntil
      }));
    }catch(e){
      console.warn("Storage save error", e);
    }
  }

  function loadState(){
    try{
      const raw = localStorage.getItem(STORAGE_KEY);
      if(!raw) return false;
      const saved = JSON.parse(raw);
      coefs = Array.isArray(saved.coefs) ? saved.coefs.map(normalizeCoef).filter(x => x != null).slice(-120) : [];
      last5 = Array.isArray(saved.last5) ? saved.last5.map(normalizeCoef).filter(x => x != null).slice(-5) : coefs.slice(-5);
      grandEvents = Array.isArray(saved.grandEvents) ? saved.grandEvents.slice(-50) : [];
      results = Array.isArray(saved.results) ? saved.results.filter(x => x === "ok" || x === "ko").slice(-10) : [];
      stats = saved.stats && Number.isFinite(Number(saved.stats.ok)) && Number.isFinite(Number(saved.stats.ko))
        ? { ok:Number(saved.stats.ok), ko:Number(saved.stats.ko) }
        : { ok:0, ko:0 };
      history = Array.isArray(saved.history) ? saved.history.slice(0, 200) : [];
      lastRoundKey = saved.lastRoundKey || "";
      pausedLossStreak = Number(saved.pausedLossStreak) || 0;
      pauseUntil = Number(saved.pauseUntil) || 0;
      if(coefs.length) lastEl.textContent = coefs[coefs.length - 1].toFixed(2) + "X";
      return true;
    }catch(e){
      console.warn("Storage load error", e);
      return false;
    }
  }

  function clearSavedState(){
    try{
      localStorage.removeItem(STORAGE_KEY);
    }catch(e){
      console.warn("Storage clear error", e);
    }
  }

  function setStatus(msg, kind){
    status.className = "status " + (kind || "");
    status.textContent = msg || "";
  }

  function setButtons(enabled){
    btn.disabled = !enabled || !!activeSignal;
    autoBtn.disabled = !enabled;
    if(grandBtn) grandBtn.disabled = !enabled || !!activeSignal;
    if(trainedBtn) trainedBtn.disabled = !enabled || !!activeSignal;
  }

  function setBetTimeToTarget(date){
    betTimeEl.textContent = hhmm(date);
  }

  function riskName(risk){
    if(risk === "low") return "низкий";
    if(risk === "medium") return "средний";
    if(risk === "high") return "высокий";
    return risk || "-";
  }

  function analysisStatsText(aInfo){
    const info = aInfo || analyze();
    const good = last5.filter(x => x > 1.5).length;
    const recent = last5.length ? "[" + last5.map(x => Number(x).toFixed(2)).join(", ") + "]" : "нет данных";
    return "PRO / баланс | рынок " + info.score + "/100 | риск " + riskName(info.risk) +
      " | уверенность " + info.conf + "% | последние: " + recent + " | >1.50: " + good + "/" + last5.length;
  }

  function writeAnalysis(message, kind, aInfo){
    if(analysisReasonEl){
      analysisReasonEl.className = "analysis-reason " + (kind || "");
      analysisReasonEl.textContent = message || "";
    }
    if(analysisStatsEl) analysisStatsEl.textContent = analysisStatsText(aInfo);
  }

  function refreshCountsUI(){
    countOkEl.textContent = stats.ok;
    countKoEl.textContent = stats.ko;
    countTotalEl.textContent = stats.ok + stats.ko;
  }

  function pushHistory(entry){
    history.unshift(entry);
    if(history.length > 200) history.length = 200;
    saveState();
  }

  function renderHistory(){
    chipsContainer.textContent = "";
    const filter = historyFilterEl ? historyFilterEl.value : "all";
    const visibleHistory = history.filter(it => {
      if(filter === "all") return true;
      if(filter === "ok" || filter === "ko") return it.status === filter;
      return it.type === filter;
    });
    if(!visibleHistory.length){
      const em = document.createElement("div");
      em.textContent = history.length ? "No predictions for this filter." : "No predictions yet.";
      em.style.opacity = .85;
      em.style.padding = "4px 2px";
      chipsContainer.appendChild(em);
      return;
    }
    visibleHistory.forEach(it => {
      const chip = document.createElement("div");
      chip.className = "chip " + (it.status === "ok" ? "ok" : "ko");
      chip.title = (it.status === "ok" ? "Win" : "Loss") + " - " + new Date(it.time).toLocaleString();
      chip.appendChild(document.createTextNode(Number(it.coef).toFixed(2) + "x"));
      const small = document.createElement("small");
      small.textContent = (it.type || "PRO") + " - " + (it.status === "ok" ? "Win" : "Loss") +
        " - " + hhmm(new Date(it.time)) + (it.round ? " - R" + it.round : "");
      chip.appendChild(small);
      chipsContainer.appendChild(chip);
    });
  }

  function parseRoundPayload(data){
    const cfg = data && typeof data.roundConfig === "object" ? data.roundConfig : {};
    const value = Array.isArray(data && data.stopCoefficients) ? data.stopCoefficients[0] : null;
    const coef = normalizeCoef(value);
    if(coef == null) return null;
    const id = cfg.id || data.roundId || data.id || data.currentRoundId || "";
    const time = data.stateChangedAt || data.currentTime || data.updatedAt || "";
    const key = id ? "id:" + String(id) : (time ? "time:" + String(time) + ":" + coef.toFixed(2) : "coef:" + coef.toFixed(2));
    return { coef, key, id:String(id || ""), time:String(time || "") };
  }

  async function getCoef(){
    if(aviatorMode) return null;
    const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
    const timeoutId = controller ? setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS) : null;
    try{
      setApiState("POLL", "");
      const res = await fetch(apiURL, { headers, cache:"no-store", signal: controller ? controller.signal : undefined });
      if(!res.ok) throw new Error("HTTP " + res.status);
      const data = await res.json();
      const parsed = parseRoundPayload(data);
      setApiState(parsed ? "LIVE" : "NO DATA", parsed ? "ok" : "");
      return parsed;
    }catch(e){
      const msg = e && e.name === "AbortError" ? "TIMEOUT" : "OFFLINE";
      setApiState(msg, "ko");
      console.warn("API error", e);
      return null;
    }finally{
      if(timeoutId) clearTimeout(timeoutId);
    }
  }

  function addCoef(round){
    if(round == null) return false;
    const coef = typeof round === "object" ? round.coef : normalizeCoef(round);
    const key = typeof round === "object" && round.key ? round.key : (coef == null ? "" : "coef:" + coef.toFixed(2));
    if(coef == null) return false;
    if(key && lastRoundKey === key) return false;
    if(!key && coefs.length && coefs[coefs.length - 1] === coef) return false;
    lastRoundKey = key || lastRoundKey;
    coefs.push(coef);
    last5.push(coef);
    if(coefs.length > 120) coefs = coefs.slice(-120);
    if(last5.length > 5) last5 = last5.slice(-5);
    rememberGrandEvent(coef);
    lastEl.textContent = coef.toFixed(2) + "X";
    renderAnalytics();
    saveState();
    console.log("[coef]", coef.toFixed(2) + "X");
    return true;
  }

  function aviatorSnapshotDelta(rawValues){
    const values = (Array.isArray(rawValues) ? rawValues : [])
      .map(normalizeCoef).filter(value => value != null).slice(-120);
    if(!values.length) return [];
    if(!coefs.length) return values;

    const maxAnchor = Math.min(12, coefs.length, values.length);
    for(let length = maxAnchor; length >= 2; length -= 1){
      const anchor = coefs.slice(-length);
      for(let start = values.length - length; start >= 0; start -= 1){
        let match = true;
        for(let index = 0; index < length; index += 1){
          if(values[start + index] !== anchor[index]){ match = false; break; }
        }
        if(match) return values.slice(start + length);
      }
    }

    const newest = values[values.length - 1];
    return coefs[coefs.length - 1] === newest ? [] : [newest];
  }

  function acceptAviatorMessage(data){
    if(!data || data.source !== "lumorax-aviator") return false;
    lastAviatorMessageAt = Date.now();

    if(data.type === "bridge-reconnecting"){
      aviatorBridgeReady = false;
      setApiState("RECONNECTING", "ko");
      return true;
    }

    if(data.type === "bridge-ready" || data.type === "heartbeat"){
      aviatorBridgeReady = true;
      setApiState("AVIATOR " + aviatorRoundsReceived + " LIVE", "ok");
      return true;
    }

    if(data.type === "history"){
      const values = aviatorSnapshotDelta(data.values);
      let added = 0;
      values.forEach((coef, index) => {
        const key = "aviator:sync:" + String(data.ts || data.batchId || Date.now()) + ":" + index;
        if(addCoef({coef, key})) added += 1;
      });
      if(added){
        aviatorRoundsReceived += added;
        setButtons(last5.length >= 5);
        setStatus("Aviator synchronized: " + added + " new rounds received.", "ok");
        writeAnalysis("Live bridge recovered and synchronized without duplicates.", "ok", analyze());
      }
      setApiState("AVIATOR " + aviatorRoundsReceived + " LIVE", "ok");
      return true;
    }

    if(data.type !== "coef") return false;
    const coef = normalizeCoef(data.coef);
    if(coef == null) return false;
    const key = "aviator:" + String(data.roundKey || (Date.now() + ":" + coef.toFixed(2)));
    if(!addCoef({coef, key})) return true;

    aviatorBridgeReady = true;
    aviatorRoundsReceived += 1;
    setButtons(last5.length >= 5);
    setApiState("AVIATOR " + aviatorRoundsReceived + " LIVE", "ok");
    onNewCoef(coef);
    return true;
  }

  window.addEventListener("message", event => {
    if(event.source !== window) return;
    acceptAviatorMessage(event.data);
  });
  function rememberGrandEvent(coef){
    if(coef < 10) return;
    const d = new Date();
    grandEvents.push({ coef, minute:d.getMinutes(), time:d.toISOString(), clock:hhmm(d) });
    if(grandEvents.length > 50) grandEvents = grandEvents.slice(-50);
    console.log("[grand]", coef.toFixed(2) + "X at " + hhmm(d));
  }

  async function pollOnce(){
    const round = await getCoef();
    if(addCoef(round)) return round.coef;
    return null;
  }

  async function maybePoll(){
    const nowMs = Date.now();
    if(pollingNow || nowMs - lastPolledAt < POLL_SECONDS * 1000) return null;
    pollingNow = true;
    lastPolledAt = nowMs;
    try{
      const coef = await pollOnce();
      if(coef != null) onNewCoef(coef);
      return coef;
    }finally{
      pollingNow = false;
    }
  }

  function filteredCoefs(){
    if(SETTINGS.mode === "SAFE") return coefs.filter(x => x >= 1.2 && x <= 5);
    if(SETTINGS.mode === "SNIPER") return coefs.filter(x => x >= 3);
    return coefs.slice();
  }

  function consecutiveLosses(){
    let losses = 0;
    for(let i = results.length - 1; i >= 0; i--){
      if(results[i] !== "ko") break;
      losses += 1;
    }
    return losses;
  }

  function analyze(){
    if(coefs.length < 3){
      return { score:50, level:"safe", risk:"low", why:"данных пока мало", conf:50, low_count:0, trend_up:false, losses:consecutiveLosses() };
    }
    const recent = coefs.slice(-8);
    const lowCount = recent.filter(x => x < 1.5).length;
    const lowRatio = lowCount / recent.length;
    const veryLow = recent.filter(x => x < 1.2).length;
    const losses = consecutiveLosses();
    const prevPart = recent.slice(0, 4);
    const nowPart = recent.slice(-4);
    const trendUp = avg(nowPart) > avg(prevPart);
    let rawScore = 100 - lowRatio * 42 - veryLow * 8 - losses * 22;
    rawScore += trendUp ? 6 : -6;
    const score = Math.round(clamp(rawScore, 0, 100));
    let risk, level;
    if(score >= 70 && losses === 0){
      risk = "low";
      level = "safe";
    }else if(score >= 45 && losses < 2){
      risk = "medium";
      level = "warn";
    }else{
      risk = "high";
      level = "danger";
    }
    let why;
    if(losses >= 2) why = losses + " проигрыша подряд";
    else if(lowCount >= 4) why = "много низких коэффициентов";
    else if(trendUp) why = "тренд растет";
    else why = "тренд слабый или рынок шумный";
    let conf = score;
    if(risk === "high") conf -= 10;
    if(SETTINGS.goal === "rare") conf += 6;
    conf = Math.round(clamp(conf, 35, 92));
    return { score, level, risk, why, conf, low_count:lowCount, trend_up:trendUp, losses };
  }

  function smartTarget(minCoef, maxCoef){
    let src = filteredCoefs().slice(-8);
    if(src.length < 5) src = last5.slice();
    if(!src.length) return Number(minCoef.toFixed(2));
    const a = avg(src);
    const lowRatio = src.filter(x => x < 1.5).length / src.length;
    const aInfo = analyze();
    let target = a * 0.72 + aInfo.score / 100 * 0.55 - lowRatio * 0.35;
    if(SETTINGS.mode === "SAFE") target = Math.min(target, 2.2);
    if(SETTINGS.mode === "SNIPER") target = Math.max(target, Math.min(maxCoef, 3.0));
    if(SETTINGS.goal === "many") target -= 0.25;
    if(SETTINGS.goal === "rare") target += 0.35;
    return Number(clamp(target, minCoef, maxCoef).toFixed(2));
  }

  function explainSignal(){
    const aInfo = analyze();
    const good = last5.filter(x => x > 1.5).length;
    return "Сигнал выбран: " + good + "/5 последних коэффициентов выше 1.50, рынок " + aInfo.score +
      "/100, риск " + riskName(aInfo.risk) + ", причина: " + aInfo.why + ".";
  }

  function trainedPct(value){
    return (value * 100).toFixed(1) + "%";
  }

  function trainedLiveInfo(){
    const recent = coefs.slice(-20);
    const hit2 = recent.filter(x => x >= TRAINED_V3.target).length;
    return {
      last: coefs.length ? coefs[coefs.length - 1] : null,
      recent,
      hit2,
      liveRate: recent.length ? hit2 / recent.length : null,
      low5: last5.filter(x => x < TRAINED_V3.triggerBelow).length
    };
  }

  function trainedTarget(){
    const info = trainedLiveInfo();
    let target = TRAINED_V3.target;
    if(info.recent.length >= 12 && info.liveRate !== null){
      if(info.liveRate < 0.42) target = TRAINED_V3.minTarget;
      else if(info.liveRate > 0.56 && last5.filter(x => x >= 1.5).length >= 3) target = TRAINED_V3.maxTarget;
    }
    return Number(clamp(target, TRAINED_V3.minTarget, TRAINED_V3.maxTarget).toFixed(2));
  }

  function explainTrainedSignal(target){
    const info = trainedLiveInfo();
    const liveText = info.liveRate === null ? "мало live-данных" : (info.hit2 + "/" + info.recent.length + " >=2.00x, " + trainedPct(info.liveRate));
    return "TRAINED V3: правило из " + TRAINED_V3.historyRounds + " раундов — " + TRAINED_V3.rule +
      ". Проверка JSON: " + TRAINED_V3.testHits + "/" + TRAINED_V3.testTotal + " = " + trainedPct(TRAINED_V3.testRate) +
      " против фона " + trainedPct(TRAINED_V3.baseRate) + ". Live рынок: " + liveText +
      ". Цель: " + target.toFixed(2) + "X.";
  }

  function canSignal(){
    const aInfo = analyze();
    if(aInfo.level === "danger"){
      lastNoSignal = "Нет сигнала: слабый рынок, " + aInfo.why + ".";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    if(last5.length < 5){
      lastNoSignal = "Нет сигнала: нужно 5 последних коэффициентов, сейчас " + last5.length + ".";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    const good = last5.filter(x => x > 1.5).length;
    if(good < 3){
      lastNoSignal = "Нет сигнала: коэффициентов выше 1.50 только " + good + "/5.";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    if(SETTINGS.goal === "rare" && aInfo.conf < 70){
      lastNoSignal = "Нет сигнала: уверенность " + aInfo.conf + "%, нужно от 70%.";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    lastNoSignal = "Сигнал разрешен: условия analys.py выполнены.";
    writeAnalysis(lastNoSignal, "ok", aInfo);
    return true;
  }

  function canTrainedSignal(){
    const aInfo = analyze();
    const info = trainedLiveInfo();
    if(coefs.length < TRAINED_V3.minLiveRounds){
      lastNoSignal = "TRAINED V3 ждёт: нужно минимум " + TRAINED_V3.minLiveRounds + " live-коэффициентов, сейчас " + coefs.length + ".";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    if(info.last === null){
      lastNoSignal = "TRAINED V3 ждёт первый коэффициент.";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    if(info.last >= TRAINED_V3.triggerBelow){
      lastNoSignal = "TRAINED V3 ждёт вход после коэффициента ниже " + TRAINED_V3.triggerBelow.toFixed(2) + "X. Последний: " + info.last.toFixed(2) + "X.";
      writeAnalysis(lastNoSignal, "", aInfo);
      return false;
    }
    if(consecutiveLosses() >= PAUSE_AFTER_LOSSES){
      lastNoSignal = "TRAINED V3 не входит: активна защита после проигрышей подряд.";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    if(aInfo.level === "danger" && info.low5 >= 3){
      lastNoSignal = "TRAINED V3 пропускает: слишком много низких коэффициентов в последних 5 (" + info.low5 + "/5).";
      writeAnalysis(lastNoSignal, "ko", aInfo);
      return false;
    }
    const target = trainedTarget();
    lastNoSignal = explainTrainedSignal(target);
    writeAnalysis(lastNoSignal, "ok", aInfo);
    return true;
  }

  function minuteDistance(a, b){
    const direct = Math.abs(a - b);
    return Math.min(direct, 60 - direct);
  }

  function nextTimeForMinute(minute){
    const d = new Date();
    d.setSeconds(0, 0);
    if(d.getMinutes() >= minute) d.setHours(d.getHours() + 1);
    d.setMinutes(minute);
    return d;
  }

  function grandAnalysis(){
    if(grandEvents.length < 2) return null;
    const currentMinute = new Date().getMinutes();
    const candidates = [];
    for(let shift = 1; shift <= 15; shift++){
      const minute = (currentMinute + shift) % 60;
      const exact = grandEvents.filter(event => event.minute === minute).length;
      const near = grandEvents.filter(event => minuteDistance(event.minute, minute) === 1).length;
      const score = exact * 3 + near;
      if(score) candidates.push({ score, exact, near, minute });
    }
    if(!candidates.length) return null;
    candidates.sort((a, b) => b.score - a.score);
    const best = candidates[0];
    const lastEvents = grandEvents.slice(-5);
    const confidence = Math.round(clamp(35 + best.score * 8 + Math.min(grandEvents.length, 10) * 2, 35, 88));
    const avgHigh = avg(lastEvents.map(event => event.coef));
    const target = Number(clamp(avgHigh * 0.42 + confidence * 0.08, 10, 35).toFixed(2));
    return { time:nextTimeForMinute(best.minute), exact:best.exact, near:best.near, score:best.score, confidence, target, lastEvents };
  }

  function chooseEntryTime(){
    const entry = new Date(Date.now() + (Math.floor(Math.random() * 4) + 1) * 60000);
    entry.setSeconds(0, 0);
    if(entry.getTime() <= Date.now() + 10000) entry.setMinutes(entry.getMinutes() + 1);
    return entry;
  }

  function chooseTrainedEntryTime(){
    const entry = new Date(Date.now() + 65000);
    entry.setSeconds(0, 0);
    if(entry.getTime() <= Date.now() + 10000) entry.setMinutes(entry.getMinutes() + 1);
    return entry;
  }

  function minMaxRange(){
    const minCoef = Math.max(1.0, Number(SETTINGS.range.min));
    const maxCoef = Math.max(minCoef + 0.01, Number(SETTINGS.range.max));
    return { min:minCoef, max:maxCoef };
  }

  function startSignal(target, entryTime, type, skipFirst, detail){
    clearSignalTimers();
    activeSignal = { target, entryTime, type, skipFirst, phase:"waitEntry", round:0, lastReal:null };
    pendingMode = null;
    roundEl.textContent = "0";
    setBetTimeToTarget(entryTime);
    multEl.textContent = target.toFixed(2) + "X";
    multEl.style.color = "#00ff66";
    circle.classList.remove("ok", "ko");
    circle.classList.add("verifying");
    spin.classList.remove("ok", "ko");
    setButtons(last5.length >= 5);
    const msg = detail + " Вход: " + hhmm(entryTime) + " по Киеву.";
    setStatus(msg, "");
    writeAnalysis(msg, "ok", analyze());
    console.log("[signal] target=" + target.toFixed(2) + "X entry=" + hhmm(entryTime));
    scheduleSignalTimers();
  }

  function formatLeft(ms){
    const total = Math.max(0, Math.ceil(ms / 1000));
    const minutes = Math.floor(total / 60);
    const seconds = total % 60;
    return minutes > 0 ? minutes + "м " + seconds + "с" : seconds + "с";
  }

  function clearSignalTimers(){
    if(entryTimer){
      clearTimeout(entryTimer);
      entryTimer = null;
    }
    if(countdownTimer){
      clearInterval(countdownTimer);
      countdownTimer = null;
    }
    if(signalPollTimer){
      clearInterval(signalPollTimer);
      signalPollTimer = null;
    }
  }

  function scheduleSignalTimers(){
    if(!activeSignal) return;
    const delay = Math.max(0, activeSignal.entryTime.getTime() - Date.now() + 150);
    entryTimer = setTimeout(() => {
      updateActiveSignalByClock(true);
    }, delay);
    countdownTimer = setInterval(() => {
      updateActiveSignalByClock(false);
    }, 1000);
    signalPollTimer = setInterval(() => {
      maybePoll();
    }, 1000);
    updateActiveSignalByClock(false);
  }

  function updateActiveSignalByClock(force){
    if(!activeSignal || activeSignal.phase !== "waitEntry") return;

    const leftMs = activeSignal.entryTime.getTime() - Date.now();
    if(leftMs > 0 && !force){
      const msg = "Вход в " + hhmm(activeSignal.entryTime) + ". Осталось " + formatLeft(leftMs) + ".";
      setStatus(msg, "");
      writeAnalysis("Сигнал выбран. Жду время входа " + hhmm(activeSignal.entryTime) + ", продолжаю сбор коэффициентов.", "ok", analyze());
      return;
    }

    const enterMsg = "⏱ Время входа. Ставить сейчас. Жду завершения текущего раунда.";
    setStatus(enterMsg, "");
    writeAnalysis("Время входа наступило. Ставь сейчас. " + (activeSignal.skipFirst ? "Ближайший новый коэффициент будет пропущен как текущий раунд, потом начнется проверка 1/3." : "Начинаю проверку следующих 3 раундов."), "ok", analyze());
    activeSignal.phase = activeSignal.skipFirst ? "skipNext" : "checking";
    if(entryTimer){
      clearTimeout(entryTimer);
      entryTimer = null;
    }
    if(countdownTimer){
      clearInterval(countdownTimer);
      countdownTimer = null;
    }
  }

  function runSignalCycle(){
    const range = minMaxRange();
    const target = smartTarget(range.min, range.max);
    const entryTime = chooseEntryTime();
    startSignal(target, entryTime, SETTINGS.mode, true, "🚀 LuckyJet сигнал. " + explainSignal());
  }

  function runTrainedCycle(){
    const target = trainedTarget();
    const entryTime = chooseTrainedEntryTime();
    startSignal(target, entryTime, TRAINED_V3.name, true, "🧠 " + explainTrainedSignal(target));
  }

  function runGrandCycle(){
    const plan = grandAnalysis();
    if(!plan){
      handleGrandRequest(true);
      return false;
    }
    startSignal(plan.target, plan.time, "GRAND", false,
      "👑 GRAND 10X. Уверенность " + plan.confidence + "%, совпадений " + plan.exact + ", рядом " + plan.near + ".");
    return true;
  }

  function handleSimpleRequest(fromWait){
    if(activeSignal) return false;
    if(canSignal()){
      pendingMode = null;
      runSignalCycle();
      return true;
    }
    pendingMode = "simple";
    if(!fromWait){
      const msg = "Простой сигнал поставлен в ожидание. Сейчас причина: " + lastNoSignal;
      setStatus(msg, "");
      writeAnalysis(msg + " Как только рынок восстановится, HTML сам даст сигнал.", "ko", analyze());
    }
    return false;
  }

  function handleGrandRequest(fromWait){
    if(activeSignal) return false;
    if(grandAnalysis()){
      pendingMode = null;
      runGrandCycle();
      return true;
    }
    pendingMode = "grand";
    const msg = "GRAND поставлен в ожидание. Нужно минимум 2 события 10X+, сейчас найдено: " + grandEvents.length + ".";
    if(!fromWait) setStatus(msg, "");
    writeAnalysis(msg, "ko", analyze());
    return false;
  }

  function handleTrainedRequest(fromWait){
    if(activeSignal) return false;
    if(canTrainedSignal()){
      pendingMode = null;
      runTrainedCycle();
      return true;
    }
    pendingMode = "trained";
    if(!fromWait){
      const msg = "TRAINED V3 поставлен в ожидание. Сейчас причина: " + lastNoSignal;
      setStatus(msg, "");
      writeAnalysis(msg + " HTML продолжит смотреть рынок и даст вход, когда появится коэффициент ниже " + TRAINED_V3.triggerBelow.toFixed(2) + "X.", "", analyze());
    }
    return false;
  }

  function handlePendingRequest(){
    if(pendingMode === "simple") handleSimpleRequest(true);
    else if(pendingMode === "grand") handleGrandRequest(true);
    else if(pendingMode === "trained") handleTrainedRequest(true);
  }

  function onNewCoef(coef){
    if(last5.length >= 5 && !activeSignal && btn.disabled){
      setButtons(true);
      const readyMsg = "Warmup complete: 5/5. Buttons enabled.";
      setStatus(readyMsg, "");
      writeAnalysis("Warmup завершен: собрано 5/5. Можно запрашивать сигнал.", "ok", analyze());
    }

    if(last5.length < 5 && !activeSignal){
      const msg = "Сбор первых коэффициентов: " + last5.length + "/5.";
      setStatus(msg, "");
      writeAnalysis(msg, "", analyze());
      if(last5.length >= 5){
        setButtons(true);
        setStatus("Готово. Кнопки активны, жду запрос сигнала.", "");
        writeAnalysis("Warmup завершен как в analys.py. Можно запрашивать сигнал.", "ok", analyze());
      }
      return;
    }

    if(!activeSignal){
      writeAnalysis("Данные обновлены. Последний коэффициент: " + coef.toFixed(2) + "X.", "", analyze());
      return;
    }

    if(activeSignal.phase === "waitEntry"){
      if(Date.now() < activeSignal.entryTime.getTime()){
        writeAnalysis("Жду время входа " + hhmm(activeSignal.entryTime) + ". Продолжаю сбор коэффициентов.", "", analyze());
        return;
      }
      setStatus("⏱ Время входа. Ставить сейчас.", "");
      writeAnalysis("Время входа наступило. " + (activeSignal.skipFirst ? "Первый новый коэффициент будет пропущен как в analys.py." : "Проверяю следующие 3 раунда."), "ok", analyze());
      activeSignal.phase = activeSignal.skipFirst ? "skipNext" : "checking";
    }

    if(activeSignal.phase === "skipNext"){
      activeSignal.lastReal = coef;
      activeSignal.phase = "checking";
      console.log("[signal] skipped current round:", coef.toFixed(2) + "X");
      writeAnalysis("Пропущен текущий раунд: " + coef.toFixed(2) + "X. Теперь проверяю 3 следующих.", "", analyze());
      return;
    }

    if(activeSignal.phase === "checking"){
      activeSignal.round += 1;
      activeSignal.lastReal = coef;
      roundEl.textContent = activeSignal.round;
      console.log("[round " + activeSignal.round + "] real=" + coef.toFixed(2) + "X target=" + activeSignal.target.toFixed(2) + "X");
      if(coef >= activeSignal.target){
        finishSignal(true, coef, activeSignal.round);
        return;
      }
      if(activeSignal.round >= 3) finishSignal(false, coef, 3);
    }
  }

  function finishSignal(ok, realCoef, roundNumber){
    const signal = activeSignal;
    clearSignalTimers();
    const result = ok ? "ok" : "ko";
    results.push(result);
    if(results.length > 10) results = results.slice(-10);
    stats[result] += 1;
    refreshCountsUI();
    pushHistory({ coef:signal.target, status:result, time:new Date().toISOString(), round:roundNumber, type:signal.type, real:realCoef });

    if(ok){
      pausedLossStreak = 0;
      setStatus("✅ Сигнал успешно зашел. Раунд " + roundNumber + "/3", "ok");
      writeAnalysis("Сигнал зашел: цель " + signal.target.toFixed(2) + "X, реальный " + realCoef.toFixed(2) + "X.", "ok", analyze());
      multEl.textContent = "Win ✅";
      multEl.style.color = "#10b981";
      circle.classList.remove("verifying", "ko");
      circle.classList.add("ok");
      spin.classList.remove("ko");
      spin.classList.add("ok");
    }else{
      setStatus("❌ Сигнал не зашел. Проверено 3/3 раунда.", "ko");
      writeAnalysis("Сигнал не зашел: цель " + signal.target.toFixed(2) + "X, последний " + realCoef.toFixed(2) + "X.", "ko", analyze());
      multEl.textContent = "Loss ❌";
      multEl.style.color = "#ef4444";
      circle.classList.remove("verifying", "ok");
      circle.classList.add("ko");
      spin.classList.remove("ok");
      spin.classList.add("ko");
    }

    activeSignal = null;
    setButtons(last5.length >= 5);
  }

  function pauseIfNeeded(){
    if(activeSignal) return true;
    const nowMs = Date.now();
    if(pauseUntil && nowMs < pauseUntil){
      const left = Math.ceil((pauseUntil - nowMs) / 1000);
      setStatus("Пауза активна: осталось " + Math.ceil(left / 60) + " мин.", "ko");
      writeAnalysis("Причина: " + consecutiveLosses() + " проигрыша подряд. Продолжу мониторинг после паузы.", "ko", analyze());
      return true;
    }
    if(pauseUntil && nowMs >= pauseUntil){
      while(results.length && results[results.length - 1] === "ko") results.pop();
      pausedLossStreak = 0;
      pauseUntil = 0;
      saveState();
      setStatus("Пауза закончилась. Снова ищу новый сигнал.", "");
      writeAnalysis("Пауза закончилась. Логика снова ищет сигнал.", "", analyze());
      return false;
    }

    const losses = consecutiveLosses();
    if(losses < PAUSE_AFTER_LOSSES){
      pausedLossStreak = 0;
      return false;
    }
    if(losses <= pausedLossStreak) return false;
    pausedLossStreak = losses;
    pauseUntil = Date.now() + PAUSE_SECONDS * 1000;
    saveState();
    setStatus("Пауза активна: " + losses + " проигрыша подряд.", "ko");
    writeAnalysis("Пауза как в analys.py: " + losses + " проигрыша подряд, мониторинг продолжится через 5 минут.", "ko", analyze());
    return true;
  }

  async function mainTick(){
    if(pauseIfNeeded()) return;
    updateActiveSignalByClock();
    await maybePoll();
    updateActiveSignalByClock();
    if(activeSignal || last5.length < 5) return;
    if(pendingMode) handlePendingRequest();
    else if(autoSignal && canSignal()) runSignalCycle();
    else if(autoSignal) writeAnalysis("AUTO включен. " + lastNoSignal, "", analyze());
  }

  function toggle(el, open){
    if(open){
      el.classList.add("open");
      el.setAttribute("aria-hidden", "false");
    }else{
      el.classList.remove("open");
      el.setAttribute("aria-hidden", "true");
    }
  }

  function csvCell(value){
    const text = value == null ? "" : String(value);
    return /[",\n\r]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
  }

  function exportCsv(){
    const rows = [["kind","time","type","status","target","real","round","coef"]];
    if(history.length){
      history.slice().reverse().forEach(it => {
        rows.push([
          "signal",
          it.time || "",
          it.type || "PRO",
          it.status || "",
          Number.isFinite(Number(it.coef)) ? Number(it.coef).toFixed(2) : "",
          Number.isFinite(Number(it.real)) ? Number(it.real).toFixed(2) : "",
          it.round || "",
          ""
        ]);
      });
    }else{
      coefs.forEach((coef, index) => {
        rows.push(["coef", "", "", "", "", "", index + 1, Number(coef).toFixed(2)]);
      });
    }
    const csv = rows.map(row => row.map(csvCell).join(",")).join("\n");
    const blob = new Blob([csv], { type:"text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "luckyjet-analysis-" + new Date().toISOString().slice(0, 10) + ".csv";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  btn.addEventListener("click", () => {
    autoSignal = false;
    autoBtn.classList.remove("on");
    autoBtn.textContent = "AUTO";
    handleSimpleRequest(false);
  });

  if(grandBtn){
    grandBtn.addEventListener("click", () => {
      autoSignal = false;
      autoBtn.classList.remove("on");
      autoBtn.textContent = "AUTO";
      handleGrandRequest(false);
    });
  }

  if(trainedBtn){
    trainedBtn.addEventListener("click", () => {
      autoSignal = false;
      autoBtn.classList.remove("on");
      autoBtn.textContent = "AUTO";
      handleTrainedRequest(false);
    });
  }

  autoBtn.addEventListener("click", () => {
    autoSignal = !autoSignal;
    pendingMode = null;
    autoBtn.classList.toggle("on", autoSignal);
    autoBtn.textContent = autoSignal ? "AUTO: ON" : "AUTO";
    if(autoSignal){
      setStatus("AUTO сигнал включен. Если рынок слабый, HTML подождет восстановления.", "");
      writeAnalysis("AUTO включен. Жду условия can_signal(), как analys.py.", "", analyze());
    }else{
      setStatus("AUTO сигнал выключен.", "");
      writeAnalysis("AUTO выключен. Новые сигналы только после нажатия кнопки.", "", analyze());
    }
  });

  openHistoryBtn.addEventListener("click", () => { renderHistory(); toggle(historyPanel, true); });
  closeHistoryBtn.addEventListener("click", () => toggle(historyPanel, false));
  if(historyFilterEl) historyFilterEl.addEventListener("change", renderHistory);
  if(aviatorBtn) aviatorBtn.addEventListener("click", () => {
    const nativeControl = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aviatorControl;
    if(nativeControl){
      nativeControl.postMessage({ action:"open", hasState:Boolean(localStorage.getItem(STORAGE_KEY)) });
      setStatus("Открываю Aviator внутри приложения. После входа мост передаст коэффициенты.", "ok");
      writeAnalysis("Войдите в 1win в открывшемся окне и запустите Aviator. Ставки приложение не нажимает.", "ok", analyze());
      return;
    }
    const gameWindow = window.open("https://1w-ftend.life/casino/play/v_spribe:aviator", "lumorax-aviator");
    if(gameWindow){
      setStatus("Aviator открыт. Мост передаст отображённые завершённые коэффициенты.", "ok");
      writeAnalysis("Жду коэффициенты Aviator. Сигналы появятся после получения истории.", "ok", analyze());
    }else{
      setStatus("Не удалось открыть Aviator.", "ko");
    }
  });
  if(exportCsvBtn) exportCsvBtn.addEventListener("click", exportCsv);
  openSettingsBtn.addEventListener("click", () => toggle(settingsPanel, true));
  closeSettingsBtn.addEventListener("click", () => toggle(settingsPanel, false));

  resetStatsBtn.addEventListener("click", () => {
    stats = { ok:0, ko:0 };
    results = [];
    pausedLossStreak = 0;
    pauseUntil = 0;
    refreshCountsUI();
    saveState();
    settingsMsg.textContent = "Stats reset.";
    writeAnalysis("Статистика сброшена.", "", analyze());
  });

  resetHistoryBtn.addEventListener("click", () => {
    clearSignalTimers();
    history = [];
    coefs = [];
    last5 = [];
    grandEvents = [];
    results = [];
    lastRoundKey = "";
    activeSignal = null;
    pendingMode = null;
    saveState();
    renderHistory();
    renderAnalytics();
    setButtons(false);
    roundEl.textContent = "0";
    lastEl.textContent = "—";
    betTimeEl.textContent = "--:--";
    settingsMsg.textContent = "History and collected analysis data reset.";
    setStatus("Сбор первых коэффициентов...", "");
    writeAnalysis("Данные сброшены. Снова собираю первые 5 коэффициентов.", "", analyze());
  });

  const restoredState = loadState();
  refreshCountsUI();
  renderAnalytics();
  renderHistory();
  setButtons(last5.length >= 5);
  setApiState(restoredState ? "AVIATOR RESTORED" : "WAIT AVIATOR", restoredState ? "ok" : "");
  if(last5.length >= 5){
    setStatus(restoredState ? "Данные восстановлены. Кнопки активны, продолжаю мониторинг." : "Готово. Кнопки активны, жду запрос сигнала.", "");
    writeAnalysis((restoredState ? "История восстановлена из localStorage. " : "") + "Собрано " + last5.length + "/5 последних коэффициентов. Можно запрашивать сигнал.", "ok", analyze());
  }else{
    setStatus("Сбор первых коэффициентов...", "");
    writeAnalysis("Как analys.py: сначала собираю 5 последних коэффициентов, потом активирую сигналы.", "", analyze());
  }
  if(!aviatorBridgeReady) setApiState(restoredState ? "AVIATOR RESTORED" : "WAIT BRIDGE", restoredState ? "ok" : "");
  mainTimer = setInterval(mainTick, 1000);
  setInterval(() => {
    if(lastAviatorMessageAt && Date.now() - lastAviatorMessageAt > 15000){
      aviatorBridgeReady = false;
      setApiState("RECONNECTING", "ko");
    }
  }, 5000);

