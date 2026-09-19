import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const readWorkflow = (path) => JSON.parse(readFileSync(path, 'utf8'));
const names = (workflow) => new Set(workflow.nodes.map((node) => node.name));

const approval = readWorkflow('workflows/approval-handler.template.json');
const delivery = readWorkflow('workflows/report-delivery.template.json');
const approvalNames = names(approval);
const deliveryNames = names(delivery);

assert(approvalNames.has('Record authorized decision and queue delivery'));
assert(approvalNames.has('Run queued delivery worker'));
assert(!approvalNames.has('Mark report delivered and cluster alerted'));
assert(!approvalNames.has('Notify engineering after approval'));

const decisionNode = approval.nodes.find((node) => node.name === 'Record authorized decision and queue delivery');
assert.match(decisionNode.parameters.query, /record_review_decision/);
const contextNode = approval.nodes.find((node) => node.name === 'Validate workspace and triage channel');
assert.match(contextNode.parameters.jsCode, /REPLACE_WITH_SLACK_WORKSPACE_ID/);
assert.match(contextNode.parameters.jsCode, /REPLACE_WITH_SUPPORT_TRIAGE_CHANNEL_ID/);

for (const required of [
  'Retry delivery every minute',
  'Claim next delivery attempt',
  'Checkpoint Google Doc delivery',
  'Checkpoint Sheets delivery',
  'Checkpoint Slack and finalize delivery',
]) assert(deliveryNames.has(required), `missing ${required}`);

const finalizer = delivery.nodes.find((node) => node.name === 'Checkpoint Slack and finalize delivery');
assert.match(finalizer.parameters.query, /complete_delivery_attempt/);
assert.match(finalizer.parameters.query, /finalize_report_delivery/);

const migration004 = readFileSync('docs/sql/004_delivery_outbox.sql', 'utf8');
const migration005 = readFileSync('docs/sql/005_review_integrity.sql', 'utf8');
const migration006 = readFileSync('docs/sql/006_ingestion_serialization.sql', 'utf8');
const review = readWorkflow('workflows/cluster-review.template.json');
assert.match(migration004, /UNIQUE \(report_draft_id, target\)/);
assert.match(migration004, /FOR UPDATE SKIP LOCKED/);
assert.match(migration004, /bool_and\(status = 'succeeded'\)/);
assert.match(migration005, /authorized_approvers/);
assert.match(migration005, /authorized_review_contexts/);
assert.match(migration005, /FOR UPDATE/);
assert.match(migration006, /pg_advisory_xact_lock/);
assert.match(migration006, /status = 'active' AND ticket_count >= verification_threshold/);

const reviewCard = review.nodes.find((node) => node.name === 'Build Slack approval card');
assert.match(reviewCard.parameters.jsCode, /\*Evidence:\*/);
assert.match(reviewCard.parameters.jsCode, /ticket_id/);

console.log('PASS: production hardening workflow and migration contracts are internally consistent.');
