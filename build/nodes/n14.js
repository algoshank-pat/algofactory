// Node 14: 5-layer contextual validation (Layer 0 + the 4 design layers)
// Inputs:
//   $input            -> Node 13 rerank response { data: [{ index, score }] }
//   $('9. Parse Intent')   -> equipment_id, anomaly_type, sensor_type, sensor_value, timestamp
//   $('12. Merge Results') -> candidates (the documents sent to rerank, same order)
//   $('9b. Lookup Equipment') -> equipment row from Postgres
//   /data/*.json -> schedules, baselines

const fs = require('fs');
const intent = $('9. Parse Intent').first().json;
const candidates = $('12. Merge Results').first().json.candidates || [];
const rerank = $input.first().json.data || [];

const { equipment_id, anomaly_type, sensor_type, sensor_value, timestamp, raw_query } = intent;

// ----- Tunable weights (adjust after the first test run) -----
const W = {
  RETRIEVAL_MAX: 50,        // Layer 0: top rerank score (0-1) x 50
  SENSOR_EXCEEDS: 40,       // Layer 1: at or above rated limit
  SENSOR_NEAR: 20,          // Layer 1: within 10% of limit
  SYMPTOM_ONLY: 25,         // Layer 1: specific symptom words, no reading
  NO_EXPLANATION: 5,        // Layer 2: validated reading and nothing scheduled explains it
  SCHEDULE_EXPLAINS: -40,   // Layer 2: active cleaning/maintenance explains the reading
  MAINTENANCE_ACTIVE: -15,  // Layer 2: equipment in maintenance, anomalies expected
  BASELINE_NORMAL: -15,     // Layer 3: within expected range for current conditions
  RECURRING: -5,            // Layer 4: explained by a weekly recurring schedule
  BENIGN_CAP: 10,           // Confirmed scheduled cause caps confidence
  THRESHOLD: 60             // >= generate, < escalate
};

// ----- Reference data -----
const readJson = (f, key) => { try { return JSON.parse(fs.readFileSync(f, 'utf8'))[key] || []; } catch (e) { return []; } };
const schedules = readJson('/data/maintenance_schedule.json', 'schedules');
const baselines = readJson('/data/environmental_baselines.json', 'baselines');

// Equipment spec from Postgres (Station 1, Node 9b). Empty item when no ID was given or no row matched.
const row = $('9b. Lookup Equipment').first().json;
const equipment = row && row.equipment_id ? row : null;

// ----- Clock: request timestamp, PLANT_CLOCK env var, or now (local plant time) -----
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
function clock() {
  // Request timestamp, else PLANT_CLOCK (tests/demo), else now
  const m = (timestamp || $env.PLANT_CLOCK || '').match(/(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/);
  if (m) {
    const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
    return { day: DAYS[d.getUTCDay()], hour: +m[4] + +m[5] / 60, month: +m[2] - 1 };
  }
  return { day: $now.weekdayLong, hour: $now.hour + $now.minute / 60, month: $now.month - 1 };
}
const now = clock();
const toHour = t => { const [h, mi] = (t || '00:00').split(':').map(Number); return h + mi / 60; };

// Schedules for this equipment active right now: same weekday, between start and end + grace hours
function activeSchedules(graceHours) {
  return schedules.filter(s => {
    if (s.equipment_id !== equipment_id) return false;
    if (s.day_of_week && s.day_of_week !== now.day) return false;
    const start = toHour(s.time);
    return now.hour >= start && now.hour <= start + (s.duration_hours || 1) + graceHours;
  });
}

const topChunks = rerank.map(r => ({ ...candidates[r.index], rerank_score: r.score }));
const reasons = {};

// ===== LAYER 0: Retrieval relevance (0 to 50) =====
// How well the knowledge base supports a diagnosis for this query
function layer0() {
  const top = topChunks.length ? topChunks[0].rerank_score : 0;
  reasons.layer0 = `Top rerank score ${top.toFixed(2)}`;
  return Math.round(top * W.RETRIEVAL_MAX);
}

// ===== LAYER 1: Sensor cross-check (0 to 40) =====
function layer1() {
  if (sensor_value == null) {
    const specific = /\bhot\b|overheat|burning|smok|grind|vibrat|shak|leak|whistl|hiss/i.test(raw_query);
    reasons.layer1 = specific ? 'No reading; specific symptom reported' : 'No reading; vague report';
    return specific ? W.SYMPTOM_ONLY : 0;
  }
  let limit = null, label = '';
  if (sensor_type === 'temperature') {
    limit = equipment ? +equipment.max_temp_c : 80; label = 'max_temp_c';
  } else if (sensor_type === 'vibration') {
    limit = equipment ? +equipment.max_vibration_mm_s : 7.1; label = 'max_vibration_mm_s';
  } else if (sensor_type === 'humidity') {
    const b = baselines.find(x => x.equipment_id === equipment_id && x.humidity_baseline != null);
    limit = (b ? b.humidity_baseline : 50) + 15; label = 'humidity baseline + 15';
  }
  if (limit == null) { reasons.layer1 = `No limit for sensor type ${sensor_type}`; return 0; }
  if (sensor_value >= limit) { reasons.layer1 = `${sensor_value} >= ${label} ${limit}`; return W.SENSOR_EXCEEDS; }
  if (sensor_value >= limit * 0.9) { reasons.layer1 = `${sensor_value} within 10% of ${label} ${limit}`; return W.SENSOR_NEAR; }
  reasons.layer1 = `${sensor_value} below ${label} ${limit}`;
  return 0;
}

// ===== LAYER 2: Schedule context (-40 to +5) =====
let explainingSchedule = null;
function layer2(l1) {
  const active = activeSchedules(1);
  for (const s of active) {
    if (s.method === 'wet-wash' && sensor_type === 'humidity') {
      const b = baselines.find(x => x.equipment_id === equipment_id && x.humidity_baseline != null);
      const expectedMax = (b ? b.humidity_baseline : 50) + (s.expected_humidity_elevation || 20) + 5;
      if (sensor_value == null || sensor_value <= expectedMax) {
        explainingSchedule = s;
        reasons.layer2 = `${s.method} ${s.schedule_type} ${s.day_of_week || ''} ${s.time} (${s.duration_hours}h) explains humidity up to ${expectedMax}%`;
        return W.SCHEDULE_EXPLAINS;
      }
    }
    if (s.method === 'wet-wash' && sensor_type === 'acoustic') {
      explainingSchedule = s;
      reasons.layer2 = `Wet-wash at ${s.time} causes acoustic false positives`;
      return W.SCHEDULE_EXPLAINS;
    }
    if (/maintenance|replacement/.test(`${s.schedule_type} ${s.method}`)) {
      reasons.layer2 = `${s.method} in progress since ${s.time}; anomalies expected`;
      return W.MAINTENANCE_ACTIVE;
    }
  }
  if (l1 >= W.SENSOR_EXCEEDS) { reasons.layer2 = 'Nothing scheduled explains the reading'; return W.NO_EXPLANATION; }
  reasons.layer2 = 'No active schedule';
  return 0;
}

// ===== LAYER 3: Environmental baseline (-25 to 0) =====
function layer3() {
  let score = 0;
  for (const b of baselines.filter(x => x.equipment_id === equipment_id)) {
    if (b.condition === 'post_cleaning' && sensor_type === 'humidity' && sensor_value != null) {
      const inWindow = activeSchedules(b.humidity_elevated_for_hours || 2).some(s => /wash|clean/.test(`${s.method} ${s.schedule_type}`));
      if (inWindow && sensor_value <= b.humidity_max_expected) {
        reasons.layer3 = `Post-cleaning max expected ${b.humidity_max_expected}%; reading ${sensor_value}% is normal`;
        score = Math.min(score, W.BASELINE_NORMAL);
      }
    }
    if (b.condition === 'summer_season' && sensor_type === 'temperature' && sensor_value != null) {
      if (now.month >= 5 && now.month <= 7 && sensor_value <= b.temperature_max_expected) {
        reasons.layer3 = `Summer max expected ${b.temperature_max_expected}°C; reading is normal`;
        score = Math.min(score, -10);
      }
    }
  }
  if (!reasons.layer3) reasons.layer3 = 'No baseline condition applies';
  return score;
}

// ===== LAYER 4: Historical pattern (-5 to 0) =====
// A weekly recurring schedule that explains the reading means this alert repeats every week
function layer4() {
  if (explainingSchedule && explainingSchedule.day_of_week) {
    reasons.layer4 = `Recurs every ${explainingSchedule.day_of_week} with the ${explainingSchedule.schedule_type}`;
    return W.RECURRING;
  }
  reasons.layer4 = 'No recurring benign pattern';
  return 0;
}

const layerScores = {};
layerScores.layer0 = layer0();
layerScores.layer1 = layer1();
layerScores.layer2 = layer2(layerScores.layer1);
layerScores.layer3 = layer3();
layerScores.layer4 = layer4();

const raw = Object.values(layerScores).reduce((a, b) => a + b, 0);
let confidence = Math.max(0, Math.min(100, raw));
if (layerScores.layer2 === W.SCHEDULE_EXPLAINS) confidence = Math.min(confidence, W.BENIGN_CAP);

const decision = confidence >= W.THRESHOLD ? 'generate' : 'escalate';
const status = decision === 'generate' ? 'ALERT'
  : (layerScores.layer2 === W.SCHEDULE_EXPLAINS || layerScores.layer3 < 0) ? 'FALSE POSITIVE'
  : 'NEEDS INVESTIGATION';
const needs_clarification = !equipment_id && sensor_value == null && layerScores.layer1 === 0;

let explanation = '';
if (status === 'FALSE POSITIVE') explanation = `${reasons.layer2}. ${reasons.layer3}.`;
else if (status === 'ALERT') explanation = `${reasons.layer1}. ${reasons.layer2}.`;
else explanation = needs_clarification
  ? 'Query is too vague: no equipment ID or sensor reading. Ask the operator which equipment and what was observed.'
  : `${reasons.layer1}. Evidence is not strong enough to diagnose.`;

// When a cleaning explains the reading: hour the elevated reading should clear (start + duration + elevated window)
let recovery_time = null;
if (explainingSchedule) {
  const b = baselines.find(x => x.equipment_id === equipment_id && x.condition === 'post_cleaning');
  const end = toHour(explainingSchedule.time) + (explainingSchedule.duration_hours || 1) + (b?.humidity_elevated_for_hours || 0);
  recovery_time = `${String(Math.floor(end)).padStart(2, '0')}:${String(Math.round((end % 1) * 60)).padStart(2, '0')}`;
}

return [{
  json: {
    equipment_id, anomaly_type, sensor_type, sensor_value, timestamp, raw_query,
    equipment_spec: equipment, recovery_time,
    confidence, raw_score: raw, layerScores, reasons,
    decision, status, needs_clarification, explanation,
    topChunks: topChunks.map(c => ({ id: c.id, text: c.text, metadata: c.metadata, rerank_score: c.rerank_score }))
  }
}];
