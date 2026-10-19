# AlgoFactory: facts for the Week 2 submission doc

*Gathered by Claude Code from the live system (workflows, code, Pinecone, Postgres) on October 18, 2026, after commit `c8bcd74`. Faithfulness (section 9) and latency (section 10) were re-measured after the October 18 changes. "NOT FOUND" or "NOT TESTED" marks anything not verified.*

## 1. Corpus

| Source (`data/`) | Format | Records | Size | Language | Contents |
|---|---|---|---|---|---|
| anomaly_patterns.md | Markdown | 8 signatures (TH-001-003, VB-001-003, AC-001-002) | 7,939 B | English | Symptoms, root causes, detection, recommended action, parts, lead time |
| playbooks.txt | Text | 4 playbooks (MP-TH-001, MP-SEAL-001, MP-COMP-001, MP-VB-BEARING) | 13,966 B | English | Step-by-step response procedures |
| parts_catalog.json | JSON | 10 parts | 6,172 B | English | Compatibility, supplier, cost, lead time |
| maintenance_schedule.json | JSON | 2 schedules | 560 B | English | Equipment-001 Monday 06:00 wet-wash (2 h); Equipment-005 Thursday 14:00 bearing replacement |
| environmental_baselines.json | JSON | 2 baselines | 427 B | English | Post-cleaning humidity (Equipment-001); summer temperature (Equipment-005) |
| equipment.csv | CSV | 20 rows | 2,145 B | English | **Not ingested.** Equipment lives in Postgres (30 machines). |

**Pinecone:** 31 vectors.

| Source / chunk_type | Chunks | Est. tokens (min / avg / max) |
|---|---|---|
| anomaly_pattern | 8 | 205 / 218 / 257 |
| procedure | 9 | 69 / 367 / 499 |
| parts | 10 | 58 / 65 / 75 |
| schedule | 2 | 37 / 38 / 38 |
| baseline | 2 | 28 / 34 / 40 |

**Owners in a real plant** (proposed; only one comes from the data):

| Source | Owner |
|---|---|
| Anomaly patterns | Reliability / condition-monitoring engineer |
| Playbooks | Maintenance engineering (the file says "Authority: Regional Engineering Team") |
| Parts | Stores / MRO purchasing |
| Schedule | Maintenance planner |
| Baselines | Reliability or process engineer |
| Equipment | Asset management / CMMS |

**Postgres tables:**
- `equipment`: 30 machines, 7 plants (Austin 9, Columbus 7, Fremont 4, Minneapolis 3, Seattle 3, Denver 2, Miami 2)
- `equipment_status`: 30 rows
- `alert_log`: every alert, including the stored answer (`response`) and actions taken (`action_note`, `performed_by`)
- `runs` and `run_trace`: the process trace for chat messages

## 2. Ingestion and cleaning
- **How data gets in:** the workflow "AlgoFactory - 1 Ingest" runs from a **Manual Trigger only**; it is not scheduled.
  - **Node 5** reads `/data`, chunks the files and writes `chunks.json` for BM25.
  - **Node 6** embeds the chunks (batches of 10).
  - **Node 7** upserts them to Pinecone.
- **Cleaning before chunking:**

| Done | Not done |
|---|---|
| `=====` banners removed from playbooks | Markdown stripping (`**` stays) |
| File preface and `## ` category headers dropped from anomaly_patterns | Entity decoding |
| JSON records rendered as sentences | Dedupe |
| `trim()` on every chunk | Whitespace normalization beyond trim |
| Null or empty metadata dropped | |

- **Stale-vector risk:** chunk IDs are positional (`source-N`), so a re-ingest after content is removed needs a Pinecone `deleteAll` first.

## 3. Freshness
- **Anomaly patterns, playbooks, parts:** manual re-ingest only. Pinecone and `chunks.json` stay stale until someone runs Ingest.
- **Schedule and baselines: read live.** Station 3 (Node 14) and the 15-minute status job read the JSON files from `/data` on every run, so a schedule change affects the very next decision. The schedule chunk in Pinecone changes only on re-ingest; it is used only as retrieval context for the LLM.
- **Equipment:** Postgres, live.

## 4. Chunking and embedding
- **Strategy:**
  - anomaly_patterns: one chunk per `###` signature
  - playbooks: per playbook, then paragraphs packed up to **500 estimated tokens** (4 characters ≈ 1 token)
  - parts, schedules, baselines: one chunk per record
  - **Overlap:** none
- **Model:** Fireworks `qwen3-embedding-8b`, **1024 dimensions**.
- **Why 1024:** the dimension is not tied to chunk length. It was chosen for a small index and fast queries; the chunks are short and single-topic (28-499 tokens).
- **Metadata on each chunk:** source_doc, chunk_type, anomaly_code, equipment_type, procedure_id, part_id, equipment_id, condition, plus `text`.

## 5. Retrieve
- **Store:** Pinecone index `algomanfactory` (serverless, aws us-east-1, cosine, 1024 dimensions).
- **Pipeline:**
  - **Dense:** top-k **20**.
  - **BM25:** top **10** with score > 0 (k1 1.2, b 0.75).
  - **Merge:** each list is divided by its own maximum, the lists are joined by ID (missing = 0), hybrid = 0.7 × dense + 0.3 × BM25, then sorted.
  - **Equipment row:** the Postgres row for the identified machine is put first.
  - **Rerank:** keep 10 -> `bge-reranker-v2-m3` -> **top 3**.
- **Query rewrite: a fixed word list, not an LLM call.** It applies only when the anomaly was inferred from symptom words:
  ```
  temperature: "thermal overload temperature exceeds max_temp_c"
  vibration:   "vibration bearing wear signature"
  acoustic:    "acoustic noise"
  humidity:    "humidity environmental baseline cleaning"
  ```
- **Metadata filters:** none on Pinecone. `equipment_id` selects the Postgres row and the matching schedule and baseline.

## 6. Generation and citations
- **ACT answers cite their sources.** Node 17 appends a "Sources" line built by code from the 3 chunks the LLM was given, so the citation itself cannot be invented. The API response also carries a `citations` array.
- **HOLD and ESCALATE** come from templates and carry no Sources line.
- **Real output, S1 (October 18):**
  ```
  Status: ALERT
  Diagnosis: Motor Thermal Overload (TH-001) – temperature at max limit, risk of bearing friction increase
  Action: Follow MP-TH-001 – reduce load immediately, inspect bearing and cooling, prepare for possible shutdown per severity
  Parts: Bearing replacement kit (6208), lubricant (ISO 32 turbine oil) – lead time 2‑3 days (bearing), 1 day (lubricant)
  Sources: [1] postgres.equipment (equipment-db-Equipment-001) · [2] anomaly_patterns.md (anomaly_patterns-0) · [3] playbooks.txt (playbooks-8)
  ```
- **Chat replies are made exact after the model answers:**
  - **Status answers:** the SQL function `status_brief` writes the text, which is returned word for word.
  - **Machine-check replies:** the header line (label, machine, site/line, confidence) is built from the tool results; only the model's one plain sentence is kept.
  - **Why:** in testing the model miscounted machines, mislabeled them and invented percentages.

## 7. Prompts and agent instructions (verbatim)
**Chat agent system prompt** (`build/chat-system.txt`; `gpt-oss-120b`, temperature 0, at most 6 iterations):
```
You are AlgoFactory, the floor assistant for factory managers and maintenance workers. Replies are read on the floor in a few seconds: short, plain words, no jargon. Never invent machines, readings or numbers.

TOOLS
- lookup_equipment: call it FIRST whenever the message mentions a machine or a symptom. Pass the machine words exactly as the worker wrote them (e.g. "Pump 2", "Equipment-001", "compressor on Line 9", "motor").
  - Exactly 1 row and the worker REPORTS SOMETHING NEW they see now (a reading like "temp 85C", a symptom like "is making a grinding noise", an alarm): call check_alert with that equipment_id and the worker's message.
  - Exactly 1 row and the worker ASKS about the machine (what's the issue, what's happening, what's wrong, status, repair plan, how is it): do NOT call check_alert. Call get_equipment_status with the machine's exact name from the row.
  - Exactly 1 row and the worker only asks where the machine is or what it is: do NOT call check_alert. Answer in one line from the row: "OK · Motor 1 is at Austin Plant, Line 1 (Floor-1-North)." Use its status label instead of OK if it is not normal.
  - Several rows: do NOT call check_alert. Ask which one: "Which motor? Motor 1 (Austin, Line 1), Motor 2 (Austin, Line 1), ..." (at most 8, one line).
  - 0 rows: do NOT call check_alert. Say you could not find that machine and ask for its name or ID. Never pick one yourself.
- check_alert: runs the sensor, schedule, baseline and history checks. Use only what it returns.
- get_equipment_status: for questions like "How are my machines doing?", "What's happening in Austin?", or questions about one machine's issue, status or repair plan. Pass "all", a site, state, region, line or machine. Use total and by_status exactly as returned (never count rows yourself).

LABELS (always uppercase, always first on the line; the dashboard colors them)
- ACT NOW: a real fault (check_alert action ACT, or status fault)
- HOLD: explained, no action needed (check_alert action HOLD, or status explained)
- CHECK: not confirmed, needs a look (check_alert action ESCALATE, or status watch)
- IN MAINTENANCE: status maintenance
- OK: everything normal

REPLY AFTER check_alert (2 lines, nothing else):
<LABEL> · <Machine name> (<site>, <line>) · <confidence_score>%
<What is going on, in plain words>. Next: <one action a floor worker can do now>.

REPLY AFTER get_equipment_status:
Reply with summary_text exactly as returned, word for word. Add nothing before or after it, change nothing, add no percentages or advice.

PLAIN WORDS
- Never show field or code names (max_temp_c, layer, baseline + 15, by_status, needs_attention) or raw formulas like "85 >= 85".
- Say it as a person would: "running at its temperature limit (85°C)", "humidity is high because of this morning's cleaning", "noise reported, no sensor reading yet".
- No zero counts, no lists of every status, no markdown headings or bold.
```

**Tools:**
- **lookup_equipment** (Postgres Tool, `SELECT * FROM lookup_equipment_traced($1, $2)`)
  - Description: "Find machines by name or ID. Input: the machine words exactly as the worker wrote them. Returns 0, 1 or several rows with equipment_id, name, type, site, line, status."
  - Parameter: `name_or_id` (string), "Machine name or ID as the worker wrote it, e.g. Pump 2, Equipment-001, motor"
  - Normalizes "Motor1", "MOTOR-1", "pump#2", "line9" to "motor 1", "pump 2", "line 9".
- **get_equipment_status** (Postgres Tool, `SELECT * FROM get_status_summary_traced($1, $2)`)
  - Description: "Machine status for managers. Input: all, a site (Austin, Columbus, Fremont, Denver, Minneapolis, Miami, Seattle), a state, region, line, or a machine. Returns summary_text: the finished reply, to be given to the user word for word."
  - Parameter: `scope` (string), "all, a site, state, region, line, or a machine name or ID"
- **check_alert** (Call n8n Workflow Tool, runs the Pipeline)
  - Description: "Run the AlgoFactory checks (evidence, sensors, schedule, baseline, history) for one identified machine. Call only after lookup_equipment returned exactly one row. Returns action (ACT/HOLD/ESCALATE), confidence_score, explanation and response."
  - Parameters: `query` ("The worker message, verbatim"), `equipment_id` ("equipment_id from lookup_equipment, e.g. Equipment-008")

**ACT action-plan prompt** (Node 15; temperature 0, reasoning_effort low, max_tokens 400):
```
You are AlgoFactory, a manufacturing maintenance assistant. Use ONLY the context and validation findings below. Do not invent values.

CONTEXT:
${context || '(no relevant documents)'}        ← "[n] (source_doc) chunk text" for the top 3

ALERT: ${raw_query}
EQUIPMENT: ${equipment_id || 'unknown'} | SENSOR: ${sensor_type || 'unknown'} ${sensor_value}
STATUS (decided by validation): ${status}
CONFIDENCE: ${confidence}%
VALIDATION FINDINGS: ${explanation}

TASK: Give a confident diagnosis and recommended action. Name the playbook procedure ID and any parts with lead time if the context lists them.

Reply in at most 4 short lines:
Status: ${status}
Diagnosis: ...
Action: ...
Parts: ... (or "None")
```

**HOLD and ESCALATE templates** (Node 15b, no LLM):
```
HOLD:      Status: FALSE POSITIVE
           Diagnosis: ${sensor_type} ${sensor_value} on ${equipment_id} is explained by context. ${explanation}
           Action: No action needed. Readings should return to baseline by ${recovery_time}.
           Parts: None
ESCALATE (vague):  Status: NEEDS INVESTIGATION
           Diagnosis: Report is too vague to diagnose: no equipment ID or sensor reading.
           Action: Specify the equipment ID and the sensor reading or symptom observed.
           Parts: None
ESCALATE (weak evidence):  Status: NEEDS INVESTIGATION
           Diagnosis: ${layer1 reason}. Evidence is not strong enough to confirm a fault (confidence ${confidence}%).
           Action: Verify the sensor reading on ${equipment_id || 'the equipment'} and keep monitoring; escalate to a technician if it keeps rising.
           Parts: None
```
**Other prompts:** NOT FOUND (there are none).

## 8. Refusal and "I don't know" paths

| Path | Text |
|---|---|
| No machine matches | LLM-written per the prompt, e.g. "I couldn't find that pump. Could you give me its exact name or ID?" |
| Several matches | "Which motor? Motor 1 (Austin Plant, Line 1), Motor 2 (Austin Plant, Line 1), …" |
| Vague report (S6) | ESCALATE (vague) template |
| Weak evidence (S4) | ESCALATE (weak evidence) template |
| Benign cause (S5) | HOLD template |

- **Zero useful chunks:** with no anomaly pattern or playbook in the top 3, Layer 0 is 0. The score then tops out at 45 (L1 40 + L2 +5), below the 60 needed, so the alert **cannot ACT** and escalates instead.
- **Empty index:** NOT TESTED.

## 9. Faithfulness check (re-run October 18, after the Layer 0 change)

**S1** (ACT 84%): 12 claims, **11 supported (92%)**.
- **Unsupported:**
  - "Motor Thermal Overload (TH-001)": the chunk defines it as "Temperature reading exceeds max_temp_c by 5-15°C", but the reading equals the maximum (85 vs. 85).
- **Supported:**
  - "temperature at max limit" ("Max temperature 85°C")
  - "risk of bearing friction increase" ("Bearing friction increase")
  - MP-TH-001 ("Procedure ID: MP-TH-001")
  - reduce load immediately ("Reduce load immediately if possible")
  - inspect bearing ("Inspect bearing for heat")
  - inspect cooling ("Check cooling system")
  - possible shutdown per severity ("SEVERITY LEVELS … Shut down immediately")
  - kit 6208 ("6208 or 6309 per equipment", plus "Ball-Bearing-6208")
  - ISO 32 turbine oil
  - 2-3 days (bearing)
  - 1 day (lubricant)

**S2** (ACT 75%): 15 claims, **13 supported (87%)**.
- **Unsupported:**
  - "shut down per emergency steps" tied to hot bearings: the playbook's emergency shutdown applies when the temperature is more than max + 10°C.
  - "thermal paste – 1 day": no lead time is given for thermal paste.
- **Supported:**
  - TH-001
  - bearing friction
  - cooling deficiency ("cooling system failure")
  - MP-TH-001
  - reduce load
  - inspect cooling ("Action 3.1: Check Cooling System")
  - feel bearings ("Feel bearing housings by hand")
  - hot/rough → replace ("If bearing feels excessively hot or sounds rough: → … Bearing Replacement Needed")
  - kit 6208/6309
  - 2-3 days
  - ISO 32
  - lubricant 1 day
  - thermal paste (in "Parts to Stage")

**S3** (ACT 81%): 6 claims, **4 supported (67%)**.
- **Unsupported:**
  - "Immediate bearing replacement… schedule replacement now": the chunk is conditional ("If vibration worsens over hours… / If stable, increase monitoring").
  - "per VB-001 playbook": no such playbook exists. The bearing playbook is MP-VB-BEARING, and it was not retrieved.
- **Supported:**
  - bearing wear (VB-001 pattern) ("Bearing wear", though that chunk is for motors and Equipment-005 is a compressor)
  - vibration at max limit ("Max vibration 8.0 mm/s")
  - Piston-Ring-PR-88 (the Postgres row labels it "Bearing", which is a data error)
  - 2-3 days

**Overall: 28 of 33 claims = 85% faithful.**

**Relevance of the top 3:**
- **S1:** 3/3 (spec 0.981, TH-001 0.781, MP-TH-001 0.56).
- **S2:** 3/3 (TH-001 0.997, MP-TH-001 parts 1 and 2: 0.992, 0.94).
- **S3:** 2 relevant + 1 partial. The spec (0.979) and the schedule (0.951) are relevant; the VB-001 motor signature (0.711) is only partly relevant, and MP-VB-BEARING was missed.

## 10. Latency (measured October 18, 3 runs each, end to end from the client)

| Case | Runs | p50 | Max | Per station (n8n node times, min-max) |
|---|---|---|---|---|
| S5 HOLD | 1.80, 1.48, 1.35 s | **1.48 s** | 1.80 s | S1 13-20 ms · **S2 1,044-1,399 ms** (rerank 242-622 ms) · S3 40-47 ms · S4 15-19 ms · write-back 48-55 ms |
| S1 ACT | 2.71, 2.63, 3.14 s | **2.71 s** | 3.14 s | S1 13-15 ms · S2 1,096-1,206 ms (rerank 357-471 ms) · S3 35-47 ms · **S4 1,175-1,661 ms (LLM 1,148-1,640 ms)** · write-back 54-57 ms |
| C3 chat | 4.33, 2.90, 4.06 s | **4.06 s** | 4.33 s | LLM call 1 ≈ 1.2-2.2 s · `lookup_equipment` 5-8 ms · LLM call 2 (reply) ≈ 1.5-2.5 s |

- **Holds and escalations** stay around 1-2 s.
- **ACT** is 2.6-3.1 s.
- **Chat** is slower than in earlier runs (about 2.2 s p50 before), because both of its LLM calls took longer. LLM time varies from run to run.

## 11. Iterations
1. **Original 4-layer scoring:** could never reach ACT (maximum 30, needs 60). Added **Layer 0 evidence**.
2. **Regex bug:** "hum" matched inside "humidity", so humidity was parsed as acoustic. Fixed by checking humidity first. Same pass: an undefined variable crash, schedules now checked by weekday, and a benign cap added → **Scenario 5 passes.**
3. **OpenAI → qwen3-embedding:** the OpenAI account had no credits.
4. **Mistral 7B → gpt-oss-120b:** Mistral was not served (404). gpt-oss also handles tool calling.
5. **Cohere → bge rerank:** no Cohere key was available.
6. **Retrieval fixes:** equipment rows crowded the playbooks out → query rewriting plus keeping only one spec row.
7. **Templates for HOLD/ESCALATE:** faster, and they cannot hallucinate.
8. **Equipment moved to Postgres,** with a deterministic lookup. Pinecone went from 51 to 31 vectors.
9. **Shared Pipeline sub-workflow;** the chatbot added with AI Agent tools.
10. **The LLM miscounted machines** (38 of 30) → counts now come from SQL.
11. **Status, alert log, 15-minute job, dashboard, 7-plant map.**
12. **Process trace and activity log** (chat runs only).
13. **ACT citations;** the ACT token cap raised from 200 to 400 (cut-off answers).
14. **Mark action taken** (status + note + name).
15. **Manager-friendly chat replies:** colored labels, and status text written by SQL.
16. **Lookup accepts "Motor1"-style names;** "where is X" answered directly.
17. **Layer 0 counts only patterns and playbooks:** every ACT with an ID had been stuck at 94%.
18. **Chat questions read status instead of re-running a check:** the re-run had overwritten real faults. The repair plan is stored and shown.

## 12. Repo check
- **Workflows:** all 6 are in `AlgoFactory-workflow.json`.
- **Secrets:** none in any commit. Each real key and the password was checked by value. `Update.env` is git-ignored.
- **README run instructions:** yes, via `DEPLOY.md` and `AlgoFactory-STATUS.md`.

## 13. How AI coding tools were used
- **Built by Claude Code:**
  - all Code-node JavaScript and SQL
  - the n8n workflow JSON, generated by a builder script and imported through the n8n CLI
  - the dashboard
  - the test runner
- **Debugged and verified by Claude Code:** ran the tests and traced bugs to their causes (regex, unreachable ACT, SQL parameter, LLM miscounts, cut-off answers, flat 94% confidence, chat overwriting faults). Also ran the faithfulness and latency checks.
- **Infrastructure set up by Claude Code:** Docker containers, the Pinecone index, ingestion, Git setup, secret scans, and the deploy and rollback docs.
- **Done by Shashank:**
  - the problem and design direction and the requirements
  - every approval
  - the API accounts and keys
  - the n8n owner account and credentials (including the OpenAI-type credential pointing at Fireworks)
  - feedback from testing the dashboard and chat (layout, wording, colors, the bugs above)
- **From earlier chat sessions:** the design docs and the source data in `data/`.
