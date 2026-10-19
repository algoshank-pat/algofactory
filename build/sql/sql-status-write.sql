-- 18a: log every alert; update the machine's status when it was identified.
-- ACT -> fault, HOLD -> explained, ESCALATE -> watch. A later reading replaces the status (that is how faults clear);
-- a report without a reading cannot downgrade a fault or maintenance.
-- For chat runs (run_id set) it also writes the Station 4 and Write-back trace steps.
WITH p AS (SELECT $1::jsonb AS j, round(extract(epoch FROM clock_timestamp()) * 1000)::bigint AS now_ms),
r AS (SELECT as_uuid(j->>'run_id') AS rid FROM p),
eq AS (SELECT e.equipment_id FROM equipment e, p WHERE e.equipment_id = p.j->>'equipment_id'),
old AS (SELECT s.status FROM equipment_status s WHERE s.equipment_id = (SELECT equipment_id FROM eq)),
log AS (
  INSERT INTO alert_log (equipment_id, input_source, summary, decision, confidence, reason, run_id, response)
  SELECT (SELECT equipment_id FROM eq), j->>'source', j->>'query', j->>'action', (j->>'confidence_score')::int, j->>'explanation', (SELECT rid FROM r), j->>'response' FROM p
  RETURNING id
),
up AS (
  INSERT INTO equipment_status (equipment_id, status, reason, last_reading, updated_at)
  SELECT eq.equipment_id,
         CASE p.j->>'action' WHEN 'ACT' THEN 'fault' WHEN 'HOLD' THEN 'explained' ELSE 'watch' END,
         p.j->>'explanation',
         jsonb_build_object('query', p.j->>'query', 'sensor_type', p.j->>'sensor_type', 'sensor_value', p.j->'sensor_value',
                            'confidence', p.j->'confidence_score', 'alert_id', (SELECT id FROM log), 'at', now()),
         now()
  FROM p, eq
  ON CONFLICT (equipment_id) DO UPDATE
    SET status = EXCLUDED.status, reason = EXCLUDED.reason, last_reading = EXCLUDED.last_reading, updated_at = EXCLUDED.updated_at
    -- A report with no sensor reading (e.g. a chat question) never downgrades a fault or a maintenance status
    WHERE NOT (equipment_status.status IN ('fault', 'maintenance') AND EXCLUDED.last_reading->>'sensor_value' IS NULL AND EXCLUDED.status <> 'fault')
  RETURNING equipment_id, status
),
t AS (
  SELECT trace_add_steps((SELECT rid FROM r), jsonb_build_array(
    jsonb_build_object('station', 'Station 4',
      'step', 'Decide -> ' || (p.j->>'action') || ' (' || (p.j->>'confidence_score') || '%), ' || CASE WHEN p.j->>'response_source' = 'template' THEN 'template' ELSE 'LLM' END,
      'detail', jsonb_build_object('decision', p.j->>'action', 'status', p.j->>'status', 'confidence', p.j->'confidence_score',
                                   'answer_by', CASE WHEN p.j->>'response_source' = 'template' THEN 'template (no LLM)' ELSE 'LLM' END,
                                   'model', p.j->>'model', 'explanation', p.j->>'explanation', 'response', p.j->>'response'),
      'ms', p.now_ms - (p.j->>'t14_end')::bigint),
    jsonb_build_object('station', 'Write-back',
      'step', CASE WHEN (SELECT equipment_id FROM eq) IS NULL THEN 'Alert logged (no machine identified)'
                   ELSE (SELECT equipment_id FROM eq) || ': ' || coalesce((SELECT status FROM old), 'none') || ' -> ' || coalesce((SELECT status FROM up), coalesce((SELECT status FROM old), 'none') || ' (kept: report had no sensor reading)') END,
      'detail', jsonb_build_object('equipment_id', (SELECT equipment_id FROM eq), 'old_status', (SELECT status FROM old),
                                   'new_status', coalesce((SELECT status FROM up), (SELECT status FROM old)), 'status_kept', (SELECT status FROM up) IS NULL AND (SELECT equipment_id FROM eq) IS NOT NULL, 'alert_log_id', (SELECT id FROM log)),
      'ms', round(extract(epoch FROM clock_timestamp()) * 1000)::bigint - p.now_ms)
  )) AS traced FROM p
)
SELECT coalesce((SELECT equipment_id FROM up), (SELECT equipment_id FROM eq)) AS equipment_id, coalesce((SELECT status FROM up), (SELECT status FROM old)) AS status, (SELECT id FROM log) AS alert_id, (SELECT traced FROM t) AS traced;
