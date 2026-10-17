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
