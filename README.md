# AlgoFactory

Context-aware equipment anomaly detection, built in n8n for the Maven "Mastering Agentic AI" course (Week 2: Grounding AI with RAG).

Every sensor alert and worker chat message runs through four stations: **Understand** (Postgres equipment lookup), **Find evidence** (Pinecone + BM25, bge rerank), **Check context** (5-layer validation: evidence, sensors, schedule, baseline, history) and **Decide** (ACT with an LLM action plan, HOLD with an explanation, or ESCALATE). Example: 75% humidity on Motor 1 right after a scheduled wet-wash is held as a false positive instead of raising an alarm.

**Start here:** [AlgoFactory-STATUS.md](AlgoFactory-STATUS.md) covers the architecture, how to run it, the test results, the demo script and what is left.

| Path | What |
|---|---|
| `AlgoFactory-workflow.json` | All 6 n8n workflows (import into n8n 2.x) |
| `dashboard/AlgoFactory-dashboard.html` | Floor dashboard: USA plant map, machines, alerts, chat, test alerts |
| `build/` | Workflow builder, Code-node scripts, SQL, chatbot prompt, test runner, Postgres dump |
| `n8n-node-code.md` | Every node's code and configuration, tables and endpoints |
| `test_results.json` | 6 sensor scenarios + 4 chatbot tests, 2 runs each: 20/20 pass |
| `n8n-design-FINAL-v2.md` | Original design (superseded where the status file differs) |

**Stack:** n8n 2.43.7 and Postgres 16 in Docker, Pinecone, Fireworks (`gpt-oss-120b`, `qwen3-embedding-8b`), and a React dashboard served by n8n.

**Secrets:** API keys are read from an env file passed to the n8n container (`--env-file`). It is git-ignored and never committed. To run this yourself, create your own with `FIREWORKS_API_KEY`, `PINECONE_API_KEY` and `POSTGRES_PASSWORD`.
