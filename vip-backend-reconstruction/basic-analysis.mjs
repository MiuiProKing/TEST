import {forecastBasic} from './vendor/basic-original.mjs';
import {normalizeRounds} from './normalize.mjs';

// A rule-based replacement for the AI response shape. No AI model is invoked.
function evaluate(input, {now=Date.now(),previousForecast=null}={}) {
  const rounds=normalizeRounds(input,{now,limit:200});
  const cutoff=rounds.at(-1)?.timestamp ?? null;
  const metadata={reconstruction:true,originalServerModel:false,aiModelUsed:false,
    method:'public_basic_rules',confidenceType:'heuristic_rule_score',calibrated:false,
    analyzed:rounds.length,dataCutoff:cutoff};
  const unavailable=reason=>({response:{...metadata,ready:false,reason},forecast:null});
  if (rounds.length<20) return unavailable('insufficient_history');
  if (now-cutoff>180000) return unavailable('stale_history');
  let start=0;
  for (let i=1;i<rounds.length;i++) {
    const delta=rounds[i].timestamp-rounds[i-1].timestamp;
    if (delta<=0 || delta>300000) start=i;
  }
  const continuous=rounds.slice(start);
  if (continuous.length<20) return unavailable('collection_gap');
  const result=forecastBasic(continuous,previousForecast,now);
  if (!result || !Number.isFinite(result.estimatedCoef)) return unavailable('no_forecast');
  const value=result.estimatedCoef;
  const response={...metadata,ready:true,analyzed:continuous.length,estimatedCoef:value,
    category:value>=100?'mega':value>=10?'high':value>=2?'mid':'low',
    confidence:result.reliability,rationale:`${result.pattern}. ${result.basis}`,
    estimatedAt:result.estimatedAt,windowMs:result.windowMs,generatedAt:result.generatedAt,
    auxiliaryHint:result.bigOpportunity ? {
      estimatedCoef:result.bigOpportunity.estimatedCoef,
      expectedAt:result.bigOpportunity.expectedAt,windowMs:result.bigOpportunity.windowMs,
      heuristicScore:result.bigOpportunity.confidence,scoreIsProbability:false,
    } : null};
  return {response,forecast:result};
}

export function analyzeBasic(input, options={}) {
  return evaluate(input,options).response;
}

// Hold the original BASIC window until expiry, isolated by game and data source.
export function createBasicAnalyzer() {
  const active=new Map();
  return {
    analyze(input,{now=Date.now(),game='luckyjet',source='configured_supabase'}={}) {
      const key=`${source}:${game}`,previous=active.get(key);
      const latest=normalizeRounds(input,{now,limit:200}).at(-1)?.timestamp;
      const reusable=previous && latest>=previous.cutoff && latest-previous.cutoff<=300000;
      const result=evaluate(input,{now,previousForecast:reusable?previous.forecast:null});
      if (result.forecast) active.set(key,{forecast:result.forecast,cutoff:latest});
      else active.delete(key);
      return result.response;
    },
    clear() {active.clear();},
  };
}
