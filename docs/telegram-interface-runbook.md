# Telegram interface operator runbook

This release adds a single-company Telegram adapter without changing the
clustering algorithm or removing Slack. Telegram can provide private ticket
intake, a private human-review group, and a separate engineering-alert group.

## Security boundary

- `TELEGRAM_BOT_TOKEN` is the token issued by BotFather.
- `TELEGRAM_WEBHOOK_SECRET` is an independently generated random value.
- Neither value belongs in Git, workflow JSON, Postgres, an n8n Code node, a
  screenshot, or chat.
- Keep BotFather **Group Privacy** enabled. Tickets are accepted only in a
  private chat with the bot. Groups are used only for explicit `/connect`
  setup commands, review buttons, and outbound alerts.
- Review callbacks require the configured review chat, an active authorized
  Telegram user, the exact message ID, an unexpired opaque token, and a still
  pending database state.

## 1. Generate and store the two secrets

The BotFather value becomes `TELEGRAM_BOT_TOKEN`. In a private server shell,
generate the other value without putting the value itself in shell history:

```bash
openssl rand -hex 32
```

Store the 64-character output immediately in the protected Compose environment
file and clear the terminal. Do not paste it into chat.

In n8n, open **Credentials**, create a **Telegram API** credential, enter the
BotFather token, and label it `TELEGRAM_BOT_TOKEN`. Attach that credential to
every Telegram node in the three imported workflows. This keeps the token out
of resolved HTTP URLs and execution diagnostics.

Add only the webhook secret to the private environment file used by Docker
Compose. Add this reference under the n8n service's `environment` section:

```yaml
- TELEGRAM_WEBHOOK_SECRET=${TELEGRAM_WEBHOOK_SECRET}
```

Do not run `docker compose config` in a shared terminal after adding them,
because rendered Compose output can expose environment values.

## 2. Apply and validate before import

Apply migrations through `014_telegram_interface.sql` to a fresh staging
database. Then run:

```bash
node tests/test_telegram_interface.mjs
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U n8n -d n8n_staging < tests/test_telegram_interface.sql
```

Keep the production workflow inactive until the staging SQL test and the
manual unauthorized-review test pass.

## 3. Import the workflows

Import or update these three files in this order:

1. `workflows/report-delivery.template.json`
2. `workflows/cluster-review.template.json`
3. `workflows/telegram-interface.template.json`

In the Telegram workflow, select the imported cluster-review workflow in both
verification nodes and select the imported report-delivery workflow in the
delivery node. Attach the existing Postgres credential to every Postgres node
and the existing Gemini header credential to **Embed queued Telegram ticket**.
Attach the `TELEGRAM_BOT_TOKEN` Telegram API credential to every Telegram node
in all three workflows. Set the standard operational error-capture workflow as this workflow's Error
Workflow. Save and publish, but do not activate yet.

## 4. Register the webhook safely

Before registration, allow Telegram's webhook senders to reach HTTPS on the
EC2 security group. Keep the operator's existing HTTPS and SSH rules, and add
two inbound **Custom TCP / port 443** rules:

- `149.154.160.0/20`
- `91.108.4.0/22`

Telegram publishes these ranges in its webhook guide and warns that they can
change, so re-check that guide during incident diagnosis. The security-group
rules do not replace the application checks: TLS, the secret-token header,
update-id idempotency, chat binding, and reviewer authorization all remain
required.

Open **Telegram support, review, and approval interface** in n8n. Select
**Telegram webhook** and copy its **Production URL**. It must end with
`/webhook/telegram-support-v1`; never use the test URL.

From a private server shell, run the registration helper. It reads the webhook
secret from the protected `.env` file and prompts for the BotFather token with
input hidden. The token is not stored or placed in the process command line:

```bash
cd ~/ticket-clustering
./scripts/register-telegram-webhook.sh
```

The helper registers the production URL
`https://16.170.93.79.nip.io/webhook/telegram-support-v1`. To use a different
approved hostname, set `TELEGRAM_WEBHOOK_URL` for that one command. Do not paste
token or secret values into this repository or n8n node fields. The request
sets:

- `url`: the n8n production webhook URL;
- `secret_token`: `TELEGRAM_WEBHOOK_SECRET`;
- `allowed_updates`: `message` and `callback_query`;
- `drop_pending_updates`: `true` for this first activation, so stale updates
  created before the workflow was ready cannot enter the live pipeline.

Telegram will then include the secret-token header that the first Code node
checks with a timing-safe comparison.

## 5. Connect the two private groups

After migration 014 is applied, create two expiring setup codes in a private
Postgres operator session:

```sql
SELECT ticket_cluster.create_telegram_setup_code('review');
SELECT ticket_cluster.create_telegram_setup_code('engineering');
```

Each code expires after 15 minutes and works once.

1. In **TriagePulse Review**, send `/connect review CODE` from the Telegram
   account that should become the first authorized reviewer.
2. In **TriagePulse Engineering Alerts**, send
   `/connect engineering CODE`.
3. Delete the setup-command messages from both groups after the bot confirms
   connection. The hashed, consumed codes are harmless, but removing them
   reduces confusion.
4. Confirm configuration without exposing secrets:

```sql
SELECT role, chat_id, chat_type, title, active, connected_at
FROM ticket_cluster.telegram_connections ORDER BY role;

SELECT telegram_user_id, display_name, active
FROM ticket_cluster.authorized_telegram_approvers;
```

Additional reviewers must be deliberately added to
`authorized_telegram_approvers`; merely joining the group grants no approval
permission.

## 6. Canary test

Activate the Telegram workflow, then test in this order:

1. Send `/help` privately to the bot.
2. Send `/new`, then a ticket description longer than 10 characters.
3. Press **Cancel**. Confirm the buttons disappear and no ticket exists.
4. Repeat and press **Confirm ticket** twice. Confirm one intake job and one
   ticket exist; the second callback must say it was already processed.
5. Send a follow-up. Confirm it is added as evidence but does not increase the
   cluster's affected-ticket count.
6. Submit three genuinely similar independent tickets. Confirm one review card
   appears in the private review group.
7. Ask a Telegram user who is not in `authorized_telegram_approvers` to press
   **Approve**. The decision must be denied and the card must remain pending.
8. Approve as the authorized reviewer. The buttons must disappear, Docs and
   Sheets must complete, and exactly one alert must appear in the Telegram
   engineering group.
9. Press the old button again from message history. It must not produce a
   second decision or engineering alert.

During the canary, inspect `telegram_updates`, `telegram_intake_jobs`,
`telegram_review_surfaces`, `telegram_decision_attempts`, and
`delivery_attempts`. Keep Slack active so rollback is simply deactivating the
Telegram workflow and removing its webhook.

## 7. Normal user experience

- `/new` starts a ticket draft.
- The next private message becomes a preview, not a ticket yet.
- **Confirm ticket** durably queues it before embedding begins.
- `/status` reports drafting, queued, or open state.
- Messages sent while a ticket is open become follow-up evidence and never
  count as additional affected customers.
- `/close` closes the current conversation so `/new` can start another case.

Version 1 accepts text and captions only. File content is not downloaded or
sent to a model. A future attachment adapter must add malware scanning,
content limits, retention, and explicit consent before activation.
