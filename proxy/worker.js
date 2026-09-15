/**
 * Red Panel — Installer Proxy Worker
 * ------------------------------------------------------------------
 * A minimal CORS proxy used by the Red Panel web installer
 * (docs/index.html) to talk to the Cloudflare API and GitHub
 * from the browser.
 *
 * Only whitelisted hosts are proxied. Deploy this once to your
 * Cloudflare account and paste its URL into the installer.
 * ------------------------------------------------------------------
 */
export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, service: 'redpanel-proxy' });
    if (request.method === 'OPTIONS') return new Response(null, { headers: corsH() });
    const target = url.searchParams.get('url');
    if (!target) return json({ error: 'missing ?url=' }, 400);
    let t; try { t = new URL(target); } catch { return json({ error: 'bad url' }, 400); }
    const allowed = ['api.cloudflare.com', 'raw.githubusercontent.com', 'cdn.jsdelivr.net', 'api.github.com'];
    if (!allowed.includes(t.hostname)) return json({ error: 'host not allowed' }, 403);
    const headers = new Headers(request.headers);
    headers.delete('host'); headers.delete('origin'); headers.delete('referer');
    const init = { method: request.method, headers, duplex: 'half' };
    if (request.method !== 'GET' && request.method !== 'HEAD') init.body = request.body;
    const res = await fetch(target, init);
    const rh = new Headers(res.headers);
    for (const [k, v] of Object.entries(corsH())) rh.set(k, v);
    return new Response(res.body, { status: res.status, headers: rh });
  }
};

function corsH() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': '*',
    'Access-Control-Max-Age': '86400'
  };
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: Object.assign({ 'Content-Type': 'application/json' }, corsH())
  });
}
