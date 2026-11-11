// Adapter for OUR plain JSON API. It does not impersonate the site's serverFn transport.
export function createClient({baseUrl,token='',fetchImpl=globalThis.fetch}={}) {
  const base=new URL(baseUrl);
  if (!base.pathname.endsWith('/')) base.pathname+='/';
  base.search='';base.hash='';
  async function request(path,{data,signal}={}) {
    const headers={Accept:'application/json'};
    if (token) headers.Authorization=`Bearer ${token}`;
    if (data) headers['Content-Type']='application/json';
    const response=await fetchImpl(new URL(path.replace(/^\//,''),base),{
      method:data?'POST':'GET',headers,body:data?JSON.stringify(data):undefined,signal});
    const result=await response.json();
    if (!response.ok) throw new Error(result.error || result.reason || `HTTP ${response.status}`);
    return result;
  }
  return {
    getVip:(game='luckyjet',options={})=>request(`/api/vip?game=${encodeURIComponent(game)}`,options),
    analyze:({game='luckyjet',rounds},options={})=>request('/api/analysis',{...options,data:{game,rounds}}),
    validate:(window,options={})=>request('/api/validate-window',{...options,data:window}),
  };
}
