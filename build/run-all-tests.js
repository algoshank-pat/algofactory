// Runs the 6 sensor scenarios (webhook) and 4 chatbot tests (chat endpoint), 2 runs each.
// Writes C:/Maven/Projects/Week2/test_results.json
const fs = require('fs');
const WEBHOOK = 'http://localhost:5678/webhook/anomaly-check';
const CHAT = 'http://localhost:5678/webhook/a1f0c4e2-7b3d-4e5f-9a6b-1c2d3e4f5a6b/chat';

const SENSOR = [
  { id: 'S1', name: 'Happy path: thermal overload', query: 'Equipment-001 TH-001 temp 85°C', expect: { action: 'ACT', range: [80, 100] } },
  { id: 'S2', name: 'Semantic only, no equipment ID', query: 'Motor running hot', expect: { action: 'ACT', range: [60, 80] } },
  { id: 'S3', name: 'Sensor validates vibration anomaly', query: 'Equipment-005 VB-001 vibration 8 mm/s', expect: { action: 'ACT', range: [75, 100] } },
  { id: 'S4', name: 'Sensor contradicts anomaly', query: 'Equipment-001 TH-002 temp 68°C', expect: { action: 'ESCALATE', range: [0, 45] } },
  { id: 'S5', name: 'Humidity false positive after cleaning', query: 'Equipment-001 humidity 75%', timestamp: '2026-10-19T08:30', expect: { action: 'HOLD', range: [0, 10] } },
  { id: 'S6', name: 'Too vague, ask for clarification', query: 'Weird noise from the floor', expect: { action: 'ESCALATE', range: [0, 30], clarify: true } },
];
const CHATS = [
  { id: 'C1', name: 'Lookup by ID, post-cleaning humidity', input: 'Equipment-001 humidity is 75%, should I worry?', expect: 'lookup finds Equipment-001, check_alert returns HOLD' },
  { id: 'C2', name: 'Lookup by plain name', input: 'Weird noise on Pump 2', expect: 'lookup finds Pump 2 (Equipment-008), then escalates or asks for detail' },
  { id: 'C3', name: 'Several machines match', input: 'Motor running hot', expect: 'lookup returns several motors, no check_alert, asks which one' },
  { id: 'C4', name: 'No machine matches', input: 'Is the compressor on Line 9 ok?', expect: 'lookup returns nothing, no check_alert, asks, names no machine' },
];

const post = async (url, body) => { const t0 = Date.now(); const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }); return { o: await r.json(), sec: +((Date.now() - t0) / 1000).toFixed(2) }; };
const parse = s => { try { return typeof s === 'string' ? JSON.parse(s) : s; } catch { return s; } };
const rowsOf = obs => { const v = parse(obs); return Array.isArray(v) ? v.filter(r => r && r.equipment_id) : (v && v.equipment_id ? [v] : []); };

function judgeChat(t, steps, reply) {
  const calls = steps.map(s => ({ tool: s.action.tool, args: s.action.toolInput, observation: parse(s.observation) }));
  const lookups = calls.filter(c => c.tool === 'lookup_equipment');
  const checks = calls.filter(c => c.tool === 'check_alert');
  const found = lookups.length ? rowsOf(lookups[lookups.length - 1].observation) : [];
  const check = checks.length ? (Array.isArray(checks[0].observation) ? checks[0].observation[0] : checks[0].observation) : null;
  const asks = /\?/.test(reply);
  let pass;
  if (t.id === 'C1') pass = found.length === 1 && found[0].equipment_id === 'Equipment-001' && check?.action === 'HOLD';
  if (t.id === 'C2') pass = found.length === 1 && found[0].name === 'Pump 2' && (check?.action === 'ESCALATE' || (!check && asks));
  if (t.id === 'C3') pass = found.length > 1 && !check && asks;
  if (t.id === 'C4') pass = lookups.length > 0 && found.length === 0 && !check && asks && !/Compressor \d/.test(reply);
  return {
    tool_called: calls.length > 0,
    tool_calls: calls.map(c => ({ tool: c.tool, args: c.args })),
    equipment_found: found.map(r => `${r.name} (${r.equipment_id})`),
    confidence: check?.confidence_score ?? null,
    decision: check?.action ?? (asks ? 'ASKED' : null),
    pass
  };
}

(async () => {
  const startedAt = new Date().toISOString();
  await post(WEBHOOK, { query: SENSOR[3].query, source: 'test' });   // warm-up, not counted
  const tests = [];
  for (const s of SENSOR) {
    const runs = [];
    for (const run of [1, 2]) {
      const { o, sec } = await post(WEBHOOK, { query: s.query, timestamp: s.timestamp, source: 'test' });
      const e = s.expect;
      const pass = o.action === e.action && o.confidence_score >= e.range[0] && o.confidence_score <= e.range[1] && (!e.clarify || o.needs_clarification === true);
      runs.push({ run, tool_called: false, tool_calls: [], equipment_found: o.equipment_name ? [`${o.equipment_name} (${o.equipment_id})`] : [], confidence: o.confidence_score, decision: o.action, status: o.status, explanation: o.explanation, layer_scores: o.layer_scores, reply: o.response, latency_sec: sec, pass });
      console.log(`${s.id} run${run} ${pass ? 'PASS' : 'FAIL'} ${o.action} ${o.confidence_score} ${sec}s`);
    }
    tests.push({ id: s.id, path: 'sensor webhook (deterministic Postgres lookup by ID, no LLM in Station 1)', name: s.name, input: s.query, timestamp: s.timestamp || null, expected: s.expect, runs, pass: runs.every(r => r.pass) });
  }
  for (const t of CHATS) {
    const runs = [];
    for (const run of [1, 2]) {
      const { o, sec } = await post(CHAT, { action: 'sendMessage', sessionId: `${t.id}-run${run}-${Date.now()}`, chatInput: t.input });
      const j = judgeChat(t, o.intermediateSteps || [], o.output || '');
      runs.push({ run, ...j, reply: o.output, latency_sec: sec });
      console.log(`${t.id} run${run} ${j.pass ? 'PASS' : 'FAIL'} tools=${j.tool_calls.map(c => c.tool + JSON.stringify(c.args)).join(' > ')} found=${j.equipment_found.length} decision=${j.decision} conf=${j.confidence} ${sec}s`);
      console.log('   reply:', (o.output || JSON.stringify(o)).replace(/\s*\n\s*/g, ' | ').slice(0, 260));
    }
    tests.push({ id: t.id, path: 'chatbot (AI Agent tool calls)', name: t.name, input: t.input, expected: t.expect, runs, pass: runs.every(r => r.pass) });
  }
  const lat = k => tests.filter(t => t.id[0] === k).flatMap(t => t.runs.map(r => r.latency_sec)).sort((a, b) => a - b);
  const p50 = a => a[Math.ceil(a.length / 2) - 1];
  const summary = {
    run_at: startedAt, tests_passed: tests.filter(t => t.pass).length, tests_total: tests.length,
    runs_passed: tests.flatMap(t => t.runs).filter(r => r.pass).length, runs_total: tests.flatMap(t => t.runs).length,
    scenario5_pass: tests.find(t => t.id === 'S5').pass,
    latency_sec: { sensor_p50: p50(lat('S')), sensor_max: lat('S').at(-1), chat_p50: p50(lat('C')), chat_max: lat('C').at(-1) },
    environment: { plant_clock: '2026-10-19T08:30 (PLANT_CLOCK, Monday after the 06:00-08:00 wet-wash)', model: 'Fireworks gpt-oss-120b (agent + answers)', embeddings: 'Fireworks qwen3-embedding-8b (1024)', rerank: 'Pinecone bge-reranker-v2-m3' },
    note: 'One warm-up call before the sensor runs is not counted. Latency is wall-clock from the client.'
  };
  fs.writeFileSync('C:/Maven/Projects/Week2/test_results.json', JSON.stringify({ project: 'AlgoFactory', summary, tests }, null, 2));
  console.log(JSON.stringify(summary, null, 1));
  console.log('STARTED_AT=' + startedAt);
})().catch(e => { console.error(e); process.exit(1); });
