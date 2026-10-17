// AlgoFactory workflow builder: generates the 6 n8n workflow JSON files into build/out/.
// Run: OPENAI_CRED_ID=no8OAWIhBkwnga5I OPENAI_CRED_NAME="OpenAI account" node build/build-wf.js
// Then import each file with: docker exec n8n n8n import:workflow --input=... (see AlgoFactory-STATUS.md)
const fs = require('fs'), crypto = require('crypto');
const code = f => fs.readFileSync(`${__dirname}/nodes/${f}`, 'utf8');
// Pinecone index host: set PINECONE_HOST for your own index (default = the original algomanfactory index)
const HOST = process.env.PINECONE_HOST || 'algomanfactory-uscfsbs.svc.aped-4627-b74a.pinecone.io';
// Keys come from container env vars (--env-file Update.env), so the workflow JSON holds no secrets
const FW = [{ name: 'Authorization', value: "={{ 'Bearer ' + $env.FIREWORKS_API_KEY }}" }];
const PC = [{ name: 'Api-Key', value: '={{ $env.PINECONE_API_KEY }}' }, { name: 'X-Pinecone-API-Version', value: '2025-04' }];
const uuid = () => crypto.randomUUID();
const codeNode = (name, file, x, y) => ({ id: uuid(), name, type: 'n8n-nodes-base.code', typeVersion: 2, position: [x, y], parameters: { jsCode: code(file) } });
const http = (name, url, body, headers, x, y, extra = {}) => ({
  id: uuid(), name, type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2, position: [x, y],
  parameters: {
    method: 'POST', url, authentication: 'none',
    sendHeaders: true, headerParameters: { parameters: headers },
    sendBody: true, specifyBody: 'json', jsonBody: body, options: extra
  }
});
const chain = names => Object.fromEntries(names.slice(0, -1).map((n, i) => [n, { main: [[{ node: names[i + 1], type: 'main', index: 0 }]] }]));
const wf = (name, nodes) => ({ id: name.includes('Ingest') ? '438f43ce2ff04804' : name.includes('Pipeline') ? '5c7a1f0e2d3b4a69' : name.includes('Status Job') ? '6d8b2e1f3c4a5b70' : name.includes('Chat') ? '4a9c3d2e1f0b5c68' : name.includes('Floor API') ? '7e9c3f2a4b5d6e81' : '9b3ede12f642464f', name, active: false, nodes, connections: chain(nodes.map(n => n.name)), settings: { executionOrder: 'v1' }, pinData: {} });

const ingest = wf('AlgoFactory - 1 Ingest', [
  { id: uuid(), name: '1. Manual Trigger', type: 'n8n-nodes-base.manualTrigger', typeVersion: 1, position: [0, 0], parameters: {} },
  codeNode('5. Load & Chunk', 'n05.js', 220, 0),
  http('6. Embed Chunks', 'https://api.fireworks.ai/inference/v1/embeddings',
    '={{ JSON.stringify({ model: "accounts/fireworks/models/qwen3-embedding-8b", input: $json.text, dimensions: 1024 }) }}', FW, 440, 0,
    { batching: { batch: { batchSize: 10, batchInterval: 200 } } }),
  http('7. Pinecone Upsert', `https://${HOST}/vectors/upsert`,
    "={{ JSON.stringify({ vectors: [{ id: $('5. Load & Chunk').item.json.id, values: $json.data[0].embedding, metadata: Object.assign({}, $('5. Load & Chunk').item.json.metadata, { text: $('5. Load & Chunk').item.json.text }) }] }) }}", PC, 660, 0),
]);

// Stations 1-4 live in one sub-workflow; the sensor webhook and the chatbot both call it
const PIPELINE_ID = '5c7a1f0e2d3b4a69';
const PIPELINE_FIELDS = ['query', 'equipment_id', 'timestamp', 'source'];
const inputSchema = PIPELINE_FIELDS.map(id => ({ id, displayName: id, required: false, defaultMatch: false, display: true, canBeUsedToMatch: true, type: 'any', removed: false }));
const inputMapping = value => ({ mappingMode: 'defineBelow', value, matchingColumns: [], schema: inputSchema, attemptToConvertTypes: false, convertFieldsToString: false });
const pipeline = wf('AlgoFactory - 3 Pipeline', [
  { id: uuid(), name: 'Pipeline Input', type: 'n8n-nodes-base.executeWorkflowTrigger', typeVersion: 1.1, position: [0, 0], parameters: { inputSource: 'workflowInputs', workflowInputs: { values: PIPELINE_FIELDS.map(name => ({ name, type: 'any' })) } } },
  codeNode('9. Parse Intent', 'n09.js', 220, 0),
  // Station 1 (sensor path): deterministic lookup by ID. Always outputs an item, empty when no ID or no row.
  { id: uuid(), name: '9b. Lookup Equipment', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [330, 160], alwaysOutputData: true,
    credentials: { postgres: { id: 'AlgoManPgCred0001', name: 'AlgoMan Postgres' } },
    parameters: { operation: 'executeQuery', query: 'SELECT * FROM equipment WHERE equipment_id = $1;', options: { queryReplacement: "={{ $json.equipment_id || 'NO-ID' }}" } } },
  http('10a. Embed Query', 'https://api.fireworks.ai/inference/v1/embeddings',
    "={{ JSON.stringify({ model: 'accounts/fireworks/models/qwen3-embedding-8b', input: $('9. Parse Intent').first().json.search_query, dimensions: 1024 }) }}", FW, 440, 0),
  http('10b. Pinecone Query', `https://${HOST}/query`, '={{ JSON.stringify({ vector: $json.data[0].embedding, topK: 20, includeMetadata: true }) }}', PC, 660, 0),
  codeNode('11. BM25 Search', 'n11.js', 880, 0),
  codeNode('12. Merge Results', 'n12.js', 1100, 0),
  http('13. Rerank', 'https://api.pinecone.io/rerank', '={{ JSON.stringify($json.rerank_body) }}', PC, 1320, 0),
  codeNode('14. Validate', 'n14.js', 1540, 0),
  { id: uuid(), name: '14b. Route', type: 'n8n-nodes-base.if', typeVersion: 2.2, position: [1760, 0], parameters: {
    conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
      conditions: [{ id: uuid(), leftValue: '={{ $json.decision }}', rightValue: 'generate', operator: { type: 'string', operation: 'equals' } }], combinator: 'and' },
    options: {} } },
  codeNode('15. Build Prompt', 'n15.js', 1980, -120),
  http('16. Fireworks LLM', 'https://api.fireworks.ai/inference/v1/chat/completions', '={{ JSON.stringify($json.llm_body) }}', FW, 2200, -120),
  codeNode('15b. Template Response', 'n15b.js', 2090, 120),
  codeNode('17. Format Response', 'n17.js', 2420, 0),
  // After Station 4, same run: alert_log + equipment_status
  { id: uuid(), name: '18a. Log & Update Status', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [2640, 0], alwaysOutputData: true,
    credentials: { postgres: { id: 'AlgoManPgCred0001', name: 'AlgoMan Postgres' } },
    parameters: { operation: 'executeQuery', query: fs.readFileSync(`${__dirname}/sql/sql-status-write.sql`, 'utf8'), options: { queryReplacement: '={{ [JSON.stringify($json)] }}' } } },
  codeNode('19. Return Result', 'n19.js', 2860, 0),
]);
// Branch: 14b true -> LLM path, false -> template path; both end in 17 (the sub-workflow's output)
const to = n => [{ node: n, type: 'main', index: 0 }];
pipeline.connections = { ...chain(pipeline.nodes.slice(0, 10).map(n => n.name)),
  '14b. Route': { main: [to('15. Build Prompt'), to('15b. Template Response')] },
  '15. Build Prompt': { main: [to('16. Fireworks LLM')] },
  '16. Fireworks LLM': { main: [to('17. Format Response')] },
  '15b. Template Response': { main: [to('17. Format Response')] },
  '17. Format Response': { main: [to('18a. Log & Update Status')] },
  '18a. Log & Update Status': { main: [to('19. Return Result')] } };

const runPipeline = (name, x, y) => ({ id: uuid(), name, type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2, position: [x, y],
  parameters: { source: 'database', workflowId: { __rl: true, value: PIPELINE_ID, mode: 'id' },
    workflowInputs: inputMapping({ query: '={{ $json.body.query }}', equipment_id: '={{ $json.body.equipment_id }}', timestamp: '={{ $json.body.timestamp }}', source: "={{ $json.body.source || 'sensor' }}" }),
    options: { waitForSubWorkflow: true } } });

const query = wf('AlgoFactory - 2 Query', [
  { id: uuid(), name: '8. Webhook', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 0], webhookId: uuid(), parameters: { httpMethod: 'POST', path: 'anomaly-check', responseMode: 'responseNode', options: {} } },
  runPipeline('Run Pipeline (Stations 1-4)', 220, 0),
  { id: uuid(), name: '18. Respond to Webhook', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [440, 0], parameters: { respondWith: 'firstIncomingItem', options: {} } },
]);

const statusJob = wf('AlgoFactory - 6 Status Job', [
  { id: uuid(), name: 'Every 15 Minutes', type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.2, position: [0, 0], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 15 }] } } },
  { id: uuid(), name: 'Run Now', type: 'n8n-nodes-base.manualTrigger', typeVersion: 1, position: [0, 180], parameters: {} },
  codeNode('Active Schedule Windows', 'n_job.js', 220, 0),
  { id: uuid(), name: 'Apply Status Rules', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [440, 0], alwaysOutputData: true,
    credentials: { postgres: { id: 'AlgoManPgCred0001', name: 'AlgoMan Postgres' } },
    parameters: { operation: 'executeQuery', query: fs.readFileSync(`${__dirname}/sql/sql-status-job.sql`, 'utf8'), options: { queryReplacement: '={{ [$json.active_ids] }}' } } },
]);
statusJob.connections = {
  'Every 15 Minutes': { main: [[{ node: 'Active Schedule Windows', type: 'main', index: 0 }]] },
  'Run Now': { main: [[{ node: 'Active Schedule Windows', type: 'main', index: 0 }]] },
  'Active Schedule Windows': { main: [[{ node: 'Apply Status Rules', type: 'main', index: 0 }]] } };
fs.writeFileSync(`${__dirname}/out/wf-status-job.json`, JSON.stringify(statusJob, null, 2));
// Chatbot: Chat Trigger -> AI Agent (gpt-oss-120b on Fireworks via the OpenAI-compatible API) with memory and 3 tools
const OPENAI_CRED = { openAiApi: { id: process.env.OPENAI_CRED_ID || 'SET_ME', name: process.env.OPENAI_CRED_NAME || 'Fireworks (OpenAI API)' } };
const PG = { postgres: { id: 'AlgoManPgCred0001', name: 'AlgoMan Postgres' } };
const pgTool = (name, description, query, arg, argDesc, x) => ({ id: uuid(), name, type: 'n8n-nodes-base.postgresTool', typeVersion: 2.5, position: [x, 260], credentials: PG,
  parameters: { descriptionType: 'manual', toolDescription: description, operation: 'executeQuery', query,
    options: { queryReplacement: `={{ $fromAI('${arg}', '${argDesc}', 'string') }}` } } });
const chat = wf('AlgoFactory - 4 Chat', [
  { id: uuid(), name: 'Worker Chat', type: '@n8n/n8n-nodes-langchain.chatTrigger', typeVersion: 1.1, position: [0, 0], webhookId: 'a1f0c4e2-7b3d-4e5f-9a6b-1c2d3e4f5a6b',
    parameters: { public: true, mode: 'hostedChat', initialMessages: 'Hi! Tell me what you see on a machine, or ask: How are my machines doing?',
      options: { title: 'AlgoFactory', subtitle: 'Floor assistant', responseMode: 'lastNode' } } },
  { id: uuid(), name: 'AI Agent', type: '@n8n/n8n-nodes-langchain.agent', typeVersion: 2.2, position: [300, 0],
    parameters: { promptType: 'auto', options: { systemMessage: fs.readFileSync(`${__dirname}/chat-system.txt`, 'utf8'), returnIntermediateSteps: true, maxIterations: 6 } } },
  { id: uuid(), name: 'Fireworks gpt-oss-120b', type: '@n8n/n8n-nodes-langchain.lmChatOpenAi', typeVersion: 1.2, position: [0, 260], credentials: OPENAI_CRED,
    parameters: { model: { __rl: true, mode: 'id', value: 'accounts/fireworks/models/gpt-oss-120b' }, options: { temperature: 0 } } },
  { id: uuid(), name: 'Chat Memory', type: '@n8n/n8n-nodes-langchain.memoryBufferWindow', typeVersion: 1.3, position: [160, 260], parameters: { contextWindowLength: 10 } },
  pgTool('lookup_equipment', 'Find machines by name or ID. Input: the machine words exactly as the worker wrote them. Returns 0, 1 or several rows with equipment_id, name, type, site, line, status.',
    'SELECT * FROM lookup_equipment($1);', 'name_or_id', 'Machine name or ID as the worker wrote it, e.g. Pump 2, Equipment-001, motor', 320),
  pgTool('get_equipment_status', 'Status summary with exact counts. Input: all, a site (Austin, Columbus, Fremont, Denver, Minneapolis, Miami, Seattle), a state, region, line, or a machine. Returns total, by_status counts, and needs_attention (every machine not normal, with reason).',
    'SELECT * FROM get_status_summary($1);', 'scope', 'all, a site, state, region, line, or a machine name or ID', 480),
  { id: uuid(), name: 'check_alert', type: '@n8n/n8n-nodes-langchain.toolWorkflow', typeVersion: 2.2, position: [640, 260],
    parameters: { description: 'Run the AlgoFactory checks (evidence, sensors, schedule, baseline, history) for one identified machine. Call only after lookup_equipment returned exactly one row. Returns action (ACT/HOLD/ESCALATE), confidence_score, explanation and response.',
      workflowId: { __rl: true, value: PIPELINE_ID, mode: 'id' },
      workflowInputs: inputMapping({ query: "={{ $fromAI('query', 'The worker message, verbatim', 'string') }}", equipment_id: "={{ $fromAI('equipment_id', 'equipment_id from lookup_equipment, e.g. Equipment-008', 'string') }}", timestamp: '', source: 'chat' }) } },
]);
const ai = type => ({ [type]: [[{ node: 'AI Agent', type, index: 0 }]] });
chat.connections = {
  'Worker Chat': { main: [[{ node: 'AI Agent', type: 'main', index: 0 }]] },
  'Fireworks gpt-oss-120b': ai('ai_languageModel'),
  'Chat Memory': ai('ai_memory'),
  'lookup_equipment': ai('ai_tool'),
  'get_equipment_status': ai('ai_tool'),
  'check_alert': ai('ai_tool') };
fs.writeFileSync(`${__dirname}/out/wf-chat.json`, JSON.stringify(chat, null, 2));
// Floor API: the dashboard page plus JSON endpoints, all served by n8n on one origin
const FLOOR_SQL = require(`${__dirname}/sql-floor.js`);
const DASHBOARD_HTML = fs.readFileSync(`${__dirname}/../dashboard/AlgoFactory-dashboard.html`, 'utf8');
const floorNodes = [], floorConn = {};
function endpoint(key, method, path, y, sql, params) {
  const hook = `${key}: ${method} /${path}`, db = `${key}: Query`, out = `${key}: Respond`;
  floorNodes.push(
    { id: uuid(), name: hook, type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, y], webhookId: uuid(),
      parameters: { httpMethod: method, path, responseMode: 'responseNode', options: {} } });
  if (sql) {
    floorNodes.push({ id: uuid(), name: db, type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [240, y], alwaysOutputData: true, credentials: PG,
      parameters: { operation: 'executeQuery', query: sql, options: params ? { queryReplacement: params } : {} } });
    floorNodes.push({ id: uuid(), name: out, type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [480, y],
      parameters: { respondWith: 'firstIncomingItem', options: { responseHeaders: { entries: [{ name: 'Cache-Control', value: 'no-store' }] } } } });
    floorConn[hook] = { main: [[{ node: db, type: 'main', index: 0 }]] };
    floorConn[db] = { main: [[{ node: out, type: 'main', index: 0 }]] };
  } else {
    floorNodes.push({ id: uuid(), name: out, type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [240, y],
      parameters: { respondWith: 'text', responseBody: DASHBOARD_HTML,
        options: { responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }, { name: 'Cache-Control', value: 'no-store' }] } } } });
    floorConn[hook] = { main: [[{ node: out, type: 'main', index: 0 }]] };
  }
}
endpoint('Dashboard', 'GET', 'floor', 0, null);
endpoint('Equipment', 'GET', 'floor/equipment', 180, FLOOR_SQL.equipment);
endpoint('Alerts', 'GET', 'floor/alerts', 360, FLOOR_SQL.alerts, "={{ [$json.query.date || 'today'] }}");
endpoint('History', 'GET', 'floor/history', 540, FLOOR_SQL.history,
  "={{ [$json.query.equipment_id || 'NO-ID', String(Math.min(168, Math.max(1, Number($json.query.hours) || 24)))] }}");
endpoint('Reset', 'POST', 'floor/reset', 720, FLOOR_SQL.reset, "={{ [$json.body.equipment_id || 'NO-ID'] }}");
const floor = wf('AlgoFactory - 5 Floor API', floorNodes);
floor.connections = floorConn;
fs.writeFileSync(`${__dirname}/out/wf-floor.json`, JSON.stringify(floor, null, 2));
fs.writeFileSync(`${__dirname}/out/wf-ingest.json`, JSON.stringify(ingest, null, 2));
fs.writeFileSync(`${__dirname}/out/wf-pipeline.json`, JSON.stringify(pipeline, null, 2));
fs.writeFileSync(`${__dirname}/out/wf-query.json`, JSON.stringify(query, null, 2));
console.log(ingest.id, pipeline.id, query.id);
