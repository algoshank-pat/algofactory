-- 9b: Station 1 equipment lookup by ID (deterministic, no LLM). Always returns one row: the machine's columns,
-- or NULLs when there is no ID or no match. For chat runs it also writes the Station 1 trace step.
-- $1 = equipment_id (or 'NO-ID'), $2 = run_id ('' for sensor alerts), $3 = parsed intent JSON
WITH p AS (
  SELECT $1::text AS eid, as_uuid($2) AS rid, $3::jsonb AS intent,
         round(extract(epoch FROM clock_timestamp()) * 1000)::bigint AS now_ms
),
e AS (SELECT * FROM equipment WHERE equipment_id = (SELECT eid FROM p)),
t AS (
  SELECT trace_add_steps(p.rid, jsonb_build_array(jsonb_build_object(
    'station', 'Station 1',
    'step', 'check_alert -> Understand: ' || coalesce((SELECT name || ' (' || equipment_id || ')' FROM e), 'no machine')
            || coalesce(', ' || (p.intent->>'sensor_type') || ' ' || coalesce(p.intent->>'sensor_value', ''), ''),
    'detail', jsonb_build_object(
      'tool', 'check_alert',
      'args', jsonb_build_object('query', p.intent->>'raw_query', 'equipment_id', p.intent->>'equipment_id'),
      'parsed', p.intent - 'raw_query' - 'started_at' - 'run_id',
      'db_lookup', (SELECT jsonb_build_object('equipment_id', equipment_id, 'name', name, 'site', site, 'line', line,
                                              'max_temp_c', max_temp_c, 'max_vibration_mm_s', max_vibration_mm_s) FROM e)),
    'ms', p.now_ms - (p.intent->>'started_at')::bigint))) AS traced
  FROM p
)
SELECT e.*, p.now_ms AS t_station1
FROM p CROSS JOIN t LEFT JOIN e ON true;
