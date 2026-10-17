-- 18a: log every alert; update the machine's status when it was identified.
-- ACT -> fault, HOLD -> explained, ESCALATE -> watch. A later reading always replaces the status (that is how faults clear).
WITH p AS (SELECT $1::jsonb AS j),
eq AS (SELECT e.equipment_id FROM equipment e, p WHERE e.equipment_id = p.j->>'equipment_id'),
log AS (
  INSERT INTO alert_log (equipment_id, input_source, summary, decision, confidence, reason)
  SELECT (SELECT equipment_id FROM eq), j->>'source', j->>'query', j->>'action', (j->>'confidence_score')::int, j->>'explanation' FROM p
  RETURNING id
)
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
RETURNING equipment_id, status;