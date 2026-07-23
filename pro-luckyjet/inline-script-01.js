
/* ── ANCIEN BLOC ALLPREDICTOR (désactivé) ── */
/* ── CONSTANTES STORAGE ── */
const COUNTS_KEY  = 'kk_pred_counts_v1';
const HISTORY_KEY = 'kk_pred_history_v1';
const RANGE_KEY   = 'kk_pred_range_v1';

const BASE = 'https://allpredictor.com/api/v1';

const fmt2 = n => n < 10 ? '0'+n : ''+n;
const hhmm = d => `${fmt2(d.getHours())}:${fmt2(d.getMinutes())}`;

/* ── STATE ── */
const apiKey = ''; // ancien accès externe supprimé
let currentPredicted    = null;
let pending             = null;
let verificationStarted = false;
let scheduledStart      = null;
let autoFetchInterval   = null;
let lastVerifiedCoef    = null;
let ignoreFirstCrash    = false;
let lastCrashAt         = null;
let waitingGameEnd      = false;
let postStartCrashSeen  = false;
let marketLevel         = null;   // 'safe'|'warn'|'danger'
let lastFetchedCoef     = null;
let lastFetchTime       = null;
let lastGeneratedCoef   = null;   // <-- NOUVEAU: Mémorise la dernière prédiction

let counts  = loadCounts();
let history = loadHistory();
let range   = loadRange();

/* ── DOM ── */
const multEl       = document.getElementById('multiplier');
const circle       = document.getElementById('circle');
const spin         = document.getElementById('spin');
const btn          = document.getElementById('generateButton');
const roundEl      = document.getElementById('roundStatus');
const betTimeEl    = document.getElementById('betTime');
const confCell     = document.getElementById('confCell');
const countOkEl    = document.getElementById('countOk');
const countKoEl    = document.getElementById('countKo');
const countTotalEl = document.getElementById('countTotal');
const autoBtn      = document.getElementById('autoButton');
const mbDot        = document.getElementById('mbDot');
const mbText       = document.getElementById('mbText');

/* ── STORAGE HELPERS ── */
function loadCounts()  { try{ const p=JSON.parse(localStorage.getItem(COUNTS_KEY)||'{}'); return{ok:p.ok||0,ko:p.ko||0}; }catch(e){ return{ok:0,ko:0}; } }
function saveCounts()  { localStorage.setItem(COUNTS_KEY,JSON.stringify(counts)); }
function loadHistory() { try{ return JSON.parse(localStorage.getItem(HISTORY_KEY)||'[]'); }catch(e){ return []; } }
function saveHistory() { localStorage.setItem(HISTORY_KEY,JSON.stringify(history)); }
function pushHistory(e){ history.unshift(e); if(history.length>200) history.length=200; saveHistory(); }
function loadRange()   { try{ const p=JSON.parse(localStorage.getItem(RANGE_KEY)||'{}'); return{min:Number(p.min||2.00),max:Number(p.max||5.00)}; }catch(e){ return{min:2.00,max:5.00}; } }
function saveRange()   { localStorage.setItem(RANGE_KEY,JSON.stringify(range)); }

function refreshCountsUI(){ countOkEl.textContent=counts.ok; countKoEl.textContent=counts.ko; countTotalEl.textContent=counts.ok+counts.ko; }
function setStatus(msg,kind){ const el=document.getElementById('verifyStatus'); el.className='status '+(kind||''); el.textContent=msg||''; }

/* ── API KEY ── */

function headers(){ return {'X-API-Key': apiKey, 'Content-Type':'application/json'}; }
function noKey()  { return !apiKey || apiKey === 'VOTRE_CLE_API'; }

/* ── MARKET BADGE ── */
async function pollMarket(){
  if(noKey()) return;
  try{
    const r = await fetch(`${BASE}/luckyjet/market`, {headers: headers()});
    if(!r.ok) return;
    const d = await r.json();
    marketLevel = d.level || 'warn';
    mbDot.className = 'mb-dot ' + marketLevel;
    const labels = {safe:'Marché favorable', warn:'Marché modéré', danger:'Marché dangereux'};
    mbText.textContent = labels[marketLevel] || d.reason || 'Marché inconnu';
  }catch(e){}
}

/* ── API : /check ── */
async function checkMarket(){
  if(noKey()) return true; // on laisse passer si pas de clé
  try{
    const r = await fetch(`${BASE}/luckyjet/check`, {headers: headers()});
    if(!r.ok) return true;
    const d = await r.json();
    if(d.blocked){
      setStatus('⛔ ' + (d.message || 'Prédictions bloquées momentanément'),'ko');
      return false;
    }
    return true;
  }catch(e){ return true; }
}

/* ── API : /predict ── */
async function fetchPredict(){
  if(noKey()){ setStatus('Clé API manquante','ko'); return null; }
  try{
    const r = await fetch(`${BASE}/luckyjet/predict`, {headers: headers()});
    if(r.status===401){ setStatus('Clé API invalide (401)','ko'); return null; }
    if(r.status===429){ setStatus('Quota API épuisé (429)','ko'); return null; }
    if(!r.ok){ setStatus('Erreur API '+r.status,'ko'); return null; }
    const d = await r.json();
    if(!d.success) return null;
    return d; // {predicted_coef, confidence, signal, bet_time, market_score, …}
  }catch(e){ return null; }
}

/* ── API : /coefficients (pour vérification) ── */
async function fetchLatestCoef(){
  if(noKey()) return null;
  try{
    const r = await fetch(`${BASE}/luckyjet/coefficients?limit=1`, {headers: headers()});
    if(!r.ok) return null;
    const d = await r.json();
    return d.data?.[0]?.coef ?? null;
  }catch(e){ return null; }
}

/* ── AUTO FETCH (vérification résultat) ── */
function startAutoFetch(){
  if(autoFetchInterval) return;
  autoFetchInterval = setInterval(fetchAndVerify, 5000);
  fetchAndVerify();
}

function tryStartVerification(){
  if(verificationStarted||currentPredicted==null||scheduledStart==null) return;
  if(lastCrashAt===null||lastCrashAt<scheduledStart){ waitingGameEnd=true; setStatus('Attendre la fin du jeu en cours',''); return; }
  if(!postStartCrashSeen){ postStartCrashSeen=true; waitingGameEnd=true; setStatus('Miser au prochain départ',''); return; }
  waitingGameEnd=false;
  setStatus('Miser maintenant','');
  verificationStarted=true; ignoreFirstCrash=true;
  pending={predictedOdds:currentPredicted,currentRound:0};
  roundEl.textContent='0'; multEl.style.color='#00ff66'; multEl.textContent=currentPredicted.toFixed(2)+'X';
  circle.classList.add('verifying'); spin.classList.remove('ok','ko');
}

async function fetchAndVerify(){
  if(!verificationStarted&&scheduledStart&&Date.now()>=scheduledStart&&currentPredicted!=null) tryStartVerification();
  const coef = await fetchLatestCoef();
  if(coef===null) return;
  const now = Date.now();
  const rounded = parseFloat(Number(coef===1.00?1.01:coef).toFixed(2));
  if(rounded===lastFetchedCoef && lastFetchTime && (now-lastFetchTime)<5000) return;
  lastFetchedCoef=rounded; lastFetchTime=now; lastCrashAt=now;

  if(!verificationStarted&&scheduledStart&&Date.now()>=scheduledStart) tryStartVerification();
  if(!pending) return;
  if(rounded===lastVerifiedCoef) return;
  lastVerifiedCoef=rounded;
  if(ignoreFirstCrash){ ignoreFirstCrash=false; return; }

  pending.currentRound+=1;
  roundEl.textContent=pending.currentRound;

  if(rounded>=pending.predictedOdds){
    setStatus(`✅ Validé au round ${pending.currentRound}`,'ok');
    multEl.textContent='Validée ✅'; multEl.style.color='#10b981';
    circle.classList.remove('verifying','ko'); circle.classList.add('ok');
    spin.classList.remove('ko'); spin.classList.add('ok');
    counts.ok+=1; saveCounts(); refreshCountsUI();
    pushHistory({coef:pending.predictedOdds,status:'ok',time:new Date().toISOString(),round:pending.currentRound});
    renderHistory();
    resetCycle();
    if(autoMode){ clearTimeout(autoTimer); autoTimer=setTimeout(lancerAuto,3000); }
    return;
  }
  if(pending.currentRound>=3){
    setStatus('❌ Échoué après 3 rounds','ko');
    multEl.textContent='Échouée ❌'; multEl.style.color='#ef4444';
    circle.classList.remove('verifying','ok'); circle.classList.add('ko');
    spin.classList.remove('ok'); spin.classList.add('ko');
    counts.ko+=1; saveCounts(); refreshCountsUI();
    pushHistory({coef:pending.predictedOdds,status:'ko',time:new Date().toISOString(),round:3});
    renderHistory();
    resetCycle();
    if(autoMode){ clearTimeout(autoTimer); autoTimer=setTimeout(lancerAuto,3000); }
  }
}

function resetCycle(){
  pending=null; verificationStarted=false; scheduledStart=null;
  btn.disabled=false; postStartCrashSeen=false; waitingGameEnd=false;
}

/* ── BOUTON PRINCIPAL ── */
btn.addEventListener('click', async () => {
  if(pending||verificationStarted) return;
  if(noKey()){ setStatus('Entrez votre clé API en haut','ko'); return; }

  btn.disabled=true;
  multEl.textContent='Analyse..'; multEl.style.color='#f4a51c';
  circle.classList.remove('ok','ko'); circle.classList.add('verifying');
  spin.classList.remove('ok','ko');
  setStatus('Vérification du marché...','');

  // 1. check
  const safe = await checkMarket();
  if(!safe){ btn.disabled=false; circle.classList.remove('verifying'); return; }

  // 2. market guard
  if(marketLevel==='danger'){
    setStatus('⛔ Marché dangereux — signal annulé','ko');
    btn.disabled=false; circle.classList.remove('verifying'); return;
  }

  // 3. predict
  const pred = await fetchPredict();
  if(!pred){
    btn.disabled=false; circle.classList.remove('verifying'); return;
  }

  // Clip coef dans la plage réglage utilisateur
  const min=Math.max(1.00,Number(range.min));
  const max=Math.max(min+0.01,Number(range.max));
  let coef = Number(pred.predicted_coef);
  coef = Math.min(Math.max(coef,min),max);
  currentPredicted = parseFloat(coef.toFixed(2));

  // --- NOUVELLE LOGIQUE ANTI-RÉPÉTITION ---
  if (currentPredicted === lastGeneratedCoef) {
    currentPredicted += 0.01; // Décale légèrement pour éviter le doublon parfait
    if (currentPredicted > max) {
      currentPredicted -= 0.02; // Si l'ajout dépasse le max autorisé, on soustrait à la place
    }
    currentPredicted = parseFloat(currentPredicted.toFixed(2));
  }
  lastGeneratedCoef = currentPredicted; 
  // ----------------------------------------

  multEl.textContent = currentPredicted.toFixed(2)+'X';
  multEl.style.color = '#00ff66';
  confCell.textContent = (pred.confidence!=null?pred.confidence+'%':'—');

  // Heure de mise : utiliser bet_time de l'API
  if(pred.bet_time){
    betTimeEl.textContent = pred.bet_time;
    // Calculer scheduledStart depuis bet_time HH:MM
    const [hh,mm] = pred.bet_time.split(':').map(Number);
    const target = new Date(); target.setHours(hh,mm,0,0);
    if(target.getTime()<Date.now()) target.setDate(target.getDate()+1);
    scheduledStart = target.getTime();
  } else {
    const offsetMin = Math.floor(Math.random()*4)+1;
    const target = new Date(Date.now()+offsetMin*60*1000); target.setSeconds(0,0);
    scheduledStart = target.getTime();
    betTimeEl.textContent = hhmm(target);
  }

  roundEl.textContent='0';
  setStatus(`Signal ${pred.signal?.toUpperCase()||'SAFE'} — Heure: ${betTimeEl.textContent}`,'');
  waitingGameEnd=false; postStartCrashSeen=false;
  startAutoFetch();
});

/* ── AUTO ── */
let autoMode=false, autoTimer=null;
autoBtn.addEventListener('click',()=>{
  if(noKey()){ setStatus('Entrez votre clé API en haut','ko'); return; }
  autoMode=!autoMode; autoBtn.textContent=autoMode?'AUTO: ON':'AUTOMATIQUE';
  if(autoMode) lancerAuto(); else clearTimeout(autoTimer);
});
function isCycleActive(){ return verificationStarted||!!pending||scheduledStart!==null; }
function lancerAuto(){
  if(!autoMode) return;
  if(isCycleActive()){
    const wait=scheduledStart&&Date.now()<scheduledStart?Math.max(1000,scheduledStart-Date.now()+500):5000;
    clearTimeout(autoTimer); autoTimer=setTimeout(lancerAuto,wait); return;
  }
  multEl.textContent='Analyse..'; multEl.style.color='#f4a51c';
  circle.classList.remove('ok','ko'); circle.classList.add('verifying'); spin.classList.remove('ok','ko');
  setStatus('Analyse en cours...','');
  setTimeout(()=>{ if(!autoMode) return; btn.click(); },2000);
}

/* ── HISTORIQUE ── */
function renderHistory(){
  const c=document.getElementById('chipsContainer'); c.innerHTML='';
  if(!history.length){ const em=document.createElement('div'); em.textContent='Aucune prédiction.'; em.style.opacity=.85; c.appendChild(em); return; }
  history.forEach(it=>{ const chip=document.createElement('div'); chip.className='chip '+(it.status==='ok'?'ok':'ko'); chip.innerHTML=`${Number(it.coef).toFixed(2)}x<small style="display:block;font-size:10px;opacity:.85;">${it.status==='ok'?'Validée':'Échouée'} • ${hhmm(new Date(it.time))}</small>`; c.appendChild(chip); });
}

/* ── PANNEAUX ── */
function toggle(el,open){ el.classList.toggle('open',open); }
document.getElementById('openHistory').addEventListener('click',()=>{ renderHistory(); toggle(document.getElementById('historyPanel'),true); });
document.getElementById('closeHistory').addEventListener('click',()=>toggle(document.getElementById('historyPanel'),false));
document.getElementById('openSettings').addEventListener('click',()=>{
  document.getElementById('minOddsInput').value=Number(range.min).toFixed(2);
  document.getElementById('maxOddsInput').value=Number(range.max).toFixed(2);
  document.getElementById('settingsMsg').textContent='';
  toggle(document.getElementById('settingsPanel'),true);
});
document.getElementById('closeSettings').addEventListener('click',()=>toggle(document.getElementById('settingsPanel'),false));
document.getElementById('saveRange').addEventListener('click',()=>{
  const min=Number(document.getElementById('minOddsInput').value);
  const max=Number(document.getElementById('maxOddsInput').value);
  if(isNaN(min)||isNaN(max)){ document.getElementById('settingsMsg').textContent='Valeurs invalides.'; return; }
  if(max<=min){ document.getElementById('settingsMsg').textContent='Max doit être > Min.'; return; }
  range={min:Math.max(1,min),max}; saveRange();
  document.getElementById('settingsMsg').textContent=`Plage: ${range.min.toFixed(2)}x – ${range.max.toFixed(2)}x`;
});
document.getElementById('resetStats').addEventListener('click',()=>{ counts={ok:0,ko:0}; saveCounts(); refreshCountsUI(); document.getElementById('settingsMsg').textContent='Stats réinitialisées.'; });
document.getElementById('resetHistory').addEventListener('click',()=>{ history=[]; saveHistory(); renderHistory(); document.getElementById('settingsMsg').textContent='Historique réinitialisé.'; });

/* ── BOOT ── */
refreshCountsUI();
btn.disabled=false;
pollMarket();
setInterval(pollMarket, 30000);
