# n8n Manufacturing RAG Design (FINAL v2)
## Week 2 Maven Course: Grounding AI with RAG

**Status:** Design review  
**Deadline:** Sunday, October 18, 2026 (11:59pm PT)  
**Submission Track:** n8n (no-code) + cloud APIs (submission), offline-capable (production)  
**Credits Used:** OpenAI (embeddings), Fireworks (LLM), Pinecone (vector store)

---

## Context & Constraints

### The Problem
Factory floor detects equipment anomalies via robotic inspection. Many are false positives:
- **Example:** Humidity 75% detected near motor → baseline 50%
- **Reality:** Cleaning crew did wet-wash cleaning this morning
- **Current:** Operator manually checks schedule, wastes 5-10 min per false alarm
- **Solution:** AI checks maintenance schedule + environmental baselines → automatically marks false positives

### Constraint: Factory Floor (No Internet)
**Production deployment** requires offline-capable architecture (local embeddings + local LLM + local vector store).

**This submission** uses cloud APIs (faster, cleaner, hits deadline Sunday). We document "production deployment" as Phase 2.

### Why This Matters
- **Standard RAG:** Detects anomaly → retrieves patterns → generates answer
- **Smart RAG:** Detects anomaly → checks schedule/environment → disambiguates false positive
- **Differentiator:** System understands operational context, not just rules

---

## Tech Stack (Submission)

| Component | Service | Why | Cost |
|-----------|---------|-----|------|
| **Embeddings** | OpenAI text-embedding-3-small | Best quality (1536-dim); deterministic; one-time cost | Maven credits |
| **LLM Generation** | Fireworks Mistral 7B Instruct | 10-50x cheaper than OpenAI; excellent quality; free tier available | Free tier or Maven credits |
| **Vector Store** | Pinecone | Managed, production-grade; hybrid search (dense + sparse) | Maven credits |
| **Orchestration** | n8n (cloud or local) | No-code, visual workflow, native API integrations | Free tier or self-hosted |
| **IDE/Config** | Replit (optional) | Cloud IDE if self-hosting n8n | Maven credits (optional) |

**Total Cost for Submission:** $0 (all credits)

---

## Production Deployment (Phase 2, Documented Only)

| Component | Service | Why |
|-----------|---------|-----|
| **Embeddings** | Local: sentence-transformers (Python) | Offline, no API calls |
| **LLM** | Local: Ollama + Mistral 7B | Offline, no API calls |
| **Vector Store** | Local: SQLite + pgvector | Single-file, embeddable |
| **Orchestration** | n8n (self-hosted on factory edge device) | No external connectivity needed |

**Note:** Production build = Phase 2 post-Maven. Submission focuses on cloud-based proof-of-concept.

---

## Core Mechanism: 4-Layer Contextual Validation

```
User Query (e.g., "Equipment-001 humidity 75%")
    ↓
[Node 9: Parse Intent]
  Extract: equipment_id, anomaly_type, sensor_values
    ↓
[Node 10-13: Hybrid Retrieval + Rerank]
  Dense (semantic) + Sparse (BM25) → Cohere rerank → Top 3 chunks
    ↓
[Node 14: 4-Layer Validation] ← KEY INNOVATION
  ├─ Layer 1: Sensor cross-check (0-40 pts)
  │   Is sensor_value > max_threshold?
  │
  ├─ Layer 2: Schedule context (-40 to +5 pts)
  │   Was maintenance/cleaning scheduled recently that explains this?
  │   Example: Cleaning scheduled 6-8am → humidity 75% at 8:30am = false positive
  │
  ├─ Layer 3: Environmental baseline (-25 to 0 pts)
  │   Is this reading within expected range for current conditions?
  │   Example: Post-cleaning baseline max 75% → 75% reading is normal
  │
  └─ Layer 4: Historical pattern (-5 to 0 pts)
      Has this equipment had this anomaly before?
      Recurring + benign = lower confidence
    ↓
Decision: confidence ≥60% → Generate | <60% → Escalate
    ↓
[Node 16-18: Generate Answer or Escalate]
  If high confidence: "Equipment-001 thermal overload detected. Recommended action: ..."
  If low confidence: "Humidity alert detected, but cleaning scheduled 6-8am explains this. FALSE POSITIVE. No action needed."
```

---

## Data Files: 6 Total

### Existing (4 files)
- `equipment.csv` — 20 equipment records with specs
- `anomaly_patterns.md` — 12 anomaly types (TH-, VB-, AC-) with signatures
- `playbooks.txt` — 5 maintenance procedures
- `parts_catalog.json` — 10 parts with suppliers & lead times

### NEW (2 files, ~1KB total)

**`maintenance_schedule.json` (30 min to create)**
```json
{
  "schedules": [
    {
      "equipment_id": "Equipment-001",
      "schedule_type": "cleaning",
      "day_of_week": "Monday",
      "time": "06:00",
      "method": "wet-wash",
      "expected_humidity_elevation": 20,
      "expected_temp_drop": 5,
      "duration_hours": 2
    },
    {
      "equipment_id": "Equipment-005",
      "schedule_type": "maintenance",
      "day_of_week": "Thursday",
      "time": "14:00",
      "method": "bearing_replacement",
      "expected_vibration_spike": 8,
      "duration_hours": 2
    }
  ]
}
```

**`environmental_baselines.json` (30 min to create)**
```json
{
  "baselines": [
    {
      "equipment_id": "Equipment-001",
      "location": "Floor-1-North",
      "condition": "post_cleaning",
      "humidity_baseline": 50,
      "humidity_max_expected": 75,
      "humidity_elevated_for_hours": 2
    },
    {
      "equipment_id": "Equipment-005",
      "condition": "summer_season",
      "temperature_baseline": 28,
      "temperature_max_expected": 32
    }
  ]
}
```

---

## n8n Workflow: 18 Nodes Across 5 Phases

### Phase 1: Data Ingestion (Nodes 1-5)
**What:** Load all 6 data files + chunk them

| Node | Type | Description | Input | Output |
|------|------|-------------|-------|--------|
| 1 | Read Files | Load equipment.csv | filename | CSV rows |
| 2 | Read Files | Load anomaly_patterns.md | filename | Markdown text |
| 3 | Read Files | Load playbooks.txt | filename | Text |
| 4 | Read Files | Load parts_catalog.json | filename | JSON objects |
| 4b | Read Files | Load maintenance_schedule.json | filename | JSON objects |
| 4c | Read Files | Load environmental_baselines.json | filename | JSON objects |
| 5 | Code (JavaScript) | Chunk all documents (500-token chunks) | [doc1, doc2, ...] | [chunk1, chunk2, ...] with metadata |

**Metadata per chunk:** `equipment_id`, `equipment_type`, `anomaly_code`, `source_doc`, `chunk_type`

---

### Phase 2: Embed & Store (Nodes 6-7)
**What:** Convert chunks to vectors, store in Pinecone

| Node | Type | Description |
|------|------|-------------|
| 6 | OpenAI Embeddings | Call OpenAI API: chunk text → 1536-dim vector |
| 7 | Pinecone Upsert | Store vectors + metadata in Pinecone index |

**One-time cost:** ~$0.02 (OpenAI embeddings for ~10K tokens)

---

### Phase 3: Query Intake (Nodes 8-9)
**What:** Receive query, parse intent

| Node | Type | Description |
|------|------|-------------|
| 8 | Webhook Trigger | Listen for POST `/query` |
| 9 | Code (JavaScript) | Parse intent: extract equipment_id, anomaly_type, sensor_values |

**Example:**
- Input: `"Equipment-001 humidity 75%"`
- Output: `{equipment_id: "Equipment-001", anomaly_type: "AC-001", sensor_value: 75, sensor_type: "humidity"}`

---

### Phase 4: Retrieve & Rerank (Nodes 10-13)
**What:** Hybrid retrieval (dense + sparse), rerank for relevance

| Node | Type | Description |
|------|------|-------------|
| 10 | Pinecone Vector Search | Query: embed user intent → dense search (semantic) |
| 11 | Pinecone Sparse Search | Query: BM25 keyword search (sparse) |
| 12 | Code (JavaScript) | Merge results: 70% dense + 30% sparse, deduplicate |
| 13 | Cohere Rerank | Rerank top 10 → top 3 chunks (AI-driven relevance) |

**Output:** Top 3 most relevant chunks + scores

---

### Phase 4b: Validate (Node 14)
**What:** 4-layer contextual validation → confidence score

| Node | Type | Description |
|------|------|-------------|
| 14 | Code (JavaScript) | 4-layer validation logic (see below) |

**Layer 1: Sensor Cross-Check (0-40 pts)**
```javascript
if (sensor_value > equipment.max_threshold) {
  confidence += 30;  // Sensor reading exceeds safe limit
}
```

**Layer 2: Schedule Context (-40 to +5 pts)**
```javascript
let recentSchedule = schedules.find(s => 
  s.equipment_id === equipment_id && 
  isWithinLastHours(s.time, 2)
);
if (recentSchedule && explainsSensorValue(recentSchedule, anomaly_type)) {
  confidence -= 30;  // Recent maintenance/cleaning explains the reading
}
```

**Layer 3: Environmental Baseline (-25 to 0 pts)**
```javascript
let baseline = baselines[equipment_id];
if (baseline && isWithinExpectedRange(sensor_value, baseline)) {
  confidence -= 15;  // Reading is normal for current conditions
}
```

**Layer 4: Historical Pattern (-5 to 0 pts)**
```javascript
let historicalMatches = topChunks.filter(c => 
  c.metadata.equipment_id === equipment_id && 
  c.metadata.anomaly_code === anomaly_type
).length;
if (historicalMatches > 2) {
  confidence -= 5;  // Recurring pattern; likely benign
}
```

**Final:**
```javascript
let finalConfidence = Math.max(0, Math.min(100, 
  sensor_score + schedule_penalty + environment_penalty + history_penalty
));
return finalConfidence;
```

---

### Phase 5: Generate or Escalate (Nodes 15-18)
**What:** LLM-driven response or escalation

| Node | Type | Description |
|------|------|-------------|
| 15 | Code (JavaScript) | Build LLM prompt with retrieved chunks + confidence |
| 16 | Fireworks LLM | **If confidence ≥60%:** Call Mistral 7B to generate answer |
| 17 | Code (JavaScript) | Format response (JSON) |
| 18 | Webhook Response | Return result to caller |

**If confidence ≥60%:**
```
Response: "Equipment-001 thermal overload detected.
Symptoms: Temperature 85°C (baseline 65°C).
Recommended action: Reduce load, inspect bearings.
Parts needed: Bearing 6309 (3-day lead time).
Procedure: See MP-VB-BEARING playbook."
```

**If confidence <60%:**
```
Response: "Humidity alert for Equipment-001 (75%, baseline 50%).
However: Scheduled wet-wash cleaning 6-8am explains this reading.
Expected elevation: 70-75% for 2 hours post-cleaning.
Status: FALSE POSITIVE. No action needed. Monitor resolves by 10:30am."
```

---

## Critical Test Case: Humidity False Positive

**Scenario:** Equipment-001 detects 75% humidity at 8:30am (Friday, Oct 17)

**Context:**
- Baseline humidity: 50%
- Scheduled cleaning: 6-8am (wet-wash)
- Current time: 8:30am (30 min after cleaning end)

**Expected Flow:**

| Layer | Calculation | Score | Reasoning |
|-------|-------------|-------|-----------|
| 1. Sensor | 75% > 50% baseline | +30 | Elevated humidity |
| 2. Schedule | Cleaning 6-8am → expected elevation 70-75% | -30 | Explains the reading |
| 3. Environment | Post-cleaning baseline max 75% | -15 | Normal for conditions |
| 4. History | 3 prior humidity spikes (all post-cleaning) | -5 | Recurring, benign |
| **Final** | 30 - 30 - 15 - 5 = **-20 → 0 (clamped)** | **0** | **Escalate** |

**Decision:** Confidence <60% → **ESCALATE** with explanation

**Response:**
```
Humidity alert for Equipment-001 (75%, baseline 50%).
However: Scheduled wet-wash cleaning 6-8am explains this reading.
Expected humidity elevation: 70-75% for 2 hours post-cleaning.
Status: FALSE POSITIVE. No action needed. Monitor returns to normal by 10:30am.
```

**Why This Matters:** Shows system understands context, not just rules. Prevents alarm fatigue.

---

## 6 Core Test Scenarios (Saturday Eval)

| # | Scenario | Purpose | Expected Result |
|---|----------|---------|-----------------|
| 1 | Equipment-001 + TH-001 + temp 85°C (baseline 65°C) | Happy path: all signals aligned | Confidence 90%, answer generated |
| 2 | "Motor running hot" (no equipment ID, semantic only) | Dense search without sparse anchor | Confidence 70-75%, answer with caveats |
| 3 | Equipment-005 + VB-001 + vibration 8 mm/s (baseline 3 mm/s) | Sensor validates anomaly | Confidence 85%, answer generated |
| 4 | Equipment-001 + TH-002 + temp 68°C (baseline 65°C, within normal) | Sensor contradicts anomaly | Confidence 30%, escalate |
| 5 | **Equipment-001 + humidity 75% at 8:30am (post-cleaning)** | **False positive detection (cleaning scheduled 6-8am)** | **Confidence 0-10%, escalate with explanation** |
| 6 | "Weird noise from the floor" (too vague) | Low confidence trigger | Confidence 15%, escalate + ask clarification |

**Metric per scenario:** Latency, retrieval precision, answer faithfulness, confidence score, decision accuracy (generate vs escalate)

**Success:** All 6 pass on first run (or second run after debug)

---

## Build Schedule: Friday-Sunday

### Friday (Oct 16) — 4-5 hours
- [ ] **Morning (1 hour):**
  - Get API keys: OpenAI, Fireworks, Pinecone ✓
  - Create `.env` file
  - Set up n8n (cloud or Replit)

- [ ] **Late Morning (1 hour):**
  - Create `maintenance_schedule.json` (30 min)
  - Create `environmental_baselines.json` (30 min)

- [ ] **Afternoon (2-3 hours):**
  - Nodes 1-4c: Load all 6 data files
  - Node 5: Implement chunking (500-token, metadata)
  - Test: Can you load all 6 files + chunk successfully?

- [ ] **Evening (1 hour):**
  - Node 6: OpenAI embeddings API call
  - Node 7: Pinecone upsert
  - Test: Can you embed + store 1 chunk successfully?

**Checkpoint:** By end of Friday, vectors in Pinecone ✓

### Saturday (Oct 17) — 5-6 hours
- [ ] **Morning (2 hours):**
  - Node 8: Webhook trigger setup
  - Node 9: Parse intent (regex + keyword matching)
  - Nodes 10-13: Retrieval + reranking
  - Test: Can you retrieve top-3 chunks for a query?

- [ ] **Early Afternoon (1 hour):**
  - Node 14: Implement 4-layer validation logic
  - Test: Confidence calculations working correctly?

- [ ] **Afternoon (2-3 hours):**
  - Nodes 15-17: Build LLM prompt, call Fireworks, format response
  - Node 18: Webhook response
  - Run all 6 test scenarios (2x each = 12 total calls)
  - Measure: precision, latency, confidence scores

**Critical:** Scenario 5 (humidity false positive) must pass

**Checkpoint:** All 6 scenarios pass ✓

### Sunday (Oct 18) — 2-3 hours
- [ ] **Morning (1-1.5 hours):**
  - Google Doc: design overview, 4-layer validation, test results
  - Record 5-min demo video (3-4 queries, emphasize false positive detection)

- [ ] **Late Morning (30 min):**
  - Export n8n workflow JSON
  - Verify all deliverables ready

- [ ] **Before 11:59pm PT:**
  - Submit via Maven form
  - Include: Google Doc link, workflow JSON, demo video link

---

## Success Criteria

| Metric | Target | Why |
|--------|--------|-----|
| Humidity false positive correctly escalated | ✓ MUST PASS | Shows context-aware validation (differentiator) |
| Other 5 scenarios pass | ≥5/6 | Core functionality working |
| Latency (p95) | <2 sec per query | n8n realistic performance |
| Confidence calculations | Spot-check 3 scenarios | Validation math correct |
| Google Doc | Clear, well-structured | Demonstrates learning |
| Demo video | Engaging, 5 min, shows differentiator | Communicates value |
| Code Quality | Well-commented n8n nodes | Reproducible workflow |

---

## Risk & Mitigation

| Risk | Mitigation |
|------|-----------|
| Fireworks API slow/unreliable | Fallback: use OpenAI (have credits); test Friday evening |
| Pinecone upsets fail | Test with 1 chunk first; verify API key + index |
| Validation logic has bugs | Run test scenarios Saturday AM; debug logic before full eval |
| LLM generates unfaithful answers | Set temperature=0; use retrieved chunks as ground truth |
| Run out of time Sunday | Prioritize: scenarios > video > doc formatting |

---

## What Makes This Solution "Smart RAG"

### Naive RAG (❌ Not This)
```
Anomaly detected → Retrieve similar patterns → Generate answer
```
Always answers, even when it shouldn't (false positives aren't caught).

### Context-Aware RAG (✓ This)
```
Anomaly detected 
  → Retrieve similar patterns 
  → Validate with 4-layer logic
    ├─ Is sensor reading real?
    ├─ Is there scheduled maintenance that explains it?
    ├─ Is it within environmental baseline?
    └─ Is it a recurring pattern?
  → Decision: Generate (high confidence) or Escalate (low confidence)
```

Understands **why** an anomaly is raised, not just **what** was detected.

**Example Differentiator:**
- **Naive:** Humidity 75% → "High humidity detected. Check seal integrity. Order Part XYZ."
- **Smart:** Humidity 75% at 8:30am → "Cleaning scheduled 6-8am explains this. FALSE POSITIVE. Resume normal monitoring."

---

## Next Steps (Review & Critique)

1. **Read this doc carefully**
2. **Critique:** What's missing? What's unclear? What's risky?
3. **Approve:** Once locked in, we start Friday build

**Questions for you:**
- Does the 4-layer validation logic make sense?
- Are the 6 test scenarios comprehensive?
- Any data files or API choices you'd change?
- Timeline feel realistic (Fri 4-5 hrs, Sat 5-6 hrs, Sun 2-3 hrs)?

Ready to review & discuss? 👇
