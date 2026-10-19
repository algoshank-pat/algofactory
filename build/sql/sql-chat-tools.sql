-- Chatbot tools. lookup_equipment(q): exact ID/name -> name in text -> type + line -> type only -> fuzzy.
-- A machine or line number that matches nothing ("compressor on line 9") returns no rows, so the agent asks.
DROP FUNCTION IF EXISTS lookup_equipment(text);
CREATE FUNCTION lookup_equipment(q text)
RETURNS TABLE (match_type text, equipment_id text, name text, type text, site text, line text, location text,
               status text, max_temp_c numeric, max_vibration_mm_s numeric, bearing_type text, description text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  n text := lower(coalesce(q, ''));
  w text[] := ARRAY['one','two','three','four','five','six','seven','eight','nine','ten'];
  i int;
  ln text;
  site_hit text;
BEGIN
  FOR i IN 1..10 LOOP n := regexp_replace(n, '\m' || w[i] || '\M', i::text, 'g'); END LOOP;
  n := regexp_replace(n, '\s+', ' ', 'g');

  RETURN QUERY SELECT 'exact', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
    WHERE lower(e.equipment_id) = n OR lower(e.name) = n OR n ~ ('\m' || lower(e.equipment_id) || '\M');
  IF FOUND THEN RETURN; END IF;

  RETURN QUERY SELECT 'name_in_text', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id) WHERE n ~ ('\m' || lower(e.name) || '\M');
  IF FOUND THEN RETURN; END IF;

  -- "compressor on line 2": machines of that type on that line (all types if none named)
  ln := substring(n from 'line ?(\d+)');
  IF ln IS NOT NULL THEN
    RETURN QUERY SELECT 'type_line', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
      FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
      WHERE e.line = 'Line ' || ln
        AND (n !~ '\m(motor|pump|compressor|fan)s?\M' OR n ~ ('\m' || e.type || 's?\M'))
      ORDER BY e.name;
    RETURN;   -- found or not, never fall through to a guess
  END IF;

  IF n ~ '\m(motor|pump|compressor|fan|machine|unit|equipment)s? ?(#|no\.? ?|-)?\d' THEN RETURN; END IF;

  -- A city in the text ("the pump in seattle") narrows a type match to that plant
  SELECT e.site INTO site_hit FROM equipment e WHERE n ~ ('\m' || lower(split_part(e.site, ' ', 1)) || '\M') LIMIT 1;
  RETURN QUERY SELECT 'type', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
    WHERE n ~ ('\m' || e.type || 's?\M') AND (site_hit IS NULL OR e.site = site_hit) ORDER BY e.name;
  IF FOUND THEN RETURN; END IF;

  RETURN QUERY SELECT 'fuzzy', e.equipment_id, e.name, e.type, e.site, e.line, e.location, s.status, e.max_temp_c, e.max_vibration_mm_s, e.bearing_type, e.description
    FROM equipment e LEFT JOIN equipment_status s USING (equipment_id)
    WHERE similarity(e.name, n) >= 0.6 ORDER BY similarity(e.name, n) DESC LIMIT 5;
END $$;

-- get_equipment_status(scope): 'all' (or empty), a site / state / region / plant / line, or a machine name or ID
CREATE OR REPLACE FUNCTION get_equipment_status(scope text)
RETURNS TABLE (equipment_id text, name text, type text, site text, line text, status text, reason text, updated_at timestamptz)
LANGUAGE plpgsql STABLE AS $$
DECLARE n text := lower(trim(coalesce(scope, '')));
BEGIN
  IF n IN ('', 'all', 'everything', 'my machines', 'machines', 'all machines') THEN
    RETURN QUERY SELECT e.equipment_id, e.name, e.type, e.site, e.line, s.status, s.reason, s.updated_at
      FROM equipment e JOIN equipment_status s USING (equipment_id) ORDER BY e.site, e.name;
    RETURN;
  END IF;
  RETURN QUERY SELECT e.equipment_id, e.name, e.type, e.site, e.line, s.status, s.reason, s.updated_at
    FROM equipment e JOIN equipment_status s USING (equipment_id)
    WHERE lower(e.site) LIKE '%' || n || '%' OR lower(e.state) = n OR lower(e.region) = n OR lower(e.plant) = n
       OR lower(split_part(e.site, ' ', 1)) = n
    ORDER BY e.site, e.name;
  IF FOUND THEN RETURN; END IF;
  RETURN QUERY SELECT l.equipment_id, l.name, l.type, l.site, l.line, s.status, s.reason, s.updated_at
    FROM lookup_equipment(scope) l JOIN equipment_status s USING (equipment_id) ORDER BY l.name;
END $$;

-- get_status_summary(scope): counts computed in SQL (the model must not count rows itself) + only machines needing attention
CREATE OR REPLACE FUNCTION get_status_summary(scope text)
RETURNS TABLE (scope_used text, total int, by_status jsonb, needs_attention jsonb)
LANGUAGE sql STABLE AS $$
  WITH s AS (SELECT * FROM get_equipment_status(scope))
  SELECT coalesce(nullif(trim(scope), ''), 'all'),
         (SELECT count(*)::int FROM s),
         (SELECT jsonb_object_agg(st, coalesce(n, 0)) FROM unnest(ARRAY['normal','watch','fault','explained','maintenance']) st
            LEFT JOIN (SELECT status, count(*)::int n FROM s GROUP BY status) c ON c.status = st),
         coalesce((SELECT jsonb_agg(jsonb_build_object('name', name, 'equipment_id', equipment_id, 'site', site, 'line', line, 'status', status, 'reason', reason) ORDER BY status, name)
                   FROM s WHERE status <> 'normal'), '[]'::jsonb)
$$;

-- status_brief(scope): the manager-facing status reply, written in SQL so counts, labels and next steps are exact.
-- Labels: ACT NOW (fault), CHECK (watch), IN MAINTENANCE, HOLD (explained). The chat agent returns this text verbatim.
CREATE OR REPLACE FUNCTION status_brief(scope text)
RETURNS text LANGUAGE sql STABLE AS $$
WITH s AS (
  SELECT g.*, e.max_temp_c, e.max_vibration_mm_s, st.last_reading
  FROM get_equipment_status(scope) g JOIN equipment e USING (equipment_id) JOIN equipment_status st USING (equipment_id)
),
cnt AS (
  SELECT count(*) AS total, count(*) FILTER (WHERE status = 'normal') AS ok, count(*) FILTER (WHERE status = 'fault') AS f,
         count(*) FILTER (WHERE status = 'watch') AS w, count(*) FILTER (WHERE status = 'maintenance') AS m,
         count(*) FILTER (WHERE status = 'explained') AS x, count(DISTINCT site) AS sites
  FROM s
),
nm AS (
  SELECT CASE WHEN lower(coalesce(trim(scope), '')) IN ('', 'all', 'everything', 'my machines', 'machines', 'all machines') THEN 'All plants'
              WHEN (SELECT sites FROM cnt) = 1 THEN (SELECT min(site) FROM s)
              ELSE initcap(scope) END AS n
),
lines AS (
  SELECT CASE status WHEN 'fault' THEN 1 WHEN 'watch' THEN 2 WHEN 'maintenance' THEN 3 ELSE 4 END AS ord, name,
         CASE status WHEN 'fault' THEN 'ACT NOW' WHEN 'watch' THEN 'CHECK' WHEN 'maintenance' THEN 'IN MAINTENANCE' ELSE 'HOLD' END
         || ' · ' || name || ' (' || CASE WHEN (SELECT sites FROM cnt) > 1 THEN split_part(site, ' ', 1) || ', ' ELSE '' END || line || '): '
         || CASE status
              WHEN 'fault' THEN CASE last_reading->>'sensor_type'
                     WHEN 'temperature' THEN 'temperature ' || (last_reading->>'sensor_value') || '°C, limit ' || max_temp_c || '°C'
                     WHEN 'vibration' THEN 'vibration ' || (last_reading->>'sensor_value') || ' mm/s, limit ' || max_vibration_mm_s || ' mm/s'
                     ELSE 'fault confirmed' END || '. Next: follow the repair plan.'
              WHEN 'watch' THEN 'reported "' || coalesce(last_reading->>'query', 'an issue') || '", not confirmed by sensors. Next: have a technician take a look.'
              WHEN 'maintenance' THEN coalesce(nullif(reason, ''), 'in maintenance') || '.'
              ELSE 'high reading explained by scheduled work. No action needed.'
            END AS txt
  FROM s WHERE status <> 'normal'
)
SELECT CASE
  WHEN (SELECT total FROM cnt) = 0 THEN 'No machines found for "' || coalesce(scope, '') || '".'
  WHEN (SELECT total FROM cnt) = 1 AND (SELECT ok FROM cnt) = 1 THEN 'OK · ' || (SELECT name || ' (' || split_part(site, ' ', 1) || ', ' || line || ')' FROM s) || ': running normally.'
  WHEN (SELECT total FROM cnt) = 1 THEN (SELECT txt FROM lines)
  WHEN (SELECT total - ok FROM cnt) = 0 THEN (SELECT n FROM nm) || ': all ' || (SELECT total FROM cnt) || ' machines OK.'
  ELSE (SELECT n FROM nm) || ': ' || (SELECT ok FROM cnt) || ' OK'
       || (SELECT concat(CASE WHEN f > 0 THEN ', ' || f || CASE WHEN f = 1 THEN ' needs' ELSE ' need' END || ' action' END,
                         CASE WHEN w > 0 THEN ', ' || w || ' to check' END,
                         CASE WHEN m > 0 THEN ', ' || m || ' in maintenance' END,
                         CASE WHEN x > 0 THEN ', ' || x || ' on hold' END) FROM cnt)
       || '.' || E'\n' || (SELECT string_agg(txt, E'\n' ORDER BY ord, name) FROM lines)
END
$$;

-- Traced status tool: now returns summary_text (the reply to give) first
DROP FUNCTION IF EXISTS get_status_summary_traced(text, text);
CREATE FUNCTION get_status_summary_traced(rid TEXT, scope TEXT)
RETURNS TABLE (summary_text text, total int, by_status jsonb, needs_attention jsonb)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE t0 TIMESTAMPTZ := clock_timestamp(); r RECORD; brief TEXT := status_brief(scope);
BEGIN
  SELECT * INTO r FROM get_status_summary(scope);
  PERFORM trace_add_steps(as_uuid(rid), jsonb_build_array(jsonb_build_object(
    'station', 'Tool', 'step', 'get_equipment_status("' || coalesce(scope, 'all') || '") -> ' || r.total || ' machines',
    'detail', jsonb_build_object('tool', 'get_equipment_status', 'args', jsonb_build_object('scope', scope), 'total', r.total,
                                 'by_status', r.by_status, 'needs_attention', r.needs_attention, 'summary_text', brief),
    'ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000))));
  RETURN QUERY SELECT brief, r.total, r.by_status, r.needs_attention;
END $$;
