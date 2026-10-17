-- Status job (every 15 min). Faults are never changed here: only a later reading or a dashboard reset clears them.
WITH a AS (SELECT unnest($1::text[]) AS id),
start_m AS (
  UPDATE equipment_status s SET status = 'maintenance', reason = 'Scheduled maintenance/cleaning window', updated_at = now()
  WHERE s.equipment_id IN (SELECT id FROM a) AND s.status NOT IN ('fault', 'maintenance')
  RETURNING s.equipment_id, 'to maintenance'::text AS change),
end_m AS (
  UPDATE equipment_status s SET status = 'normal', reason = 'Maintenance window ended', updated_at = now()
  WHERE s.status = 'maintenance' AND s.equipment_id NOT IN (SELECT id FROM a)
  RETURNING s.equipment_id, 'maintenance -> normal'::text),
expired AS (
  UPDATE equipment_status s SET status = 'normal', reason = 'Explained alert expired after 3 hours', updated_at = now()
  WHERE s.status = 'explained' AND s.updated_at < now() - interval '3 hours' AND s.equipment_id NOT IN (SELECT id FROM a)
  RETURNING s.equipment_id, 'explained -> normal'::text)
SELECT * FROM start_m UNION ALL SELECT * FROM end_m UNION ALL SELECT * FROM expired;
