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
