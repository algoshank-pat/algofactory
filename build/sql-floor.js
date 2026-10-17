// Floor API queries. Each returns exactly one row so the webhook always answers with one JSON object.
const TZ = `'America/Los_Angeles'`;

module.exports = {
  equipment: `
SELECT coalesce(json_agg(r ORDER BY r.site, r.line, r.name), '[]') AS equipment
FROM (
  SELECT e.equipment_id, e.name, e.type, e.site, e.state, e.region, e.line, e.location,
         e.max_temp_c, e.max_vibration_mm_s, e.bearing_type,
         s.status, s.reason, s.last_reading, s.updated_at,
         (SELECT count(*) FROM alert_log a
           WHERE a.equipment_id = e.equipment_id
             AND (a.created_at AT TIME ZONE ${TZ})::date = (now() AT TIME ZONE ${TZ})::date)::int AS alerts_today
  FROM equipment e JOIN equipment_status s USING (equipment_id)
) r;`,

  alerts: `
WITH d AS (SELECT CASE WHEN $1 = 'today' THEN (now() AT TIME ZONE ${TZ})::date ELSE $1::date END AS day)
SELECT (SELECT day FROM d)::text AS date, coalesce(json_agg(r ORDER BY r.created_at DESC), '[]') AS alerts
FROM (
  SELECT a.id, a.created_at, a.equipment_id, e.name, e.site, e.line, a.input_source, a.summary,
         a.decision, a.confidence, a.reason
  FROM alert_log a LEFT JOIN equipment e USING (equipment_id), d
  WHERE (a.created_at AT TIME ZONE ${TZ})::date = d.day
) r;`,

  history: `
SELECT e.equipment_id, e.name, e.type, e.site, e.line, e.location, e.max_temp_c, e.max_vibration_mm_s,
       s.status, s.reason, s.last_reading, s.updated_at, $2::int AS hours,
       coalesce((SELECT json_agg(x ORDER BY x.created_at DESC) FROM (
          SELECT id, created_at, input_source, summary, decision, confidence, reason
          FROM alert_log WHERE equipment_id = $1 AND created_at >= now() - make_interval(hours => $2::int)) x), '[]') AS alerts
FROM equipment e JOIN equipment_status s USING (equipment_id)
WHERE e.equipment_id = $1;`,

  reset: `
WITH r AS (
  UPDATE equipment_status SET status = 'normal', reason = 'Reset from dashboard', updated_at = now()
  WHERE equipment_id = $1 RETURNING equipment_id
), l AS (
  INSERT INTO alert_log (equipment_id, input_source, summary, decision, confidence, reason)
  SELECT equipment_id, 'dashboard', 'Status reset from dashboard', 'RESET', NULL, 'Technician reset' FROM r
  RETURNING id
)
SELECT (SELECT count(*) FROM r)::int AS reset, $1 AS equipment_id, (SELECT id FROM l) AS alert_id;`,
  // Chat runs for the Activity log. $1 = limit, $2 = plant ('' = all), $3 = decision ('' = all)
  runs: `
SELECT coalesce(json_agg(x ORDER BY x.started_at DESC), '[]') AS runs
FROM (
  SELECT r.run_id, r.started_at, r.input, r.status, r.equipment_id, e.name, e.site, r.decision, r.confidence,
         r.llm_calls, r.tool_calls,
         coalesce(r.total_ms, round(extract(epoch FROM now() - r.started_at) * 1000)::int) AS total_ms,
         (r.status = 'running' AND r.started_at < now() - interval '2 minutes') AS stalled
  FROM runs r LEFT JOIN equipment e USING (equipment_id)
  WHERE ($2 = '' OR e.site = $2 OR lower(split_part(e.site, ' ', 1)) = lower($2))
    AND ($3 = '' OR r.decision = upper($3))
  ORDER BY r.started_at DESC
  LIMIT least(greatest($1::int, 1), 200)
) x;`,

  // One run with all of its steps. $1 = run id
  run: `
SELECT r.run_id, r.started_at, r.finished_at, r.input, r.status, r.equipment_id, e.name, e.site, r.decision, r.confidence,
       r.llm_calls, r.tool_calls, r.reply,
       coalesce(r.total_ms, round(extract(epoch FROM now() - r.started_at) * 1000)::int) AS total_ms,
       (r.status = 'running' AND r.started_at < now() - interval '2 minutes') AS stalled,
       coalesce((SELECT json_agg(json_build_object('step_no', t.step_no, 'station', t.station, 'step', t.step, 'detail', t.detail,
                                                   'ms', t.ms, 'created_at', t.created_at) ORDER BY t.step_no)
                 FROM run_trace t WHERE t.run_id = r.run_id), '[]') AS steps
FROM runs r LEFT JOIN equipment e USING (equipment_id)
WHERE r.run_id = as_uuid($1);`
};
