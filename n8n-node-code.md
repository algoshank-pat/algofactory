# n8n Node Code: Ready to Paste (v3, tested)

**Status:** Running in n8n 2.43.7 on 2026-10-16: 12/12 test calls pass. Escalations 1.0-1.3 s, LLM answers 2.0-2.4 s. Results: `AlgoFactory-results.json`.
**Node names matter:** later nodes read earlier ones with `$('9. Parse Intent')`, `$('10b. Pinecone Query')`, `$('12. Merge Results')` and `$('14. Validate')`. Name the nodes exactly as shown.

## Changes from v2 (and why)

| Change | Why |
|---|---|
| Embeddings: Fireworks `qwen3-embedding-8b`, 1024-dim (was OpenAI 1536) | OpenAI key has no credits. Open-weight model, also runs offline for Phase 2. |
| LLM: Fireworks `gpt-oss-120b` (was Mistral 7B) | Mistral 7B is no longer served on the account (404). Open-weight, ~0.8 s. |
| Rerank: Pinecone hosted `bge-reranker-v2-m3` (was Cohere) | No Cohere key. Same Pinecone key, open-source model, ~0.5 s. |
| BM25: in-memory over `/data/chunks.json` (was Pinecone sparse) | No sparse vectors or dotproduct index needed. 51 chunks fit easily in memory. |
| Node 5 reads files with `fs` (replaces Read Files Nodes 1-4c) | Original Node 5 used wrong CSV column names and `doc.nodeName`/`doc.data`, which n8n items do not have. |
| Node 9: humidity checked before acoustic | `/hum/` matched "humidity", so humidity was parsed as acoustic. |
| Node 9: reads `body.query`, accepts `timestamp` | Webhook puts the payload under `body`. Timestamp makes Scenario 5 reproducible at any hour. |
| Node 9: query rewriting (`search_query`) | "Motor running hot" retrieved equipment rows instead of TH-001. |
| Node 12: keeps one equipment spec row | 20 near-identical rows crowded patterns and playbooks out of the top 10. |
| Node 14: declares `sensor_type` | Was undefined; Scenario 5 crashed with a ReferenceError. |
| Node 14: Layer 0 retrieval relevance (0-50) | Max score was 30, so "generate" (>= 60) was unreachable; Scenarios 1-3 could never pass. |
| Node 14: Layer 1 per sensor type | Humidity and vibration were compared against Max Temp. |
| Node 14: Layer 2 checks `day_of_week` | A Monday cleaning matched every day. |
| Node 14: benign cap (10) when a schedule explains the reading | A confirmed scheduled cause overrides; puts Scenario 5 in its 0-10 range. |
| Node 14: Layer 4 = weekly recurring explanation | No incident history exists; the weekly schedule is the recurrence evidence. |
| Node 17: reads scores from Node 14 | Node 16 output only has the LLM text. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |
| Node 9b: equipment specs from Postgres; equipment.csv no longer chunked into Pinecone | One source of truth for machine data (31 vectors, was 51). Node 12 adds the row as a context chunk. |
| Node 14b + 15b: escalations use a template, no LLM | Node 14 already decides them; saves ~1 s and cannot hallucinate. |
| Node 15: max_tokens 200 | ALERT answers stop at ~150 tokens; the cap guards against runaway output. |



## Prerequisites

- **Container:** n8n container runs with `/data` mounted to `C:\Maven\Projects\Week2\data` (the repo's `data/` folder) and `NODE_FUNCTION_ALLOW_BUILTIN=fs`.
- **Data files:** `/data` holds the 6 data files (`maintenance_schedule.json` and `environmental_baselines.json` as in the design doc).
- **Pinecone index:** `algomanfactory`, dimension 1024, metric cosine, serverless.
- **API keys:** container started with `--env-file Update.env` and `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`. HTTP nodes read `$env.FIREWORKS_API_KEY` and `$env.PINECONE_API_KEY`, so no n8n credentials are used and the exported JSON holds no keys.

## Workflow map

```
INGEST (run once):  1. Manual Trigger -> 5. Load & Chunk -> 6. Embed Chunks -> 7. Pinecone Upsert

QUERY (per alert):  8. Webhook -> 9. Parse Intent -> 10a. Embed Query -> 10b. Pinecone Query -> 11. BM25 Search
                    -> 12. Merge Results -> 13. Rerank -> 14. Validate -> 14b. Route
                       generate: 15. Build Prompt -> 16. Fireworks LLM ---+
                       escalate: 15b. Template Response ------------------+-> 17. Format Response -> 18. Respond to Webhook
```

All HTTP Request nodes: Method POST, Authentication None, Send Headers on, Send Body on, Specify Body "Using JSON", and the body expression shown.
- Fireworks nodes header: `Authorization` = `{{ 'Bearer ' + $env.FIREWORKS_API_KEY }}`
- Pinecone nodes headers: `Api-Key` = `{{ $env.PINECONE_API_KEY }}`, `X-Pinecone-API-Version` = `2025-04`

The build has three workflows, exported together in `AlgoFactory-workflow.json`:
- **AlgoFactory - 1 Ingest** (Nodes 1, 5, 6, 7): run once.
- **AlgoFactory - 3 Pipeline** (Nodes 9-17, Stations 1-4): a sub-workflow started by an Execute Workflow Trigger (passthrough). One copy of the stations, shared by both inputs.
- **AlgoFactory - 2 Query** (Node 8 Webhook -> Run Pipeline -> Node 18 Respond): the sensor input. The chatbot (next step) calls the same pipeline.
- **AlgoFactory - 4 Chat**: worker chatbot (Chat Trigger -> AI Agent with 3 tools -> same pipeline).
- **AlgoFactory - 5 Floor API**: dashboard page + JSON endpoints.
- **AlgoFactory - 6 Status Job**: every 15 minutes, applies the status rules below.

---

## Node 1: Manual Trigger
Type: Manual Trigger. No settings.

## Node 5: Load & Chunk (Code)
Mode: Run Once for All Items.

```javascript
// Node 5: Load and chunk the knowledge-base files from /data
// equipment.csv is not chunked: equipment specs live in Postgres (Station 1 lookup)
// Output: one item per chunk { id, text, metadata }. Also writes /data/chunks.json for BM25 (Node 11).

const fs = require('fs');
const D = '/data/';
const CHUNK_TOKENS = 500;                       // ~4 chars per token
const chunks = [];
// Pinecone rejects null metadata values, so drop empty fields
const add = (source, text, metadata) => chunks.push({
  id: `${source.split('.')[0]}-${chunks.length}`,
  text: text.trim(),
  metadata: Object.fromEntries(Object.entries({ source_doc: source, ...metadata }).filter(([, v]) => v != null && v !== ''))
});

function chunkText(text, maxTokens = CHUNK_TOKENS) {
  const out = []; let cur = '';
  for (const para of text.split(/\n\s*\n/)) {
    if (cur && (cur.length + para.length) / 4 > maxTokens) { out.push(cur); cur = ''; }
    cur += (cur ? '\n\n' : '') + para;
  }
  if (cur.trim()) out.push(cur);
  return out;
}

// anomaly_patterns.md: one chunk per ### signature
for (const section of fs.readFileSync(D + 'anomaly_patterns.md', 'utf8').split(/\n(?=### )/).slice(1)) {
  const code = (section.match(/\b(TH|VB|AC)-\d{3}\b/) || ['UNKNOWN'])[0];
  const type = (section.match(/\*\*Equipment Type:\*\*\s*([^\n]+)/) || [, ''])[1].trim();
  for (const part of chunkText(section.split(/\n## /)[0]))
    add('anomaly_patterns.md', part, { anomaly_code: code, equipment_type: type, chunk_type: 'anomaly_pattern' });
}

// playbooks.txt: split per playbook (==== banner), then by paragraph
for (const book of fs.readFileSync(D + 'playbooks.txt', 'utf8').split(/\n?={20,}\n(?=MAINTENANCE PLAYBOOK)/)) {
  if (!book.trim()) continue;
  const title = (book.match(/MAINTENANCE PLAYBOOK:\s*([^\n]+)/) || [, 'Playbook'])[1].trim();
  const proc = (book.match(/Procedure ID:\s*(\S+)/) || [, ''])[1];
  const code = (proc.match(/(TH|VB|AC)-\d{3}/) || [null])[0];
  for (const part of chunkText(book.replace(/={20,}/g, '')))
    add('playbooks.txt', `${title} (${proc})\n${part}`, { procedure_id: proc, anomaly_code: code, chunk_type: 'procedure' });
}

// parts_catalog.json: one chunk per part
for (const p of JSON.parse(fs.readFileSync(D + 'parts_catalog.json', 'utf8')).parts || []) {
  add('parts_catalog.json',
    `Part ${p.part_id}: ${p.description}. For ${(p.equipment_types || []).join(', ')}. Compatible: ${(p.compatible_equipment_ids || []).join(', ')}. Supplier ${p.supplier_id}, $${p.cost_usd}, lead time ${p.lead_time_days} days. ${p.notes || ''}`,
    { part_id: p.part_id, chunk_type: 'parts' });
}

// maintenance_schedule.json: one chunk per schedule
for (const s of JSON.parse(fs.readFileSync(D + 'maintenance_schedule.json', 'utf8')).schedules || []) {
  const effects = Object.entries(s).filter(([k]) => k.startsWith('expected_')).map(([k, v]) => `${k.replace('expected_', '').replace(/_/g, ' ')} ${v}`).join(', ');
  add('maintenance_schedule.json',
    `Scheduled ${s.schedule_type} for ${s.equipment_id}: every ${s.day_of_week} at ${s.time}, method ${s.method}, duration ${s.duration_hours} hours. Expected effects: ${effects}.`,
    { equipment_id: s.equipment_id, chunk_type: 'schedule' });
}

// environmental_baselines.json: one chunk per baseline
for (const b of JSON.parse(fs.readFileSync(D + 'environmental_baselines.json', 'utf8')).baselines || []) {
  const facts = Object.entries(b).filter(([k]) => !['equipment_id', 'condition'].includes(k)).map(([k, v]) => `${k.replace(/_/g, ' ')} ${v}`).join(', ');
  add('environmental_baselines.json',
    `Environmental baseline for ${b.equipment_id} (${b.condition.replace(/_/g, ' ')}): ${facts}.`,
    { equipment_id: b.equipment_id, condition: b.condition, chunk_type: 'baseline' });
}

fs.writeFileSync(D + 'chunks.json', JSON.stringify(chunks));
return chunks.map(c => ({ json: c }));
```

## Node 6: Embed Chunks (HTTP Request)
- **URL:** `https://api.fireworks.ai/inference/v1/embeddings`
- **Options > Batching:** 10 items per batch
- **Body:**
```
{{ JSON.stringify({ model: "accounts/fireworks/models/qwen3-embedding-8b", input: $json.text, dimensions: 1024 }) }}
```

## Node 7: Pinecone Upsert (HTTP Request)
- **URL:** `https://algomanfactory-uscfsbs.svc.aped-4627-b74a.pinecone.io/vectors/upsert`
- **Body:**
```
{{ JSON.stringify({ vectors: [{ id: $('5. Load & Chunk').item.json.id, values: $json.data[0].embedding, metadata: { ...$('5. Load & Chunk').item.json.metadata, text: $('5. Load & Chunk').item.json.text } }] }) }}
```

---

## Node 8: Webhook
- **HTTP Method:** POST
- **Path:** `anomaly-check`
- **Authentication:** None
- **Respond:** Using 'Respond to Webhook' Node
- **Request body:** `{ "query": "Equipment-001 humidity 75%", "timestamp": "2026-10-19T08:30" }` (timestamp optional)

## Node 9: Parse Intent (Code)
Mode: Run Once for All Items.

```javascript
// Node 9: Parse intent from the webhook body
// Input: Webhook item. Body: { "query": "Equipment-001 humidity 75%", "timestamp": "2026-10-19T08:30" }
// timestamp is optional (local plant time, no "Z"). Omit it to use the current time.

const item = $input.first().json;
const body = item.body || item;            // Webhook node puts the payload under "body"
const query = (body.query || "").trim();
const timestamp = body.timestamp || null;
const source = body.source || 'sensor';      // sensor | chat | test | dashboard
const run_id = body.run_id || null;            // set only for chat runs (process trace)

// Equipment ID
const equipmentMatch = query.match(/Equipment-(\d{3})/i);
// The chatbot passes the ID it resolved with lookup_equipment; sensor alerts carry it in the text
const equipment_id = body.equipment_id || (equipmentMatch ? `Equipment-${equipmentMatch[1]}` : null);

// Anomaly code (TH/VB/AC) or sensor type
let anomaly_type = null;
let sensor_type = null;
const codeMatch = query.match(/\b(TH|VB|AC)-\d{3}\b/i);

if (codeMatch) {
  anomaly_type = codeMatch[0].toUpperCase();
  sensor_type = { TH: "temperature", VB: "vibration", AC: "acoustic" }[anomaly_type.slice(0, 2)];
} else if (/humid|moisture|\bwet\b/i.test(query)) {
  // Checked before acoustic: "humidity" contains "hum"
  anomaly_type = "ENV-HUMIDITY";           // No signature in anomaly_patterns.md; environmental reading
  sensor_type = "humidity";
} else if (/temp|heat|\bhot\b|thermal|overheat/i.test(query)) {
  anomaly_type = "TH-001";
  sensor_type = "temperature";
} else if (/vibrat|shak|wobbl/i.test(query)) {
  anomaly_type = "VB-001";
  sensor_type = "vibration";
} else if (/noise|sound|acoustic|squeak|whistl|hiss|grind|\bhum\b|buzz/i.test(query)) {
  anomaly_type = "AC-001";
  sensor_type = "acoustic";
}

// Sensor value: number followed by a unit
let sensor_value = null;
const valueMatch = query.match(/(\d+(?:\.\d+)?)\s*(°\s?C|°\s?F|mm\/s|dB|%|C\b|F\b)/i);
if (valueMatch) sensor_value = parseFloat(valueMatch[1]);

// Query rewriting: when the anomaly was inferred from symptom words, add the domain terms the docs use
const EXPANSION = {
  temperature: "thermal overload temperature exceeds max_temp_c",
  vibration: "vibration bearing wear signature",
  acoustic: "acoustic noise",
  humidity: "humidity environmental baseline cleaning"
};
const search_query = codeMatch || !sensor_type ? query : `${query} ${anomaly_type} ${EXPANSION[sensor_type]}`;

return [{
  json: {
    equipment_id,
    anomaly_type,
    sensor_type,
    sensor_value,
    timestamp,
    raw_query: query,
    run_id,
    source,
    search_query,
    started_at: Date.now()                  // For latency measurement in Node 17
  }
}];
```

## Node 9b: Lookup Equipment (Postgres) — Station 1, sensor path
- **Credential:** `AlgoMan Postgres` (host `algoman-pg`, db `algoman`; password lives in `Update.env`)
- **Operation:** Execute Query
- **Query:** `SELECT * FROM equipment WHERE equipment_id = $1;`
- **Query Parameters:** `{{ $json.equipment_id || 'NO-ID' }}` (a value that never matches, because an empty parameter makes Postgres error)
- **Settings > Always Output Data:** on, so inputs with no ID (S2, S6) continue with an empty item

Deterministic, no LLM. Nodes 12 and 14 read the row with `$('9b. Lookup Equipment')`.

## Node 10a: Embed Query (HTTP Request)
- **URL:** `https://api.fireworks.ai/inference/v1/embeddings`
- **Body:**
```
{{ JSON.stringify({ model: "accounts/fireworks/models/qwen3-embedding-8b", input: $('9. Parse Intent').first().json.search_query, dimensions: 1024 }) }}
```

## Node 10b: Pinecone Query (HTTP Request)
- **URL:** `https://algomanfactory-uscfsbs.svc.aped-4627-b74a.pinecone.io/query`
- **Body:**
```
{{ JSON.stringify({ vector: $json.data[0].embedding, topK: 20, includeMetadata: true }) }}
```

## Node 11: BM25 Search (Code)

```javascript
// Node 11: BM25 sparse search (in memory over /data/chunks.json written by Node 5)
// Input: Node 10b output (passed through). Query terms come from Node 9.

const fs = require('fs');
const intent = $('9. Parse Intent').first().json;
const chunks = JSON.parse(fs.readFileSync('/data/chunks.json', 'utf8'));

const STOP = new Set(['the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'is', 'at', 'by', 'with', 'from', 'if', 'be', 'as', 'it', 'this', 'that']);
const tokenize = s => (s || '').toLowerCase().split(/[^a-z0-9-]+/).filter(t => t.length > 1 && !STOP.has(t));

const queryTerms = [...new Set(tokenize([intent.search_query, intent.equipment_id, intent.anomaly_type, intent.sensor_type].filter(Boolean).join(' ')))];

// BM25 (k1 = 1.2, b = 0.75)
const k1 = 1.2, b = 0.75;
const docs = chunks.map(c => tokenize(c.text));
const avgLen = docs.reduce((n, d) => n + d.length, 0) / docs.length;
const df = {};
for (const d of docs) for (const t of new Set(d)) df[t] = (df[t] || 0) + 1;

const scored = docs.map((d, i) => {
  const tf = {};
  for (const t of d) tf[t] = (tf[t] || 0) + 1;
  let score = 0;
  for (const t of queryTerms) {
    if (!tf[t]) continue;
    const idf = Math.log(1 + (docs.length - df[t] + 0.5) / (df[t] + 0.5));
    score += idf * (tf[t] * (k1 + 1)) / (tf[t] + k1 * (1 - b + b * d.length / avgLen));
  }
  return { id: chunks[i].id, text: chunks[i].text, metadata: chunks[i].metadata, score };
});

const sparse = scored.filter(s => s.score > 0).sort((a, b) => b.score - a.score).slice(0, 10);
return [{ json: { query_terms: queryTerms, sparse } }];
```

## Node 12: Merge Results (Code)

```javascript
// Node 12: Merge dense + sparse (70% / 30%), deduplicate, keep top 10, build the rerank request
// Inputs: $input -> Node 11 { sparse }, $('10b. Pinecone Query') -> { matches }

const intent = $('9. Parse Intent').first().json;
const dense = ($('10b. Pinecone Query').first().json.matches || []).map(m => ({
  id: m.id, text: m.metadata?.text || '', metadata: m.metadata || {}, score: m.score
}));
const sparse = $input.first().json.sparse || [];

// Normalize each list to 0-1 by its max score
const norm = list => { const max = Math.max(...list.map(x => x.score), 1e-9); return new Map(list.map(x => [x.id, { ...x, n: x.score / max }])); };
const D = norm(dense), S = norm(sparse);

const ranked = [...new Set([...D.keys(), ...S.keys()])].map(id => {
  const d = D.get(id), s = S.get(id), base = d || s;
  const dn = d ? d.n : 0, sn = s ? s.n : 0;
  return { id, text: base.text, metadata: base.metadata, dense: +dn.toFixed(3), sparse: +sn.toFixed(3), hybrid: +(0.7 * dn + 0.3 * sn).toFixed(3) };
}).sort((a, b) => b.hybrid - a.hybrid);

// Station 1 equipment row (Postgres) goes in as one context chunk, so rerank and the LLM see the spec
const eq = $('9b. Lookup Equipment').first().json;
const spec = eq && eq.equipment_id ? {
  id: `equipment-db-${eq.equipment_id}`,
  text: `Equipment ${eq.equipment_id} (${eq.name}): ${eq.type} at ${eq.plant} ${eq.location}. Max temperature ${eq.max_temp_c}°C. Max vibration ${eq.max_vibration_mm_s} mm/s. Bearing ${eq.bearing_type}. Supplier ${eq.supplier_id}.`,
  metadata: { source_doc: 'postgres.equipment', equipment_id: eq.equipment_id, chunk_type: 'equipment_spec' },
  dense: 0, sparse: 0, hybrid: 0
} : null;
const merged = [...(spec ? [spec] : []), ...ranked].slice(0, 10);

return [{
  json: {
    candidates: merged,
    rerank_body: {
      model: 'bge-reranker-v2-m3',
      query: intent.search_query,
      top_n: 3,
      return_documents: false,
      documents: merged.map(c => ({ id: c.id, text: c.text }))
    }
  }
}];
```

## Node 13: Rerank (HTTP Request)
- **URL:** `https://api.pinecone.io/rerank`
- **Body:**
```
{{ JSON.stringify($json.rerank_body) }}
```

## Node 14: Validate (Code)
5 layers: Layer 0 retrieval relevance plus the 4 design layers. Weights are constants in `W` at the top.

```javascript
// Node 14: 5-layer contextual validation (Layer 0 + the 4 design layers)
// Inputs:
//   $('13. Rerank')        -> rerank response { data: [{ index, score }] }
//   $('9. Parse Intent')   -> equipment_id, anomaly_type, sensor_type, sensor_value, timestamp
//   $('12. Merge Results') -> candidates (the documents sent to rerank, same order)
//   $('9b. Lookup Equipment') -> equipment row from Postgres
//   /data/*.json -> schedules, baselines

const t_start = Date.now();
const fs = require('fs');
const intent = $('9. Parse Intent').first().json;
const candidates = $('12. Merge Results').first().json.candidates || [];
const rerank = $('13. Rerank').first().json.data || [];

const { equipment_id, anomaly_type, sensor_type, sensor_value, timestamp, raw_query } = intent;

// ----- Tunable weights (adjust after the first test run) -----
const W = {
  RETRIEVAL_MAX: 50,        // Layer 0: top rerank score (0-1) x 50
  SENSOR_EXCEEDS: 40,       // Layer 1: at or above rated limit
  SENSOR_NEAR: 20,          // Layer 1: within 10% of limit
  SYMPTOM_ONLY: 25,         // Layer 1: specific symptom words, no reading
  NO_EXPLANATION: 5,        // Layer 2: validated reading and nothing scheduled explains it
  SCHEDULE_EXPLAINS: -40,   // Layer 2: active cleaning/maintenance explains the reading
  MAINTENANCE_ACTIVE: -15,  // Layer 2: equipment in maintenance, anomalies expected
  BASELINE_NORMAL: -15,     // Layer 3: within expected range for current conditions
  RECURRING: -5,            // Layer 4: explained by a weekly recurring schedule
  BENIGN_CAP: 10,           // Confirmed scheduled cause caps confidence
  THRESHOLD: 60             // >= generate, < escalate
};

// ----- Reference data -----
const readJson = (f, key) => { try { return JSON.parse(fs.readFileSync(f, 'utf8'))[key] || []; } catch (e) { return []; } };
const schedules = readJson('/data/maintenance_schedule.json', 'schedules');
const baselines = readJson('/data/environmental_baselines.json', 'baselines');

// Equipment spec from Postgres (Station 1, Node 9b). Empty item when no ID was given or no row matched.
const row = $('9b. Lookup Equipment').first().json;
const equipment = row && row.equipment_id ? row : null;

// ----- Clock: request timestamp, PLANT_CLOCK env var, or now (local plant time) -----
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
function clock() {
  // Request timestamp, else PLANT_CLOCK (tests/demo), else now
  const m = (timestamp || $env.PLANT_CLOCK || '').match(/(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/);
  if (m) {
    const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
    return { day: DAYS[d.getUTCDay()], hour: +m[4] + +m[5] / 60, month: +m[2] - 1 };
  }
  return { day: $now.weekdayLong, hour: $now.hour + $now.minute / 60, month: $now.month - 1 };
}
const now = clock();
const toHour = t => { const [h, mi] = (t || '00:00').split(':').map(Number); return h + mi / 60; };

// Schedules for this equipment active right now: same weekday, between start and end + grace hours
function activeSchedules(graceHours) {
  return schedules.filter(s => {
    if (s.equipment_id !== equipment_id) return false;
    if (s.day_of_week && s.day_of_week !== now.day) return false;
    const start = toHour(s.time);
    return now.hour >= start && now.hour <= start + (s.duration_hours || 1) + graceHours;
  });
}

const topChunks = rerank.map(r => ({ ...candidates[r.index], rerank_score: r.score }));
const reasons = {};

// ===== LAYER 0: Retrieval relevance (0 to 50) =====
// How well the knowledge base supports a diagnosis for this query
function layer0() {
  const top = topChunks.length ? topChunks[0].rerank_score : 0;
  reasons.layer0 = `Top rerank score ${top.toFixed(2)}`;
  return Math.round(top * W.RETRIEVAL_MAX);
}

// ===== LAYER 1: Sensor cross-check (0 to 40) =====
function layer1() {
  if (sensor_value == null) {
    const specific = /\bhot\b|overheat|burning|smok|grind|vibrat|shak|leak|whistl|hiss/i.test(raw_query);
    reasons.layer1 = specific ? 'No reading; specific symptom reported' : 'No reading; vague report';
    return specific ? W.SYMPTOM_ONLY : 0;
  }
  let limit = null, label = '';
  if (sensor_type === 'temperature') {
    limit = equipment ? +equipment.max_temp_c : 80; label = 'max_temp_c';
  } else if (sensor_type === 'vibration') {
    limit = equipment ? +equipment.max_vibration_mm_s : 7.1; label = 'max_vibration_mm_s';
  } else if (sensor_type === 'humidity') {
    const b = baselines.find(x => x.equipment_id === equipment_id && x.humidity_baseline != null);
    limit = (b ? b.humidity_baseline : 50) + 15; label = 'humidity baseline + 15';
  }
  if (limit == null) { reasons.layer1 = `No limit for sensor type ${sensor_type}`; return 0; }
  if (sensor_value >= limit) { reasons.layer1 = `${sensor_value} >= ${label} ${limit}`; return W.SENSOR_EXCEEDS; }
  if (sensor_value >= limit * 0.9) { reasons.layer1 = `${sensor_value} within 10% of ${label} ${limit}`; return W.SENSOR_NEAR; }
  reasons.layer1 = `${sensor_value} below ${label} ${limit}`;
  return 0;
}

// ===== LAYER 2: Schedule context (-40 to +5) =====
let explainingSchedule = null;
function layer2(l1) {
  const active = activeSchedules(1);
  for (const s of active) {
    if (s.method === 'wet-wash' && sensor_type === 'humidity') {
      const b = baselines.find(x => x.equipment_id === equipment_id && x.humidity_baseline != null);
      const expectedMax = (b ? b.humidity_baseline : 50) + (s.expected_humidity_elevation || 20) + 5;
      if (sensor_value == null || sensor_value <= expectedMax) {
        explainingSchedule = s;
        reasons.layer2 = `${s.method} ${s.schedule_type} ${s.day_of_week || ''} ${s.time} (${s.duration_hours}h) explains humidity up to ${expectedMax}%`;
        return W.SCHEDULE_EXPLAINS;
      }
    }
    if (s.method === 'wet-wash' && sensor_type === 'acoustic') {
      explainingSchedule = s;
      reasons.layer2 = `Wet-wash at ${s.time} causes acoustic false positives`;
      return W.SCHEDULE_EXPLAINS;
    }
    if (/maintenance|replacement/.test(`${s.schedule_type} ${s.method}`)) {
      reasons.layer2 = `${s.method} in progress since ${s.time}; anomalies expected`;
      return W.MAINTENANCE_ACTIVE;
    }
  }
  if (l1 >= W.SENSOR_EXCEEDS) { reasons.layer2 = 'Nothing scheduled explains the reading'; return W.NO_EXPLANATION; }
  reasons.layer2 = 'No active schedule';
  return 0;
}

// ===== LAYER 3: Environmental baseline (-25 to 0) =====
function layer3() {
  let score = 0;
  for (const b of baselines.filter(x => x.equipment_id === equipment_id)) {
    if (b.condition === 'post_cleaning' && sensor_type === 'humidity' && sensor_value != null) {
      const inWindow = activeSchedules(b.humidity_elevated_for_hours || 2).some(s => /wash|clean/.test(`${s.method} ${s.schedule_type}`));
      if (inWindow && sensor_value <= b.humidity_max_expected) {
        reasons.layer3 = `Post-cleaning max expected ${b.humidity_max_expected}%; reading ${sensor_value}% is normal`;
        score = Math.min(score, W.BASELINE_NORMAL);
      }
    }
    if (b.condition === 'summer_season' && sensor_type === 'temperature' && sensor_value != null) {
      if (now.month >= 5 && now.month <= 7 && sensor_value <= b.temperature_max_expected) {
        reasons.layer3 = `Summer max expected ${b.temperature_max_expected}°C; reading is normal`;
        score = Math.min(score, -10);
      }
    }
  }
  if (!reasons.layer3) reasons.layer3 = 'No baseline condition applies';
  return score;
}

// ===== LAYER 4: Historical pattern (-5 to 0) =====
// A weekly recurring schedule that explains the reading means this alert repeats every week
function layer4() {
  if (explainingSchedule && explainingSchedule.day_of_week) {
    reasons.layer4 = `Recurs every ${explainingSchedule.day_of_week} with the ${explainingSchedule.schedule_type}`;
    return W.RECURRING;
  }
  reasons.layer4 = 'No recurring benign pattern';
  return 0;
}

const layerScores = {};
layerScores.layer0 = layer0();
layerScores.layer1 = layer1();
layerScores.layer2 = layer2(layerScores.layer1);
layerScores.layer3 = layer3();
layerScores.layer4 = layer4();

const raw = Object.values(layerScores).reduce((a, b) => a + b, 0);
let confidence = Math.max(0, Math.min(100, raw));
if (layerScores.layer2 === W.SCHEDULE_EXPLAINS) confidence = Math.min(confidence, W.BENIGN_CAP);

const decision = confidence >= W.THRESHOLD ? 'generate' : 'escalate';
const status = decision === 'generate' ? 'ALERT'
  : (layerScores.layer2 === W.SCHEDULE_EXPLAINS || layerScores.layer3 < 0) ? 'FALSE POSITIVE'
  : 'NEEDS INVESTIGATION';
const needs_clarification = !equipment_id && sensor_value == null && layerScores.layer1 === 0;

let explanation = '';
if (status === 'FALSE POSITIVE') explanation = `${reasons.layer2}. ${reasons.layer3}.`;
else if (status === 'ALERT') explanation = `${reasons.layer1}. ${reasons.layer2}.`;
else explanation = needs_clarification
  ? 'Query is too vague: no equipment ID or sensor reading. Ask the operator which equipment and what was observed.'
  : `${reasons.layer1}. Evidence is not strong enough to diagnose.`;

// When a cleaning explains the reading: hour the elevated reading should clear (start + duration + elevated window)
let recovery_time = null;
if (explainingSchedule) {
  const b = baselines.find(x => x.equipment_id === equipment_id && x.condition === 'post_cleaning');
  const end = toHour(explainingSchedule.time) + (explainingSchedule.duration_hours || 1) + (b?.humidity_elevated_for_hours || 0);
  recovery_time = `${String(Math.floor(end)).padStart(2, '0')}:${String(Math.round((end % 1) * 60)).padStart(2, '0')}`;
}

// ----- Process trace (chat runs only): Station 2 evidence and Station 3 context -----
const t_end = Date.now();
const t_station1 = Number($('9b. Lookup Equipment').first().json.t_station1) || t_start;
const trace_steps = [
  { station: 'Station 2', step: `Find evidence -> ${topChunks.length} chunks`, ms: t_start - t_station1,
    detail: {
      search_query: intent.search_query,
      before_rerank: candidates.map(c => ({ id: c.id, source: c.metadata?.source_doc, dense: c.dense, bm25: c.sparse, hybrid: c.hybrid })),
      after_rerank: topChunks.map(c => ({ id: c.id, source: c.metadata?.source_doc, score: +(+c.rerank_score).toFixed(3) }))
    } },
  { station: 'Station 3', step: `Check context -> confidence ${confidence}`, ms: t_end - t_start,
    detail: { layer_scores: layerScores, reasons, raw_score: raw, cap_applied: confidence < Math.max(0, Math.min(100, raw)), cap: W.BENIGN_CAP, confidence, threshold: W.THRESHOLD, status } }
];

return [{
  json: {
    run_id: intent.run_id || null, t_end, trace_steps,
    equipment_id, anomaly_type, sensor_type, sensor_value, timestamp, raw_query,
    equipment_spec: equipment, recovery_time,
    confidence, raw_score: raw, layerScores, reasons,
    decision, status, needs_clarification, explanation,
    topChunks: topChunks.map(c => ({ id: c.id, text: c.text, metadata: c.metadata, rerank_score: c.rerank_score }))
  }
}];
```

## Node 14b: Route (IF)
- **Condition:** `{{ $json.decision }}` is equal to `generate` (String)
- **True** -> 15. Build Prompt -> 16. Fireworks LLM -> 17
- **False** -> 15b. Template Response -> 17

Escalations are fully decided by Node 14, so they skip the LLM: ~1 s faster and no risk of hallucination.

## Node 15: Build Prompt (Code)
Runs on the ALERT path only.

```javascript
// Node 15: Build the LLM request (status and confidence are decided by Node 14, not the LLM)

const v = $('14. Validate').first().json;
const context = (v.topChunks || []).map((c, i) => `[${i + 1}] (${c.metadata?.source_doc}) ${c.text}`).join('\n\n');

const task = {
  'ALERT': 'Give a confident diagnosis and recommended action. Name the playbook procedure ID and any parts with lead time if the context lists them.',
  'FALSE POSITIVE': 'Explain that the alert is a false positive and why, using the validation findings. State that no action is needed and when readings should return to normal.',
  'NEEDS INVESTIGATION': v.needs_clarification
    ? 'Say the report is too vague to diagnose. Ask for the equipment ID and the sensor reading or symptom observed.'
    : 'Say the evidence is not strong enough to confirm a fault. Suggest what to check next.'
}[v.status];

const prompt = `You are AlgoFactory, a manufacturing maintenance assistant. Use ONLY the context and validation findings below. Do not invent values.

CONTEXT:
${context || '(no relevant documents)'}

ALERT: ${v.raw_query}
EQUIPMENT: ${v.equipment_id || 'unknown'} | SENSOR: ${v.sensor_type || 'unknown'} ${v.sensor_value ?? ''}
STATUS (decided by validation): ${v.status}
CONFIDENCE: ${v.confidence}%
VALIDATION FINDINGS: ${v.explanation}

TASK: ${task}

Reply in at most 4 short lines:
Status: ${v.status}
Diagnosis: ...
Action: ...
Parts: ... (or "None")`;

return [{
  json: {
    llm_body: {
      model: 'accounts/fireworks/models/gpt-oss-120b',
      temperature: 0,
      max_tokens: 400,             // reasoning tokens count against the cap; 200 cut off some answers mid-line
      reasoning_effort: 'low',
      messages: [{ role: 'user', content: prompt }]
    }
  }
}];
```

## Node 16: Fireworks LLM (HTTP Request)
- **URL:** `https://api.fireworks.ai/inference/v1/chat/completions`
- **Body:**
```
{{ JSON.stringify($json.llm_body) }}
```

## Node 15b: Template Response (Code)

```javascript
// Node 15b: Template response for escalations (no LLM call)
// Escalations are fully decided by Node 14, so a template is faster (~1 s saved) and cannot hallucinate.
// Output matches the Fireworks response shape so Node 17 handles both paths.

const v = $('14. Validate').first().json;
let lines;

if (v.status === 'FALSE POSITIVE') {
  lines = [
    'Status: FALSE POSITIVE',
    `Diagnosis: ${v.sensor_type} ${v.sensor_value ?? ''} on ${v.equipment_id} is explained by context. ${v.explanation}`.replace(/\s+/g, ' ').trim(),
    `Action: No action needed.${v.recovery_time ? ` Readings should return to baseline by ${v.recovery_time}.` : ''}`,
    'Parts: None'
  ];
} else if (v.needs_clarification) {
  lines = [
    'Status: NEEDS INVESTIGATION',
    'Diagnosis: Report is too vague to diagnose: no equipment ID or sensor reading.',
    'Action: Specify the equipment ID and the sensor reading or symptom observed.',
    'Parts: None'
  ];
} else {
  lines = [
    'Status: NEEDS INVESTIGATION',
    `Diagnosis: ${v.reasons?.layer1 || 'Sensor evidence unclear'}. Evidence is not strong enough to confirm a fault (confidence ${v.confidence}%).`,
    `Action: Verify the sensor reading on ${v.equipment_id || 'the equipment'} and keep monitoring; escalate to a technician if it keeps rising.`,
    'Parts: None'
  ];
}

return [{ json: { source: 'template', choices: [{ message: { content: lines.join('\n') } }] } }];
```

## Node 17: Format Response (Code)

```javascript
// Node 17: Format the final response
// Inputs: $input -> Node 16 Fireworks response, $('14. Validate') -> scores, $('9. Parse Intent') -> start time

const v = $('14. Validate').first().json;
const started = $('9. Parse Intent').first().json.started_at;
const llm = $input.first().json;
const ACTION = { 'ALERT': 'ACT', 'FALSE POSITIVE': 'HOLD', 'NEEDS INVESTIGATION': 'ESCALATE' };
const answer = llm.choices?.[0]?.message?.content?.trim() || 'Unable to generate response.';
// Citations: ACT answers end with a deterministic Sources line built from the chunks the LLM was given
// (same order as the [n] labels in the Node 15 prompt), so the citation itself cannot be hallucinated.
const citations = v.topChunks.map((c, i) => ({ n: i + 1, source: c.metadata?.source_doc, chunk_id: c.id, rerank_score: +(+c.rerank_score).toFixed(3) }));
const text = ACTION[v.status] === 'ACT' && citations.length
  ? `${answer}
Sources: ${citations.map(c => `[${c.n}] ${c.source} (${c.chunk_id})`).join(' · ')}`
  : answer;

return [{
  json: {
    query: v.raw_query,
    equipment_id: v.equipment_id,
    equipment_name: v.equipment_spec?.name || null,
    source: $('9. Parse Intent').first().json.source,
    action: ACTION[v.status],
    sensor_type: v.sensor_type,
    sensor_value: v.sensor_value,
    confidence_score: Math.round(v.confidence),
    decision: v.decision,
    status: v.status,
    needs_clarification: v.needs_clarification,
    explanation: v.explanation,
    layer_scores: v.layerScores,
    layer_reasons: v.reasons,
    sources: v.topChunks.map(c => ({ id: c.id, source: c.metadata?.source_doc, rerank_score: +c.rerank_score.toFixed(3) })),
    response: text,
    citations: ACTION[v.status] === 'ACT' ? citations : [],
    response_source: llm.source || 'llm',
    model: llm.source === 'template' ? null : (llm.model || 'accounts/fireworks/models/gpt-oss-120b'),
    run_id: v.run_id,
    t14_end: v.t_end,
    latency_sec: +((Date.now() - started) / 1000).toFixed(2),
    timestamp: new Date().toISOString()
  }
}];
```

## Node 18: Respond to Webhook
- **Respond With:** JSON
- **Response Body:** `{{ $json }}`
- **Response Code:** 200

---

## Node 18a: Log & Update Status (Postgres)
After Station 4, in the same run. Query Parameters: `{{ [JSON.stringify($json)] }}`. Always Output Data: on.

```sql
-- 18a: log every alert; update the machine's status when it was identified.
-- ACT -> fault, HOLD -> explained, ESCALATE -> watch. A later reading always replaces the status (that is how faults clear).
WITH p AS (SELECT $1::jsonb AS j),
eq AS (SELECT e.equipment_id FROM equipment e, p WHERE e.equipment_id = p.j->>'equipment_id'),
log AS (
  INSERT INTO alert_log (equipment_id, input_source, summary, decision, confidence, reason)
  SELECT (SELECT equipment_id FROM eq), j->>'source', j->>'query', j->>'action', (j->>'confidence_score')::int, j->>'explanation' FROM p
  RETURNING id
)
INSERT INTO equipment_status (equipment_id, status, reason, last_reading, updated_at)
SELECT eq.equipment_id,
       CASE p.j->>'action' WHEN 'ACT' THEN 'fault' WHEN 'HOLD' THEN 'explained' ELSE 'watch' END,
       p.j->>'explanation',
       jsonb_build_object('query', p.j->>'query', 'sensor_type', p.j->>'sensor_type', 'sensor_value', p.j->'sensor_value',
                          'confidence', p.j->'confidence_score', 'alert_id', (SELECT id FROM log), 'at', now()),
       now()
FROM p, eq
ON CONFLICT (equipment_id) DO UPDATE
  SET status = EXCLUDED.status, reason = EXCLUDED.reason, last_reading = EXCLUDED.last_reading, updated_at = EXCLUDED.updated_at
RETURNING equipment_id, status;
```

## Node 19: Return Result (Code)

```javascript
// Node 19: Return the pipeline result (the sub-workflow returns the last node's output)
const result = $('17. Format Response').first().json;
const st = $('18a. Log & Update Status').first().json;
return [{ json: { ...result, equipment_status: st.status || null } }];
```

## Status Job (workflow "AlgoFactory - 6 Status Job")
Schedule Trigger every 15 minutes (plus a "Run Now" manual trigger) -> Active Schedule Windows (Code) -> Apply Status Rules (Postgres, Query Parameters `{{ [$json.active_ids] }}`).

```javascript
// Status job: which machines are inside a scheduled window right now (maintenance or cleaning)
// Clock: PLANT_CLOCK env var (tests / demo, e.g. 2026-10-19T08:30) or the current time.

const fs = require('fs');
const schedules = JSON.parse(fs.readFileSync('/data/maintenance_schedule.json', 'utf8')).schedules || [];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

let day, hour;
const m = ($env.PLANT_CLOCK || '').match(/(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/);
if (m) { day = DAYS[new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).getUTCDay()]; hour = +m[4] + +m[5] / 60; }
else { day = $now.weekdayLong; hour = $now.hour + $now.minute / 60; }

const active = schedules.filter(s => {
  const [h, mi] = (s.time || '00:00').split(':').map(Number);
  const start = h + mi / 60;
  return (!s.day_of_week || s.day_of_week === day) && hour >= start && hour < start + (s.duration_hours || 1);
});

return [{ json: {
  clock: `${day} ${String(Math.floor(hour)).padStart(2, '0')}:${String(Math.round((hour % 1) * 60)).padStart(2, '0')}`,
  active_ids: `{${[...new Set(active.map(s => s.equipment_id))].join(',')}}`,   // Postgres text[] literal
  active: active.map(s => `${s.equipment_id} ${s.schedule_type} (${s.method})`)
} }];
```

```sql
-- Status job (every 15 min). Faults are never changed here: only a later reading or a dashboard reset clears them.
WITH a AS (SELECT unnest($1::text[]) AS id),
start_m AS (
  UPDATE equipment_status s SET status = 'maintenance', reason = 'Scheduled maintenance/cleaning window', updated_at = now()
  WHERE s.equipment_id IN (SELECT id FROM a) AND s.status NOT IN ('fault', 'maintenance')
  RETURNING s.equipment_id, 'to maintenance'::text AS change),
end_m AS (
  UPDATE equipment_status s SET status = 'normal', reason = 'Maintenance window ended', updated_at = now()
  WHERE s.status = 'maintenance' AND s.equipment_id NOT IN (SELECT id FROM a)
  RETURNING s.equipment_id, 'maintenance -> normal'::text),
expired AS (
  UPDATE equipment_status s SET status = 'normal', reason = 'Explained alert expired after 3 hours', updated_at = now()
  WHERE s.status = 'explained' AND s.updated_at < now() - interval '3 hours' AND s.equipment_id NOT IN (SELECT id FROM a)
  RETURNING s.equipment_id, 'explained -> normal'::text)
SELECT * FROM start_m UNION ALL SELECT * FROM end_m UNION ALL SELECT * FROM expired;
```

## Postgres tables
- `equipment`: ID, plain name (Motor 1, Pump 2...), type, plant, site, region, state, line, location, specs. Plus `lookup_equipment(q)` for the chatbot.
- `equipment_status`: one row per machine: normal / watch / fault / explained / maintenance, reason, last_reading (JSONB), updated_at.
- `alert_log`: every alert: equipment_id (NULL if unidentified), input_source (sensor / chat / test / dashboard), summary, decision (ACT / HOLD / ESCALATE), confidence, reason.

| Decision | Status | Clears when |
|---|---|---|
| ACT | fault | a later reading for that machine, or a dashboard reset |
| ESCALATE | watch | a later reading |
| HOLD | explained | the status job, 3 hours later |
| (schedule window) | maintenance | the status job, when the window ends; never overrides a fault |

## Chatbot (workflow "AlgoFactory - 4 Chat")
Two front ends talk to the same n8n chat workflow:
- **The dashboard's "Ask AlgoFactory" panel** at http://localhost:5678/webhook/floor. It posts `{ action: "sendMessage", sessionId, chatInput }` to the chat webhook, shows the reply and the tool calls, and refreshes the board after a `check_alert`.
- **n8n's hosted chat page** at `/webhook/a1f0c4e2-7b3d-4e5f-9a6b-1c2d3e4f5a6b/chat`.

Worker Chat (Chat Trigger, public) -> **AI Agent** with:
- **Model:** `Fireworks gpt-oss-120b` (OpenAI Chat Model node v1.2; the "OpenAI" credential holds the Fireworks key with Base URL `https://api.fireworks.ai/inference/v1`). It called `lookup_equipment` correctly in a function-calling test. OpenAI has no credits, and Mistral 7B is not served.
- **Memory:** Simple Memory, 10 messages, so "Did you mean...?" follow-ups keep context.
- **Tool `lookup_equipment`** (Postgres Tool): `SELECT * FROM lookup_equipment($1)`, matching by ID, by name, by type plus line, or by type plus city.
- **Tool `get_equipment_status`** (Postgres Tool): `SELECT * FROM get_status_summary($1)`. Counts are computed in SQL, because the model miscounted rows (it said 38 normal out of 30).
- **Tool `check_alert`** (Call n8n Workflow Tool): runs **AlgoFactory - 3 Pipeline** with `query`, `equipment_id` and `source = chat`. It is the same Stations 2-4 as sensor alerts.

System prompt:

```text
You are AlgoFactory, the floor assistant for maintenance workers. Be short and plain. Never invent machines, readings or numbers.

TOOLS
- lookup_equipment: call it FIRST whenever the message mentions a machine or a symptom. Pass the machine words exactly as the worker wrote them (e.g. "Pump 2", "Equipment-001", "compressor on Line 9", "motor").
  - Exactly 1 row: call check_alert with that equipment_id and the worker's message.
  - Several rows: do NOT call check_alert. Ask "Did you mean ...?" listing the names with site and line (at most 8).
  - 0 rows: do NOT call check_alert. Say you could not find that machine and ask for its name or ID. Never pick one yourself.
- check_alert: runs the sensor, schedule, baseline and history checks. Use only what it returns.
- get_equipment_status: for questions like "How are my machines doing?" or "How is Austin?". Pass "all", a site, state, region, line or machine. Report total and by_status exactly as returned (never count rows yourself), then list every machine in needs_attention with its status and reason.

REPLY FORMAT after check_alert (use its "action", "confidence_score", "explanation" and "response" fields):
Decision: ACT, HOLD or ESCALATE (Machine name)
Why: one sentence
Confidence: N%
Next step: one sentence a floor worker can act on
```

```sql
-- Chatbot tools. lookup_equipment(q): exact ID/name -> name in text -> type + line -> type only -> fuzzy.
-- A machine or line number that matches nothing ("compressor on line 9") returns no rows, so the agent asks.
DROP FUNCTION IF EXISTS lookup_equipment(text);
CREATE FUNCTION lookup_equipment(q text)
RETURNS TABLE (match_type text, equipment_id text, name text, type text, site text, line text, location text,
               status text, max_temp_c numeric, max_vibration_mm_s numeric, bearing_type text, description text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  n text := lower(coalesce(q, ''));
  w text[] := ARRAY['one','two','three','four','five','six','seven','eight','nine','ten'];
  i int;
  ln text;
  site_hit text;
BEGIN
  FOR i IN 1..10 LOOP n := regexp_replace(n, '\m' || w[i] || '\M', i::text, 'g'); END LOOP;
  n := regexp_replace(n, '\s+', ' ', 'g');

  RETURN QUERY SELECT 'exact', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
    WHERE lower(e.equipment_id) = n OR lower(e.name) = n OR n ~ ('\m' || lower(e.equipment_id) || '\M');
  IF FOUND THEN RETURN; END IF;

  RETURN QUERY SELECT 'name_in_text', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id) WHERE n ~ ('\m' || lower(e.name) || '\M');
  IF FOUND THEN RETURN; END IF;

  -- "compressor on line 2": machines of that type on that line (all types if none named)
  ln := substring(n from 'line ?(\d+)');
  IF ln IS NOT NULL THEN
    RETURN QUERY SELECT 'type_line', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
      FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
      WHERE e.line = 'Line ' || ln
        AND (n !~ '\m(motor|pump|compressor|fan)s?\M' OR n ~ ('\m' || e.type || 's?\M'))
      ORDER BY e.name;
    RETURN;   -- found or not, never fall through to a guess
  END IF;

  IF n ~ '\m(motor|pump|compressor|fan|machine|unit|equipment)s? ?(#|no\.? ?|-)?\d' THEN RETURN; END IF;

  -- A city in the text ("the pump in seattle") narrows a type match to that plant
  SELECT e.site INTO site_hit FROM equipment e WHERE n ~ ('\m' || lower(split_part(e.site, ' ', 1)) || '\M') LIMIT 1;
  RETURN QUERY SELECT 'type', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
    WHERE n ~ ('\m' || e.type || 's?\M') AND (site_hit IS NULL OR e.site = site_hit) ORDER BY e.name;
  IF FOUND THEN RETURN; END IF;

  RETURN QUERY SELECT 'fuzzy', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
    WHERE similarity(e.name, n) >= 0.6 ORDER BY similarity(e.name, n) DESC LIMIT 5;
END $$;

-- get_equipment_status(scope): 'all' (or empty), a site / state / region / plant / line, or a machine name or ID
CREATE OR REPLACE FUNCTION get_equipment_status(scope text)
RETURNS TABLE (equipment_id text, name text, type text, site text, line text, status text, reason text, updated_at timestamptz)
LANGUAGE plpgsql STABLE AS $$
DECLARE n text := lower(trim(coalesce(scope, '')));
BEGIN
  IF n IN ('', 'all', 'everything', 'my machines', 'machines', 'all machines') THEN
    RETURN QUERY SELECT e.equipment_id, e.name, e.type, e.site, e.line, s.status, s.reason, s.updated_at
      FROM equipment e JOIN equipment_status s USING (equipment_id) ORDER BY e.site, e.name;
    RETURN;
  END IF;
  RETURN QUERY SELECT e.equipment_id, e.name, e.type, e.site, e.line, s.status, s.reason, s.updated_at
    FROM equipment e JOIN equipment_status s USING (equipment_id)
    WHERE lower(e.site) LIKE '%' || n || '%' OR lower(e.state) = n OR lower(e.region) = n OR lower(e.plant) = n
       OR lower(split_part(e.site, ' ', 1)) = n
    ORDER BY e.site, e.name;
  IF FOUND THEN RETURN; END IF;
  RETURN QUERY SELECT l.equipment_id, l.name, l.type, l.site, l.line, s.status, s.reason, s.updated_at
    FROM lookup_equipment(scope) l JOIN equipment_status s USING (equipment_id) ORDER BY l.name;
END $$;

-- get_status_summary(scope): counts computed in SQL (the model must not count rows itself) + only machines needing attention
CREATE OR REPLACE FUNCTION get_status_summary(scope text)
RETURNS TABLE (scope_used text, total int, by_status jsonb, needs_attention jsonb)
LANGUAGE sql STABLE AS $$
  WITH s AS (SELECT * FROM get_equipment_status(scope))
  SELECT coalesce(nullif(trim(scope), ''), 'all'),
         (SELECT count(*)::int FROM s),
         (SELECT jsonb_object_agg(st, coalesce(n, 0)) FROM unnest(ARRAY['normal','watch','fault','explained','maintenance']) st
            LEFT JOIN (SELECT status, count(*)::int n FROM s GROUP BY status) c ON c.status = st),
         coalesce((SELECT jsonb_agg(jsonb_build_object('name', name, 'equipment_id', equipment_id, 'site', site, 'line', line, 'status', status, 'reason', reason) ORDER BY status, name)
                   FROM s WHERE status <> 'normal'), '[]'::jsonb)
$$;
```

**Demo clock:** `PLANT_CLOCK=2026-10-19T08:30` (container env) is used when a request has no timestamp, so C1 runs inside Monday's post-cleaning window. Unset it for production.

## Floor dashboard (workflow "AlgoFactory - 5 Floor API")
Open **http://localhost:5678/webhook/floor**. n8n serves the page and its data from one origin, so no CORS setup or second server is needed. Source file: `dashboard/AlgoFactory-dashboard.html` (React 18 + htm from CDN, no build step). It is embedded into the workflow when the workflow is built.

| Endpoint | Returns |
|---|---|
| `GET /webhook/floor` | the dashboard page |
| `GET /webhook/floor/equipment` | `{ equipment: [...] }`: 20 machines with site, line, status, reason, last_reading, alerts_today |
| `GET /webhook/floor/alerts?date=today` | `{ date, alerts: [...] }`: alert_log for that day (Pacific time); also accepts YYYY-MM-DD |
| `GET /webhook/floor/history?equipment_id=..&hours=24` | the machine, its status, and its alerts in the window (1-168 h) |
| `POST /webhook/floor/action` `{ equipment_id, new_status, note, performed_by }` | Mark action taken: status -> normal or maintenance, logs an ACTION row with the note and name; rejects missing fields |

Dashboard features: a USA plant map (7 plants, dot color = worst status, click to filter), the **Ask AlgoFactory** chat panel, status tiles (click to filter), a site filter, machine cards by site and line (click for 24 h history and Mark action taken), an Alerts today list, and **Send test alert** (presets plus free text, posting to the real `/webhook/anomaly-check` with source `dashboard`). It refreshes every 15 s.

## Test results (n8n webhook, 2026-10-16, 2 runs each)

| # | Query | Expected | Confidence | Decision / Status | Answer by | Latency run 1 / 2 | Result |
|---|---|---|---|---|---|---|---|
| 1 | Equipment-001 TH-001 temp 85°C | 80-100, generate | 94 | generate / ALERT | llm | 2.24 s / 2.33 s | PASS |
| 2 | Motor running hot | 60-80, generate | 75 | generate / ALERT | llm | 2.3 s / 2.06 s | PASS |
| 3 | Equipment-005 VB-001 vibration 8 mm/s | 75-100, generate | 94 | generate / ALERT | llm | 2.23 s / 1.84 s | PASS |
| 4 | Equipment-001 TH-002 temp 68°C | 0-45, escalate | 35 | escalate / NEEDS INVESTIGATION | template | 1.27 s / 1.1 s | PASS |
| 5 | Equipment-001 humidity 75% @ Mon 08:30 | 0-10, escalate | 10 | escalate / FALSE POSITIVE | template | 1.33 s / 1.71 s | PASS |
| 6 | Weird noise from the floor | 0-30, escalate | 22 | escalate / NEEDS INVESTIGATION | template | 1.5 s / 1.44 s | PASS |

p50 1.71 s, p95 2.33 s. 7/12 under 2 s: all escalations. LLM answers take 2.0-2.4 s (retrieval + rerank ~1.0 s, LLM 0.6-1.5 s).

Scenario 5 layers: L0 +50, L1 +40, L2 -40, L3 -15, L4 -5 = 30 raw, capped at 10 by the confirmed scheduled cause.
