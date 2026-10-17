# Deploying and rolling back AlgoFactory

AlgoFactory runs as two Docker containers on one machine: **n8n** (workflows, chatbot, dashboard) and **Postgres** (equipment, status, alert log). Pinecone and Fireworks are cloud APIs.

- [1. Deploy from scratch](#1-deploy-from-scratch)
- [2. Deploy a change](#2-deploy-a-change)
- [3. Back up before you change anything](#3-back-up-before-you-change-anything)
- [4. Roll back](#4-roll-back)
- [5. Troubleshooting](#5-troubleshooting)

> **Windows / Git Bash:** prefix `docker` commands that contain container paths (`/tmp/...`, `/data`) with `MSYS_NO_PATHCONV=1`, otherwise Git Bash rewrites them. The commands below are written for Git Bash from the repo root.

---

## 1. Deploy from scratch

### Prerequisites
- Docker Desktop, Git, Node.js 18 or later
- A **Pinecone** account (API key) and a **Fireworks** account (API key)

### 1.1 Clone and create the env file
```bash
git clone https://github.com/algoshank-pat/algofactory.git
cd algofactory
```
Create `Update.env` in the repo root. It is git-ignored; never commit it.
```bash
cat > Update.env <<'EOF'
FIREWORKS_API_KEY=fw_your_key
PINECONE_API_KEY=pcsk_your_key
POSTGRES_PASSWORD=choose_a_long_random_password
EOF
```

### 1.2 Postgres (equipment, status, alert log)
```bash
docker network create algoman
docker run -d --name algoman-pg --restart unless-stopped --network algoman \
  -v algoman_pg_data:/var/lib/postgresql/data \
  --env-file Update.env -e POSTGRES_USER=algoman -e POSTGRES_DB=algoman \
  postgres:16-alpine
# Wait until it accepts connections, then load schema, functions and the 30 machines
until docker exec algoman-pg pg_isready -U algoman -d algoman; do sleep 2; done
docker exec -i algoman-pg psql -U algoman -d algoman < build/db/algoman.sql
```

### 1.3 Pinecone index
Create a serverless index named `algomanfactory` with **dimension 1024** and metric **cosine**, either in the Pinecone console or with:
```bash
curl -s https://api.pinecone.io/indexes -H "Api-Key: $(grep ^PINECONE_API_KEY= Update.env | cut -d= -f2-)" \
  -H "Content-Type: application/json" -H "X-Pinecone-API-Version: 2025-04" \
  -d '{"name":"algomanfactory","dimension":1024,"metric":"cosine","spec":{"serverless":{"cloud":"aws","region":"us-east-1"}}}'
```
Copy the index **host** from the response (or the console). If it differs from the default in `build/build-wf.js`, export it before building:
```bash
export PINECONE_HOST=your-index-host.svc.your-env.pinecone.io
```

### 1.4 n8n
```bash
MSYS_NO_PATHCONV=1 docker run -d --name n8n --restart unless-stopped -p 5678:5678 --network algoman \
  -v n8n_data:/home/node/.n8n \
  -v "$(pwd -W 2>/dev/null || pwd)/data:/data" \
  --env-file Update.env \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
  -e NODE_FUNCTION_ALLOW_BUILTIN=fs \
  -e N8N_RESTRICT_FILE_ACCESS_TO=/data \
  -e GENERIC_TIMEZONE=America/Los_Angeles -e TZ=America/Los_Angeles \
  n8nio/n8n:2.43.7
```
- `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` lets the HTTP nodes read the API keys from the env file. The keys never appear in workflow JSON.
- `NODE_FUNCTION_ALLOW_BUILTIN=fs` lets the Code nodes read `/data` (knowledge base, schedules, baselines, chunks).
- **Optional demo clock:** add `-e PLANT_CLOCK=2026-10-19T08:30` so requests without a timestamp behave as Monday 08:30, right after the wet-wash. Leave it out in production.

Open http://localhost:5678 and create the owner account.

### 1.5 Credentials
**Postgres** (the workflows expect id `AlgoManPgCred0001`). Run this script; it reads the password from `Update.env` and never prints it:
```bash
node build/make-pg-credential.js
```

**Chat model.** In n8n go to **Credentials → Create credential → OpenAI**, then:
- **API Key:** your **Fireworks** key (`fw_...`, no `Bearer`)
- **Base URL:** `https://api.fireworks.ai/inference/v1`

Save it (the connection test should be green), then copy its ID. Open the credential in n8n: the ID is the last part of the browser URL (`.../credentials/<id>`).

### 1.6 Build, import and publish the workflows
```bash
mkdir -p build/out
OPENAI_CRED_ID=<id from 1.5> OPENAI_CRED_NAME="OpenAI account" node build/build-wf.js
for f in ingest pipeline query chat floor status-job; do
  MSYS_NO_PATHCONV=1 docker cp build/out/wf-$f.json n8n:/tmp/wf-$f.json
  MSYS_NO_PATHCONV=1 docker exec n8n n8n import:workflow --input=/tmp/wf-$f.json
done
# Publish everything except Ingest (it is run manually)
for id in 5c7a1f0e2d3b4a69 9b3ede12f642464f 4a9c3d2e1f0b5c68 7e9c3f2a4b5d6e81 6d8b2e1f3c4a5b70; do
  docker exec n8n n8n publish:workflow --id=$id
done
docker restart n8n
```

| Workflow | ID | Published |
|---|---|---|
| AlgoFactory - 1 Ingest | 438f43ce2ff04804 | No (run manually) |
| AlgoFactory - 2 Query (sensor webhook) | 9b3ede12f642464f | Yes |
| AlgoFactory - 3 Pipeline (Stations 1-4) | 5c7a1f0e2d3b4a69 | Yes |
| AlgoFactory - 4 Chat | 4a9c3d2e1f0b5c68 | Yes |
| AlgoFactory - 5 Floor API (dashboard) | 7e9c3f2a4b5d6e81 | Yes |
| AlgoFactory - 6 Status Job | 6d8b2e1f3c4a5b70 | Yes |

### 1.7 Load the knowledge base into Pinecone (once)
This chunks `data/` (31 chunks), embeds the chunks with Fireworks and upserts them to Pinecone. The extra ports avoid clashing with the running n8n:
```bash
docker exec -e N8N_RUNNERS_BROKER_PORT=5690 -e QUEUE_HEALTH_CHECK_PORT=5691 -e N8N_PORT=5692 \
  n8n n8n execute --id=438f43ce2ff04804
```
Expected: `Execution was successful`, and the index shows 31 vectors.

### 1.8 Verify
```bash
curl -s http://localhost:5678/healthz                                   # 200
curl -s -X POST http://localhost:5678/webhook/anomaly-check \
  -H "Content-Type: application/json" -d '{"query":"Equipment-001 humidity 75%","timestamp":"2026-10-19T08:30"}'
                                                                        # action HOLD, confidence 10
node build/run-all-tests.js                                             # 10/10 tests, writes test_results.json
```
Then open the dashboard at http://localhost:5678/webhook/floor.

After testing, clear the test rows:
```bash
docker exec algoman-pg psql -U algoman -d algoman -c "DELETE FROM alert_log;" \
  -c "UPDATE equipment_status SET status='normal', reason='Initial state', last_reading=NULL, updated_at=now();"
```

---

## 2. Deploy a change

1. **Back up first** (section 3).
2. **Edit the source**, never the workflow in the n8n editor (editor changes are overwritten on the next import):

   | What | Where |
   |---|---|
   | Code nodes | `build/nodes/*.js` |
   | SQL | `build/sql/*.sql`, `build/sql-floor.js` |
   | Chatbot prompt | `build/chat-system.txt` |
   | Dashboard | `dashboard/AlgoFactory-dashboard.html` (embedded into the Floor API workflow at build time) |
   | Knowledge base | `data/` (then re-run Ingest, section 1.7) |
   | Database functions | apply with `docker exec -i algoman-pg psql -U algoman -d algoman < build/sql/sql-chat-tools.sql` |

3. **Rebuild, import and publish** only the workflows you changed (IDs in the table above):
   ```bash
   OPENAI_CRED_ID=<id> OPENAI_CRED_NAME="OpenAI account" node build/build-wf.js
   MSYS_NO_PATHCONV=1 docker cp build/out/wf-floor.json n8n:/tmp/wf-floor.json
   MSYS_NO_PATHCONV=1 docker exec n8n n8n import:workflow --input=/tmp/wf-floor.json
   docker exec n8n n8n publish:workflow --id=7e9c3f2a4b5d6e81
   docker restart n8n
   ```
4. **Warm up and test.** The first request after a restart can still be served by the previous version, so send one warm-up call. Then run `node build/run-all-tests.js` and clear the test rows.
5. **Export and commit:**
   ```bash
   MSYS_NO_PATHCONV=1 docker exec n8n n8n export:workflow --all --pretty --output=/tmp/wf-export.json
   MSYS_NO_PATHCONV=1 docker cp n8n:/tmp/wf-export.json AlgoFactory-workflow.json
   docker exec algoman-pg pg_dump -U algoman -d algoman --no-owner --no-privileges > build/db/algoman.sql
   git add -A && git commit -m "Describe the change" && git push
   ```

---

## 3. Back up before you change anything

```bash
mkdir -p backups/$(date +%Y%m%d-%H%M)
B=backups/$(date +%Y%m%d-%H%M)
# Workflows (every saved version stays in n8n's history too, see 4.2)
MSYS_NO_PATHCONV=1 docker exec n8n n8n export:workflow --all --pretty --output=/tmp/wf-backup.json
MSYS_NO_PATHCONV=1 docker cp n8n:/tmp/wf-backup.json $B/workflows.json
# Database
docker exec algoman-pg pg_dump -U algoman -d algoman --no-owner --no-privileges > $B/algoman.sql
# n8n's own data (accounts, credentials, history), as a tarball of the volume
docker run --rm -v n8n_data:/src -v "$(pwd -W 2>/dev/null || pwd)/$B:/out" alpine tar czf /out/n8n_data.tgz -C /src .
```
`backups/` holds credentials (encrypted) and data. Keep it out of git; add `backups/` to `.gitignore` if you create it inside the repo.

---

## 4. Roll back

Pick the smallest rollback that fixes the problem.

### 4.1 Stop the damage first (optional)
Take a misbehaving workflow off the air without deleting it:
```bash
docker exec n8n n8n unpublish:workflow --id=9b3ede12f642464f    # e.g. the sensor webhook
docker restart n8n
```
Re-enable it later with `publish:workflow --id=...`.

### 4.2 Roll back one workflow to an earlier n8n version (fastest)
n8n 2.x keeps every saved version.
- **In the editor:** open the workflow → **Workflow history** (clock icon, top right) → pick the last good version → **Restore** → **Publish**.
- **From the CLI:** copy the version ID from that history panel, then:
  ```bash
  docker exec n8n n8n publish:workflow --id=5c7a1f0e2d3b4a69 --versionId=<version id>
  docker restart n8n
  ```

### 4.3 Roll back to a git commit (code + workflows)
```bash
git log --oneline                         # find the last good commit, e.g. 2cf6b96
git show 2cf6b96:AlgoFactory-workflow.json > wf-rollback.json        # git-ignored scratch file in the repo root
MSYS_NO_PATHCONV=1 docker cp wf-rollback.json n8n:/tmp/wf-rollback.json
MSYS_NO_PATHCONV=1 docker exec n8n n8n import:workflow --input=/tmp/wf-rollback.json   # imports all 6, same IDs
for id in 5c7a1f0e2d3b4a69 9b3ede12f642464f 4a9c3d2e1f0b5c68 7e9c3f2a4b5d6e81 6d8b2e1f3c4a5b70; do
  docker exec n8n n8n publish:workflow --id=$id
done
docker restart n8n
```
To bring the source files back to match, use `git revert <bad commit>` (keeps history) rather than rewriting history, then push.

If the rollback crosses a database change (for example a SQL function signature), also restore the database from the same commit (4.4) or re-apply `build/sql/*.sql` from that commit.

### 4.4 Roll back the database
This **replaces** all equipment, status and alert data with the dump.
```bash
docker exec algoman-pg psql -U algoman -d algoman -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
docker exec -i algoman-pg psql -U algoman -d algoman < backups/<timestamp>/algoman.sql
# or the committed dump:  git show <commit>:build/db/algoman.sql | docker exec -i algoman-pg psql -U algoman -d algoman
```

### 4.5 Roll back the knowledge base (Pinecone)
```bash
git checkout <good commit> -- data/
curl -s -X POST https://$PINECONE_HOST/vectors/delete -H "Api-Key: <your key>" \
  -H "X-Pinecone-API-Version: 2025-04" -H "Content-Type: application/json" -d '{"deleteAll":true}'
docker exec -e N8N_RUNNERS_BROKER_PORT=5690 -e QUEUE_HEALTH_CHECK_PORT=5691 -e N8N_PORT=5692 \
  n8n n8n execute --id=438f43ce2ff04804
```

### 4.6 Roll back the n8n container or version
The image is pinned to `n8nio/n8n:2.43.7`, and all n8n data lives on the `n8n_data` volume, so the container is disposable:
```bash
docker stop n8n && docker rm n8n
# re-run the docker run command from 1.4 (with the image tag you want to return to)
```
If a newer n8n version migrated the database and you need to go back, restore the volume from the backup tarball (section 3) before starting the older image:
```bash
docker run --rm -v n8n_data:/dst -v "$(pwd -W 2>/dev/null || pwd)/backups/<timestamp>:/in" alpine sh -c "rm -rf /dst/* && tar xzf /in/n8n_data.tgz -C /dst"
```

---

## 5. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Dashboard shows "Could not reach the Floor API" | n8n is down or still starting: `docker ps`, `curl localhost:5678/healthz`. Claude's built-in browser pane also blocks these requests; use Chrome. |
| Webhook returns `{"message":"Error in workflow"}` | Open **Executions** in n8n for the error. Common causes: missing credential, Pinecone host mismatch (`PINECONE_HOST`), or an expired API key. |
| Chat says "400 invalid model ID" | The OpenAI-type credential points at OpenAI. Set its Base URL to `https://api.fireworks.ai/inference/v1` and use the Fireworks key. |
| Code node error mentioning `fs` | The container is missing `-e NODE_FUNCTION_ALLOW_BUILTIN=fs` (1.4). |
| `n8n execute` fails with "Task Broker's port 5679 is already in use" | Add the extra `-e ..._PORT` flags shown in 1.7. |
| First request after a restart behaves like the old version | Known n8n behavior: send one warm-up call. |
| Humidity test returns ACT instead of HOLD | No timestamp and no `PLANT_CLOCK`: the wet-wash window (Monday 06:00-10:00) is not active at the real current time. Pass `"timestamp":"2026-10-19T08:30"`. |
