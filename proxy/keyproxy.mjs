#!/usr/bin/env node
// keyproxy — sidecar that injects the real API keys into outgoing requests, so
// the pi container only ever holds the dummy value "proxy".
// The route table is fixed: a request can never carry a real key to a host
// chosen by the agent. Node stdlib only, no dependency, no config file.
import http from 'node:http';
import https from 'node:https';
import { fileURLToPath } from 'node:url';

const ROUTES = [
  { prefix: '/deepseek', env: 'DEEPSEEK_API_KEY', upstream: 'https://api.deepseek.com' },
  { prefix: '/openai', env: 'OPENAI_API_KEY', upstream: 'https://api.openai.com/v1' },
  { prefix: '/tavily', env: 'TAVILY_API_KEY', upstream: 'https://api.tavily.com' },
];

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
  delete out.authorization;
  delete out.host;
  delete out.connection;
  delete out['proxy-authorization'];
  out.authorization = `Bearer ${route.key}`;
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
      up.pipe(res); // streaming: SSE works
    });
    upstream.on('error', () => {
      if (!res.headersSent) res.writeHead(502);
      res.end(); // never echo upstream headers or the error body
    });
    req.pipe(upstream);
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
