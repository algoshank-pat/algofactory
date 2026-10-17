-- Chat run lifecycle for the process trace.
-- run_start: creates the run (id from the dashboard, or a new one) and the "Prompt received" step.
CREATE OR REPLACE FUNCTION run_start(rid TEXT, prompt TEXT)
RETURNS UUID LANGUAGE plpgsql VOLATILE AS $$
DECLARE v UUID := coalesce(as_uuid(rid), gen_random_uuid());
BEGIN
  INSERT INTO runs (run_id, source, input) VALUES (v, 'chat', prompt) ON CONFLICT (run_id) DO NOTHING;
  PERFORM trace_add_steps(v, jsonb_build_array(jsonb_build_object(
    'station', 'Prompt', 'step', 'Prompt received', 'detail', jsonb_build_object('text', prompt), 'ms', 0)));
  RETURN v;
END $$;

-- run_steps: the run and its live steps so far (used once the agent has replied, to interleave the LLM calls)
CREATE OR REPLACE FUNCTION run_steps(rid TEXT)
RETURNS TABLE (run_id UUID, started_ms BIGINT, steps JSONB)
LANGUAGE sql STABLE AS $$
  SELECT r.run_id, round(extract(epoch FROM r.started_at) * 1000)::bigint,
         coalesce((SELECT jsonb_agg(jsonb_build_object('step_no', t.step_no, 'station', t.station, 'step', t.step, 'detail', t.detail,
                                                      'ms', t.ms, 'created_at', t.created_at,
                                                      'created_ms', round(extract(epoch FROM t.created_at) * 1000)::bigint) ORDER BY t.step_no)
                   FROM run_trace t WHERE t.run_id = r.run_id), '[]'::jsonb)
  FROM runs r WHERE r.run_id = as_uuid(rid)
$$;

-- run_finish: rewrites the run's steps in final order (LLM calls interleaved with tool calls) and closes the run
CREATE OR REPLACE FUNCTION run_finish(rid TEXT, steps JSONB, summary JSONB)
RETURNS INT LANGUAGE plpgsql VOLATILE AS $$
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
