"""Shared LuckyJet transport. Does not start threads or Telegram polling on import."""
import json
import math
import os
import time
import threading
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
import requests

ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / 'sources.json').read_text(encoding='utf-8'))

def source_url(source_id):
    if source_id in CONFIG.get('endpoints',{}):
        return CONFIG['endpoints'][source_id]
    return next(s['url'] for s in CONFIG['sources'] if s['id'] == source_id)

def rows_of(value):
    if isinstance(value, list):
        return [r for r in value if isinstance(r, dict)]
    if isinstance(value, dict):
        for key in ('history', 'rounds', 'items', 'results', 'data', 'coefficients'):
            if key in value:
                rows = rows_of(value[key])
                if rows:
                    return rows
    return []

def normalize_round(row, source='legacy', now=None):
    if not isinstance(row, dict):
        return None
    rid = next((str(row[k]) for k in ('id','round_id','roundId','gameId','game_id','uuid','hash','_id') if row.get(k) is not None and str(row[k])), None)
    if rid is None:
        return None  # A coefficient alone cannot uniquely identify a round.
    coef = None
    for key in ('topCoefficient','top_coefficient','coefficient','coef','multiplier','crash','value'):
        raw = row.get(key)
        if raw is None or isinstance(raw, bool):
            continue
        try:
            coef = float(str(raw).replace(',', '.'))
            break
        except (ValueError, TypeError):
            pass
    if coef is None:
        finals = row.get('finalValues', row.get('final_values', []))
        for raw in reversed(finals if isinstance(finals, list) else []):
            try:
                coef = float(raw)
                break
            except (ValueError, TypeError):
                pass
    if coef is None or not math.isfinite(coef) or coef < 1:
        return None
    ts = None
    for key in ('round_timestamp','timestamp','createdAt','created_at','time','endedAt','ended_at'):
        raw = row.get(key)
        if raw is None:
            continue
        try:
            if isinstance(raw,(float,int)) or str(raw).replace('.','',1).isdigit():
                num = float(raw)
                ts = datetime.fromtimestamp(num/1000 if num > 1e11 else num, timezone.utc)
            else:
                ts = datetime.fromisoformat(str(raw).replace('Z','+00:00'))
                if ts.tzinfo is None:
                    ts = None  # Do not guess a timezone for a naive server clock.
            if ts is not None:
                break
        except (ValueError,TypeError,OverflowError,OSError):
            pass
    uncertain = bool(row.get('estimated')) or ts is None or ts.timestamp() > (now or time.time()) + 120
    return {'id':rid,'coefficient':coef,'timestamp':ts.isoformat() if ts else None,'source':source,'estimated':uncertain,'created_at':datetime.now(timezone.utc).isoformat()}

def migrate_rounds(con):
    """Add metadata, retaining every legacy row and the original primary key."""
    columns = {r[1] for r in con.execute('PRAGMA table_info(rounds)')}
    if not columns:
        return
    for name,kind in [('source',"TEXT NOT NULL DEFAULT 'legacy'"),('created_at','TEXT'),('estimated','INTEGER NOT NULL DEFAULT 0')]:
        if name not in columns:
            con.execute(f'ALTER TABLE rounds ADD COLUMN {name} {kind}')
    # Expose a unified schema without renaming columns used by old predictors.
    aliases = {'id':('round_id','TEXT'),'round_id':('id','TEXT'),
               'coefficient':('coef','REAL'),'timestamp':('api_time' if 'api_time' in columns else 'ts','TEXT')}
    for target,(original,kind) in aliases.items():
        if target not in columns and original in columns:
            con.execute(f'ALTER TABLE rounds ADD COLUMN {target} {kind}')
            con.execute(f'UPDATE rounds SET {target}={original}')
    con.execute('CREATE INDEX IF NOT EXISTS idx_rounds_source_v37 ON rounds(source)')
    con.commit()

class SourceManager:
    def __init__(self, config=None, transport=None, clock=None):
        self.config = config or CONFIG
        self.transport = transport or self._request
        self.clock = clock or time.time
        self.health = {s['id']:dict(status='OFFLINE',last_success=None,last_error=None,latency=0,last_new_round=None,retry_at=0,failures=0,ids=set()) for s in self.config['sources']}
        self.cache = []
        self.cache_path = Path(os.getenv('KIBORG_CACHE_FILE',str(ROOT / 'luckyjet-source-cache.json')))
        try:
            saved = json.loads(self.cache_path.read_text(encoding='utf-8'))
            self.cache = [r for r in saved if isinstance(r,dict) and r.get('id') and isinstance(r.get('coefficient'),(float,int)) and math.isfinite(r['coefficient']) and r['coefficient'] >= 1]
        except (OSError, ValueError, TypeError):
            pass
        self.last_full = {}
        self.active = 'local'
        self.cached = False
        self.lock = threading.RLock()
        self.session = requests.Session()
        self.state_path = Path(os.getenv('KIBORG_SOURCE_STATE', str(ROOT / 'source-selection.json')))
        try:
            self.selection = json.loads(self.state_path.read_text(encoding='utf-8'))['selection']
        except (OSError,ValueError,KeyError):
            self.selection = os.getenv('KIBORG_SOURCE', 'AUTO')

    def select(self, source_id):
        if source_id != 'AUTO' and source_id not in self.health:
            raise ValueError('Unknown source')
        self.selection = source_id
        self.state_path.write_text(json.dumps({'selection':source_id}),encoding='utf-8')
        self.last_full.clear()

    def _request(self, url, headers, timeout):
        start = time.monotonic()
        with self.session.get(url,headers=headers,timeout=(min(5,timeout),timeout),stream=True,allow_redirects=True) as response:
            if response.status_code in (401,403):
                raise PermissionError(f'HTTP {response.status_code}')
            response.raise_for_status()
            data = bytearray()
            for part in response.iter_content(4096):
                data.extend(part)
                if len(data) > 16_000_000 or time.monotonic()-start > 20:
                    raise TimeoutError('Response limit exceeded')
            return json.loads(data)

    def _headers(self, source):
        headers = {'Accept':'application/json','User-Agent':'KIBORG/3.7'}
        if source['type'] == 'session':
            session = next((os.getenv(k,'').strip() for k in ('LUCKYJET_SESSION_ID','V0XFF3_SESSION_ID','LJ_SESSION_ID') if os.getenv(k,'').strip()), '')
            if not session or session == '00000000-0000-0000-0000-000000000000':
                raise PermissionError('SESSION required')
            headers['session-id'] = session
            headers['customer-id'] = os.getenv('LJ_CUSTOMER_ID','077dee8d-c923-4c02-9bee-757573662e69')
        if source['type'] == 'api_key':
            key = os.getenv(source.get('key_env',''),'').strip()
            if not key:
                raise PermissionError('Own API key required')
            if source['id'] == 'parse':
                headers['x-api-key'] = key
            else:
                headers['Authorization'] = 'Bearer '+key
                headers['x-api-key'] = key
        return headers

    def fetch(self, limit=5000, force=False):
        with self.lock:
            candidates = sorted([s for s in self.config['sources'] if s.get('enabled') and s['type'] != 'cache' and (self.selection=='AUTO' or self.selection==s['id'])],key=lambda s:s['priority'])
            for source in candidates:
                h = self.health[source['id']]
                if not force and h['retry_at'] > self.clock():
                    continue
                started = self.clock()
                try:
                    headers = self._headers(source)
                    full = source['id'] not in self.last_full or started-self.last_full[source['id']] >= self.config.get('full_sync_seconds',30)
                    rows, seen, offset = [],set(),0
                    while True:
                        url = source['url']
                        if source['type'] == 'snapshot':
                            parts = urlsplit(url)
                            q = [(k,v) for k,v in parse_qsl(parts.query) if k not in ('limit','offset','t')]
                            q += [('limit','1000'),('offset',str(offset)),('t',str(int(self.clock()*1000)))]
                            url = urlunsplit((parts.scheme,parts.netloc,parts.path,urlencode(q),parts.fragment))
                        obj = self.transport(url,headers,source['timeout'])
                        raw = rows_of(obj)
                        for row in raw:
                            normal = normalize_round(row,source['id'],self.clock())
                            if normal and normal['id'] not in seen:
                                seen.add(normal['id']); rows.append(normal)
                        if not raw or not full or not isinstance(obj,dict) or not obj.get('hasMore'):
                            break
                        next_offset = obj.get('nextOffset')
                        if not isinstance(next_offset,int) or not offset < next_offset < 5000:
                            break
                        offset = next_offset
                    if not rows:
                        raise ValueError('No valid rounds / unknown format')
                    ids = {r['id'] for r in rows}
                    if h['last_success'] is None or ids-h['ids']:
                        h['last_new_round'] = self.clock()
                    h['ids'].update(ids)
                    if len(h['ids']) > 10000:
                        h['ids'] = ids
                    h.update(last_success=self.clock(),latency=self.clock()-started,last_error=None,failures=0,retry_at=0,status='ONLINE')
                    if h['latency'] > 5:
                        h['status']='SLOW'
                    if self.clock()-h['last_new_round'] > self.config.get('stale_seconds',120):
                        h.update(status='SLOW',last_error='No new round >120s',retry_at=self.clock()+30)
                        continue
                    self.cache=rows; self.active=source['id']; self.cached=False
                    try:
                        tmp=self.cache_path.with_suffix('.tmp')
                        tmp.write_text(json.dumps(rows,ensure_ascii=False),encoding='utf-8')
                        tmp.replace(self.cache_path)
                    except OSError:
                        pass # Runtime can still serve its in-memory / SQLite cache.
                    if full:
                        self.last_full[source['id']]=self.clock()
                    return rows  # Never truncate a newly received batch to the old 500-row default.
                except Exception as error:
                    # Keep only error class / fixed descriptions; no request URLs, credentials or response body.
                    h['failures']+=1
                    delays=self.config.get('retry_seconds',[1,2,5,10,30])
                    h.update(status='AUTH_REQUIRED' if isinstance(error,PermissionError) else 'ERROR' if isinstance(error,(ValueError,json.JSONDecodeError)) else 'OFFLINE',last_error=type(error).__name__,latency=self.clock()-started,retry_at=self.clock()+delays[min(h['failures']-1,len(delays)-1)])
            if self.cache:
                self.active='local'; self.cached=True; self.health['local']['status']='ONLINE'
                return self.cache
            raise ConnectionError('No available LuckyJet source; local cache is empty')

_manager = None
def shared_manager():
    global _manager
    if _manager is None:
        _manager = SourceManager()
    return _manager
