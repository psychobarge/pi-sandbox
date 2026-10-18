#!/usr/bin/env node
// keyproxy — sidecar that injects the real API keys into outgoing requests, so
// the pi container only ever holds the dummy value "proxy".
// The route table is fixed: a request can never carry a real key to a host
// chosen by the agent. Node stdlib only, no dependency, no config file.
import http from 'node:http';
import https from 'node:https';
import { readFileSync } from 'node:fs';
import { pipeline } from 'node:stream';
import { fileURLToPath } from 'node:url';

// prefix = pi's provider id (config/models.json points each one here), upstream
// = pi's own baseUrl for it. pi.sh reads the env names from this table.
// auth: the header the provider reads the key from (default Authorization: Bearer).
const ROUTES = [
  { prefix: '/deepseek', env: 'DEEPSEEK_API_KEY', upstream: 'https://api.deepseek.com' },
  { prefix: '/openai', env: 'OPENAI_API_KEY', upstream: 'https://api.openai.com/v1' },
  { prefix: '/tavily', env: 'TAVILY_API_KEY', upstream: 'https://api.tavily.com' },
  { prefix: '/anthropic', env: 'ANTHROPIC_API_KEY', upstream: 'https://api.anthropic.com', auth: 'x-api-key' },
  { prefix: '/minimax', env: 'MINIMAX_API_KEY', upstream: 'https://api.minimax.io/anthropic', auth: 'x-api-key' },
  { prefix: '/google', env: 'GEMINI_API_KEY', upstream: 'https://generativelanguage.googleapis.com/v1beta', auth: 'x-goog-api-key' },
  { prefix: '/groq', env: 'GROQ_API_KEY', upstream: 'https://api.groq.com/openai/v1' },
  { prefix: '/cerebras', env: 'CEREBRAS_API_KEY', upstream: 'https://api.cerebras.ai/v1' },
  { prefix: '/xai', env: 'XAI_API_KEY', upstream: 'https://api.x.ai/v1' },
  { prefix: '/mistral', env: 'MISTRAL_API_KEY', upstream: 'https://api.mistral.ai' },
  { prefix: '/together', env: 'TOGETHER_API_KEY', upstream: 'https://api.together.ai/v1' },
  { prefix: '/nvidia', env: 'NVIDIA_API_KEY', upstream: 'https://integrate.api.nvidia.com/v1' },
  { prefix: '/huggingface', env: 'HF_TOKEN', upstream: 'https://router.huggingface.co/v1' },
  { prefix: '/moonshotai', env: 'MOONSHOT_API_KEY', upstream: 'https://api.moonshot.ai/v1' },
  { prefix: '/zai', env: 'ZAI_API_KEY', upstream: 'https://api.z.ai/api/coding/paas/v4' },
  { prefix: '/kimi-coding', env: 'KIMI_API_KEY', upstream: 'https://api.kimi.com/coding/v1' },
  { prefix: '/baseten', env: 'BASETEN_API_KEY', upstream: 'https://inference.baseten.co/v1' },
  { prefix: '/meta', env: 'META_API_KEY', upstream: 'https://api.meta.ai/v1' },
  { prefix: '/xiaomi', env: 'XIAOMI_API_KEY', upstream: 'https://api.xiaomimimo.com/v1' },
  { prefix: '/ant-ling', env: 'ANT_LING_API_KEY', upstream: 'https://api.ant-ling.com/v1' },
  { prefix: '/qwen-token-plan', env: 'QWEN_TOKEN_PLAN_API_KEY', upstream: 'https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1' },
];
const AUTH_HEADERS = ['authorization', 'x-api-key', 'x-goog-api-key'];

// A route exists only when its key is set (the same list pi.sh proxies).
function activeRoutes(env = process.env) {
  return ROUTES.filter((r) => env[r.env]).map((r) => ({ ...r, key: env[r.env] }));
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

function proxyHeaders(route, headers) {
  const out = { ...headers };
  // drop every incoming key header: pi's dummy "proxy" must not ride along
  for (const h of AUTH_HEADERS) delete out[h];
  delete out.host;
  delete out.connection;
  delete out['proxy-authorization'];
  const auth = route.auth || 'authorization';
  out[auth] = auth === 'authorization' ? `Bearer ${route.key}` : route.key;
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

  const env = {};
  for (const r of ROUTES) env[r.env] = 'dummy-key';
  const routes = activeRoutes(env);

  assert('unknown route → 404', routeFor(routes, '/evil.com/x') === null);
  assert('/deepseek@evil.com/x → 404', routeFor(routes, '/deepseek@evil.com/x') === null);
  assert('/deepseekX → 404', routeFor(routes, '/deepseekX') === null);
  assert('route with no key → 404', routeFor(activeRoutes({}), '/tavily/search') === null);
  for (const r of routes) {
    const host = new URL(r.upstream).host;
    const ok = paths.every((p) => {
      const t = targetFor(r, r.prefix + p.slice('/deepseek'.length), '?a=b');
      return t !== null && t.host === host;
    });
    assert(`target host stays ${host} for every trick path`, ok);
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
  const incoming = { authorization: 'Bearer proxy', 'x-api-key': 'proxy', 'x-goog-api-key': 'proxy' };
  for (const [prefix, header] of [['/anthropic', 'x-api-key'], ['/google', 'x-goog-api-key']]) {
    const hh = proxyHeaders(routeFor(routes, prefix), incoming);
    const others = AUTH_HEADERS.filter((x) => x !== header);
    assert(`${prefix}: key in ${header} only`, hh[header] === 'dummy-key' && others.every((x) => hh[x] === undefined));
  }

  // config/models.json and ROUTES must agree, or a key is proxied for nothing
  // (or a provider points at a route that 404s). Tavily is not a pi provider.
  const models = JSON.parse(readFileSync(new URL('../config/models.json', import.meta.url), 'utf8'));
  const providers = models.providers || {};
  for (const r of ROUTES.filter((x) => x.prefix !== '/tavily')) {
    assert(`models.json routes ${r.prefix.slice(1)} to the proxy`,
      providers[r.prefix.slice(1)]?.baseUrl === `http://keyproxy:8787${r.prefix}`);
  }
  for (const [id, p] of Object.entries(providers)) {
    const path = p.baseUrl && new URL(p.baseUrl).pathname;
    assert(`models.json ${id} points at an existing route`, routeFor(routes, path) !== null);
  }

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
  else http.createServer(makeHandler(activeRoutes())).listen(8787, '0.0.0.0', () => console.log('keyproxy listening'));
}
