-- Process trace for chat runs: one row per run in runs, one row per step in run_trace.
-- Sensor alerts are not traced: every trace function is a no-op when the run id is NULL.

CREATE TABLE IF NOT EXISTS runs (
  run_id       UUID PRIMARY KEY,
  source       TEXT NOT NULL DEFAULT 'chat',
  input        TEXT,
  status       TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'done', 'error')),
  equipment_id TEXT REFERENCES equipment(equipment_id),
  decision     TEXT,          -- ACT | HOLD | ESCALATE | ASKED | STATUS | ANSWERED
  confidence   INT,
  llm_calls    INT,
  tool_calls   INT,
  total_ms     INT,
  reply        TEXT,
  started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS runs_started ON runs (started_at DESC);

CREATE TABLE IF NOT EXISTS run_trace (
  run_id     UUID NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  step_no    INT  NOT NULL,
  station    TEXT,            -- Prompt | LLM | Station 1-4 | Write-back | Reply
  step       TEXT,
  detail     JSONB,
  ms         INT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, step_no)
);

ALTER TABLE alert_log ADD COLUMN IF NOT EXISTS run_id UUID;

-- Append steps (jsonb array of {station, step, detail, ms}) in order. NULL run id = sensor alert = no-op.
CREATE OR REPLACE FUNCTION trace_add_steps(rid UUID, steps JSONB)
RETURNS INT LANGUAGE plpgsql VOLATILE AS $$
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

CREATE OR REPLACE FUNCTION as_uuid(t TEXT) RETURNS UUID LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN t::uuid END
$$;

-- Chat tool wrappers: same results as the plain functions, plus a trace row with the call, result and time
CREATE OR REPLACE FUNCTION lookup_equipment_traced(rid TEXT, q TEXT)
RETURNS TABLE (match_type text, equipment_id text, name text, type text, site text, line text, location text,
               status text, max_temp_c numeric, max_vibration_mm_s numeric, bearing_type text, description text)
LANGUAGE plpgsql VOLATILE AS $$
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

CREATE OR REPLACE FUNCTION get_status_summary_traced(rid TEXT, scope TEXT)
RETURNS TABLE (scope_used text, total int, by_status jsonb, needs_attention jsonb)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE t0 TIMESTAMPTZ := clock_timestamp(); r RECORD;
BEGIN
  SELECT * INTO r FROM get_status_summary(scope);
  PERFORM trace_add_steps(as_uuid(rid), jsonb_build_array(jsonb_build_object(
    'station', 'Tool', 'step', 'get_equipment_status("' || coalesce(scope, 'all') || '") -> ' || r.total || ' machines',
    'detail', jsonb_build_object('tool', 'get_equipment_status', 'args', jsonb_build_object('scope', scope), 'total', r.total, 'by_status', r.by_status, 'needs_attention', r.needs_attention),
    'ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000))));
  RETURN QUERY SELECT r.scope_used, r.total, r.by_status, r.needs_attention;
END $$;
