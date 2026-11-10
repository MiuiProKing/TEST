import {SUPABASE_URL, PUBLISHABLE_KEY, TABLE} from './config.mjs?v=20261110-1';
import {createReader} from './data.mjs?v=20261110-1';
import {analyzeRounds} from './model.mjs?v=20261110-1';
import {createArchiveCache} from './cache.mjs?v=20261110-1';

const el = id => document.getElementById(id);
const reader = createReader({url:SUPABASE_URL, publishableKey:PUBLISHABLE_KEY, table:TABLE});
const cache = createArchiveCache({identity:`${SUPABASE_URL}/${TABLE}/confirmed-v1`});
const state = {rounds:[], cursor:null, busy:false, complete:false, archiveAt:0, model:null, cacheSaved:false,lastCacheAt:0};
const clock = new Intl.DateTimeFormat('ru-RU', {
  timeZone:'Europe/Kyiv', year:'numeric', month:'2-digit', day:'2-digit',
  hour:'2-digit', minute:'2-digit', second:'2-digit', hour12:false,
});
const date = t => Number.isFinite(t) ? clock.format(new Date(t)) : '—';
const fmt = (x, digits=1) => Number.isFinite(x) ? x.toLocaleString('ru-RU', {minimumFractionDigits:digits, maximumFractionDigits:digits}) : '—';
const pct = x => Number.isFinite(x) ? `${fmt(x*100,2)}%` : '—';
const interval = a => Array.isArray(a) ? `${pct(a[0])} — ${pct(a[1])}` : '—';
const whole = x => Number(x).toLocaleString('ru-RU');
const pause = () => new Promise(resolve => setTimeout(resolve,0));

function showError(error) {
  el('error').textContent = error ? String(error.message || error) : '';
  el('error').hidden = !error;
}

function updateConnection() {
  const last = state.model?.latest;
  const age = last ? Date.now()-last.t : Infinity;
  el('status').classList.remove('good','warn');
  if (!navigator.onLine) {
    el('status').textContent = 'Нет интернета · сохранённые данные';
    el('status').classList.add('warn');
  } else if (state.busy) {
    el('status').textContent = state.complete ? 'Обновление…' : 'Загрузка архива…';
  } else if (!state.rounds.length) {
    el('status').textContent = 'Нет данных';
  } else if (age > 180000) {
    el('status').textContent = 'Поток не свежий · история доступна';
    el('status').classList.add('warn');
  } else if (!el('error').hidden) {
    el('status').textContent = 'Ошибка обновления · история доступна';
    el('status').classList.add('warn');
  } else {
    el('status').textContent = `● Supabase LIVE · ${whole(state.rounds.length)}`;
    el('status').classList.add('good');
  }
}

function archiveLabel(progress='') {
  if (progress) {
    el('archive-status').textContent = progress;
    return;
  }
  const first = state.model?.rounds?.[0], last = state.model?.latest;
  el('archive-status').textContent = state.rounds.length
    ? `${state.complete?'Полный доступный архив':'Частичная загрузка'} · ${whole(state.rounds.length)} раундов · ${date(first?.t)} → ${date(last?.t)}${state.cacheSaved?' · сохранён в браузере':''}`
    : 'Ожидание подтверждённых данных';
}

function renderTimeBins() {
  if (!state.model) return;
  const unit = el('time-unit').value;
  el('time-unit-heading').textContent = unit==='seconds' ? 'Секунда' : 'Минута';
  el('minutes').replaceChildren();
  const bins = state.model.timeBins[unit];
  for (const bin of bins) {
    const row = document.createElement('tr');
    for (const value of [`:${String(bin.value).padStart(2,'0')}`, `${whole(bin.hits)} / ${whole(bin.total)}`,pct(bin.p)]) {
      const cell = document.createElement('td'); cell.textContent=value; row.append(cell);
    }
    el('minutes').append(row);
  }
  if (!bins.length) {
    const row=document.createElement('tr'),cell=document.createElement('td');
    cell.colSpan=3; cell.textContent='Недостаточно данных'; row.append(cell); el('minutes').append(row);
  }
}

function render() {
  if (!state.rounds.length) { updateConnection(); return; }
  const model = analyzeRounds(state.rounds, {
    threshold:Number(el('threshold').value), horizon:Number(el('horizon').value),
  });
  state.model = model;
  const {baseline,survival,cluster,validation,latest} = model;
  el('count').textContent=whole(model.count);
  el('last').textContent=`${fmt(latest.x,2)}×`;
  el('lasttime').textContent=`Последний: ${date(latest.t)}`;
  el('base').textContent=pct(baseline.probability);
  el('survival').textContent=pct(survival.probability);
  el('survnote').textContent = survival.status==='ready'
    ? `Похожих интервалов: ${whole(survival.atRisk)} · 95% диапазон: ${interval(survival.interval95)}. Историческая оценка, без подтверждённого преимущества.`
    : survival.status==='stale'
      ? 'Свежих раундов нет — текущая оценка приостановлена.'
      : `Недостаточно похожих интервалов: ${whole(survival.atRisk)} (нужно ≥20) либо начало текущего интервала не наблюдалось.`;
  el('median').textContent=`${fmt(survival.medianGap,0)} раундов`;
  el('gapnote').textContent=`Событий: ${whole(baseline.hits)} · после последнего в непрерывном фрагменте: ${fmt(survival.distance,0)} · разрывов: ${Math.max(0,survival.segmentCount-1)}`;
  el('cluster').textContent=`${whole(cluster.hits)} / ${whole(cluster.count)}`;
  el('clusternote').textContent=`События ≥${el('threshold').value}× в последних доступных раундах`;
  el('expected').textContent=pct(validation.expected);
  el('actual').textContent=pct(validation.actual);
  el('tested').textContent=whole(validation.testCount);
  el('brier').textContent=fmt(validation.brier,5);
  el('testnote').textContent='Проверка базовой частоты за 1 раунд. Survival, минуты и секунды этой проверкой не подтверждаются.';
  renderTimeBins();
  el('recent').replaceChildren();
  for (const round of model.rounds.slice(-15).reverse()) {
    const row=document.createElement('tr');
    for (const [i,value] of [date(round.t),`${fmt(round.x,2)}×`,round.seq].entries()) {
      const cell=document.createElement('td'); cell.textContent=value;
      if (i===1 && round.x>=model.threshold) cell.className='good';
      row.append(cell);
    }
    el('recent').append(row);
  }
  el('download').disabled=!state.complete;
  archiveLabel();
  updateConnection();
}

async function saveCache() {
  if (!state.complete) return;
  state.cacheSaved = await cache.write({rounds:state.rounds,cursor:state.cursor,updatedAt:Date.now(),archiveAt:state.archiveAt,complete:true});
  state.lastCacheAt=Date.now();
  archiveLabel();
}

async function loadFullArchive() {
  if (state.busy) return;
  state.busy=true; showError(null); updateConnection();
  el('refresh').disabled=true; el('reload-archive').disabled=true;
  let lastPaint=0;
  try {
    const snapshotSeq=await reader.getHead({});
    const result=await reader.loadArchive({snapshotSeq,onBatch:async (_batch,progress)=>{
      archiveLabel(`Загрузка всей базы: ${whole(progress.count)} подтверждённых раундов · последняя страница ${whole(progress.sourceCount)} строк источника`);
      if (Date.now()-lastPaint>500) { lastPaint=Date.now(); await pause(); }
    }});
    if (!result.rounds.length) throw new Error('В таблице нет доступных подтверждённых раундов.');
    state.rounds=result.rounds; state.cursor=result.cursor; state.complete=true;
    state.archiveAt=Date.now(); state.cacheSaved=false;
    render();
    await saveCache();
  } catch(error) {
    showError(error); archiveLabel();
  } finally {
    state.busy=false; el('refresh').disabled=false; el('reload-archive').disabled=false;
    updateConnection();
  }
}

async function refresh() {
  if (state.busy) return;
  if (!state.complete) return loadFullArchive();
  state.busy=true; showError(null); el('refresh').disabled=true; updateConnection();
  try {
    const update=await reader.pollAfter({cursor:state.cursor});
    const oldCursor=state.cursor;
    if (update.rounds.length) {
      const merged=new Map(state.rounds.map(r=>[r.id,r]));
      for (const round of update.rounds) merged.set(round.id,round);
      state.rounds=Array.from(merged.values());
    }
    state.cursor=update.cursor;
    if (update.rounds.length) render();
    if ((update.rounds.length || state.cursor!==oldCursor) && Date.now()-state.lastCacheAt>60000) await saveCache();
  } catch(error) { showError(error); }
  finally { state.busy=false; el('refresh').disabled=false; updateConnection(); }
}

function downloadArchive() {
  if (!state.complete || !state.model) return;
  const rows=['id,source_seq,coefficient,round_timestamp'];
  const quote=v=>`"${String(v).replaceAll('"','""')}"`;
  for (const r of state.model.rounds) rows.push([quote(r.id),r.seq,String(r.x),quote(new Date(r.t).toISOString())].join(','));
  const blob=new Blob(['\uFEFF'+rows.join('\r\n')],{type:'text/csv;charset=utf-8'});
  const objectUrl=globalThis.URL.createObjectURL(blob),a=document.createElement('a');
  a.href=objectUrl; a.download=`luckyjet-full-history-${new Date().toISOString().slice(0,10)}.csv`;
  document.body.append(a); a.click(); a.remove();
  setTimeout(()=>globalThis.URL.revokeObjectURL(objectUrl),1000);
}

async function start() {
  const saved=await cache.read();
  if (saved?.rounds.length) {
    state.rounds=saved.rounds; state.cursor=saved.cursor; state.complete=true;
    state.archiveAt=saved.archiveAt; state.lastCacheAt=saved.updatedAt; state.cacheSaved=true; render();
  }
  if (!state.complete || Date.now()-state.archiveAt>6*60*60*1000) await loadFullArchive();
  else await refresh();
  setInterval(refresh,10000);
  setInterval(()=>{ if (state.model?.latest && !state.model.latest.stale && Date.now()-state.model.latest.t>180000) render(); else updateConnection(); },10000);
}

el('threshold').addEventListener('change',render);
el('horizon').addEventListener('change',render);
el('time-unit').addEventListener('change',renderTimeBins);
el('refresh').addEventListener('click',refresh);
el('reload-archive').addEventListener('click',loadFullArchive);
el('download').addEventListener('click',downloadArchive);
addEventListener('online',()=>{updateConnection(); refresh();});
addEventListener('offline',updateConnection);
document.addEventListener('visibilitychange',()=>{if(!document.hidden) refresh();});
start().catch(error=>{showError(error);updateConnection();});
