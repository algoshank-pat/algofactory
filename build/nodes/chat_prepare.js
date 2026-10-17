// Chat: Prepare Prompt. Hands the agent the worker's message plus the run id the trace uses.
// Input: Run Start (Postgres) -> { run_id }. The message and session come from the Chat Trigger.
const msg = $('Worker Chat').first().json;
return [{ json: { chatInput: msg.chatInput, sessionId: msg.sessionId, run_id: $input.first().json.run_id } }];
