#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();
const workflowsDir = join(root, 'workflows');
const migrationsDir = join(root, 'docs', 'sql');

const workflowFiles = readdirSync(workflowsDir)
  .filter((name) => name.endsWith('.json'))
  .sort();

assert(workflowFiles.length > 0, 'no workflow templates found');

for (const file of workflowFiles) {
  const workflow = JSON.parse(readFileSync(join(workflowsDir, file), 'utf8'));
  assert.equal(workflow.active, false, `${file} must remain inactive when exported`);

  for (const node of workflow.nodes) {
    assert.equal(node.credentials, undefined, `${file}:${node.name} must not export credentials`);
    if (node.type === 'n8n-nodes-base.webhook') {
      assert.match(String(node.webhookId ?? ''), /^[0-9a-f]{8}-[0-9a-f-]{27}$/i,
        `${file}:${node.name} needs a stable webhookId for production registration`);
    }
  }
}

const migrations = readdirSync(migrationsDir)
  .filter((name) => /^\d{3}_.+\.sql$/.test(name))
  .sort();
assert.deepEqual(migrations.map((name) => name.slice(0, 3)),
  migrations.map((_, index) => String(index + 1).padStart(3, '0')),
  'migrations must be contiguous and zero-padded');

for (const required of [
  'docs/production-foundation-plan.md',
  'docs/deployment-guide.md',
  'docs/tenant-isolation-design.md',
  'scripts/create-staging-database.sh',
  'scripts/apply-migrations.sh',
  'scripts/operator-status.sh',
]) {
  readFileSync(join(root, required), 'utf8');
}

console.log(`PASS: ${workflowFiles.length} credential-free workflows and ${migrations.length} ordered migrations validated.`);
