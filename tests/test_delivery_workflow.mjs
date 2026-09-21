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
assert(approvalNames.has('Build finalized Slack card'));
assert(approvalNames.has('Disable reviewed Slack card'));
assert(approvalNames.has('Verify reviewed card disabled'));
assert(!approvalNames.has('Mark report delivered and cluster alerted'));
assert(!approvalNames.has('Notify engineering after approval'));

const decisionNode = approval.nodes.find((node) => node.name === 'Record authorized decision and queue delivery');
assert.match(decisionNode.parameters.query, /record_review_decision/);
const contextNode = approval.nodes.find((node) => node.name === 'Validate workspace and triage channel');
assert.match(contextNode.parameters.jsCode, /REPLACE_WITH_SLACK_WORKSPACE_ID/);
assert.match(contextNode.parameters.jsCode, /REPLACE_WITH_SUPPORT_TRIAGE_CHANNEL_ID/);
const parseDecision = approval.nodes.find((node) => node.name === 'Verify signature and parse review decision');
assert.match(parseDecision.parameters.jsCode, /message_ts/);
assert.match(parseDecision.parameters.jsCode, /message_blocks/);
const finalizedCard = approval.nodes.find((node) => node.name === 'Build finalized Slack card');
assert.match(finalizedCard.parameters.jsCode, /block\.type!=='actions'/);
assert.match(finalizedCard.parameters.jsCode, /ignored_not_pending/);
const disableCard = approval.nodes.find((node) => node.name === 'Disable reviewed Slack card');
assert.equal(disableCard.parameters.url, 'https://slack.com/api/chat.update');

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
const core = readWorkflow('workflows/support-ticket-clustering.template.json');
const errorCapture = readWorkflow('workflows/operational-error-capture.template.json');
const operationalMonitor = readWorkflow('workflows/operational-monitor.template.json');
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

const normalize = core.nodes.find((node) => node.name === 'Normalize and validate input');
assert.match(normalize.parameters.jsCode, /REDACTED_EMAIL/);
assert.match(normalize.parameters.jsCode, /REDACTED_CARD/);
assert.doesNotMatch(normalize.parameters.jsCode, /original_event/);
assert(names(errorCapture).has('Sanitize failure metadata'));
assert(names(operationalMonitor).has('Refresh operational incidents'));
assert(names(operationalMonitor).has('Mark incidents notified'));

const migration007 = readFileSync('docs/sql/007_operational_observability.sql', 'utf8');
const migration008 = readFileSync('docs/sql/008_privacy_retention.sql', 'utf8');
const migration009 = readFileSync('docs/sql/009_recurrence_episodes.sql', 'utf8');
const migration010 = readFileSync('docs/sql/010_pilot_readiness_gates.sql', 'utf8');
assert.match(migration007, /operational_incidents/);
assert.match(migration007, /record_workflow_failure/);
assert.match(migration007, /severity = 'error' AND notified_at/);
assert.match(operationalMonitor.nodes.find((node) => node.name === 'Refresh operational incidents').parameters.query, /count\(\*\).*refreshed_count/);
assert.match(operationalMonitor.nodes.find((node) => node.name === 'Build sanitized operations alert').parameters.jsCode, /new Map\(\)/);
assert.match(migration008, /redact_ticket_before_write/);
assert.match(migration008, /redact_expired_ticket_content/);
assert.match(migration009, /recurrence_group_id/);
assert.match(migration009, /previous_episode_id/);
assert.match(migration009, /v_disposition := 'new_episode'/);
assert.match(migration009, /status = 'alerted'/);
assert.match(migration010, /DROP FUNCTION IF EXISTS record_review_action/);
assert.match(migration010, /ignored_wrong_state/);
assert.match(migration010, /verification_stuck/);

const coreWorkflow = JSON.parse(readFileSync('workflows/support-ticket-clustering.template.json', 'utf8'));
const normalizeInput = coreWorkflow.nodes.find((node) => node.name === 'Normalize and validate input');
assert.match(normalizeInput.parameters.jsCode, /REPLACE_WITH_SUPPORT_TICKETS_CHANNEL_ID/);
assert.match(normalizeInput.parameters.jsCode, /if \(sourceChannel !== allowedChannel\) return \[\]/);

const setupGuide = readFileSync('docs/n8n-ui-setup.md', 'utf8');
for (const workflowFile of [
  'operational-error-capture.template.json',
  'operational-monitor.template.json',
  'report-delivery.template.json',
  'approval-handler.template.json',
  'cluster-review.template.json',
  'requeue-cluster-verification.template.json',
  'support-ticket-clustering.template.json',
]) assert.match(setupGuide, new RegExp(workflowFile.replaceAll('.', '\\.'), 'u'));
assert.doesNotMatch(setupGuide, /16\.170\.93\.79/);
assert.doesNotMatch(setupGuide, /Notify engineering after approval/);
assert.doesNotMatch(setupGuide, /Record auditable human decision/);

console.log('PASS: production hardening workflow and migration contracts are internally consistent.');
