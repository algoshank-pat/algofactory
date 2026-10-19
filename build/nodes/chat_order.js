// Chat: Order Trace. Builds the final step list for the run:
//   Prompt -> LLM call 1 -> tool call(s) it chose -> LLM call 2 -> ... -> LLM call N (reply)
// Tool steps were written live by Postgres (lookup/status wrappers, check_alert's Stations 1-4 + write-back).
// LLM call details (tool chosen, reasoning note, tokens) only exist in the agent's intermediate steps, so they are added here.
// LLM call times are estimates: the gap between the previous step and the next tool call.
const agent = $('AI Agent').first().json;
const run = $input.first().json;
const live = run.steps || [];
const started = Number(run.started_ms) || Date.now();

// One LLM call per distinct model message; parallel tool calls from the same message share it
const calls = [];
for (const st of agent.intermediateSteps || []) {
  const k = st.action?.messageLog?.[0]?.kwargs || {};
  const id = k.id || st.action?.toolCallId;
  let c = calls[calls.length - 1];
  if (!c || c.id !== id) {
    c = { id, tools: [], reasoning: String(k.additional_kwargs?.reasoning_content || '').trim(),
          tokens: k.response_metadata?.tokenUsage || null, model: k.response_metadata?.model_name || null };
    calls.push(c);
  }
  c.tools.push({ tool: st.action.tool, args: st.action.toolInput });
}

// Split live steps into the prompt part and one group per tool call
const isToolStart = s => s.station === 'Tool' || (s.station === 'Station 1' && /^check_alert/.test(s.step));
const head = [], groups = [];
for (const s of live) {
  if (isToolStart(s)) groups.push([s]);
  else if (groups.length) groups[groups.length - 1].push(s);
  else head.push(s);
}

const fmtArgs = a => Object.values(a || {}).map(v => JSON.stringify(v)).join(', ');
const out = [...head];
let anchor = head.length ? Number(head[head.length - 1].created_ms) : started;
let g = 0;
const model = calls.find(c => c.model)?.model || 'accounts/fireworks/models/gpt-oss-120b';
calls.forEach((c, i) => {
  const next = groups[g];
  const toolStartMs = next ? Number(next[0].created_ms) - (Number(next[0].ms) || 0) : Date.now();
  out.push({
    station: 'LLM', step: `LLM call ${i + 1} -> ${c.tools.map(t => `${t.tool}(${fmtArgs(t.args)})`).join(' + ')}`,
    ms: Math.max(0, Math.round(toolStartMs - anchor)), created_at: new Date(Math.max(anchor, toolStartMs - 1)).toISOString(),
    detail: { model, chose: c.tools, reasoning: c.reasoning.slice(0, 600), tokens: c.tokens, ms_estimated: true }
  });
  for (let k = 0; k < c.tools.length && g < groups.length; k++) {
    out.push(...groups[g]);
    anchor = Number(groups[g][groups[g].length - 1].created_ms);
    g++;
  }
});
while (g < groups.length) { out.push(...groups[g]); anchor = Number(groups[g][groups[g].length - 1].created_ms); g++; }

// Final reply, made exact where the data allows (the model tended to reword numbers):
// - status answers: the SQL summary_text, word for word
// - machine checks: the header line (label, machine, site/line, confidence) is built from the tool results;
//   only the model's plain-language sentence is kept
const allSteps = agent.intermediateSteps || [];
const parseObs = o => { try { return typeof o === 'string' ? JSON.parse(o) : o; } catch { return null; } };
const firstRow = o => [].concat(parseObs(o) || [])[0] || null;
const lastOf = tool => [...allSteps].reverse().find(s => s.action?.tool === tool);
const statusStep = lastOf('get_equipment_status'), checkStep = lastOf('check_alert');
let reply = String(agent.output || '');
if (checkStep) {
  const r = firstRow(checkStep.observation);
  if (r && r.action) {
    const label = { ACT: 'ACT NOW', HOLD: 'HOLD', ESCALATE: 'CHECK' }[r.action] || r.action;
    const found = allSteps.filter(s => s.action?.tool === 'lookup_equipment')
      .flatMap(s => [].concat(parseObs(s.observation) || [])).find(x => x && x.equipment_id === r.equipment_id) || null;
    const where = found ? ` (${found.site}, ${found.line})` : '';
    const header = `${label} · ${r.equipment_name || r.equipment_id || 'Unknown machine'}${where} · ${r.confidence_score}%`;
    const body = reply.split(/\r?\n/).map(l => l.trim()).filter(l => l && !/^(ACT NOW|ACT|HOLD|CHECK|ESCALATE|IN MAINTENANCE|OK)\b/.test(l)).join(' ');
    reply = body ? header + '\n' + body : header;
  }
} else if (statusStep) {
  const r = firstRow(statusStep.observation);
  if (r && r.summary_text) reply = r.summary_text;
}
out.push({ station: 'LLM', step: `LLM call ${calls.length + 1} -> reply to the worker`, ms: Math.max(0, Date.now() - anchor),
           created_at: new Date().toISOString(), detail: { model, reply, ms_estimated: true } });

// Run summary for the Activity log
const s4 = out.find(s => s.station === 'Station 4');
const wb = out.find(s => s.station === 'Write-back');
const s1 = out.find(s => s.station === 'Station 1');
const lookups = out.filter(s => s.detail?.tool === 'lookup_equipment');
const lastLookup = lookups[lookups.length - 1];
const usedStatus = calls.some(c => c.tools.some(t => t.tool === 'get_equipment_status'));
const summary = {
  equipment_id: wb?.detail?.equipment_id || s1?.detail?.db_lookup?.equipment_id
    || (lastLookup?.detail?.matches === 1 ? lastLookup.detail.found[0].equipment_id : null),
  decision: s4?.detail?.decision || (usedStatus ? 'STATUS' : /\?/.test(reply) ? 'ASKED' : 'ANSWERED'),
  confidence: s4?.detail?.confidence ?? null,
  llm_calls: calls.length + 1,
  tool_calls: calls.reduce((n, c) => n + c.tools.length, 0),
  reply: reply.slice(0, 1000)
};

const steps = out.map(({ station, step, detail, ms, created_at }) => ({ station, step, detail, ms, created_at }));
return [{ json: { run_id: run.run_id, steps, summary, final_reply: reply } }];
