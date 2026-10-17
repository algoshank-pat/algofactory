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
