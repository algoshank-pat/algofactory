--
-- PostgreSQL database dump
--

\restrict NbcNHNmXGi0FS92W0bqKO2pi1P9ZX4Bcdl2gkYam2ogi0OMEOccK73t7OVFYMsS

-- Dumped from database version 16.14
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: as_uuid(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.as_uuid(t text) RETURNS uuid
    LANGUAGE sql IMMUTABLE
    AS $_$
  SELECT CASE WHEN t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN t::uuid END
$_$;


--
-- Name: get_equipment_status(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_equipment_status(scope text) RETURNS TABLE(equipment_id text, name text, type text, site text, line text, status text, reason text, updated_at timestamp with time zone)
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: get_status_summary(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_status_summary(scope text) RETURNS TABLE(scope_used text, total integer, by_status jsonb, needs_attention jsonb)
    LANGUAGE sql STABLE
    AS $$
  WITH s AS (SELECT * FROM get_equipment_status(scope))
  SELECT coalesce(nullif(trim(scope), ''), 'all'),
         (SELECT count(*)::int FROM s),
         (SELECT jsonb_object_agg(st, coalesce(n, 0)) FROM unnest(ARRAY['normal','watch','fault','explained','maintenance']) st
            LEFT JOIN (SELECT status, count(*)::int n FROM s GROUP BY status) c ON c.status = st),
         coalesce((SELECT jsonb_agg(jsonb_build_object('name', name, 'equipment_id', equipment_id, 'site', site, 'line', line, 'status', status, 'reason', reason) ORDER BY status, name)
                   FROM s WHERE status <> 'normal'), '[]'::jsonb)
$$;


--
-- Name: get_status_summary_traced(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_status_summary_traced(rid text, scope text) RETURNS TABLE(scope_used text, total integer, by_status jsonb, needs_attention jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE t0 TIMESTAMPTZ := clock_timestamp(); r RECORD;
BEGIN
  SELECT * INTO r FROM get_status_summary(scope);
  PERFORM trace_add_steps(as_uuid(rid), jsonb_build_array(jsonb_build_object(
    'station', 'Tool', 'step', 'get_equipment_status("' || coalesce(scope, 'all') || '") -> ' || r.total || ' machines',
    'detail', jsonb_build_object('tool', 'get_equipment_status', 'args', jsonb_build_object('scope', scope), 'total', r.total, 'by_status', r.by_status, 'needs_attention', r.needs_attention),
    'ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000))));
  RETURN QUERY SELECT r.scope_used, r.total, r.by_status, r.needs_attention;
END $$;


--
-- Name: lookup_equipment(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lookup_equipment(q text) RETURNS TABLE(match_type text, equipment_id text, name text, type text, site text, line text, location text, status text, max_temp_c numeric, max_vibration_mm_s numeric, bearing_type text, description text)
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: lookup_equipment_traced(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lookup_equipment_traced(rid text, q text) RETURNS TABLE(match_type text, equipment_id text, name text, type text, site text, line text, location text, status text, max_temp_c numeric, max_vibration_mm_s numeric, bearing_type text, description text)
    LANGUAGE plpgsql
    AS $$
DECLARE t0 TIMESTAMPTZ := clock_timestamp(); found JSONB;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'equipment_id', l.equipment_id, 'site', l.site, 'match', l.match_type)), '[]')
    INTO found FROM lookup_equipment(q) l;
  PERFORM trace_add_steps(as_uuid(rid), jsonb_build_array(jsonb_build_object(
    'station', 'Tool', 'step', 'lookup_equipment("' || q || '") -> ' || jsonb_array_length(found) || ' match' || CASE WHEN jsonb_array_length(found) = 1 THEN '' ELSE 'es' END,
    'detail', jsonb_build_object('tool', 'lookup_equipment', 'args', jsonb_build_object('name_or_id', q), 'matches', jsonb_array_length(found), 'found', found),
    'ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000))));
  RETURN QUERY SELECT * FROM lookup_equipment(q);
END $$;


--
-- Name: run_finish(text, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.run_finish(rid text, steps jsonb, summary jsonb) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE v UUID := as_uuid(rid); s JSONB; n INT := 0;
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(v::text));
  DELETE FROM run_trace WHERE run_id = v;
  FOR s IN SELECT * FROM jsonb_array_elements(steps) LOOP
    n := n + 1;
    INSERT INTO run_trace (run_id, step_no, station, step, detail, ms, created_at)
    VALUES (v, n, s->>'station', s->>'step', s->'detail', nullif(s->>'ms', '')::numeric::int,
            coalesce(nullif(s->>'created_at', '')::timestamptz, now()));
  END LOOP;
  UPDATE runs SET status = 'done', finished_at = now(),
         total_ms = round(extract(epoch FROM now() - started_at) * 1000),
         equipment_id = (SELECT e.equipment_id FROM equipment e WHERE e.equipment_id = summary->>'equipment_id'),
         decision = summary->>'decision', confidence = nullif(summary->>'confidence', '')::numeric::int,
         llm_calls = nullif(summary->>'llm_calls', '')::int, tool_calls = nullif(summary->>'tool_calls', '')::int,
         reply = summary->>'reply'
   WHERE run_id = v;
  RETURN n;
END $$;


--
-- Name: run_start(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.run_start(rid text, prompt text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE v UUID := coalesce(as_uuid(rid), gen_random_uuid());
BEGIN
  INSERT INTO runs (run_id, source, input) VALUES (v, 'chat', prompt) ON CONFLICT (run_id) DO NOTHING;
  PERFORM trace_add_steps(v, jsonb_build_array(jsonb_build_object(
    'station', 'Prompt', 'step', 'Prompt received', 'detail', jsonb_build_object('text', prompt), 'ms', 0)));
  RETURN v;
END $$;


--
-- Name: run_steps(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.run_steps(rid text) RETURNS TABLE(run_id uuid, started_ms bigint, steps jsonb)
    LANGUAGE sql STABLE
    AS $$
  SELECT r.run_id, round(extract(epoch FROM r.started_at) * 1000)::bigint,
         coalesce((SELECT jsonb_agg(jsonb_build_object('step_no', t.step_no, 'station', t.station, 'step', t.step, 'detail', t.detail,
                                                      'ms', t.ms, 'created_at', t.created_at,
                                                      'created_ms', round(extract(epoch FROM t.created_at) * 1000)::bigint) ORDER BY t.step_no)
                   FROM run_trace t WHERE t.run_id = r.run_id), '[]'::jsonb)
  FROM runs r WHERE r.run_id = as_uuid(rid)
$$;


--
-- Name: trace_add_steps(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trace_add_steps(rid uuid, steps jsonb) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE s JSONB; n INT;
BEGIN
  IF rid IS NULL OR NOT EXISTS (SELECT 1 FROM runs WHERE run_id = rid) THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(rid::text));   -- keep step numbers in order
  SELECT coalesce(max(step_no), 0) INTO n FROM run_trace WHERE run_id = rid;
  FOR s IN SELECT * FROM jsonb_array_elements(steps) LOOP
    n := n + 1;
    INSERT INTO run_trace (run_id, step_no, station, step, detail, ms)
    VALUES (rid, n, s->>'station', s->>'step', s->'detail', nullif(s->>'ms', '')::numeric::int);
  END LOOP;
  RETURN n;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: alert_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alert_log (
    id integer NOT NULL,
    equipment_id text,
    input_source text,
    summary text,
    decision text,
    confidence integer,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    run_id uuid
);


--
-- Name: alert_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.alert_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alert_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.alert_log_id_seq OWNED BY public.alert_log.id;


--
-- Name: equipment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment (
    equipment_id text NOT NULL,
    name text NOT NULL,
    type text,
    plant text,
    location text,
    max_temp_c numeric,
    max_vibration_mm_s numeric,
    bearing_type text,
    supplier_id text,
    install_date date,
    last_maintenance date,
    description text,
    site text,
    region text,
    state text,
    line text
);


--
-- Name: equipment_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_status (
    equipment_id text NOT NULL,
    status text NOT NULL,
    reason text,
    last_reading jsonb,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT equipment_status_status_check CHECK ((status = ANY (ARRAY['normal'::text, 'watch'::text, 'fault'::text, 'explained'::text, 'maintenance'::text])))
);


--
-- Name: run_trace; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.run_trace (
    run_id uuid NOT NULL,
    step_no integer NOT NULL,
    station text,
    step text,
    detail jsonb,
    ms integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runs (
    run_id uuid NOT NULL,
    source text DEFAULT 'chat'::text NOT NULL,
    input text,
    status text DEFAULT 'running'::text NOT NULL,
    equipment_id text,
    decision text,
    confidence integer,
    llm_calls integer,
    tool_calls integer,
    total_ms integer,
    reply text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    CONSTRAINT runs_status_check CHECK ((status = ANY (ARRAY['running'::text, 'done'::text, 'error'::text])))
);


--
-- Name: alert_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_log ALTER COLUMN id SET DEFAULT nextval('public.alert_log_id_seq'::regclass);


--
-- Data for Name: alert_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.alert_log (id, equipment_id, input_source, summary, decision, confidence, reason, created_at, run_id) FROM stdin;
136	Equipment-001	chat	Equipment-001 humidity is 75%, should I worry?	HOLD	10	wet-wash cleaning Monday 06:00 (2h) explains humidity up to 75%. Post-cleaning max expected 75%; reading 75% is normal.	2026-10-17 01:18:29.392388+00	188d8d32-87e5-4b56-b1ae-cc0f56e21c31
\.


--
-- Data for Name: equipment; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.equipment (equipment_id, name, type, plant, location, max_temp_c, max_vibration_mm_s, bearing_type, supplier_id, install_date, last_maintenance, description, site, region, state, line) FROM stdin;
Equipment-001	Motor 1	motor	Plant-A	Floor-1-North	85	5.0	Ball-Bearing-6208	Supplier-A	2019-03-15	2026-09-10	Motor 1: motor at Plant-A, Floor-1-North; Ball-Bearing-6208; supplier Supplier-A.	Austin Plant	South	TX	Line 1
Equipment-002	Motor 2	motor	Plant-A	Floor-1-South	85	5.0	Ball-Bearing-6208	Supplier-A	2020-06-22	2026-08-28	Motor 2: motor at Plant-A, Floor-1-South; Ball-Bearing-6208; supplier Supplier-A.	Austin Plant	South	TX	Line 1
Equipment-003	Motor 3	motor	Plant-B	Floor-2-East	85	5.0	Roller-Bearing-RB210	Supplier-B	2018-11-10	2026-09-05	Motor 3: motor at Plant-B, Floor-2-East; Roller-Bearing-RB210; supplier Supplier-B.	Columbus Plant	Midwest	OH	Line 2
Equipment-004	Pump 1	pump	Plant-A	Floor-1-South	95	7.0	Seal-Assembly-SA-42	Supplier-C	2021-02-01	2026-09-12	Pump 1: pump at Plant-A, Floor-1-South; Seal-Assembly-SA-42; supplier Supplier-C.	Austin Plant	South	TX	Line 1
Equipment-005	Compressor 1	compressor	Plant-B	Floor-3-West	110	8.0	Piston-Ring-PR-88	Supplier-B	2017-05-30	2026-08-15	Compressor 1: compressor at Plant-B, Floor-3-West; Piston-Ring-PR-88; supplier Supplier-B.	Columbus Plant	Midwest	OH	Line 3
Equipment-006	Fan 1	fan	Plant-A	Floor-1-North	75	3.0	Ball-Bearing-6309	Supplier-A	2020-09-14	2026-09-08	Fan 1: fan at Plant-A, Floor-1-North; Ball-Bearing-6309; supplier Supplier-A.	Austin Plant	South	TX	Line 1
Equipment-007	Motor 4	motor	Plant-C	Floor-4-North	85	5.0	Ball-Bearing-6208	Supplier-A	2019-12-05	2026-08-30	Motor 4: motor at Plant-C, Floor-4-North; Ball-Bearing-6208; supplier Supplier-A.	Fremont Plant	West	CA	Line 4
Equipment-008	Pump 2	pump	Plant-B	Floor-2-East	95	7.0	Seal-Assembly-SA-42	Supplier-C	2021-07-18	2026-09-03	Pump 2: pump at Plant-B, Floor-2-East; Seal-Assembly-SA-42; supplier Supplier-C.	Columbus Plant	Midwest	OH	Line 2
Equipment-009	Motor 5	motor	Plant-A	Floor-1-East	85	5.0	Ball-Bearing-6208	Supplier-A	2020-01-20	2026-09-15	Motor 5: motor at Plant-A, Floor-1-East; Ball-Bearing-6208; supplier Supplier-A.	Austin Plant	South	TX	Line 1
Equipment-010	Compressor 2	compressor	Plant-A	Floor-2-South	110	8.0	Piston-Ring-PR-88	Supplier-B	2018-04-12	2026-09-01	Compressor 2: compressor at Plant-A, Floor-2-South; Piston-Ring-PR-88; supplier Supplier-B.	Austin Plant	South	TX	Line 2
Equipment-011	Fan 2	fan	Plant-B	Floor-3-East	75	3.0	Ball-Bearing-6309	Supplier-A	2021-03-09	2026-08-25	Fan 2: fan at Plant-B, Floor-3-East; Ball-Bearing-6309; supplier Supplier-A.	Columbus Plant	Midwest	OH	Line 3
Equipment-012	Motor 6	motor	Plant-C	Floor-4-South	85	5.0	Ball-Bearing-6208	Supplier-A	2020-11-30	2026-09-07	Motor 6: motor at Plant-C, Floor-4-South; Ball-Bearing-6208; supplier Supplier-A.	Fremont Plant	West	CA	Line 4
Equipment-013	Pump 3	pump	Plant-C	Floor-4-West	95	7.0	Seal-Assembly-SA-42	Supplier-C	2019-08-17	2026-09-11	Pump 3: pump at Plant-C, Floor-4-West; Seal-Assembly-SA-42; supplier Supplier-C.	Fremont Plant	West	CA	Line 4
Equipment-014	Compressor 3	compressor	Plant-B	Floor-2-West	110	8.0	Piston-Ring-PR-88	Supplier-B	2020-02-25	2026-08-22	Compressor 3: compressor at Plant-B, Floor-2-West; Piston-Ring-PR-88; supplier Supplier-B.	Columbus Plant	Midwest	OH	Line 2
Equipment-015	Fan 3	fan	Plant-A	Floor-1-West	75	3.0	Ball-Bearing-6309	Supplier-A	2021-05-13	2026-09-14	Fan 3: fan at Plant-A, Floor-1-West; Ball-Bearing-6309; supplier Supplier-A.	Austin Plant	South	TX	Line 1
Equipment-016	Motor 7	motor	Plant-B	Floor-3-North	85	5.0	Ball-Bearing-6208	Supplier-A	2019-07-28	2026-09-02	Motor 7: motor at Plant-B, Floor-3-North; Ball-Bearing-6208; supplier Supplier-A.	Columbus Plant	Midwest	OH	Line 3
Equipment-017	Pump 4	pump	Plant-A	Floor-2-North	95	7.0	Seal-Assembly-SA-42	Supplier-C	2020-10-10	2026-08-31	Pump 4: pump at Plant-A, Floor-2-North; Seal-Assembly-SA-42; supplier Supplier-C.	Austin Plant	South	TX	Line 2
Equipment-018	Motor 8	motor	Plant-C	Floor-4-East	85	5.0	Ball-Bearing-6208	Supplier-A	2021-01-22	2026-09-13	Motor 8: motor at Plant-C, Floor-4-East; Ball-Bearing-6208; supplier Supplier-A.	Fremont Plant	West	CA	Line 4
Equipment-019	Compressor 4	compressor	Plant-A	Floor-3-North	110	8.0	Piston-Ring-PR-88	Supplier-B	2017-12-08	2026-08-20	Compressor 4: compressor at Plant-A, Floor-3-North; Piston-Ring-PR-88; supplier Supplier-B.	Austin Plant	South	TX	Line 3
Equipment-020	Fan 4	fan	Plant-B	Floor-2-North	75	3.0	Ball-Bearing-6309	Supplier-A	2020-03-19	2026-09-09	Fan 4: fan at Plant-B, Floor-2-North; Ball-Bearing-6309; supplier Supplier-A.	Columbus Plant	Midwest	OH	Line 2
Equipment-021	Motor 9	motor	Plant-D	Floor-1-North	85	5.0	Ball-Bearing-6208	Supplier-A	2022-04-01	2026-09-01	Motor 9: motor at Minneapolis Plant (MN), Line 1; Ball-Bearing-6208.	Minneapolis Plant	Midwest	MN	Line 1
Equipment-022	Compressor 5	compressor	Plant-D	Floor-2-North	110	8.0	Piston-Ring-PR-88	Supplier-B	2022-04-01	2026-09-01	Compressor 5: compressor at Minneapolis Plant (MN), Line 2; Piston-Ring-PR-88.	Minneapolis Plant	Midwest	MN	Line 2
Equipment-023	Fan 5	fan	Plant-D	Floor-2-North	75	3.0	Ball-Bearing-6309	Supplier-A	2022-04-01	2026-09-01	Fan 5: fan at Minneapolis Plant (MN), Line 2; Ball-Bearing-6309.	Minneapolis Plant	Midwest	MN	Line 2
Equipment-024	Pump 5	pump	Plant-E	Floor-1-North	95	7.0	Seal-Assembly-SA-42	Supplier-C	2022-04-01	2026-09-01	Pump 5: pump at Miami Plant (FL), Line 1; Seal-Assembly-SA-42.	Miami Plant	South	FL	Line 1
Equipment-025	Motor 10	motor	Plant-E	Floor-1-North	85	5.0	Ball-Bearing-6208	Supplier-A	2022-04-01	2026-09-01	Motor 10: motor at Miami Plant (FL), Line 1; Ball-Bearing-6208.	Miami Plant	South	FL	Line 1
Equipment-028	Motor 11	motor	Plant-G	Floor-1-North	85	5.0	Ball-Bearing-6208	Supplier-A	2022-04-01	2026-09-01	Motor 11: motor at Seattle Plant (WA), Line 1; Ball-Bearing-6208.	Seattle Plant	West	WA	Line 1
Equipment-029	Pump 6	pump	Plant-G	Floor-2-North	95	7.0	Seal-Assembly-SA-42	Supplier-C	2022-04-01	2026-09-01	Pump 6: pump at Seattle Plant (WA), Line 2; Seal-Assembly-SA-42.	Seattle Plant	West	WA	Line 2
Equipment-030	Fan 7	fan	Plant-G	Floor-3-North	75	3.0	Ball-Bearing-6309	Supplier-A	2022-04-01	2026-09-01	Fan 7: fan at Seattle Plant (WA), Line 3; Ball-Bearing-6309.	Seattle Plant	West	WA	Line 3
Equipment-026	Fan 6	fan	Plant-F	Floor-1-North	75	3.0	Ball-Bearing-6309	Supplier-A	2022-04-01	2026-09-01	Fan 6: fan at Denver Plant (CO), Line 1; Ball-Bearing-6309.	Denver Plant	West	CO	Line 1
Equipment-027	Compressor 6	compressor	Plant-F	Floor-2-North	110	8.0	Piston-Ring-PR-88	Supplier-B	2022-04-01	2026-09-01	Compressor 6: compressor at Denver Plant (CO), Line 2; Piston-Ring-PR-88.	Denver Plant	West	CO	Line 2
\.


--
-- Data for Name: equipment_status; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.equipment_status (equipment_id, status, reason, last_reading, updated_at) FROM stdin;
Equipment-008	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-005	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-029	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-013	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-002	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-003	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-006	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-007	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-009	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-010	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-011	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-012	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-014	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-015	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-016	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-017	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-018	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-019	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-020	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-004	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-021	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-022	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-023	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-024	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-025	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-026	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-027	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-028	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-030	normal	Initial state	\N	2026-10-17 01:17:49.568825+00
Equipment-001	explained	wet-wash cleaning Monday 06:00 (2h) explains humidity up to 75%. Post-cleaning max expected 75%; reading 75% is normal.	{"at": "2026-10-17T01:18:29.392388+00:00", "query": "Equipment-001 humidity is 75%, should I worry?", "alert_id": 136, "confidence": 10, "sensor_type": "humidity", "sensor_value": 75}	2026-10-17 01:18:29.392388+00
\.


--
-- Data for Name: run_trace; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.run_trace (run_id, step_no, station, step, detail, ms, created_at) FROM stdin;
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	1	Prompt	Prompt received	{"text": "Equipment-001 humidity is 75%, should I worry?"}	0	2026-10-17 01:18:26.666604+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	2	LLM	LLM call 1 -> lookup_equipment("Equipment-001")	{"chose": [{"args": {"name_or_id": "Equipment-001"}, "tool": "lookup_equipment"}], "model": "accounts/fireworks/models/gpt-oss-120b", "tokens": {"totalTokens": 796, "promptTokens": 690, "completionTokens": 106}, "reasoning": "We need to follow instructions. The user mentions \\"Equipment-001\\". We must call lookup_equipment with name_or_id \\"Equipment-001\\". Then based on result count: if exactly 1 row, call check_alert with query and equipment_id. If multiple rows, ask clarification. If 0 rows, ask for name/ID.\\n\\nSo first call lookup_equipment.", "ms_estimated": true}	945	2026-10-17 01:18:27.611+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	3	Tool	lookup_equipment("Equipment-001") -> 1 match	{"args": {"name_or_id": "Equipment-001"}, "tool": "lookup_equipment", "found": [{"name": "Motor 1", "site": "Austin Plant", "match": "exact", "equipment_id": "Equipment-001"}], "matches": 1}	7	2026-10-17 01:18:27.619451+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	4	LLM	LLM call 2 -> check_alert("Equipment-001 humidity is 75%, should I worry?", "Equipment-001")	{"chose": [{"args": {"query": "Equipment-001 humidity is 75%, should I worry?", "equipment_id": "Equipment-001"}, "tool": "check_alert"}], "model": "accounts/fireworks/models/gpt-oss-120b", "tokens": {"totalTokens": 889, "promptTokens": 830, "completionTokens": 59}, "reasoning": "We have exactly one row. Need to call check_alert with query and equipment_id.", "ms_estimated": true}	648	2026-10-17 01:18:28.266+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	5	Station 1	check_alert -> Understand: Motor 1 (Equipment-001), humidity 75	{"args": {"query": "Equipment-001 humidity is 75%, should I worry?", "equipment_id": "Equipment-001"}, "tool": "check_alert", "parsed": {"sensor_type": "humidity", "anomaly_type": "ENV-HUMIDITY", "equipment_id": "Equipment-001", "search_query": "Equipment-001 humidity is 75%, should I worry? ENV-HUMIDITY humidity environmental baseline cleaning", "sensor_value": 75}, "db_lookup": {"line": "Line 1", "name": "Motor 1", "site": "Austin Plant", "max_temp_c": 85, "equipment_id": "Equipment-001", "max_vibration_mm_s": 5}}	16	2026-10-17 01:18:28.283052+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	6	Station 2	Find evidence -> 3 chunks	{"after_rerank": [{"id": "environmental_baselines-29", "score": 0.997, "source": "environmental_baselines.json"}, {"id": "maintenance_schedule-27", "score": 0.607, "source": "maintenance_schedule.json"}, {"id": "equipment-db-Equipment-001", "score": 0.052, "source": "postgres.equipment"}], "search_query": "Equipment-001 humidity is 75%, should I worry? ENV-HUMIDITY humidity environmental baseline cleaning", "before_rerank": [{"id": "equipment-db-Equipment-001", "bm25": 0, "dense": 0, "hybrid": 0, "source": "postgres.equipment"}, {"id": "environmental_baselines-29", "bm25": 1, "dense": 1, "hybrid": 1, "source": "environmental_baselines.json"}, {"id": "environmental_baselines-30", "bm25": 0.289, "dense": 0.911, "hybrid": 0.725, "source": "environmental_baselines.json"}, {"id": "maintenance_schedule-27", "bm25": 0.482, "dense": 0.69, "hybrid": 0.628, "source": "maintenance_schedule.json"}, {"id": "maintenance_schedule-28", "bm25": 0, "dense": 0.559, "hybrid": 0.391, "source": "maintenance_schedule.json"}, {"id": "parts_catalog-20", "bm25": 0, "dense": 0.534, "hybrid": 0.374, "source": "parts_catalog.json"}, {"id": "parts_catalog-26", "bm25": 0, "dense": 0.515, "hybrid": 0.36, "source": "parts_catalog.json"}, {"id": "parts_catalog-17", "bm25": 0.129, "dense": 0.459, "hybrid": 0.36, "source": "parts_catalog.json"}, {"id": "parts_catalog-24", "bm25": 0, "dense": 0.51, "hybrid": 0.357, "source": "parts_catalog.json"}, {"id": "parts_catalog-25", "bm25": 0, "dense": 0.488, "hybrid": 0.341, "source": "parts_catalog.json"}]}	1044	2026-10-17 01:18:29.353281+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	7	Station 3	Check context -> confidence 10	{"cap": 10, "status": "FALSE POSITIVE", "reasons": {"layer0": "Top rerank score 1.00", "layer1": "75 >= humidity baseline + 15 65", "layer2": "wet-wash cleaning Monday 06:00 (2h) explains humidity up to 75%", "layer3": "Post-cleaning max expected 75%; reading 75% is normal", "layer4": "Recurs every Monday with the cleaning"}, "raw_score": 30, "threshold": 60, "confidence": 10, "cap_applied": true, "layer_scores": {"layer0": 50, "layer1": 40, "layer2": -40, "layer3": -15, "layer4": -5}}	7	2026-10-17 01:18:29.353281+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	8	Station 4	Decide -> HOLD (10%), template	{"model": null, "status": "FALSE POSITIVE", "decision": "HOLD", "response": "Status: FALSE POSITIVE\\nDiagnosis: humidity 75 on Equipment-001 is explained by context. wet-wash cleaning Monday 06:00 (2h) explains humidity up to 75%. Post-cleaning max expected 75%; reading 75% is normal.\\nAction: No action needed. Readings should return to baseline by 10:00.\\nParts: None", "answer_by": "template (no LLM)", "confidence": 10, "explanation": "wet-wash cleaning Monday 06:00 (2h) explains humidity up to 75%. Post-cleaning max expected 75%; reading 75% is normal."}	59	2026-10-17 01:18:29.392388+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	9	Write-back	Equipment-001: normal -> explained	{"new_status": "explained", "old_status": "normal", "alert_log_id": 136, "equipment_id": "Equipment-001"}	0	2026-10-17 01:18:29.392388+00
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	10	LLM	LLM call 3 -> reply to the worker	{"model": "accounts/fireworks/models/gpt-oss-120b", "reply": "Decision: HOLD (Motor 1)  \\nWhy: Humidity 75% is explained by the scheduled wet‑wash cleaning, which can raise humidity to that level.  \\nConfidence: 10%  \\nNext step: No action needed; the reading should return to normal by the next hour.", "ms_estimated": true}	540	2026-10-17 01:18:29.932+00
88cc96d8-e8b7-4c3e-afbf-650347534f3e	1	Prompt	Prompt received	{"text": "Motor running hot"}	0	2026-10-17 01:18:34.902648+00
88cc96d8-e8b7-4c3e-afbf-650347534f3e	2	LLM	LLM call 1 -> lookup_equipment("Motor")	{"chose": [{"args": {"name_or_id": "Motor"}, "tool": "lookup_equipment"}], "model": "accounts/fireworks/models/gpt-oss-120b", "tokens": {"totalTokens": 815, "promptTokens": 762, "completionTokens": 53}, "reasoning": "We need to process \\"Motor running hot\\". First, lookup_equipment with name_or_id \\"Motor\\". Use tool.", "ms_estimated": true}	820	2026-10-17 01:18:35.722+00
88cc96d8-e8b7-4c3e-afbf-650347534f3e	3	Tool	lookup_equipment("Motor") -> 11 matches	{"args": {"name_or_id": "Motor"}, "tool": "lookup_equipment", "found": [{"name": "Motor 1", "site": "Austin Plant", "match": "type", "equipment_id": "Equipment-001"}, {"name": "Motor 10", "site": "Miami Plant", "match": "type", "equipment_id": "Equipment-025"}, {"name": "Motor 11", "site": "Seattle Plant", "match": "type", "equipment_id": "Equipment-028"}, {"name": "Motor 2", "site": "Austin Plant", "match": "type", "equipment_id": "Equipment-002"}, {"name": "Motor 3", "site": "Columbus Plant", "match": "type", "equipment_id": "Equipment-003"}, {"name": "Motor 4", "site": "Fremont Plant", "match": "type", "equipment_id": "Equipment-007"}, {"name": "Motor 5", "site": "Austin Plant", "match": "type", "equipment_id": "Equipment-009"}, {"name": "Motor 6", "site": "Fremont Plant", "match": "type", "equipment_id": "Equipment-012"}, {"name": "Motor 7", "site": "Columbus Plant", "match": "type", "equipment_id": "Equipment-016"}, {"name": "Motor 8", "site": "Fremont Plant", "match": "type", "equipment_id": "Equipment-018"}, {"name": "Motor 9", "site": "Minneapolis Plant", "match": "type", "equipment_id": "Equipment-021"}], "matches": 11}	11	2026-10-17 01:18:35.733637+00
88cc96d8-e8b7-4c3e-afbf-650347534f3e	4	LLM	LLM call 2 -> reply to the worker	{"model": "accounts/fireworks/models/gpt-oss-120b", "reply": "Did you mean one of these machines?\\n\\n- Motor 1 (Austin Plant, Line 1)  \\n- Motor 2 (Austin Plant, Line 1)  \\n- Motor 3 (Columbus Plant, Line 2)  \\n- Motor 4 (Fremont Plant, Line 4)  \\n- Motor 5 (Austin Plant, Line 1)  \\n- Motor 6 (Fremont Plant, Line 4)  \\n- Motor 7 (Columbus Plant, Line 3)  \\n- Motor 8 (Fremont Plant, Line 4)  \\n\\nPlease specify the exact name or ID.", "ms_estimated": true}	886	2026-10-17 01:18:36.62+00
\.


--
-- Data for Name: runs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.runs (run_id, source, input, status, equipment_id, decision, confidence, llm_calls, tool_calls, total_ms, reply, started_at, finished_at) FROM stdin;
188d8d32-87e5-4b56-b1ae-cc0f56e21c31	chat	Equipment-001 humidity is 75%, should I worry?	done	Equipment-001	HOLD	10	3	2	3284	Decision: HOLD (Motor 1)  \nWhy: Humidity 75% is explained by the scheduled wet‑wash cleaning, which can raise humidity to that level.  \nConfidence: 10%  \nNext step: No action needed; the reading should return to normal by the next hour.	2026-10-17 01:18:26.666604+00	2026-10-17 01:18:29.950646+00
88cc96d8-e8b7-4c3e-afbf-650347534f3e	chat	Motor running hot	done	\N	ASKED	\N	2	1	1740	Did you mean one of these machines?\n\n- Motor 1 (Austin Plant, Line 1)  \n- Motor 2 (Austin Plant, Line 1)  \n- Motor 3 (Columbus Plant, Line 2)  \n- Motor 4 (Fremont Plant, Line 4)  \n- Motor 5 (Austin Plant, Line 1)  \n- Motor 6 (Fremont Plant, Line 4)  \n- Motor 7 (Columbus Plant, Line 3)  \n- Motor 8 (Fremont Plant, Line 4)  \n\nPlease specify the exact name or ID.	2026-10-17 01:18:34.902648+00	2026-10-17 01:18:36.642941+00
\.


--
-- Name: alert_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.alert_log_id_seq', 136, true);


--
-- Name: alert_log alert_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_log
    ADD CONSTRAINT alert_log_pkey PRIMARY KEY (id);


--
-- Name: equipment equipment_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT equipment_name_key UNIQUE (name);


--
-- Name: equipment equipment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment
    ADD CONSTRAINT equipment_pkey PRIMARY KEY (equipment_id);


--
-- Name: equipment_status equipment_status_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_status
    ADD CONSTRAINT equipment_status_pkey PRIMARY KEY (equipment_id);


--
-- Name: run_trace run_trace_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_trace
    ADD CONSTRAINT run_trace_pkey PRIMARY KEY (run_id, step_no);


--
-- Name: runs runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT runs_pkey PRIMARY KEY (run_id);


--
-- Name: alert_log_equipment_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX alert_log_equipment_time ON public.alert_log USING btree (equipment_id, created_at DESC);


--
-- Name: equipment_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_name_trgm ON public.equipment USING gin (name public.gin_trgm_ops);


--
-- Name: runs_started; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX runs_started ON public.runs USING btree (started_at DESC);


--
-- Name: alert_log alert_log_equipment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_log
    ADD CONSTRAINT alert_log_equipment_id_fkey FOREIGN KEY (equipment_id) REFERENCES public.equipment(equipment_id);


--
-- Name: equipment_status equipment_status_equipment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_status
    ADD CONSTRAINT equipment_status_equipment_id_fkey FOREIGN KEY (equipment_id) REFERENCES public.equipment(equipment_id);


--
-- Name: run_trace run_trace_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_trace
    ADD CONSTRAINT run_trace_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.runs(run_id) ON DELETE CASCADE;


--
-- Name: runs runs_equipment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runs
    ADD CONSTRAINT runs_equipment_id_fkey FOREIGN KEY (equipment_id) REFERENCES public.equipment(equipment_id);


--
-- PostgreSQL database dump complete
--

\unrestrict NbcNHNmXGi0FS92W0bqKO2pi1P9ZX4Bcdl2gkYam2ogi0OMEOccK73t7OVFYMsS

