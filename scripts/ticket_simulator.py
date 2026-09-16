#!/usr/bin/env python3
"""Post the fixed synthetic evaluation tickets to Slack, or preview them safely.

No third-party dependencies are required. It loads an optional untracked .env
from the repository root but never writes secrets or echoes them.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA = REPOSITORY_ROOT / "data" / "evaluation-tickets.json"
SLACK_POST_MESSAGE_URL = "https://slack.com/api/chat.postMessage"


def load_dotenv(path: Path) -> None:
    """Load simple KEY=VALUE lines without overwriting exported environment."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip().strip("'\"")
        if key and key not in os.environ:
            os.environ[key] = value


def load_tickets(path: Path) -> list[dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Cannot read ticket data {path}: {exc}") from exc
    if not isinstance(data, list):
        raise SystemExit("Ticket data must be a JSON list.")
    return data


def post_ticket(token: str, channel_id: str, case_id: str, text: str) -> dict[str, Any]:
    # Prefix is intentionally machine-readable and is removed by the n8n
    # normalization node before embedding; it makes manual evaluation traceable.
    payload = json.dumps(
        {"channel": channel_id, "text": f"[SIM:{case_id}] {text}", "unfurl_links": False}
    ).encode("utf-8")
    request = urllib.request.Request(
        SLACK_POST_MESSAGE_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=utf-8",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Slack delivery failed for {case_id}: {exc}") from exc
    if not body.get("ok"):
        raise RuntimeError(f"Slack rejected {case_id}: {body.get('error', 'unknown_error')}")
    return body


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA, help="JSON test-set path")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Preview tickets without contacting Slack (the default)")
    mode.add_argument("--post", action="store_true", help="Send valid tickets to Slack")
    parser.add_argument("--interval", type=float, default=1.0, help="Base seconds between posts")
    parser.add_argument("--jitter", type=float, default=0.0, help="Maximum additional random delay")
    parser.add_argument("--limit", type=int, help="Send/preview only the first N tickets")
    parser.add_argument("--seed", type=int, default=7, help="Random seed for reproducible jitter")
    args = parser.parse_args()

    if args.interval < 0 or args.jitter < 0:
        parser.error("--interval and --jitter must be non-negative")
    load_dotenv(REPOSITORY_ROOT / ".env")
    tickets = load_tickets(args.data)
    if args.limit is not None:
        tickets = tickets[: args.limit]

    token = os.environ.get("SLACK_BOT_TOKEN", "")
    channel_id = os.environ.get("SLACK_SUPPORT_CHANNEL_ID", "")
    if args.post and (not token or not channel_id):
        parser.error("--post requires SLACK_BOT_TOKEN and SLACK_SUPPORT_CHANNEL_ID in the environment or untracked .env")

    random.seed(args.seed)
    for position, ticket in enumerate(tickets, start=1):
        case_id = str(ticket.get("case_id", f"row-{position}"))
        text = str(ticket.get("text", ""))
        if not text.strip():
            print(f"{case_id}: SKIPPED_EMPTY — exercise this via the n8n webhook test; Slack rejects empty messages.")
            continue
        if not args.post:
            print(f"{case_id}: DRY_RUN — {text}")
            continue
        try:
            response = post_ticket(token, channel_id, case_id, text)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        timestamp = response.get("ts", "unknown-ts")
        print(f"{case_id}: POSTED — ts={timestamp}")
        if position < len(tickets):
            time.sleep(args.interval + random.uniform(0, args.jitter))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
