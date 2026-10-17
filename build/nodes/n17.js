// Node 17: Format the final response
// Inputs: $input -> Node 16 Fireworks response, $('14. Validate') -> scores, $('9. Parse Intent') -> start time

const v = $('14. Validate').first().json;
const started = $('9. Parse Intent').first().json.started_at;
const llm = $input.first().json;
const ACTION = { 'ALERT': 'ACT', 'FALSE POSITIVE': 'HOLD', 'NEEDS INVESTIGATION': 'ESCALATE' };
const text = llm.choices?.[0]?.message?.content?.trim() || 'Unable to generate response.';

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
    response_source: llm.source || 'llm',
    model: llm.source === 'template' ? null : (llm.model || 'accounts/fireworks/models/gpt-oss-120b'),
    run_id: v.run_id,
    t14_end: v.t_end,
    latency_sec: +((Date.now() - started) / 1000).toFixed(2),
    timestamp: new Date().toISOString()
  }
}];
