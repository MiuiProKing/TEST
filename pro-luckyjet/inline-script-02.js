
(function(){
'use strict';

const COUNTS_KEY='kk_pred_counts_v1';
const HISTORY_KEY='kk_pred_history_v1';
const RANGE_KEY='kk_pred_range_v1';
const LIVE_KEY='kk_luckyjet_live_v1';
const LAST_ROUND_KEY='kk_luckyjet_last_round_v1';
const GATEWAY_URL='https://crash-gateway-grm-cr.100hp.app/state';
const GATEWAY_HEADERS={
  'customer-id':'077dee8d-c923-4c02-9bee-757573662e69',
  'session-id':'ba47ba53-8ac6-4ed5-9bda-3d7d033acffc',
  'accept':'application/json'
};
const FETCH_TIMEOUT_MS=8000;
const POLL_MS=5000;

const multEl=document.getElementById('multiplier');
const circle=document.getElementById('circle');
const spin=document.getElementById('spin');
const btn=document.getElementById('generateButton');
const roundEl=document.getElementById('roundStatus');
const betTimeEl=document.getElementById('betTime');
const confCell=document.getElementById('confCell');
const countOkEl=document.getElementById('countOk');
const countKoEl=document.getElementById('countKo');
const countTotalEl=document.getElementById('countTotal');
const autoBtn=document.getElementById('autoButton');
const mbDot=document.getElementById('mbDot');
const mbText=document.getElementById('mbText');

let counts=readJson(COUNTS_KEY,{ok:0,ko:0});
let history=readJson(HISTORY_KEY,[]);
let range=readJson(RANGE_KEY,{min:2,max:5});
const savedLiveCoefs=readJson(LIVE_KEY,[]);
let liveCoefs=(Array.isArray(savedLiveCoefs)?savedLiveCoefs:[]).map(Number).filter(Number.isFinite).slice(-200);
let lastRoundKey=localStorage.getItem(LAST_ROUND_KEY)||'';
let currentPredicted=null;
let pending=null;
let polling=false;
let pollTimer=null;
let autoMode=false;
let autoTimer=null;
let marketLevel='warn';

function readJson(key,fallback){
  try{const value=JSON.parse(localStorage.getItem(key)||'null');return value==null?fallback:value;}
  catch(e){return fallback;}
}
function saveCounts(){localStorage.setItem(COUNTS_KEY,JSON.stringify(counts));}
function saveHistory(){localStorage.setItem(HISTORY_KEY,JSON.stringify(history));}
function saveRange(){localStorage.setItem(RANGE_KEY,JSON.stringify(range));}
function saveLive(){localStorage.setItem(LIVE_KEY,JSON.stringify(liveCoefs.slice(-200)));}
function pushHistory(item){history.unshift(item);if(history.length>200)history.length=200;saveHistory();}
function fmt2(n){return n<10?'0'+n:String(n);}
function hhmm(d){return fmt2(d.getHours())+':'+fmt2(d.getMinutes());}
function clamp(v,a,b){return Math.max(a,Math.min(b,v));}
function avg(a){return a.length?a.reduce(function(s,v){return s+v;},0)/a.length:0;}
function setStatus(msg,kind){
  const el=document.getElementById('verifyStatus');
  el.className='status '+(kind||'');
  el.textContent=msg||'';
}
function refreshCountsUI(){
  countOkEl.textContent=counts.ok||0;
  countKoEl.textContent=counts.ko||0;
  countTotalEl.textContent=(counts.ok||0)+(counts.ko||0);
}

function normalizeCoef(value){
  if(value==null||value==='')return null;
  const n=Number(typeof value==='string'?value.toLowerCase().replace('x','').trim():value);
  if(!Number.isFinite(n)||n<1)return null;
  return Number((n===1?1.01:n).toFixed(2));
}
function parseRoundPayload(data){
  const cfg=data&&typeof data.roundConfig==='object'?data.roundConfig:{};
  const value=Array.isArray(data&&data.stopCoefficients)?data.stopCoefficients[0]:null;
  const coef=normalizeCoef(value);
  if(coef==null)return null;
  const id=cfg.id||data.roundId||data.id||data.currentRoundId||'';
  const time=data.stateChangedAt||data.currentTime||data.updatedAt||'';
  const key=id?'id:'+String(id):(time?'time:'+String(time)+':'+coef.toFixed(2):'coef:'+coef.toFixed(2));
  return {coef:coef,key:key,id:String(id||''),time:String(time||'')};
}
function consecutiveLosses(){
  let n=0;
  for(let i=0;i<history.length;i++){if(history[i].status!=='ko')break;n++;}
  return n;
}
function analyzeLocal(){
  if(liveCoefs.length<3){
    return {score:50,level:'warn',risk:'medium',why:'нужно больше данных',conf:50,losses:consecutiveLosses()};
  }
  const recent=liveCoefs.slice(-8);
  const lowCount=recent.filter(function(x){return x<1.5;}).length;
  const veryLow=recent.filter(function(x){return x<1.2;}).length;
  const losses=consecutiveLosses();
  const trendUp=avg(recent.slice(-4))>avg(recent.slice(0,4));
  const raw=100-(lowCount/recent.length)*42-veryLow*8-losses*22+(trendUp?6:-6);
  const score=Math.round(clamp(raw,0,100));
  let risk='high',level='danger';
  if(score>=70&&losses===0){risk='low';level='safe';}
  else if(score>=45&&losses<2){risk='medium';level='warn';}
  let why='тренд слабый или рынок шумный';
  if(losses>=2)why=losses+' неудачи подряд';
  else if(lowCount>=4)why='много низких коэффициентов';
  else if(trendUp)why='тренд растёт';
  return {score:score,level:level,risk:risk,why:why,conf:Math.round(clamp(score-(risk==='high'?10:0),35,92)),losses:losses};
}
function smartTargetLocal(min,max){
  let src=liveCoefs.slice(-8);
  if(src.length<5)src=liveCoefs.slice(-5);
  if(!src.length)return Number(min.toFixed(2));
  const lowRatio=src.filter(function(x){return x<1.5;}).length/src.length;
  const info=analyzeLocal();
  return Number(clamp(avg(src)*0.72+info.score/100*0.55-lowRatio*0.35,min,max).toFixed(2));
}
function signalCheck(){
  const info=analyzeLocal();
  if(liveCoefs.length<5)return {allowed:false,message:'Нужно 5 коэффициентов, получено '+liveCoefs.length+'/5',info:info};
  const good=liveCoefs.slice(-5).filter(function(x){return x>1.5;}).length;
  if(info.level==='danger')return {allowed:false,message:'Слабый рынок: '+info.why,info:info};
  if(good<3)return {allowed:false,message:'Выше 1.50 только '+good+'/5',info:info};
  return {allowed:true,message:'Условия выполнены: '+good+'/5 выше 1.50',info:info};
}

async function localApi(path){
  if(path.indexOf('/luckyjet/coefficients')===0){
    return {success:true,data:liveCoefs.slice().reverse().map(function(coef,index){return {coef:coef,index:index};})};
  }
  const check=signalCheck();
  if(path==='/luckyjet/market'){
    return {success:true,level:check.info.level,score:check.info.score,reason:check.info.why,count:liveCoefs.length};
  }
  if(path==='/luckyjet/check'){
    return {success:true,blocked:!check.allowed,message:check.message,market_score:check.info.score};
  }
  if(path==='/luckyjet/predict'){
    if(!check.allowed)return {success:false,message:check.message};
    const min=Math.max(1,Number(range.min)||2);
    const max=Math.max(min+0.01,Number(range.max)||5);
    return {success:true,predicted_coef:smartTargetLocal(min,max),confidence:check.info.conf,signal:check.info.level,bet_time:null,market_score:check.info.score,reason:check.message};
  }
  throw new Error('Неизвестный локальный маршрут: '+path);
}
window.LuckyJetLocalAPI=localApi;

function updateMarketBadge(online){
  const info=analyzeLocal();
  marketLevel=info.level;
  mbDot.className='mb-dot '+(online?marketLevel:'danger');
  if(!online){mbText.textContent='Источник недоступен — переподключение';return;}
  const labels={safe:'LIVE • рынок благоприятный',warn:'LIVE • рынок умеренный',danger:'LIVE • высокий риск'};
  mbText.textContent=(labels[marketLevel]||'LIVE')+' • '+liveCoefs.length+' кэф.';
}
async function fetchGatewayRound(){
  const controller=typeof AbortController!=='undefined'?new AbortController():null;
  const timeout=controller?setTimeout(function(){controller.abort();},FETCH_TIMEOUT_MS):null;
  try{
    const response=await fetch(GATEWAY_URL,{headers:GATEWAY_HEADERS,cache:'no-store',signal:controller?controller.signal:undefined});
    if(!response.ok)throw new Error('HTTP '+response.status);
    return parseRoundPayload(await response.json());
  }finally{if(timeout)clearTimeout(timeout);}
}
function acceptRound(round){
  if(!round||round.key===lastRoundKey)return null;
  lastRoundKey=round.key;
  localStorage.setItem(LAST_ROUND_KEY,lastRoundKey);
  liveCoefs.push(round.coef);
  if(liveCoefs.length>200)liveCoefs=liveCoefs.slice(-200);
  saveLive();
  return round.coef;
}
async function pollLive(){
  if(polling)return;
  polling=true;
  try{
    const coef=acceptRound(await fetchGatewayRound());
    updateMarketBadge(true);
    if(coef!=null)handleNewCoefficient(coef);
  }catch(e){
    updateMarketBadge(false);
    console.warn('LuckyJet gateway:',e);
  }finally{polling=false;}
}
async function pollMarket(){
  const data=await localApi('/luckyjet/market');
  marketLevel=data.level;
  updateMarketBadge(true);
  return data;
}
async function checkMarket(){
  const data=await localApi('/luckyjet/check');
  if(data.blocked){setStatus('⛔ '+data.message,'ko');return false;}
  return true;
}
async function fetchPredict(){
  const data=await localApi('/luckyjet/predict');
  if(!data.success){setStatus(data.message||'Сигнал пока недоступен','ko');return null;}
  return data;
}
async function fetchLatestCoef(){
  const data=await localApi('/luckyjet/coefficients?limit=1');
  return data.data&&data.data[0]?data.data[0].coef:null;
}
window.fetchLatestLuckyJetCoef=fetchLatestCoef;

function handleNewCoefficient(coef){
  pollMarket();
  if(!pending)return;
  pending.currentRound++;
  roundEl.textContent=pending.currentRound;
  if(coef>=pending.predictedOdds){
    setStatus('✅ Подтверждено в раунде '+pending.currentRound,'ok');
    multEl.textContent='Успех ✅';
    multEl.style.color='#10b981';
    circle.classList.remove('verifying','ko');
    circle.classList.add('ok');
    spin.classList.remove('ko');
    spin.classList.add('ok');
    counts.ok=(counts.ok||0)+1;
    saveCounts();
    refreshCountsUI();
    pushHistory({coef:pending.predictedOdds,status:'ok',time:new Date().toISOString(),round:pending.currentRound});
    renderHistory();
    finishCycle();
    return;
  }
  if(pending.currentRound>=3){
    setStatus('❌ Не подтверждено за 3 раунда','ko');
    multEl.textContent='Неудача ❌';
    multEl.style.color='#ef4444';
    circle.classList.remove('verifying','ok');
    circle.classList.add('ko');
    spin.classList.remove('ok');
    spin.classList.add('ko');
    counts.ko=(counts.ko||0)+1;
    saveCounts();
    refreshCountsUI();
    pushHistory({coef:pending.predictedOdds,status:'ko',time:new Date().toISOString(),round:3});
    renderHistory();
    finishCycle();
  }
}
function finishCycle(){
  pending=null;
  btn.disabled=false;
  if(autoMode){clearTimeout(autoTimer);autoTimer=setTimeout(runAuto,3000);}
}
function startPolling(){
  if(pollTimer)return;
  pollTimer=setInterval(pollLive,POLL_MS);
  pollLive();
}

btn.addEventListener('click',async function(){
  if(pending)return;
  btn.disabled=true;
  multEl.textContent='Анализ..';
  multEl.style.color='#f4a51c';
  circle.classList.remove('ok','ko');
  circle.classList.add('verifying');
  spin.classList.remove('ok','ko');
  setStatus('Проверка локального рынка...','');
  if(!await checkMarket()){
    btn.disabled=false;
    circle.classList.remove('verifying');
    return;
  }
  const pred=await fetchPredict();
  if(!pred){
    btn.disabled=false;
    circle.classList.remove('verifying');
    return;
  }
  currentPredicted=Number(pred.predicted_coef.toFixed(2));
  multEl.textContent=currentPredicted.toFixed(2)+'X';
  multEl.style.color='#00ff66';
  confCell.textContent=pred.confidence!=null?pred.confidence+'%':'—';
  betTimeEl.textContent='NEXT';
  roundEl.textContent='0';
  pending={predictedOdds:currentPredicted,currentRound:0};
  setStatus('Локальный сигнал '+String(pred.signal||'safe').toUpperCase()+' • проверка следующих 3 раундов','');
});

autoBtn.addEventListener('click',function(){
  autoMode=!autoMode;
  autoBtn.textContent=autoMode?'AUTO: ON':'AUTOMATIQUE';
  if(autoMode)runAuto();
  else clearTimeout(autoTimer);
});
function runAuto(){
  if(!autoMode)return;
  if(pending){clearTimeout(autoTimer);autoTimer=setTimeout(runAuto,5000);return;}
  btn.click();
  clearTimeout(autoTimer);
  autoTimer=setTimeout(runAuto,10000);
}

function renderHistory(){
  const container=document.getElementById('chipsContainer');
  container.innerHTML='';
  if(!history.length){
    const empty=document.createElement('div');
    empty.textContent='Aucune prédiction.';
    empty.style.opacity='.85';
    container.appendChild(empty);
    return;
  }
  history.forEach(function(item){
    const chip=document.createElement('div');
    chip.className='chip '+(item.status==='ok'?'ok':'ko');
    chip.innerHTML=Number(item.coef).toFixed(2)+'x<small style="display:block;font-size:10px;opacity:.85;">'+(item.status==='ok'?'Validée':'Échouée')+' • '+hhmm(new Date(item.time))+'</small>';
    container.appendChild(chip);
  });
}
function toggle(el,open){el.classList.toggle('open',open);}
document.getElementById('openHistory').addEventListener('click',function(){renderHistory();toggle(document.getElementById('historyPanel'),true);});
document.getElementById('closeHistory').addEventListener('click',function(){toggle(document.getElementById('historyPanel'),false);});
document.getElementById('openSettings').addEventListener('click',function(){
  document.getElementById('minOddsInput').value=Number(range.min).toFixed(2);
  document.getElementById('maxOddsInput').value=Number(range.max).toFixed(2);
  document.getElementById('settingsMsg').textContent='';
  toggle(document.getElementById('settingsPanel'),true);
});
document.getElementById('closeSettings').addEventListener('click',function(){toggle(document.getElementById('settingsPanel'),false);});
document.getElementById('saveRange').addEventListener('click',function(){
  const min=Number(document.getElementById('minOddsInput').value);
  const max=Number(document.getElementById('maxOddsInput').value);
  const msg=document.getElementById('settingsMsg');
  if(!Number.isFinite(min)||!Number.isFinite(max)){msg.textContent='Valeurs invalides.';return;}
  if(max<=min){msg.textContent='Max doit être > Min.';return;}
  range={min:Math.max(1,min),max:max};
  saveRange();
  msg.textContent='Plage: '+range.min.toFixed(2)+'x – '+range.max.toFixed(2)+'x';
});
document.getElementById('resetStats').addEventListener('click',function(){
  counts={ok:0,ko:0};saveCounts();refreshCountsUI();
  document.getElementById('settingsMsg').textContent='Stats réinitialisées.';
});
document.getElementById('resetHistory').addEventListener('click',function(){
  history=[];saveHistory();renderHistory();
  document.getElementById('settingsMsg').textContent='Historique réinitialisé.';
});

refreshCountsUI();
btn.disabled=false;
updateMarketBadge(false);
setStatus(liveCoefs.length<5?'Сбор данных: '+liveCoefs.length+'/5':'Источник готов • нажмите SIGNAL','');
startPolling();
})();
