#!/usr/bin/env node
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const valueAfter = (flag) => {
  const index = args.indexOf(flag);
  return index === -1 ? undefined : args[index + 1];
};

const input = valueAfter('--input');
const output = valueAfter('--output');
const workflowId = valueAfter('--workflow-id');
const replacements = [];
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === '--set') replacements.push(args[index + 1]);
}

if (!input || !output || !workflowId || !/^[A-Za-z0-9_-]{8,36}$/.test(workflowId)) {
  throw new Error('Usage: node scripts/prepare-n8n-import.mjs --input workflow.json --output prepared.json --workflow-id NEW_ID [--set REPLACE_WITH_NAME=value]');
}

let workflow = JSON.parse(readFileSync(input, 'utf8'));
let serialized = JSON.stringify(workflow);
for (const assignment of replacements) {
  const equalsAt = String(assignment).indexOf('=');
  if (equalsAt < 1) throw new Error(`Invalid --set value: ${assignment}`);
  const key = assignment.slice(0, equalsAt);
  const value = assignment.slice(equalsAt + 1);
  if (!/^REPLACE_WITH_[A-Z0-9_]+$/.test(key)) throw new Error(`Only REPLACE_WITH_* values may be set: ${key}`);
  if (/(TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY)/.test(key)) throw new Error(`Secrets must be attached in n8n credentials, not substituted: ${key}`);
  serialized = serialized.split(key).join(value);
}

if (serialized.includes('REPLACE_WITH_')) {
  throw new Error('Unresolved REPLACE_WITH_* value remains. Supply its non-secret configuration with --set.');
}

workflow = JSON.parse(serialized);
workflow.id = workflowId;
workflow.active = false;
for (const node of workflow.nodes) {
  if (node.type === 'n8n-nodes-base.webhook' && !node.webhookId) node.webhookId = randomUUID();
  delete node.credentials;
}
writeFileSync(output, `${JSON.stringify(workflow, null, 2)}\n`, { mode: 0o600 });
console.log(`Prepared inactive workflow ${workflow.name} (${workflowId}) at ${output}`);
