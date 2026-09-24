#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs';

const load = (path) => JSON.parse(readFileSync(path, 'utf8'));
const save = (path, value) => writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
const byName = (workflow, name) => {
  const node = workflow.nodes.find((candidate) => candidate.name === name);
  if (!node) throw new Error(`Missing node: ${name}`);
  return node;
};
const main = (node, index = 0) => ({ node, type: 'main', index });
const connect = (workflow, from, outputs) => {
  workflow.connections[from] = { main: outputs.map((nodes) => nodes.map((name) => main(name))) };
};
const node = (id, name, type, position, parameters, typeVersion = 2) => ({
  id,
  name,
  type,
  typeVersion,
  position,
  parameters,
});
const ifEquals = (leftValue, rightValue, type = 'string') => ({
  conditions: {
    options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
    conditions: [{ leftValue, rightValue, operator: { type, operation: 'equals' } }],
    combinator: 'and',
  },
});
const telegramButton = (text, callbackData) => ({ text, additionalFields: { callback_data: callbackData } });
const telegramSend = (rows = [], dynamicMarkup = false) => ({
  resource: 'message',
  operation: 'sendMessage',
  chatId: '={{ $json.telegram_body.chat_id }}',
  text: '={{ $json.telegram_body.text }}',
  replyMarkup: rows.length ? (dynamicMarkup ? "={{ $json.operation === 'preview' ? 'inlineKeyboard' : 'none' }}" : 'inlineKeyboard') : 'none',
  ...(rows.length ? { inlineKeyboard: { rows: rows.map((buttons) => ({ row: { buttons } })) } } : {}),
  additionalFields: { appendAttribution: false, parse_mode: 'HTML', disable_web_page_preview: true },
});
const telegramEdit = () => ({
  resource: 'message', operation: 'editMessageText', messageType: 'message',
  chatId: '={{ $json.telegram_body.chat_id }}', messageId: '={{ $json.telegram_body.message_id }}',
  text: '={{ $json.telegram_body.text }}', replyMarkup: 'none',
  additionalFields: { parse_mode: 'HTML', disable_web_page_preview: true },
});
const telegramAnswer = () => ({
  resource: 'callback', operation: 'answerQuery',
  queryId: '={{ $json.telegram_body.callback_query_id }}',
  additionalFields: { text: '={{ $json.telegram_body.text }}', show_alert: '={{ $json.telegram_body.show_alert }}' },
});

function buildTelegramInterface() {
  const workflow = {
    name: 'Telegram support, review, and approval interface (template)',
    nodes: [],
    pinData: {},
    connections: {},
    active: false,
    settings: { executionOrder: 'v1' },
    tags: [],
    meta: {
      template: true,
      credentialFree: true,
      secrets: ['TELEGRAM_BOT_TOKEN', 'TELEGRAM_WEBHOOK_SECRET'],
    },
  };

  const nodes = [
    node('tg-0001', 'Telegram webhook', 'n8n-nodes-base.webhook', [180, 400], {
      httpMethod: 'POST',
      path: 'telegram-support-v1',
      responseMode: 'responseNode',
      options: {},
    }, 2),
    node('tg-0002', 'Authenticate and normalize Telegram update', 'n8n-nodes-base.code', [400, 400], {
      jsCode: `const crypto=require('crypto');
const body=$json.body??$json;
const headers=$json.headers??{};
const expected=String($env.TELEGRAM_WEBHOOK_SECRET??'');
const provided=String(headers['x-telegram-bot-api-secret-token']??headers['X-Telegram-Bot-Api-Secret-Token']??'');
const equal=expected.length>0&&provided.length===expected.length&&crypto.timingSafeEqual(Buffer.from(provided),Buffer.from(expected));
if(!equal)return[{json:{authorized:false}}];
const callback=body.callback_query;
const message=callback?.message??body.message;
const actor=callback?.from??message?.from;
const chat=message?.chat;
const updateId=Number(body.update_id);
if(!Number.isSafeInteger(updateId)||!message||!actor||!chat)return[{json:{authorized:false}}];
const raw=String(message?.text??message?.caption??'').trim();
const redact=(value)=>String(value)
 .replace(/\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b/gi,'[REDACTED_EMAIL]')
 .replace(/\\b(?:\\d[ -]?){13,19}\\b/g,'[REDACTED_CARD]')
 .replace(/(?<![A-Za-z0-9])\\+?\\d[\\d(). -]{7,}\\d(?![A-Za-z0-9])/g,'[REDACTED_PHONE]');
const kind=callback?'callback_query':body.message?'message':'unsupported';
return[{json:{authorized:true,update_id:updateId,kind,chat_id:chat.id,chat_type:String(chat.type??''),chat_title:String(chat.title??''),actor_user_id:actor.id,actor_name:[actor.first_name,actor.last_name].filter(Boolean).join(' '),text:redact(raw),callback_query_id:String(callback?.id??''),callback_token:String(callback?.data??''),message_id:message.message_id??null,message_text:String(message.text??''),received_at:new Date().toISOString()}}];`,
    }),
    node('tg-0003', 'Authorized webhook?', 'n8n-nodes-base.if', [620, 400], ifEquals('={{ $json.authorized }}', true, 'boolean'), 2.2),
    node('tg-0004', 'Reject unauthenticated webhook', 'n8n-nodes-base.respondToWebhook', [850, 560], {
      respondWith: 'json', responseBody: '={"ok":false}', options: { responseCode: 401 },
    }, 1.4),
    node('tg-0005', 'Register idempotent Telegram update', 'n8n-nodes-base.postgres', [850, 320], {
      operation: 'executeQuery',
      query: 'SELECT * FROM ticket_cluster.register_telegram_update($1::bigint,$2,$3::bigint,$4::bigint,30);',
      options: { queryReplacement: "={{ [$json.update_id,$json.kind,$json.chat_id,$json.actor_user_id] }}" },
    }, 2.5),
    node('tg-0006', 'New update?', 'n8n-nodes-base.if', [1070, 320], ifEquals('={{ $json.accepted }}', true, 'boolean'), 2.2),
    node('tg-0007', 'Acknowledge duplicate or limited update', 'n8n-nodes-base.respondToWebhook', [1290, 500], {
      respondWith: 'json', responseBody: '={"ok":true}', options: { responseCode: 200 },
    }, 1.4),
    node('tg-0008', 'Acknowledge accepted update', 'n8n-nodes-base.respondToWebhook', [1290, 260], {
      respondWith: 'json', responseBody: '={"ok":true}', options: { responseCode: 200 },
    }, 1.4),
    node('tg-0009', 'Callback query?', 'n8n-nodes-base.if', [1510, 260], ifEquals("={{ $('Authenticate and normalize Telegram update').item.json.kind }}", 'callback_query'), 2.2),
    node('tg-0010', 'Handle Telegram message state', 'n8n-nodes-base.postgres', [1730, 440], {
      operation: 'executeQuery',
      query: 'SELECT * FROM ticket_cluster.handle_telegram_message($1::bigint,$2::bigint,$3,$4::bigint,$5,$6);',
      options: { queryReplacement: "={{ [\n  $('Authenticate and normalize Telegram update').item.json.update_id,\n  $('Authenticate and normalize Telegram update').item.json.chat_id,\n  $('Authenticate and normalize Telegram update').item.json.chat_type,\n  $('Authenticate and normalize Telegram update').item.json.actor_user_id,\n  $('Authenticate and normalize Telegram update').item.json.actor_name,\n  $('Authenticate and normalize Telegram update').item.json.text\n] }}" },
    }, 2.5),
    node('tg-0011', 'Build Telegram bot reply', 'n8n-nodes-base.code', [1950, 440], {
      jsCode: `const r=$json,n=$('Authenticate and normalize Telegram update').item.json;
const escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch]));
const rawReply=String(r.reply_text??''),body={chat_id:n.chat_id,text:escape(rawReply.length>3900?rawReply.slice(0,3897)+'...':rawReply),disable_web_page_preview:true};
if(r.operation==='preview')body.reply_markup={inline_keyboard:[[{text:'Confirm ticket',callback_data:r.confirm_token},{text:'Cancel',callback_data:r.cancel_token}]]};
return[{json:{...r,update_id:n.update_id,telegram_body:body}}];`,
    }),
    node('tg-0012', 'Send Telegram bot reply', 'n8n-nodes-base.telegram', [2170, 440], telegramSend([[
      telegramButton('Confirm ticket', '={{ $json.confirm_token }}'),
      telegramButton('Cancel', '={{ $json.cancel_token }}'),
    ]], true), 1.2),
    node('tg-0013', 'Verify Telegram bot reply', 'n8n-nodes-base.code', [2390, 440], {
      jsCode: "if($json.ok!==true)throw new Error(`Telegram sendMessage rejected: ${$json.description??'unknown error'}`);return[{json:{update_id:$('Authenticate and normalize Telegram update').item.json.update_id}}];",
    }),
    node('tg-0014', 'Complete Telegram message update', 'n8n-nodes-base.postgres', [2610, 440], {
      operation: 'executeQuery',
      query: "SELECT ticket_cluster.complete_telegram_update($1::bigint,'completed') AS completed;",
      options: { queryReplacement: '={{ [$json.update_id] }}' },
    }, 2.5),
    node('tg-0015', 'Process Telegram callback atomically', 'n8n-nodes-base.postgres', [1730, 80], {
      operation: 'executeQuery',
      query: 'SELECT * FROM ticket_cluster.process_telegram_callback($1::bigint,$2,$3,$4::bigint,$5::bigint,$6::bigint);',
      options: { queryReplacement: "={{ [\n  $('Authenticate and normalize Telegram update').item.json.update_id,\n  $('Authenticate and normalize Telegram update').item.json.callback_query_id,\n  $('Authenticate and normalize Telegram update').item.json.callback_token,\n  $('Authenticate and normalize Telegram update').item.json.actor_user_id,\n  $('Authenticate and normalize Telegram update').item.json.chat_id,\n  $('Authenticate and normalize Telegram update').item.json.message_id\n] }}" },
    }, 2.5),
    node('tg-0016', 'Build callback acknowledgement', 'n8n-nodes-base.code', [1950, 80], {
      jsCode: `const r=$json,n=$('Authenticate and normalize Telegram update').item.json;return[{json:{...r,update_id:n.update_id,telegram_body:{callback_query_id:n.callback_query_id,text:r.answer_text,show_alert:String(r.outcome).startsWith('denied_')}}}];`,
    }),
    node('tg-0017', 'Answer Telegram callback', 'n8n-nodes-base.telegram', [2170, 80], telegramAnswer(), 1.2),
    node('tg-0018', 'Complete Telegram callback update', 'n8n-nodes-base.postgres', [2390, 80], {
      operation: 'executeQuery',
      query: "SELECT ticket_cluster.complete_telegram_update($1::bigint,'completed') AS completed;",
      options: { queryReplacement: "={{ [$('Build callback acknowledgement').item.json.update_id] }}" },
    }, 2.5),
    node('tg-0019', 'Retry Telegram intake jobs', 'n8n-nodes-base.scheduleTrigger', [180, -180], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
    }, 1.2),
    node('tg-0020', 'Claim Telegram intake job', 'n8n-nodes-base.postgres', [400, -180], {
      operation: 'executeQuery', query: 'SELECT * FROM ticket_cluster.claim_telegram_intake_job(5);', options: {},
    }, 2.5),
    node('tg-0021', 'Embed queued Telegram ticket', 'n8n-nodes-base.httpRequest', [620, -180], {
      method: 'POST',
      url: 'https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent',
      sendHeaders: true,
      headerParameters: { parameters: [{ name: 'Content-Type', value: 'application/json' }] },
      sendBody: true,
      contentType: 'raw',
      rawContentType: 'application/json',
      body: "={{ JSON.stringify({ taskType: 'CLUSTERING', output_dimensionality: 768, content: { parts: [{ text: $('Claim Telegram intake job').item.json.ticket_text }] } }) }}",
      options: { timeout: 15000, retry: { maxTries: 3, waitBetweenTries: 1000 } },
    }, 4.2),
    node('tg-0022', 'Validate queued Telegram embedding', 'n8n-nodes-base.code', [840, -180], {
      jsCode: `const job=$('Claim Telegram intake job').item.json,values=$json.embedding?.values;const valid=Array.isArray(values)&&values.length===768&&values.every(Number.isFinite);return[{json:{...job,embedding_valid:valid,embedding_vector:valid?'['+values.join(',')+']':null,error_message:valid?null:String($json.error?.message??$json.message??'Gemini returned an invalid embedding').slice(0,500)}}];`,
    }),
    node('tg-0023', 'Embedding ready?', 'n8n-nodes-base.if', [1060, -180], ifEquals('={{ $json.embedding_valid }}', true, 'boolean'), 2.2),
    node('tg-0024', 'Complete queued Telegram ticket', 'n8n-nodes-base.postgres', [1280, -280], {
      operation: 'executeQuery',
      query: "SELECT * FROM ticket_cluster.complete_telegram_intake_job($1::uuid,$2::vector,'gemini-embedding-001','telegram-v1');",
      options: { queryReplacement: '={{ [$json.job_id,$json.embedding_vector] }}' },
    }, 2.5),
    node('tg-0025', 'Build completed ticket message', 'n8n-nodes-base.code', [1500, -280], {
      jsCode: `const r=$json,suffix=r.disposition==='duplicate'?'This ticket was already received.':'Ticket created: '+r.ticket_id;return[{json:{...r,telegram_body:{chat_id:r.chat_id,text:'✅ '+suffix+'\\n\\nYou can send follow-ups here or use /close.'}}}];`,
    }),
    node('tg-0026', 'Send completed ticket message', 'n8n-nodes-base.telegram', [1720, -280], telegramSend(), 1.2),
    node('tg-0027', 'Telegram verification required?', 'n8n-nodes-base.if', [1940, -280], ifEquals("={{ $('Complete queued Telegram ticket').item.json.review_required }}", true, 'boolean'), 2.2),
    node('tg-0028', 'Prepare Telegram review request', 'n8n-nodes-base.code', [2160, -360], {
      jsCode: "const r=$('Complete queued Telegram ticket').item.json;return[{json:{...r,review_interface:'telegram',delivery_channel:'telegram'}}];",
    }),
    node('tg-0029', 'Run verification for Telegram cluster', 'n8n-nodes-base.executeWorkflow', [2380, -360], {
      workflowId: { __rl: true, mode: 'id', value: 'REPLACE_WITH_IMPORTED_CLUSTER_REVIEW_WORKFLOW_ID' }, options: {},
    }, 1.2),
    node('tg-0030', 'Fail queued Telegram ticket', 'n8n-nodes-base.postgres', [1280, -80], {
      operation: 'executeQuery', query: 'SELECT * FROM ticket_cluster.fail_telegram_intake_job($1::uuid,$2,5);', options: { queryReplacement: '={{ [$json.job_id,$json.error_message] }}' },
    }, 2.5),
    node('tg-0031', 'Telegram intake permanently failed?', 'n8n-nodes-base.if', [1500, -80], ifEquals('={{ $json.terminal }}', true, 'boolean'), 2.2),
    node('tg-0032', 'Build Telegram intake failure message', 'n8n-nodes-base.code', [1720, -80], {
      jsCode: "return[{json:{telegram_body:{chat_id:$json.chat_id,text:'We could not process this ticket after several retries. Your description is still available; send it again or contact support operations.'}}}];",
    }),
    node('tg-0033', 'Send Telegram intake failure message', 'n8n-nodes-base.telegram', [1940, -80], telegramSend(), 1.2),
    node('tg-0034', 'Finalize callback card?', 'n8n-nodes-base.if', [2610, 200], {
      conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: "={{ $('Process Telegram callback atomically').item.json.operation }}", rightValue: 'noop', operator: { type: 'string', operation: 'notEquals' } }], combinator: 'and' },
    }, 2.2),
    node('tg-0035', 'Build finalized callback card', 'n8n-nodes-base.code', [2830, 200], {
      jsCode: `const r=$('Process Telegram callback atomically').item.json,n=$('Authenticate and normalize Telegram update').item.json;const escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch]));const raw=n.message_text.replace(/\\n\\n(?:✅|❌|ℹ️|⏳)[\\s\\S]*$/,''),original=raw.length>3600?raw.slice(0,3597)+'...':raw;const icon=r.outcome==='queued'?'⏳':['delivery_queued','retry_queued'].includes(r.outcome)?'✅':r.outcome==='split'?'ℹ️':'❌';return[{json:{...r,telegram_body:{chat_id:n.chat_id,message_id:n.message_id,text:escape(original)+'\\n\\n'+icon+' '+escape(r.answer_text),reply_markup:{inline_keyboard:[]}}}}];`,
    }),
    node('tg-0036', 'Disable finalized Telegram buttons', 'n8n-nodes-base.telegram', [3050, 200], telegramEdit(), 1.2),
    node('tg-0037', 'Run queued Telegram delivery?', 'n8n-nodes-base.if', [3270, 200], ifEquals("={{ $('Process Telegram callback atomically').item.json.operation }}", 'run_delivery'), 2.2),
    node('tg-0038', 'Run queued report delivery', 'n8n-nodes-base.executeWorkflow', [3490, 120], {
      workflowId: { __rl: true, mode: 'id', value: 'REPLACE_WITH_IMPORTED_REPORT_DELIVERY_WORKFLOW_ID' }, options: {},
    }, 1.2),
    node('tg-0039', 'Retry Telegram investigation?', 'n8n-nodes-base.if', [3490, 280], ifEquals("={{ $('Process Telegram callback atomically').item.json.operation }}", 'retry_verification'), 2.2),
    node('tg-0040', 'Run Telegram verification again', 'n8n-nodes-base.executeWorkflow', [3710, 280], {
      workflowId: { __rl: true, mode: 'id', value: 'REPLACE_WITH_IMPORTED_CLUSTER_REVIEW_WORKFLOW_ID' }, options: {},
    }, 1.2),
  ];
  nodes.find((candidate) => candidate.name === 'Telegram webhook').webhookId = 'f42d8d63-b979-4fd5-8c83-c8a96ef84a14';
  workflow.nodes.push(...nodes);

  connect(workflow, 'Telegram webhook', [['Authenticate and normalize Telegram update']]);
  connect(workflow, 'Authenticate and normalize Telegram update', [['Authorized webhook?']]);
  connect(workflow, 'Authorized webhook?', [['Register idempotent Telegram update'], ['Reject unauthenticated webhook']]);
  connect(workflow, 'Register idempotent Telegram update', [['New update?']]);
  connect(workflow, 'New update?', [['Acknowledge accepted update'], ['Acknowledge duplicate or limited update']]);
  connect(workflow, 'Acknowledge accepted update', [['Callback query?']]);
  connect(workflow, 'Callback query?', [['Process Telegram callback atomically'], ['Handle Telegram message state']]);
  connect(workflow, 'Handle Telegram message state', [['Build Telegram bot reply']]);
  connect(workflow, 'Build Telegram bot reply', [['Send Telegram bot reply']]);
  connect(workflow, 'Send Telegram bot reply', [['Verify Telegram bot reply']]);
  connect(workflow, 'Verify Telegram bot reply', [['Complete Telegram message update']]);
  connect(workflow, 'Process Telegram callback atomically', [['Build callback acknowledgement']]);
  connect(workflow, 'Build callback acknowledgement', [['Answer Telegram callback']]);
  connect(workflow, 'Answer Telegram callback', [['Complete Telegram callback update']]);
  connect(workflow, 'Complete Telegram callback update', [['Finalize callback card?']]);
  connect(workflow, 'Retry Telegram intake jobs', [['Claim Telegram intake job']]);
  connect(workflow, 'Claim Telegram intake job', [['Embed queued Telegram ticket']]);
  connect(workflow, 'Embed queued Telegram ticket', [['Validate queued Telegram embedding']]);
  connect(workflow, 'Validate queued Telegram embedding', [['Embedding ready?']]);
  connect(workflow, 'Embedding ready?', [['Complete queued Telegram ticket'], ['Fail queued Telegram ticket']]);
  connect(workflow, 'Complete queued Telegram ticket', [['Build completed ticket message']]);
  connect(workflow, 'Build completed ticket message', [['Send completed ticket message']]);
  connect(workflow, 'Send completed ticket message', [['Telegram verification required?']]);
  connect(workflow, 'Telegram verification required?', [['Prepare Telegram review request'], []]);
  connect(workflow, 'Prepare Telegram review request', [['Run verification for Telegram cluster']]);
  connect(workflow, 'Fail queued Telegram ticket', [['Telegram intake permanently failed?']]);
  connect(workflow, 'Telegram intake permanently failed?', [['Build Telegram intake failure message'], []]);
  connect(workflow, 'Build Telegram intake failure message', [['Send Telegram intake failure message']]);
  connect(workflow, 'Finalize callback card?', [['Build finalized callback card'], []]);
  connect(workflow, 'Build finalized callback card', [['Disable finalized Telegram buttons']]);
  connect(workflow, 'Disable finalized Telegram buttons', [['Run queued Telegram delivery?']]);
  connect(workflow, 'Run queued Telegram delivery?', [['Run queued report delivery'], ['Retry Telegram investigation?']]);
  connect(workflow, 'Retry Telegram investigation?', [['Run Telegram verification again'], []]);
  return workflow;
}

function extendClusterReview() {
  const workflow = load('workflows/cluster-review.template.json');
  if (workflow.nodes.some((candidate) => candidate.name === 'Telegram review route?')) {
    const approval = byName(workflow, 'Post Telegram approval card');
    approval.type = 'n8n-nodes-base.telegram'; approval.typeVersion = 1.2;
    approval.parameters = telegramSend([
      [telegramButton('Approve & alert engineering', "={{ $('Create Telegram approval surface').item.json.approve_token }}")],
      [telegramButton('Reject', "={{ $('Create Telegram approval surface').item.json.reject_token }}"), telegramButton('Split cluster', "={{ $('Create Telegram approval surface').item.json.split_token }}")],
    ]);
    const investigation = byName(workflow, 'Post Telegram investigation card');
    investigation.type = 'n8n-nodes-base.telegram'; investigation.typeVersion = 1.2;
    investigation.parameters = telegramSend([
      [telegramButton('Retry verification', "={{ $('Create Telegram investigation surface').item.json.retry_token }}")],
      [telegramButton('Dismiss', "={{ $('Create Telegram investigation surface').item.json.dismiss_token }}"), telegramButton('Split cluster', "={{ $('Create Telegram investigation surface').item.json.split_token }}")],
    ]);
    byName(workflow, 'Build Telegram approval card').parameters.jsCode = `const s=$json,d=s.report_context;const escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch])),clip=(value,n)=>escape(String(value??'').slice(0,n));const evidence=(d.evidence??[]).slice(0,5).map((e,i)=>(i+1)+'. '+clip(e.description??e.text??'No description',350)).join('\\n');const text='Root-cause review required\\n\\nSummary: '+clip(d.summary,600)+'\\n\\nSuspected cause: '+clip(d.suspected_root_cause,600)+'\\n\\nImpact: '+clip(d.impact,600)+'\\n\\nEvidence:\\n'+evidence+'\\n\\nNext step: '+clip(d.recommended_next_step,500);return[{json:{surface_id:s.surface_id,telegram_body:{chat_id:s.chat_id,text,disable_web_page_preview:true}}}];`;
    byName(workflow, 'Build Telegram investigation card').parameters.jsCode = `const s=$json,d=s.investigation_context,c=d.review_context;const escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch])),clip=(value,n)=>escape(String(value??'').slice(0,n));const evidence=(c.tickets??[]).slice(0,5).map((t,i)=>(i+1)+'. '+clip(t.text,400)).join('\\n');const text='Root-cause investigation required\\n\\nAI verdict: '+clip(d.verdict,100)+' ('+Math.round(Number(d.confidence)*100)+'% confidence)\\nWhy: '+clip(c.verification?.rationale??d.reason,600)+'\\nCurrent hypothesis: '+clip(d.reason,600)+'\\n\\nEvidence:\\n'+evidence+'\\n\\nRetry only after more evidence or provider recovery.';return[{json:{surface_id:s.surface_id,telegram_body:{chat_id:s.chat_id,text}}}];`;
    return workflow;
  }

  const loadEvidence = byName(workflow, 'Load cluster evidence');
  loadEvidence.parameters.query = "SELECT c.id AS cluster_id,c.ticket_count,jsonb_agg(jsonb_build_object('ticket_id',t.id,'text',t.raw_text||coalesce(f.followups,'')) ORDER BY ct.assigned_at) AS tickets,$2::jsonb AS adapter_context FROM ticket_cluster.clusters c JOIN ticket_cluster.cluster_tickets ct ON ct.cluster_id=c.id JOIN ticket_cluster.tickets t ON t.id=ct.ticket_id LEFT JOIN LATERAL (SELECT E'\\nFollow-up evidence:\\n'||string_agg(m.text,E'\\n' ORDER BY m.created_at) AS followups FROM ticket_cluster.telegram_case_messages m WHERE m.ticket_id=t.id) f ON true WHERE c.id=$1::uuid GROUP BY c.id,c.ticket_count;";
  loadEvidence.parameters.options.queryReplacement = "={{ [$json.cluster_id,JSON.stringify({review_interface:$json.review_interface??'slack',delivery_channel:$json.delivery_channel??'slack'})] }}";

  const persistVerification = byName(workflow, 'Persist verification');
  persistVerification.parameters.options.queryReplacement = "={{ [$json.cluster_id,$json.verification_model,$json.verification.verdict,$json.verification.confidence,$json.verification.root_cause,$json.evidence_ticket_ids_json,$json.verification_response_json,$json.review_context_json] }}";

  workflow.nodes.push(node('tg-review-persist-prepare', 'Prepare verification persistence', 'n8n-nodes-base.code', [1925, 300], {
    jsCode: "const j=$json;const adapter_context=j.adapter_context??{review_interface:'slack',delivery_channel:'slack'};return[{json:{...j,evidence_ticket_ids_json:JSON.stringify(j.verification.evidence_ticket_ids),verification_response_json:JSON.stringify({result:j.verification,response:j.response,provider_failure:j.provider_failure===true}),review_context_json:JSON.stringify({cluster_id:j.cluster_id,tickets:j.tickets,verification:j.verification,adapter_context})}}];",
  }));
  workflow.connections['Use Gemini verification fallback?'].main[1][0].node = 'Prepare verification persistence';
  workflow.connections['Validate Gemini verification fallback'].main[0][0].node = 'Prepare verification persistence';
  connect(workflow, 'Prepare verification persistence', [['Persist verification']]);

  const persistDraft = byName(workflow, 'Persist pending report draft');
  persistDraft.parameters.query = "INSERT INTO ticket_cluster.cluster_report_drafts (cluster_id,model,summary,suspected_root_cause,impact,evidence,recommended_next_step,report,delivery_channel) VALUES ($1::uuid,$2,$3,$4,$5,$6::jsonb,$7,$8::jsonb,$9) RETURNING id AS report_draft_id,cluster_id,summary,suspected_root_cause,impact,evidence,recommended_next_step,delivery_channel;";
  persistDraft.parameters.options.queryReplacement = "={{ [$json.cluster_id,$json.report_model,$json.report.summary,$json.report.suspected_root_cause,$json.report.impact,JSON.stringify($json.report.evidence),$json.report.recommended_next_step,JSON.stringify($json.report),$json.adapter_context?.delivery_channel??'slack'] }}";

  workflow.nodes.push(
    node('tg-review-01', 'Telegram review route?', 'n8n-nodes-base.if', [4110, 160], ifEquals('={{ $json.delivery_channel }}', 'telegram'), 2.2),
    node('tg-review-02', 'Create Telegram approval surface', 'n8n-nodes-base.postgres', [4340, 40], {
      operation: 'executeQuery',
      query: "SELECT s.*,$2::jsonb AS report_context FROM ticket_cluster.create_telegram_review_surface('report',$1::uuid) s;",
      options: { queryReplacement: '={{ [$json.report_draft_id,JSON.stringify($json)] }}' },
    }, 2.5),
    node('tg-review-03', 'Build Telegram approval card', 'n8n-nodes-base.code', [4570, 40], {
      jsCode: `const s=$json,d=s.report_context;const escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch])),clip=(value,n)=>escape(String(value??'').slice(0,n));const evidence=(d.evidence??[]).slice(0,5).map((e,i)=>(i+1)+'. '+clip(e.description??e.text??'No description',350)).join('\\n');const text='Root-cause review required\\n\\nSummary: '+clip(d.summary,600)+'\\n\\nSuspected cause: '+clip(d.suspected_root_cause,600)+'\\n\\nImpact: '+clip(d.impact,600)+'\\n\\nEvidence:\\n'+evidence+'\\n\\nNext step: '+clip(d.recommended_next_step,500);return[{json:{surface_id:s.surface_id,telegram_body:{chat_id:s.chat_id,text,disable_web_page_preview:true}}}];`,
    }),
    node('tg-review-04', 'Post Telegram approval card', 'n8n-nodes-base.telegram', [4800, 40], telegramSend([
      [telegramButton('Approve & alert engineering', "={{ $('Create Telegram approval surface').item.json.approve_token }}")],
      [
        telegramButton('Reject', "={{ $('Create Telegram approval surface').item.json.reject_token }}"),
        telegramButton('Split cluster', "={{ $('Create Telegram approval surface').item.json.split_token }}"),
      ],
    ]), 1.2),
    node('tg-review-05', 'Verify Telegram approval card', 'n8n-nodes-base.code', [5030, 40], {
      jsCode: "if($json.ok!==true||!$json.result?.message_id)throw new Error(`Telegram approval card rejected: ${$json.description??'missing message id'}`);return[{json:{surface_id:$('Build Telegram approval card').item.json.surface_id,message_id:$json.result.message_id}}];",
    }),
    node('tg-review-06', 'Checkpoint Telegram approval card', 'n8n-nodes-base.postgres', [5260, 40], {
      operation: 'executeQuery', query: 'SELECT ticket_cluster.mark_telegram_review_surface_sent($1::uuid,$2::bigint);', options: { queryReplacement: '={{ [$json.surface_id,$json.message_id] }}' },
    }, 2.5),
    node('tg-investigation-01', 'Telegram investigation route?', 'n8n-nodes-base.if', [2960, 440], ifEquals("={{ $json.review_context?.adapter_context?.delivery_channel ?? 'slack' }}", 'telegram'), 2.2),
    node('tg-investigation-02', 'Create Telegram investigation surface', 'n8n-nodes-base.postgres', [3190, 600], {
      operation: 'executeQuery',
      query: "SELECT s.*,$2::jsonb AS investigation_context FROM ticket_cluster.create_telegram_review_surface('investigation',$1::uuid) s;",
      options: { queryReplacement: '={{ [$json.investigation_id,JSON.stringify($json)] }}' },
    }, 2.5),
    node('tg-investigation-03', 'Build Telegram investigation card', 'n8n-nodes-base.code', [3420, 600], {
      jsCode: `const s=$json,d=s.investigation_context,c=d.review_context;const escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch])),clip=(value,n)=>escape(String(value??'').slice(0,n));const evidence=(c.tickets??[]).slice(0,5).map((t,i)=>(i+1)+'. '+clip(t.text,400)).join('\\n');const text='Root-cause investigation required\\n\\nAI verdict: '+clip(d.verdict,100)+' ('+Math.round(Number(d.confidence)*100)+'% confidence)\\nWhy: '+clip(c.verification?.rationale??d.reason,600)+'\\nCurrent hypothesis: '+clip(d.reason,600)+'\\n\\nEvidence:\\n'+evidence+'\\n\\nRetry only after more evidence or provider recovery.';return[{json:{surface_id:s.surface_id,telegram_body:{chat_id:s.chat_id,text}}}];`,
    }),
    node('tg-investigation-04', 'Post Telegram investigation card', 'n8n-nodes-base.telegram', [3650, 600], telegramSend([
      [telegramButton('Retry verification', "={{ $('Create Telegram investigation surface').item.json.retry_token }}")],
      [
        telegramButton('Dismiss', "={{ $('Create Telegram investigation surface').item.json.dismiss_token }}"),
        telegramButton('Split cluster', "={{ $('Create Telegram investigation surface').item.json.split_token }}"),
      ],
    ]), 1.2),
    node('tg-investigation-05', 'Verify Telegram investigation card', 'n8n-nodes-base.code', [3880, 600], {
      jsCode: "if($json.ok!==true||!$json.result?.message_id)throw new Error(`Telegram investigation card rejected: ${$json.description??'missing message id'}`);return[{json:{surface_id:$('Build Telegram investigation card').item.json.surface_id,message_id:$json.result.message_id}}];",
    }),
    node('tg-investigation-06', 'Checkpoint Telegram investigation card', 'n8n-nodes-base.postgres', [4110, 600], {
      operation: 'executeQuery', query: 'SELECT ticket_cluster.mark_telegram_review_surface_sent($1::uuid,$2::bigint);', options: { queryReplacement: '={{ [$json.surface_id,$json.message_id] }}' },
    }, 2.5),
  );

  connect(workflow, 'Persist pending report draft', [['Telegram review route?']]);
  connect(workflow, 'Telegram review route?', [['Create Telegram approval surface'], ['Build Slack approval card']]);
  connect(workflow, 'Create Telegram approval surface', [['Build Telegram approval card']]);
  connect(workflow, 'Build Telegram approval card', [['Post Telegram approval card']]);
  connect(workflow, 'Post Telegram approval card', [['Verify Telegram approval card']]);
  connect(workflow, 'Verify Telegram approval card', [['Checkpoint Telegram approval card']]);

  connect(workflow, 'Investigation card needed?', [['Telegram investigation route?'], []]);
  connect(workflow, 'Telegram investigation route?', [['Create Telegram investigation surface'], ['Build Slack investigation card']]);
  connect(workflow, 'Create Telegram investigation surface', [['Build Telegram investigation card']]);
  connect(workflow, 'Build Telegram investigation card', [['Post Telegram investigation card']]);
  connect(workflow, 'Post Telegram investigation card', [['Verify Telegram investigation card']]);
  connect(workflow, 'Verify Telegram investigation card', [['Checkpoint Telegram investigation card']]);
  return workflow;
}

function extendReportDelivery() {
  const workflow = load('workflows/report-delivery.template.json');
  const createDocument = byName(workflow, 'Create approved Google Doc');
  if (!createDocument.parameters.folderId) {
    createDocument.parameters.folderId = 'REPLACE_WITH_GOOGLE_DRIVE_FOLDER_ID';
  }
  if (workflow.nodes.some((candidate) => candidate.name === 'Engineering Telegram stage?')) {
    const notify = byName(workflow, 'Notify engineering in Telegram');
    notify.type = 'n8n-nodes-base.telegram'; notify.typeVersion = 1.2; notify.parameters = telegramSend();
    byName(workflow, 'Build Telegram engineering alert').parameters.jsCode = "const r=$json,escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch]));return[{json:{attempt_id:r.attempt_id,report_draft_id:r.report_draft_id,telegram_body:{chat_id:r.destination_ref,text:'Approved support root-cause alert: '+escape(String(r.summary??'').slice(0,3000))+' — '+escape(r.google_doc_url)}}}];";
    return workflow;
  }
  byName(workflow, 'Prepare Sheets audit row').parameters.jsCode = byName(workflow, 'Prepare Sheets audit row').parameters.jsCode.replace('Approved via Slack human review.', 'Approved via human review.');
  byName(workflow, 'Format approved report').parameters.jsCode = byName(workflow, 'Format approved report').parameters.jsCode.replace('Approved via Slack human review.', 'Approved via human review.');

  workflow.nodes.push(
    node('tg-delivery-01', 'Engineering Telegram stage?', 'n8n-nodes-base.if', [1360, 820], ifEquals('={{ $json.target }}', 'eng_telegram'), 2.2),
    node('tg-delivery-02', 'Build Telegram engineering alert', 'n8n-nodes-base.code', [1590, 820], {
      jsCode: "const r=$json,escape=value=>String(value??'').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch]));return[{json:{attempt_id:r.attempt_id,report_draft_id:r.report_draft_id,telegram_body:{chat_id:r.destination_ref,text:'Approved support root-cause alert: '+escape(String(r.summary??'').slice(0,3000))+' — '+escape(r.google_doc_url)}}}];",
    }),
    node('tg-delivery-03', 'Notify engineering in Telegram', 'n8n-nodes-base.telegram', [1820, 820], telegramSend(), 1.2),
    node('tg-delivery-04', 'Verify Telegram engineering alert', 'n8n-nodes-base.code', [2050, 820], {
      jsCode: "if($json.ok!==true||!$json.result?.message_id)throw new Error(`Engineering Telegram alert rejected: ${$json.description??'missing message id'}`);const s=$('Build Telegram engineering alert').item.json;return[{json:{attempt_id:s.attempt_id,report_draft_id:s.report_draft_id,message_id:String($json.result.message_id)}}];",
    }),
    node('tg-delivery-05', 'Checkpoint Telegram and finalize delivery', 'n8n-nodes-base.postgres', [2280, 820], {
      operation: 'executeQuery',
      query: 'SELECT ticket_cluster.complete_delivery_attempt($1::uuid,$2,NULL); SELECT ticket_cluster.finalize_report_delivery($3::uuid) AS finalized;',
      options: { queryReplacement: '={{ [$json.attempt_id,$json.message_id,$json.report_draft_id] }}' },
    }, 2.5),
  );
  connect(workflow, 'Engineering Slack stage?', [['Build engineering alert'], ['Engineering Telegram stage?']]);
  connect(workflow, 'Engineering Telegram stage?', [['Build Telegram engineering alert'], []]);
  connect(workflow, 'Build Telegram engineering alert', [['Notify engineering in Telegram']]);
  connect(workflow, 'Notify engineering in Telegram', [['Verify Telegram engineering alert']]);
  connect(workflow, 'Verify Telegram engineering alert', [['Checkpoint Telegram and finalize delivery']]);
  return workflow;
}

save('workflows/telegram-interface.template.json', buildTelegramInterface());
save('workflows/cluster-review.template.json', extendClusterReview());
save('workflows/report-delivery.template.json', extendReportDelivery());
console.log('Built Telegram workflow and extended shared review/delivery workflows.');
