// Node 9: Parse intent from the webhook body
// Input: Webhook item. Body: { "query": "Equipment-001 humidity 75%", "timestamp": "2026-10-19T08:30" }
// timestamp is optional (local plant time, no "Z"). Omit it to use the current time.

const item = $input.first().json;
const body = item.body || item;            // Webhook node puts the payload under "body"
const query = (body.query || "").trim();
const timestamp = body.timestamp || null;
const source = body.source || 'sensor';      // sensor | chat | test | dashboard
const run_id = body.run_id || null;            // set only for chat runs (process trace)

// Equipment ID
const equipmentMatch = query.match(/Equipment-(\d{3})/i);
// The chatbot passes the ID it resolved with lookup_equipment; sensor alerts carry it in the text
const equipment_id = body.equipment_id || (equipmentMatch ? `Equipment-${equipmentMatch[1]}` : null);

// Anomaly code (TH/VB/AC) or sensor type
let anomaly_type = null;
let sensor_type = null;
const codeMatch = query.match(/\b(TH|VB|AC)-\d{3}\b/i);

if (codeMatch) {
  anomaly_type = codeMatch[0].toUpperCase();
  sensor_type = { TH: "temperature", VB: "vibration", AC: "acoustic" }[anomaly_type.slice(0, 2)];
} else if (/humid|moisture|\bwet\b/i.test(query)) {
  // Checked before acoustic: "humidity" contains "hum"
  anomaly_type = "ENV-HUMIDITY";           // No signature in anomaly_patterns.md; environmental reading
  sensor_type = "humidity";
} else if (/temp|heat|\bhot\b|thermal|overheat/i.test(query)) {
  anomaly_type = "TH-001";
  sensor_type = "temperature";
} else if (/vibrat|shak|wobbl/i.test(query)) {
  anomaly_type = "VB-001";
  sensor_type = "vibration";
} else if (/noise|sound|acoustic|squeak|whistl|hiss|grind|\bhum\b|buzz/i.test(query)) {
  anomaly_type = "AC-001";
  sensor_type = "acoustic";
}

// Sensor value: number followed by a unit
let sensor_value = null;
const valueMatch = query.match(/(\d+(?:\.\d+)?)\s*(°\s?C|°\s?F|mm\/s|dB|%|C\b|F\b)/i);
if (valueMatch) sensor_value = parseFloat(valueMatch[1]);

// Query rewriting: when the anomaly was inferred from symptom words, add the domain terms the docs use
const EXPANSION = {
  temperature: "thermal overload temperature exceeds max_temp_c",
  vibration: "vibration bearing wear signature",
  acoustic: "acoustic noise",
  humidity: "humidity environmental baseline cleaning"
};
const search_query = codeMatch || !sensor_type ? query : `${query} ${anomaly_type} ${EXPANSION[sensor_type]}`;

return [{
  json: {
    equipment_id,
    anomaly_type,
    sensor_type,
    sensor_value,
    timestamp,
    raw_query: query,
    run_id,
    source,
    search_query,
    started_at: Date.now()                  // For latency measurement in Node 17
  }
}];
