// k6 load test for the MCP Gateway Registry local stack.
//
// Run by the mcpgw-k6-* commands (modules/mcp-gateway.nix) inside a
// grafana/k6 container on the compose network; metrics stream to the stack's
// Prometheus via remote write and render in the "MCP Gateway · Load &
// Reliability" Grafana dashboard.
//
// Four traffic journeys, each a k6 scenario (the dashboard groups by these):
//   browse_dashboard  humans loading the UI through nginx
//   agent_login       agents acquiring OAuth tokens from Keycloak
//   registry_api      authenticated registry API reads through the gateway
//   mcp_tool_call     the real data plane: MCP initialize + tools/list
//
// Profiles (PROFILE env):
//   smoke / load / stress  closed-model VU envelopes (ramping-vus)
//   scale1500              open-model workload simulating a 1,500-user
//                          production peak hour (arrival rates; see model
//                          below). USERS env rescales linearly.
//   breakpoint             open-model capacity search on the MCP data plane;
//                          climbs arrival rate until SLO breach, then aborts.
//
// Env: BASE_URL, KEYCLOAK_URL, CLIENT_ID, CLIENT_SECRET, MCP_PATH, PROFILE, USERS.

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://registry:8080';
const KC = __ENV.KEYCLOAK_URL || 'http://keycloak:8080';
const CLIENT_ID = __ENV.CLIENT_ID || 'mcp-gateway-m2m';
const CLIENT_SECRET = __ENV.CLIENT_SECRET;
const MCP_PATH = __ENV.MCP_PATH || '/airegistry-tools/mcp';
const PROFILE = __ENV.PROFILE || 'smoke';
const USERS = parseInt(__ENV.USERS || '1500', 10);
// The gateway's nginx edge rate-limits per client IP (50r/s, burst 100).
// Real users arrive from many IPs, so the open-model profiles are run as N
// parallel k6 containers (each its own IP); every shard carries 1/SHARDS of
// the modeled traffic. Closed-model profiles run unsharded (SHARDS=1).
const SHARDS = Math.max(1, parseInt(__ENV.SHARDS || '1', 10));
const TOKEN_URL = `${KC}/realms/mcp-gateway/protocol/openid-connect/token`;

// ---------------------------------------------------------------------------
// Closed-model profiles (VU envelopes). Deliberately modest: the whole stack
// shares one 8GB VM. "stress" is meant to find the local knee, not a DDoS.
// ---------------------------------------------------------------------------
const ENVELOPES = {
  smoke: {
    stages: [{ duration: '1m', target: 3 }],
    loginRate: 1,
  },
  load: {
    stages: [
      { duration: '1m', target: 12 },
      { duration: '3m', target: 12 },
      { duration: '30s', target: 0 },
    ],
    loginRate: 2,
  },
  stress: {
    stages: [
      { duration: '2m', target: 20 },
      { duration: '3m', target: 60 },
      { duration: '3m', target: 60 },
      { duration: '1m', target: 0 },
    ],
    loginRate: 5,
  },
};

// Open-model profiles pace requests themselves; VU-model journeys pace with
// sleep() instead. Set per-profile below.
let openModel = false;
let scenarios;
let thresholds = {
  http_req_failed: ['rate<0.01'],
  'http_req_duration{scenario:browse_dashboard}': ['p(95)<1000'],
  'http_req_duration{scenario:registry_api}': ['p(95)<1000'],
  'http_req_duration{scenario:mcp_tool_call}': ['p(95)<1500'],
  'http_req_duration{scenario:agent_login}': ['p(95)<1500'],
};

if (PROFILE === 'scale1500') {
  // -------------------------------------------------------------------------
  // 1,500-user production peak-hour model (open model, arrival rates).
  // Assumptions — tune with USERS=<n> (rates scale linearly):
  //   * 10% of the user base is active at peak            -> 150 active
  //   * 80% of active are agents (120), 20% humans (30)
  //   * each agent averages 6 MCP tool calls/min          -> 12 calls/s
  //   * each agent averages 2 registry API reads/min      ->  4 reads/s
  //   * humans browse ~3 pageviews/min                    -> 1.5 views/s
  //   * token churn (5-min expiry across active sessions) ->  1 login/s
  // Phases: ramp to peak (2m), hold (4m), 3x burst (3m), recover (2m), down.
  // Total ~12 min. HTTP req/s ~= 2x iteration rate (most journeys make 2).
  // -------------------------------------------------------------------------
  openModel = true;
  const scale = USERS / 1500 / SHARDS;
  const rate = (base) => Math.max(1, Math.round(base * scale));
  const phases = (base) => [
    { target: rate(base), duration: '2m' },
    { target: rate(base), duration: '4m' },
    { target: rate(base * 3), duration: '1m' },
    { target: rate(base * 3), duration: '2m' },
    { target: rate(base), duration: '2m' },
    { target: 0, duration: '1m' },
  ];
  const arrival = (fn, base, maxVUs) => ({
    executor: 'ramping-arrival-rate',
    exec: fn,
    startRate: 1,
    timeUnit: '1s',
    preAllocatedVUs: Math.max(10, Math.round(maxVUs / 3)),
    maxVUs: Math.max(20, Math.round(maxVUs * scale)),
    stages: phases(base),
  });
  scenarios = {
    mcp_tool_call: arrival('mcpToolCall', 12, 120),
    registry_api: arrival('registryApi', 4, 50),
    browse_dashboard: arrival('browseDashboard', 1.5, 30),
    agent_login: arrival('agentLogin', 1, 30),
  };
  // Burst-phase tolerant SLOs; breaches flag but don't abort.
  thresholds = {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{scenario:mcp_tool_call}': ['p(95)<2000'],
    'http_req_duration{scenario:registry_api}': ['p(95)<1500'],
    'http_req_duration{scenario:browse_dashboard}': ['p(95)<1000'],
    'http_req_duration{scenario:agent_login}': ['p(95)<2000'],
  };
} else if (PROFILE === 'breakpoint') {
  // -------------------------------------------------------------------------
  // Capacity search: climb MCP tool-call arrival rate one step per minute
  // until the SLO breaks, then abort. The last healthy step is this
  // hardware's per-instance capacity for the gateway data plane.
  // -------------------------------------------------------------------------
  openModel = true;
  scenarios = {
    mcp_tool_call: {
      executor: 'ramping-arrival-rate',
      exec: 'mcpToolCall',
      startRate: Math.max(1, Math.round(5 / SHARDS)),
      timeUnit: '1s',
      preAllocatedVUs: Math.max(15, Math.round(50 / SHARDS)),
      maxVUs: Math.max(50, Math.round(300 / SHARDS)),
      // Aggregate ramp 15→120 req/s across all shards combined.
      stages: [15, 30, 45, 60, 75, 90, 105, 120].map((t) => ({
        target: Math.max(1, Math.round(t / SHARDS)),
        duration: '1m',
      })),
    },
  };
  thresholds = {
    'http_req_duration{scenario:mcp_tool_call}': [
      { threshold: 'p(95)<2000', abortOnFail: true, delayAbortEval: '30s' },
    ],
    http_req_failed: [
      { threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s' },
    ],
  };
} else {
  const env = ENVELOPES[PROFILE];
  if (!env) throw new Error(`Unknown PROFILE '${PROFILE}'`);
  const scaled = (fraction) =>
    env.stages.map((s) => ({
      duration: s.duration,
      target: Math.max(1, Math.round(s.target * fraction)),
    }));
  const totalSeconds = env.stages.reduce(
    (acc, s) =>
      acc + parseInt(s.duration) * (s.duration.endsWith('m') ? 60 : 1),
    0,
  );
  scenarios = {
    browse_dashboard: {
      executor: 'ramping-vus',
      exec: 'browseDashboard',
      stages: scaled(0.3),
    },
    registry_api: {
      executor: 'ramping-vus',
      exec: 'registryApi',
      stages: scaled(0.35),
    },
    mcp_tool_call: {
      executor: 'ramping-vus',
      exec: 'mcpToolCall',
      stages: scaled(0.35),
    },
    // Token issuance is arrival-rate: N logins/sec regardless of VU count,
    // which is how agent fleets actually hit an IdP.
    agent_login: {
      executor: 'constant-arrival-rate',
      exec: 'agentLogin',
      rate: env.loginRate,
      timeUnit: '1s',
      duration: `${totalSeconds}s`,
      preAllocatedVUs: 5,
      maxVUs: 20,
    },
  };
}

export const options = { scenarios, thresholds };

// ---------------------------------------------------------------------------
// Per-VU token cache. Keycloak tokens expire in ~300s; refresh 60s early so
// long test runs keep working (and exercise the IdP the way real agents do).
// ---------------------------------------------------------------------------
let cachedToken = null;
let tokenExpiry = 0;

function fetchToken(tagName) {
  return http.post(
    TOKEN_URL,
    {
      grant_type: 'client_credentials',
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    },
    { tags: { name: tagName } },
  );
}

function getToken() {
  if (cachedToken && Date.now() < tokenExpiry) return cachedToken;
  const res = fetchToken('keycloak-token-cached');
  if (res.status === 200) {
    const body = res.json();
    cachedToken = body.access_token;
    tokenExpiry = Date.now() + (body.expires_in - 60) * 1000;
  }
  return cachedToken;
}

// Closed-model journeys pace themselves; open-model executors do the pacing.
function pace(seconds) {
  if (!openModel) sleep(seconds);
}

// ---------------------------------------------------------------------------
// Journeys
// ---------------------------------------------------------------------------
export function browseDashboard() {
  const home = http.get(`${BASE}/`, { tags: { name: 'ui-home' } });
  check(home, { 'ui home ok': (r) => r.status === 200 || r.status === 302 });
  const health = http.get(`${BASE}/health`, { tags: { name: 'health' } });
  check(health, { 'health ok': (r) => r.status === 200 });
  pace(1);
}

export function agentLogin() {
  const res = fetchToken('keycloak-token');
  check(res, { 'token issued': (r) => r.status === 200 });
}

export function registryApi() {
  const token = getToken();
  const res = http.get(`${BASE}/api/servers`, {
    headers: { Authorization: `Bearer ${token}` },
    tags: { name: 'api-servers' },
  });
  check(res, { 'api servers 200': (r) => r.status === 200 });
  pace(0.5);
}

export function mcpToolCall() {
  const token = getToken();
  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    Authorization: `Bearer ${token}`,
  };

  const init = http.post(
    `${BASE}${MCP_PATH}`,
    JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2025-03-26',
        capabilities: {},
        clientInfo: { name: 'k6-loadtest', version: '1.0' },
      },
    }),
    { headers, tags: { name: 'mcp-initialize' } },
  );
  check(init, { 'mcp initialize 200': (r) => r.status === 200 });

  const sid = init.headers['Mcp-Session-Id'];
  if (sid) headers['Mcp-Session-Id'] = sid;

  const list = http.post(
    `${BASE}${MCP_PATH}`,
    JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }),
    { headers, tags: { name: 'mcp-tools-list' } },
  );
  check(list, { 'mcp tools/list 200': (r) => r.status === 200 });
  pace(1);
}
