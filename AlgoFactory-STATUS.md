# AlgoFactory: Status and Handoff

*Updated Friday, October 16, 2026 (evening). Maven "Mastering Agentic AI", Week 2: Grounding AI with RAG. Due Sunday, October 18, 11:59 pm PT.*

## One line
AlgoFactory is context-aware anomaly detection for a factory floor. Every sensor alert and every worker chat message runs through the same four stations: Understand, Find evidence, Check context, Decide. Real faults get an action plan; false positives (such as humidity after a scheduled wet-wash) are held with an explanation. It is built in n8n.

## Where it stands

| Area | Status |
|---|---|
| Sensor pipeline (webhook, Stations 1-4) | Done. Runs locally in n8n. |
| Postgres equipment lookup (Station 1) | Done. 30 machines at 7 plants. |
| Worker chatbot (AI Agent + 3 tools) | Done. Lives in the dashboard and on the n8n chat page. |
| Equipment status, alert log, 15-minute status job | Done |
| Floor dashboard (USA map, machines, alerts, chat, test alerts) | Done |
| Tests: 6 sensor scenarios + 4 chatbot tests, 2 runs each | **10/10 tests, 20/20 runs pass.** Scenario 5 passes. |
| Workflow export | Done: `AlgoFactory-workflow.json` (6 workflows, no secrets) |
| Google Doc | **Not started** |
| 5-minute demo video | **Not started** |
| Maven form submission | **Not started** |
| Architecture diagram label fixes (Cowork) | **Not started** (wording below) |

Everything runs on this PC. No cloud deployment is planned; graders get the doc, the video and the workflow JSON.

## How to open it

Docker Desktop must be running. Both containers restart automatically when Docker starts.

| What | URL |
|---|---|
| Floor dashboard (map, machines, alerts, chat, test alerts) | http://localhost:5678/webhook/floor |
| n8n editor (sign in with your account) | http://localhost:5678 |
| n8n hosted chat page (same chatbot) | http://localhost:5678/webhook/a1f0c4e2-7b3d-4e5f-9a6b-1c2d3e4f5a6b/chat |
| Sensor alert API | `POST http://localhost:5678/webhook/anomaly-check` with `{ "query": "Equipment-001 humidity 75%" }` |

Health check: `curl http://localhost:5678/healthz` should return 200.

**Note for screenshots:** Claude's built-in browser pane blocks the dashboard's own background requests to localhost. Use Chrome to see live data.

## Architecture

```
INPUTS            STATION 1            STATION 2                  STATION 3                 STATION 4              OUTPUT
Sensor webhook -> Parse + Postgres  -> Pinecone (semantic)     -> 5-layer validation     -> >=60: LLM action     -> webhook reply
                  lookup by ID         + BM25 (keyword)           (evidence, sensors,       plan (ACT)              + alert_log
Worker chat    -> AI Agent calls       -> bge rerank (top 3)      schedule, baseline,       <60: template           + equipment_status
                  lookup_equipment()                              history) -> 0-100        (HOLD / ESCALATE)       -> dashboard
```

### n8n workflows (all in `AlgoFactory-workflow.json`)

| Workflow | ID | What it does |
|---|---|---|
| AlgoFactory - 1 Ingest | 438f43ce2ff04804 | Run once: chunks the knowledge base into 31 chunks, embeds them, and upserts them to Pinecone. Equipment rows live in Postgres, not Pinecone. |
| AlgoFactory - 2 Query | 9b3ede12f642464f | Sensor input: Webhook -> Run Pipeline -> Respond |
| AlgoFactory - 3 Pipeline | 5c7a1f0e2d3b4a69 | Stations 1-4 (Nodes 9-19), shared by sensor alerts and chat. Writes alert_log and equipment_status. |
| AlgoFactory - 4 Chat | 4a9c3d2e1f0b5c68 | Chat Trigger -> Run Start -> AI Agent (gpt-oss-120b) + memory + traced tools: lookup_equipment, get_equipment_status, check_alert (calls the pipeline) -> Order Trace -> Finish Run -> Reply |
| AlgoFactory - 5 Floor API | 7e9c3f2a4b5d6e81 | Serves the dashboard and its JSON endpoints: /floor, /floor/equipment, /floor/alerts, /floor/history, /floor/reset, /floor/runs, /floor/run |
| AlgoFactory - 6 Status Job | 6d8b2e1f3c4a5b70 | Every 15 minutes: explained -> normal after 3 hours; maintenance windows. Never overrides a fault. |

### Services and models

| Piece | Choice | Why |
|---|---|---|
| Orchestration | n8n 2.43.7 in Docker (container `n8n`, volume `n8n_data`, `/data` mounted from `Week2\data`) | Course track |
| Equipment DB | Postgres 16 (container `algoman-pg`, volume `algoman_pg_data`, network `algoman`) | Station 1 lookup, status, alert log |
| Vector store | Pinecone index `algomanfactory` (1024-dim, cosine) | Semantic search |
| Embeddings | Fireworks `qwen3-embedding-8b` (1024) | OpenAI account has no credits; open-weight model |
| Reranker | Pinecone hosted `bge-reranker-v2-m3` | No Cohere key; open-source model; same Pinecone key |
| LLM + agent | Fireworks `gpt-oss-120b` | Mistral 7B is not served (404). It passed a function-calling test. Open-weight. |
| Keyword search | In-memory BM25 over `/data/chunks.json` | No sparse index needed for 31 chunks |

### Confidence scoring (Node 14, Station 3)
- **Layer 0, evidence (0 to 50):** top rerank score x 50. Added because the original 4 layers maxed out at 30, so "act" (>= 60) was unreachable.
- **Layer 1, sensors (0 to 40):** reading vs. the machine's limit from Postgres (temperature, vibration, humidity baseline).
- **Layer 2, schedule (-40 to +5):** an active cleaning or maintenance window that explains the reading.
- **Layer 3, baseline (-25 to 0):** within the expected range for current conditions (for example, post-cleaning humidity).
- **Layer 4, history (-5 to 0):** the explaining schedule recurs weekly.
- **Benign cap:** a confirmed scheduled cause caps confidence at 10.
- **Decision:** >= 60 ACT (fault); < 60 with a benign cause HOLD (explained); otherwise ESCALATE (watch).

### Postgres
- **`equipment`:** 30 machines with plain names (Motor 1-11, Pump 1-6, Compressor 1-6, Fan 1-7), type, site, state, region, line and limits.
- **`equipment_status`:** status, reason, last reading.
- **`alert_log`:** every alert, with source sensor / chat / test / dashboard.
- **Functions:**
  - `lookup_equipment(q)`: matches by exact ID or name, by name in the text, by type + line, by type + city, or by fuzzy name. A machine or line number that matches nothing returns no rows, so the agent asks instead of guessing.
  - `get_equipment_status(scope)` and `get_status_summary(scope)`: the summary computes the counts in SQL, because the LLM miscounted rows.

| Plant | City | Machines |
|---|---|---|
| Austin Plant | Austin, TX | 9 |
| Columbus Plant | Columbus, OH | 7 |
| Fremont Plant | Fremont, CA | 4 |
| Minneapolis Plant | Minneapolis, MN | 3 |
| Seattle Plant | Seattle, WA | 3 |
| Denver Plant | Denver, CO | 2 |
| Miami Plant | Miami, FL | 2 |

### Secrets
- **Where they live:** API keys are in `Update.env`, passed to the n8n container with `--env-file`. HTTP nodes read `$env.FIREWORKS_API_KEY` and `$env.PINECONE_API_KEY`. The Postgres password is also in `Update.env`.
- **n8n credentials in use:**
  - `AlgoMan Postgres`
  - `OpenAI account`: holds the **Fireworks** key with Base URL `https://api.fireworks.ai/inference/v1`. It is used only by the chat agent's model node.
- **Unused credentials:** two old Header Auth credentials (titled "Authorization" and "Api-Key") can be deleted.
- **Checked clean:** none of the exported or documented files contain a key.

## Test results (`test_results.json`, last run October 16, 2026, 30 machines)

| Test | Input | Result |
|---|---|---|
| S1 | Equipment-001 TH-001 temp 85°C | ACT 94% |
| S2 | Motor running hot | ACT 75% |
| S3 | Equipment-005 VB-001 vibration 8 mm/s | ACT 94% |
| S4 | Equipment-001 TH-002 temp 68°C | ESCALATE 35% |
| **S5** | **Equipment-001 humidity 75% (Mon 08:30, after the 06:00-08:00 wet-wash)** | **HOLD 10%: false positive caught** |
| S6 | Weird noise from the floor | ESCALATE 22% + asks for detail |
| C1 | "Equipment-001 humidity is 75%, should I worry?" | lookup_equipment(Equipment-001) -> check_alert -> HOLD 10% |
| C2 | "Weird noise on Pump 2" | lookup_equipment(Pump 2) -> Equipment-008 -> check_alert -> ESCALATE 28% |
| C3 | "Motor running hot" | lookup_equipment(Motor) -> 11 motors -> asks which one |
| C4 | "Is the compressor on Line 9 ok?" | lookup -> no match -> asks; names no machine |

Median latency: sensor alerts 1.46 s (max 2.56 s); chat 2.23 s (max 3.54 s). Holds and escalations take about 1 s. Act answers take 2-2.5 s because they call the LLM; this is over the original "under 2 s" target.

## Process trace and activity log (chat runs only)

Every chat message (dashboard chat or n8n chat page) is recorded as a run. Sensor alerts and the dashboard's test-alert buttons are **not** traced.

- **What a run shows:** Prompt -> **LLM call 1** (tool chosen, arguments, model's reasoning note, tokens) -> **tool call** (`lookup_equipment` / `get_equipment_status`, with results) -> **LLM call 2** -> `check_alert`, which expands into Station 1 (parse + Postgres lookup), Station 2 (chunks before/after rerank), Station 3 (L0-L4 scores, cap, confidence) and Station 4 (decision, template or LLM) plus Write-back (status old -> new, alert_log id) -> **final LLM call** (reply).
- **Timing:** tool and station steps are timed exactly. LLM call times are estimates (marked ≈) from the gap between steps, because n8n does not expose per-call timing.
- **Live progress:** tool and station steps are written to Postgres as they happen. The LLM-call details are slotted in when the agent replies.
- **Dashboard:**
  - **Process trace tab:** pick a run, see a timeline of steps, click a step for its detail.
  - **Activity log tab:** chat runs newest first, filterable by plant and decision; clicking a row opens its trace.
  - **Activity panel** beside the chat: streams the current message's steps (polls every 500 ms). Show/Hide is remembered per browser.
- **Storage:** Postgres tables `runs` (one row per chat message) and `run_trace` (one row per step); `alert_log.run_id` links alerts to runs. SQL is in `build/sql/sql-trace.sql`, `sql-chat-run.sql` and `sql-station1-lookup.sql`.
- **API:** `GET /webhook/floor/runs?limit=&plant=&decision=` and `GET /webhook/floor/run?id=<run_id>`. The detail endpoint uses a query parameter, because n8n registers webhooks with path parameters under a generated ID prefix.
- **Verified October 16:** C1 shows +50 +40 -40 -15 -5, cap -> 10, HOLD, 3 LLM calls and 2 tool calls; C3 shows lookup -> 11 motors -> asks which. The full regression still passes 10/10 tests (20/20 runs). The chat path takes about 0.3-0.5 s longer because of the extra trace steps.

## Demo setup and script (5 minutes)

`PLANT_CLOCK=2026-10-19T08:30` is set on the n8n container, so requests without a timestamp behave as Monday 08:30 and the humidity case returns HOLD. **Remove it after the demo.** To do that, recreate the container without `-e PLANT_CLOCK=...`.

1. **Problem (30 s):** false alarms from humidity after cleaning waste 5-10 minutes each.
2. **Dashboard:** show the map and the 7 plants, all normal.
3. **Send test alert:**
   - "Humidity after cleaning" -> **HOLD**: explain Layer 2 + 3, and confidence dropping to 10.
   - "Thermal overload" -> **ACT**: Austin turns red, Motor 1 goes to fault, and the alert appears in the list.
4. **Ask AlgoFactory (chat on the dashboard):**
   - "Motor running hot" -> asks which motor.
   - "the pump in Seattle, it is making noise" -> lookup -> pipeline -> ESCALATE. Point at the tool-call chips.
   - "How are my machines doing?" -> exact counts.
5. **n8n editor:** show the Pipeline workflow (Stations 1-4) and the chat agent's tools.
6. **Close:** 10/10 tests, latency, and the Phase 2 offline path (local LLM + local vectors).

After the demo, reset the data:
```sql
DELETE FROM alert_log;
UPDATE equipment_status SET status='normal', reason='Initial state', last_reading=NULL, updated_at=now();
```
Run it with `docker exec -i algoman-pg psql -U algoman -d algoman`.

## What is left (for Cowork)

1. **Google Doc:** "AlgoFactory: Context-Aware Equipment Anomaly Detection". Sources:
   - this file
   - `n8n-node-code.md` (every node, table and endpoint)
   - `test_results.json`
   - `n8n-design-FINAL-v2.md` (original design; superseded where this file differs)

   Sections: problem, architecture, 5-layer validation, Scenario 5 in detail, chatbot tool calls, dashboard, test results, learnings, Phase 2.
2. **Demo video:** about 5 minutes, using the script above.
3. **Architecture diagram label fixes:**
   - Title: "ALGOFACTORY APP · runs on n8n" (also fix the "APP"/"runs" overlap).
   - Station 2: "Pinecone" + "Rerank (bge)" (replaces Cohere).
   - Station 3: add "0 Evidence" before "1 Sensors".
   - Station 4: "Fireworks · gpt-oss-120b".
   - Knowledge base caption: "Loaded once with open-weight embeddings (Fireworks qwen3)".
   - Equipment DB caption: "ID · name · specs · status".
   - Outputs: add a third card, "NEEDS A HUMAN / Escalate / 'Which motor?' or 'Not enough evidence'".
   - New box: "Floor dashboard: USA map, machines, alerts, chat".
   - Chatbot input: "Ask AlgoFactory (on the dashboard)".
   - Footer: "~1 s to Hold · ~2-3 s to Act now · Built in n8n · Edge-ready path: local LLM + local vectors".
4. **Maven form:** Google Doc link, video link, `AlgoFactory-workflow.json`. Due Sunday, October 18, 11:59 pm PT.
5. **Optional cleanup:**
   - `docker rm n8n-old n8n-prev n8n-prev2` (stopped leftovers).
   - Delete the two unused Header Auth credentials.

## Known limits
- **Status job changes:** changes made by the 15-minute job are not written to alert_log, so a machine's history shows its alerts and resets only.
- **Plant coordinates:** fixed in the dashboard file, not stored in Postgres.
- **Map outline:** loads from a CDN (us-atlas via jsDelivr), so it needs internet access.
- **Endpoints:** unauthenticated. Fine locally; not safe to expose publicly as-is.
- **`equipment.csv`:** still lists the original 20 machines; Postgres is the source of truth.
- **Data oddity:** in Scenario 3 the LLM called `Piston-Ring-PR-88` a bearing, because the CSV's `bearing_type` column holds it.

## Rebuild and redeploy

Full step-by-step setup, change deployment, backups and rollback: **[DEPLOY.md](DEPLOY.md)**. Short version:

All sources are in `build/`:
- **`build-wf.js`:** generates the 6 workflows.
- **`nodes/`:** Code-node JavaScript.
- **`sql/`:** status write, status job and chatbot functions.
- **`sql-floor.js`:** dashboard API queries.
- **`chat-system.txt`:** the agent's system prompt.
- **`run-all-tests.js`:** the 10 tests.
- **`db/algoman.sql`:** a full Postgres dump.

The dashboard source is `dashboard/AlgoFactory-dashboard.html`; it is embedded into the Floor API workflow at build time.

```bash
OPENAI_CRED_ID=no8OAWIhBkwnga5I OPENAI_CRED_NAME="OpenAI account" node build/build-wf.js
docker cp build/out/wf-floor.json n8n:/tmp/wf-floor.json
docker exec n8n n8n import:workflow --input=/tmp/wf-floor.json
docker exec n8n n8n publish:workflow --id=7e9c3f2a4b5d6e81
docker restart n8n
node build/run-all-tests.js
```
On Git Bash, prefix the docker commands with `MSYS_NO_PATHCONV=1`. The first request after a restart can still be served by the previous workflow version, so send one warm-up call. To restore the database: `docker exec -i algoman-pg psql -U algoman -d algoman < build/db/algoman.sql`.

## Week2 folder map

| File | What |
|---|---|
| `AlgoFactory-STATUS.md` | This file: status, how to run, handoff |
| `AlgoFactory-workflow.json` | All 6 n8n workflows (submission artifact) |
| `DEPLOY.md` | Deploy, back up and roll back |
| `test_results.json` | 10 tests x 2 runs (submission evidence) |
| `AlgoFactory-results.json` | Earlier sensor-only run (S1-S6); superseded by test_results.json |
| `n8n-node-code.md` | Every node's code and config, tables, endpoints, chatbot |
| `n8n-design-FINAL-v2.md` | Original design (Oct 15); superseded where this file differs |
| `dashboard/AlgoFactory-dashboard.html` | Dashboard source |
| `data/` | Knowledge-base source files, mounted into n8n as `/data` |
| `build/` | Rebuild sources and DB dump (above) |
| `Update.env` | API keys and Postgres password. **Do not share or upload.** |
| `00_*.md` ... `10_*.md`, `AlgoMove_Advisor.xlsx`, `Competitive_Landscape_2026.md`, `HANDOFF - Start Here.md`, `Week2_Problem_Analysis.md` | An earlier Week 2 idea (US–India relocation advisor); not part of AlgoFactory and git-ignored |

Knowledge-base data files are in `data/`, mounted into n8n as `/data`. They are anomaly_patterns.md, playbooks.txt, parts_catalog.json, maintenance_schedule.json, environmental_baselines.json, equipment.csv and the generated chunks.json.
