#!/usr/bin/env node
// keyproxy — sidecar that injects the real API keys into outgoing requests, so
// the pi container only ever holds the dummy value "proxy".
// The route table comes from pi.sh (KEYPROXY_ROUTES, which the agent cannot
// write) and is validated at startup: a request can never carry a real key to
// a host chosen by the agent. Node stdlib only, no dependency, no config file.
import http from 'node:http';
import https from 'node:https';
import { spawnSync } from 'node:child_process';
import { pipeline } from 'node:stream';
import { fileURLToPath } from 'node:url';

// "KEY|/prefix|upstream;…" → [{ env, prefix, upstream }]. Any error throws:
// a typo must stop the launch, never silently drop or misroute a key.
function parseRoutes(text) {
  const routes = [];
  for (const entry of text.split(';').filter(Boolean)) {
    const fail = (why) => { throw new Error(`invalid route "${entry}": ${why}`); };
    const fields = entry.split('|');
    if (fields.length !== 3) fail('expected KEY|/prefix|upstream');
    const [env, prefix, upstream] = fields;
    if (!/^[A-Z_][A-Z0-9_]*$/.test(env)) fail('bad key name');
    if (!/^\/[a-z0-9-]+$/.test(prefix)) fail('prefix must be one segment /[a-z0-9-]+');
    if (routes.some((r) => r.prefix === prefix)) fail('duplicate prefix');
    let u;
    try { u = new URL(upstream); } catch { fail('upstream is not a URL'); }
    if (u.protocol !== 'https:') fail('upstream must be https');
    if (u.username || u.password || u.search || u.hash) fail('no userinfo, query or fragment in upstream');
    routes.push({ env, prefix, upstream });
  }
  return routes;
}

// Every route stays open; it carries a key only when that key is set.
function activeRoutes(text, env = process.env) {
  return parseRoutes(text).map((r) => ({ ...r, key: env[r.env] }));
}

// Exact prefix match only: `/deepseek@evil.com/x` and `/deepseekX` are not
// routes (they used to be one by a naive startsWith(prefix)).
function routeFor(routes, path) {
  return routes.find((r) => path === r.prefix || path.startsWith(r.prefix + '/')) || null;
}

// Build the target by mutating the route's own URL, never by concatenation:
// `https://api.deepseek.com` + `@evil.com/x` would send the key to evil.com
// (userinfo). The host check is belt and braces — URL setters cannot change it.
function targetFor(route, path, search) {
  const base = new URL(route.upstream);
  const target = new URL(route.upstream);
  target.pathname = base.pathname.replace(/\/$/, '') + (path.slice(route.prefix.length) || '/');
  target.search = search;
  return target.host === base.host ? target : null;
}

// The real key replaces the dummy "proxy" in whichever auth header the client
// put it, so one route serves clients with different auth styles (OpenRouter
// gets both Bearer and x-api-key from pi). Auth headers only: a header an API
// echoes back (error message…) would hand the key to the agent. Any other
// credential (e.g. a /login token) passes unchanged to the route's fixed host.
const AUTH_HEADERS = ['authorization', 'x-api-key', 'x-goog-api-key'];

function proxyHeaders(route, headers) {
  const out = { ...headers };
  delete out.host;
  delete out.connection;
  delete out['proxy-authorization'];
  if (!route.key) return out;
  for (const name of AUTH_HEADERS) {
    if (out[name] === 'proxy') out[name] = route.key;
    else if (out[name] === 'Bearer proxy') out[name] = `Bearer ${route.key}`;
  }
  return out;
}

function makeHandler(routes) {
  return (req, res) => {
    const url = new URL(req.url, 'http://keyproxy');
    const route = routeFor(routes, url.pathname);
    const target = route && targetFor(route, url.pathname, url.search);
    if (!target) {
      res.writeHead(404).end();
      return;
    }
    // https.request does not follow redirects: a 3xx goes back to pi as is and
    // the key never reaches a second host. fetch() would follow it.
    const upstream = https.request(target, { method: req.method, headers: proxyHeaders(route, req.headers) }, (up) => {
      res.writeHead(up.statusCode, up.headers);
      // streaming: SSE works. pipeline, not pipe: an upstream cut mid-stream must
      // end pi's response (pipe leaves it hanging), and pi hanging up must stop
      // the upstream call (no credits burnt on a stream nobody reads).
      pipeline(up, res, () => {});
    });
    upstream.on('error', () => {
      if (!res.headersSent) res.writeHead(502);
      res.end(); // never echo upstream headers or the error body
    });
    pipeline(req, upstream, () => {});
  };
}

function selftest() {
  const paths = ['/deepseek/search', '/deepseek/../../@evil.com/x', '/deepseek//evil.com', '/deepseek/@evil.com'];
  let bad = 0;
  const assert = (name, cond) => {
    if (cond) console.log(`PASS ${name}`);
    else { bad++; console.error(`FAIL ${name}`); }
  };

  const table = 'DEEPSEEK_API_KEY|/deepseek|https://api.deepseek.com;'
    + 'OPENAI_API_KEY|/openai|https://api.openai.com/v1;TAVILY_API_KEY|/tavily|https://api.tavily.com';
  const routes = activeRoutes(table, { DEEPSEEK_API_KEY: 'dummy-key', OPENAI_API_KEY: 'dummy-key' });

  assert('unknown route → 404', routeFor(routes, '/evil.com/x') === null);
  assert('/deepseek@evil.com/x → 404', routeFor(routes, '/deepseek@evil.com/x') === null);
  assert('/deepseekX → 404', routeFor(routes, '/deepseekX') === null);
  for (const path of paths) {
    const t = targetFor(routes[0], path, '?a=b');
    assert(`target host stays api.deepseek.com for ${path}`, t !== null && t.host === 'api.deepseek.com');
  }
  assert('upstream base path kept (/openai → /v1)',
    targetFor(routes[1], '/openai/chat/completions', '').pathname === '/v1/chat/completions');
  const h = proxyHeaders(routes[0], {
    authorization: 'Bearer proxy',
    host: 'keyproxy:8787',
    connection: 'keep-alive',
    'proxy-authorization': 'Basic x',
    'content-type': 'application/json',
  });
  assert('auth header replaced with the real key', h.authorization === 'Bearer dummy-key');
  assert('no proxy-authorization', h['proxy-authorization'] === undefined);
  assert('no incoming host/connection', h.host === undefined && h.connection === undefined);
  assert('other headers kept', h['content-type'] === 'application/json');
  const x = proxyHeaders(routes[0], { 'x-api-key': 'proxy', 'x-goog-api-key': 'proxy' });
  assert('dummy replaced in x-api-key / x-goog-api-key, no authorization added',
    x['x-api-key'] === 'dummy-key' && x['x-goog-api-key'] === 'dummy-key' && x.authorization === undefined);
  assert('other credential (/login token) passes unchanged',
    proxyHeaders(routes[0], { authorization: 'Bearer sk-ant-oat-x' }).authorization === 'Bearer sk-ant-oat-x');
  assert('dummy outside auth headers left alone',
    proxyHeaders(routes[0], { 'x-title': 'proxy' })['x-title'] === 'proxy');
  assert('route with no key: dummy passes unchanged',
    proxyHeaders(routes[2], { authorization: 'Bearer proxy' }).authorization === 'Bearer proxy');

  const rejects = (name, text) => {
    let msg = '';
    try { parseRoutes(text); } catch (e) { msg = e.message; }
    assert(`parseRoutes rejects ${name}`, msg.startsWith('invalid route'));
  };
  rejects('http://', 'A_API_KEY|/a|http://a.test');
  rejects('userinfo', 'A_API_KEY|/a|https://u:p@a.test');
  rejects('a query', 'A_API_KEY|/a|https://a.test/?k=1');
  rejects('a fragment', 'A_API_KEY|/a|https://a.test/#x');
  rejects('prefix /a/b', 'A_API_KEY|/a/b|https://a.test');
  rejects('prefix /..', 'A_API_KEY|/..|https://a.test');
  rejects('prefix /A', 'A_API_KEY|/A|https://a.test');
  rejects('a duplicate prefix', 'A_API_KEY|/a|https://a.test;B_API_KEY|/a|https://b.test');
  rejects('a wrong field count', 'A_API_KEY|/a|https://a.test|x-api-key');
  rejects('a bad key name', 'a-key|/a|https://a.test');
  rejects('a non-URL upstream', 'A_API_KEY|/a|not a url');
  const start = spawnSync(process.execPath, [fileURLToPath(import.meta.url)],
    { env: { KEYPROXY_ROUTES: 'A_API_KEY|/a|http://a.test' }, encoding: 'utf8' });
  assert('bad table: startup exits non-zero with the reason',
    start.status !== 0 && start.stderr.includes('invalid route'));

  const server = http.createServer(makeHandler(routes));
  server.listen(0, '127.0.0.1', async () => {
    const base = `http://127.0.0.1:${server.address().port}`;
    for (const path of ['/evil.com/x', '/deepseek@evil.com/x', '/deepseekX']) {
      const code = await fetch(base + path).then((r) => r.status);
      assert(`GET ${path} → 404`, code === 404);
    }
    server.close();
    process.exit(bad ? 1 : 0);
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.includes('--selftest')) selftest();
  else {
    let routes;
    try { routes = activeRoutes(process.env.KEYPROXY_ROUTES || ''); } catch (e) { console.error(e.message); process.exit(1); }
    http.createServer(makeHandler(routes)).listen(8787, '0.0.0.0', () => console.log('keyproxy listening'));
  }
}
