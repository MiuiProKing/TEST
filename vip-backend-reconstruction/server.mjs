import http from 'node:http';
import {timingSafeEqual} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {calculateVip} from './vip-model.mjs';
import {createBasicAnalyzer} from './basic-analysis.mjs';
import {normalizeRounds} from './normalize.mjs';
import {resolveWindow} from './vendor/vip-state-machine-original.mjs';
import {createSupabaseFeed} from './supabase-feed.mjs';

const MAX_BODY=256*1024;
class RequestError extends Error {
  constructor(status,message) {super(message);this.status=status;}
}
function positiveInteger(value,fallback,max=10000) {
  if (value===undefined || value==='') return fallback;
  const parsed=Number(value);
  if (!Number.isInteger(parsed) || parsed<1 || parsed>max) throw new Error('Invalid numeric configuration');
  return parsed;
}
async function bodyJson(req) {
  const parts=await new Promise((resolve,reject)=>{
    let size=0,failed=false;
    const chunks=[];
    req.on('data',part=>{
      if (failed) return;
      size+=part.length;
      if (size>MAX_BODY) {failed=true;reject(new RequestError(413,'Request body too large'));return;}
      chunks.push(part);
    });
    req.once('end',()=>{if(!failed) resolve(chunks);});
    req.once('error',error=>{if(!failed) reject(error);});
    req.once('aborted',()=>{if(!failed) reject(new RequestError(400,'Request aborted'));});
  });
  try {
    const value=JSON.parse(Buffer.concat(parts).toString('utf8'));
    if (!value || Array.isArray(value) || typeof value!=='object') throw new Error();
    return value;
  } catch {throw new RequestError(400,'Expected a JSON object');}
}
function equalToken(first,second) {
  const a=Buffer.from(first),b=Buffer.from(second);
  return a.length===b.length && timingSafeEqual(a,b);
}
function validateGame(game,configuredGame) {
  if (game!==configuredGame) throw new RequestError(400,'Game is not configured for this data source');
}

export function createApp({feed,game='luckyjet',token='',allowedOrigins=[],clock=Date.now,demo=false}={}) {
  if (!feed || typeof feed.load!=='function') throw new TypeError('A read-only feed is required');
  const origins=new Set(allowedOrigins);
  const basic=createBasicAnalyzer();
  return async function app(req,res) {
    const headers={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'};
    const reply=(status,value)=>{if (!res.headersSent) res.writeHead(status,headers);res.end(JSON.stringify(value));};
    try {
      const origin=req.headers.origin;
      if (origin) {
        if (!origins.has(origin)) throw new RequestError(403,'Origin is not allowed');
        headers['Access-Control-Allow-Origin']=origin;headers.Vary='Origin';
        headers['Access-Control-Allow-Methods']='GET, POST, OPTIONS';
        headers['Access-Control-Allow-Headers']='Authorization, Content-Type';
      }
      if (req.method==='OPTIONS') {res.writeHead(204,headers);res.end();return;}
      const url=new globalThis.URL(req.url,'http://localhost');
      if (url.pathname==='/health' && req.method==='GET') {
        reply(200,{ok:true,reconstruction:true,originalServerModel:false,demo,game});return;
      }
      if (token && !equalToken(req.headers.authorization ?? '',`Bearer ${token}`)) throw new RequestError(401,'Authentication required');
      if (url.pathname==='/api/vip' && req.method==='GET') {
        const selected=url.searchParams.get('game') ?? game;validateGame(selected,game);
        const now=clock(),snapshot=await feed.load({now});
        reply(200,{...calculateVip(snapshot.rounds,{now}),game,source:demo?'synthetic_demo':'configured_supabase',
          sourceCount:snapshot.sourceCount,snapshotLoadedAt:snapshot.loadedAt});return;
      }
      if (url.pathname==='/api/analysis' && ['POST','GET'].includes(req.method)) {
        const now=clock();
        const body=req.method==='POST'?await bodyJson(req):{};
        const selected=body.game ?? url.searchParams.get('game') ?? game;validateGame(selected,game);
        let rounds;
        if (req.method==='POST') {
          if (!Array.isArray(body.rounds) || body.rounds.length>200) throw new RequestError(400,'rounds must contain at most 200 records');
          rounds=body.rounds;
        } else rounds=(await feed.load({now})).rounds;
        const source=req.method==='POST'?'provided_history':demo?'synthetic_demo':'configured_supabase';
        const result=basic.analyze(rounds,{now,game,source});
        reply(result.ready?200:422,{...result,game,source});return;
      }
      if (url.pathname==='/api/validate-window' && req.method==='POST') {
        const body=await bodyJson(req),now=clock();
        if (![body.target,body.start,body.end].every(Number.isFinite) || body.target<1 || body.start<=0 || body.end<=body.start || body.end-body.start>600000) throw new RequestError(400,'Invalid target or window');
        if (!Array.isArray(body.rounds) || body.rounds.length>10000) throw new RequestError(400,'Invalid history');
        const pace=body.avgRoundSeconds ?? 30;
        if (!Number.isFinite(pace) || pace<=0 || pace>300) throw new RequestError(400,'Invalid round pace');
        const rounds=normalizeRounds(body.rounds,{now,limit:10000});
        const result=resolveWindow({target:body.target,start:body.start,end:body.end},rounds,now,pace);
        reply(200,{reconstruction:true,validation:'original_public_vip_client',status:result?.status ?? (now<=body.end?'pending':'unknown'),result});return;
      }
      throw new RequestError(404,'Route not found');
    } catch(error) {
      if (error instanceof RequestError) reply(error.status,{error:error.message,reconstruction:true});
      else reply(502,{error:'Data source or calculation is unavailable',reconstruction:true});
    }
  };
}

export function createDemoFeed() {
  return {async load({now=Date.now()}={}) {
    const rounds=Array.from({length:2000},(_,i)=>({id:`demo-${i}`,
      coefficient:i%157===0?550:i%73===0?210:i%31===0?45:[1.05,1.4,2.2,3.1,1.01,6.4][i%6],
      timestamp:now-1000-(1999-i)*15000}));
    return {rounds,sourceCount:rounds.length,snapshotSeq:'demo',loadedAt:now};
  }};
}

export async function startFromEnvironment(env=process.env) {
  const demo=process.argv.includes('--demo') || env.DEMO_MODE==='true';
  const host=env.HOST || '127.0.0.1',port=positiveInteger(env.PORT,8787,65535);
  const token=env.API_TOKEN || '';
  if (!['127.0.0.1','localhost','::1'].includes(host) && !token) throw new Error('API_TOKEN is required for a public listener');
  const feed=demo?createDemoFeed():createSupabaseFeed({url:env.SUPABASE_URL,publishableKey:env.SUPABASE_PUBLISHABLE_KEY,
    table:env.SUPABASE_TABLE || 'luckyjet_rounds',timeColumn:env.SUPABASE_TIME_COLUMN || 'round_timestamp',
    sequenceColumn:env.SUPABASE_SEQUENCE_COLUMN || 'source_seq',
    historyLimit:positiveInteger(env.HISTORY_LIMIT,2000),cacheMs:positiveInteger(env.CACHE_MS,15000,300000)});
  const app=createApp({feed,game:env.GAME || 'luckyjet',token,demo,
    allowedOrigins:(env.ALLOWED_ORIGINS || '').split(',').map(x=>x.trim()).filter(Boolean)});
  const server=http.createServer(app);
  server.requestTimeout=30000;server.headersTimeout=15000;
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,host,resolve);});
  process.stdout.write(`VIP reconstruction listening on http://${host}:${port} (${demo?'SYNTHETIC DEMO':'configured Supabase'})\n`);
  const close=()=>server.close(()=>process.exit(0));
  process.once('SIGINT',close);process.once('SIGTERM',close);
  return server;
}
if (process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  startFromEnvironment().catch(()=>{process.stderr.write('Startup failed: check the environment configuration.\n');process.exitCode=1;});
}
