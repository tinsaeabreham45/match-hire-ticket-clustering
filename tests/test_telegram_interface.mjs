import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));
const telegram = readJson('workflows/telegram-interface.template.json');
const review = readJson('workflows/cluster-review.template.json');
const delivery = readJson('workflows/report-delivery.template.json');
const migration = readFileSync('docs/sql/014_telegram_interface.sql', 'utf8');

const validateGraph = (workflow) => {
  const names = new Set(workflow.nodes.map((node) => node.name));
  assert.equal(names.size, workflow.nodes.length, `${workflow.name} has duplicate node names`);
  for (const [source, outputs] of Object.entries(workflow.connections)) {
    assert(names.has(source), `${workflow.name} connection starts at missing node ${source}`);
    for (const output of outputs.main ?? []) {
      for (const edge of output) assert(names.has(edge.node), `${workflow.name} points to missing node ${edge.node}`);
    }
  }
  for (const codeNode of workflow.nodes.filter((node) => node.type === 'n8n-nodes-base.code')) {
    assert.doesNotThrow(() => new Function(codeNode.parameters.jsCode), `invalid JS in ${codeNode.name}`);
  }
};

for (const workflow of [telegram, review, delivery]) validateGraph(workflow);

const telegramNames = new Set(telegram.nodes.map((node) => node.name));
for (const required of [
  'Authenticate and normalize Telegram update',
  'Register idempotent Telegram update',
  'Acknowledge accepted update',
  'Process Telegram callback atomically',
  'Retry Telegram intake jobs',
  'Claim Telegram intake job',
  'Complete queued Telegram ticket',
  'Fail queued Telegram ticket',
  'Disable finalized Telegram buttons',
  'Run queued report delivery',
]) assert(telegramNames.has(required), `missing Telegram workflow node: ${required}`);

const auth = telegram.nodes.find((node) => node.name === 'Authenticate and normalize Telegram update');
assert.match(auth.parameters.jsCode, /TELEGRAM_WEBHOOK_SECRET/);
assert.match(auth.parameters.jsCode, /timingSafeEqual/);
assert.match(auth.parameters.jsCode, /x-telegram-bot-api-secret-token/i);
assert.match(auth.parameters.jsCode, /REDACTED_EMAIL/);
assert.match(auth.parameters.jsCode, /REDACTED_CARD/);
assert.match(auth.parameters.jsCode, /REDACTED_PHONE/);

const serializedTelegram = JSON.stringify(telegram);
assert.doesNotMatch(serializedTelegram, /bot[0-9]{8,}:[A-Za-z0-9_-]{20,}/);
assert.doesNotMatch(serializedTelegram, /api\.telegram\.org\/bot/);
assert(telegram.nodes.some((node) => node.type === 'n8n-nodes-base.telegram' && node.parameters.operation === 'answerQuery'));
assert.match(serializedTelegram, /editMessageText/);
const telegramEmbedding = telegram.nodes.find((node) => node.name === 'Embed queued Telegram ticket');
assert.equal(telegramEmbedding.parameters.options.response, undefined, 'embedding response must use n8n JSON auto-detection');
assert.deepEqual(
  telegramEmbedding.parameters.options,
  readJson('workflows/support-ticket-clustering.template.json').nodes.find((node) => node.name === 'Embed ticket with Gemini').parameters.options,
  'Telegram and Slack Gemini embedding nodes must use the same proven response options',
);
for (const telegramNode of [telegram, review, delivery].flatMap((workflow) => workflow.nodes).filter((node) => node.type === 'n8n-nodes-base.telegram')) {
  assert.equal(telegramNode.credentials, undefined, `${telegramNode.name} must remain credential-free in Git`);
}

for (const pattern of [
  /telegram_updates/,
  /update_id bigint PRIMARY KEY/,
  /telegram_intake_jobs/,
  /FOR UPDATE SKIP LOCKED/,
  /telegram_ticket_sessions/,
  /telegram_case_messages/,
  /authorized_telegram_approvers/,
  /telegram_review_surfaces/,
  /telegram_callback_tokens/,
  /create_telegram_setup_code/,
  /consume_telegram_setup_code/,
  /process_telegram_callback/,
  /claim_telegram_intake_job/,
  /complete_telegram_intake_job/,
  /fail_telegram_intake_job/,
  /record_workflow_failure/,
  /eng_telegram/,
  /delivery_channel/,
]) assert.match(migration, pattern);

assert.match(migration, /expires_at/);
assert.match(migration, /denied_not_authorized/);
assert.match(migration, /denied_unexpected_context/);
assert.match(migration, /message_id IS DISTINCT FROM p_message_id/);
assert.match(migration, /count\(\*\)=3 AND bool_and\(status='succeeded'\)/);
assert.doesNotMatch(migration, /TELEGRAM_BOT_TOKEN\s*=/);
assert.doesNotMatch(migration, /TELEGRAM_WEBHOOK_SECRET\s*=/);

const reviewNames = new Set(review.nodes.map((node) => node.name));
for (const required of [
  'Telegram review route?',
  'Create Telegram approval surface',
  'Post Telegram approval card',
  'Checkpoint Telegram approval card',
  'Telegram investigation route?',
  'Post Telegram investigation card',
]) assert(reviewNames.has(required), `missing shared review node: ${required}`);
assert.match(review.nodes.find((node) => node.name === 'Load cluster evidence').parameters.query, /telegram_case_messages/);
assert.match(review.nodes.find((node) => node.name === 'Persist pending report draft').parameters.query, /delivery_channel/);

const deliveryNames = new Set(delivery.nodes.map((node) => node.name));
for (const required of [
  'Engineering Telegram stage?',
  'Build Telegram engineering alert',
  'Notify engineering in Telegram',
  'Checkpoint Telegram and finalize delivery',
]) assert(deliveryNames.has(required), `missing Telegram delivery node: ${required}`);
assert.doesNotMatch(delivery.nodes.find((node) => node.name === 'Prepare Sheets audit row').parameters.jsCode, /Approved via Slack human review/);
assert.equal(
  delivery.nodes.find((node) => node.name === 'Create approved Google Doc').parameters.folderId,
  'REPLACE_WITH_GOOGLE_DRIVE_FOLDER_ID',
  'Google Docs delivery must require an explicit destination folder',
);

console.log('PASS: Telegram adapter security, durability, review, and delivery contracts are present.');
