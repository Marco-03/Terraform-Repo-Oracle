#!/usr/bin/env node
/* Minimal managed-runtime regression. It deliberately exercises only public
 * HTTP contracts and never prints credentials or request headers. */
const baseUrl = (process.env.APPLICATION_BASE_URL || process.argv[2] || '').replace(/\/$/, '');
const full = process.argv.includes('--include-agent-chat');
if (!/^https?:\/\//.test(baseUrl)) throw new Error('Set APPLICATION_BASE_URL to the deployed application URL.');

async function request(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: { 'content-type': 'application/json', ...(options.headers || {}) },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}: ${body.code || body.error || 'unknown error'}`);
  return body;
}

const checks = [];
function check(name, condition) { if (!condition) throw new Error(`check failed: ${name}`); checks.push(name); }

const health = await request('/api/health');
check('health', health.ready === true || health.status === 'healthy' || health.status === 'connected');
const native = await request('/api/selectai/query', { method: 'POST', body: JSON.stringify({ question: 'Show the first five utility services.' }) });
check('native-select-ai', native.native === true && native.profileName === 'UTILITIES_SELECTAI_V1' && Array.isArray(native.rows));
for (const [name, path] of [
  ['vector', '/api/social/vector-readiness'],
  ['spatial', '/api/fulfillment/spatial-readiness'],
  ['graph', '/api/graph/readiness'],
  ['native-json', '/api/demo/native-json-readiness'],
]) {
  const body = await request(path);
  check(name, body.ready === true);
}
if (full) {
  const teams = await request('/api/agents/teams');
  const names = new Set(teams.map((team) => team.TEAM_NAME));
  for (const team of ['GRID_RELIABILITY_TEAM', 'FIELD_CREW_LOGISTICS_TEAM', 'UTILITY_SERVICE_REQUEST_TEAM']) check(team, names.has(team));
}
console.log(JSON.stringify({ passed: checks.length, failed: 0, checks }));
console.log('UTILITIES_API_REGRESSION_OK');
