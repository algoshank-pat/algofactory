// Creates the n8n credential "AlgoMan Postgres" (id AlgoManPgCred0001, which the workflows reference)
// from POSTGRES_PASSWORD in your env file. The password is never printed; the temp file is deleted.
//
// Usage: node build/make-pg-credential.js [path/to/env-file] [n8n-project-id]
//   env file defaults to ./Update.env. The project id is optional (n8n assigns your personal project).
const fs = require('fs'), os = require('os'), path = require('path'), { execFileSync } = require('child_process');

const envFile = process.argv[2] || path.join(__dirname, '..', 'Update.env');
const projectId = process.argv[3];
const m = fs.readFileSync(envFile, 'utf8').match(/^POSTGRES_PASSWORD=(.*)$/m);
if (!m) { console.error(`POSTGRES_PASSWORD not found in ${envFile}`); process.exit(1); }

const cred = [{
  id: 'AlgoManPgCred0001', name: 'AlgoMan Postgres', type: 'postgres',
  data: { host: 'algoman-pg', database: 'algoman', user: 'algoman', password: m[1].trim(), port: 5432, ssl: 'disable', allowUnauthorizedCerts: false, sshTunnel: false }
}];
const tmp = path.join(os.tmpdir(), `pgcred-${Date.now()}.json`);
const docker = (...args) => execFileSync('docker', args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, MSYS_NO_PATHCONV: '1' } }).toString();
try {
  fs.writeFileSync(tmp, JSON.stringify(cred), { mode: 0o600 });
  docker('cp', tmp, 'n8n:/tmp/pgcred.json');
  const out = docker('exec', 'n8n', 'n8n', 'import:credentials', '--input=/tmp/pgcred.json', ...(projectId ? [`--projectId=${projectId}`] : []));
  console.log(out.trim().split('\n').pop());
} finally {
  fs.rmSync(tmp, { force: true });
  try { docker('exec', '-u', 'root', 'n8n', 'rm', '-f', '/tmp/pgcred.json'); } catch { /* container may be gone */ }
}
