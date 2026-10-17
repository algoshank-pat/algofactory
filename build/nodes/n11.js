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
