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
