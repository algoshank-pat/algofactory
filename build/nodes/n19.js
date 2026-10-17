// Node 19: Return the pipeline result (the sub-workflow returns the last node's output)
const result = $('17. Format Response').first().json;
const st = $('18a. Log & Update Status').first().json;
return [{ json: { ...result, equipment_status: st.status || null } }];
