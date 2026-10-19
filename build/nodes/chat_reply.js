// Chat: Reply. The Chat Trigger returns the last node's output: the final reply built by Order Trace
// (exact status summary or tool-based header + the model's sentence), plus the agent's tool steps and the run id.
const agent = $('AI Agent').first().json;
return [{ json: { output: $('Order Trace').first().json.final_reply, intermediateSteps: agent.intermediateSteps, run_id: $('Prepare Prompt').first().json.run_id } }];
