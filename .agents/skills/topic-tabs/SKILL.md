---
name: topic-tabs
description: Load when the captain says "open <topic>" or asks for a separate tab or chat for one topic, when an inbox note starts with `[topic:<topic>]`, and before reporting a result for work that came from a topic tab.
user-invocable: false
metadata:
  internal: true
---

# Topic tabs

A topic tab is a separate, ordinary Claude Code chat for one captain topic, opened as a Herdr tab in the main firstmate's own workspace and started in that topic's project folder.
It is not a firstmate session, so it never takes or meets this home's session lock; it reads freely and hands real work back to this home's inbox.
`bin/fm-topic.sh` owns the mechanics, directory policy, and durable records; [`docs/herdr-backend.md`](../../../docs/herdr-backend.md#topic-tabs) owns the operator view.

## Opening a topic

1. Resolve the topic's project folder from the captain's words, the project registry, and the workspace layout (for example `~/work/saas/crm` for "crm").
   Ask one concise question when more than one folder plausibly matches or none does.
2. Write a short starting note to a scratch file: where the topic stands, the latest relevant reports, open decisions held for the captain, and full links to open PRs, drawn from existing records only.
   Do not commission a new investigation to write it.
3. Run `bin/fm-topic.sh open <topic> <folder> --context <note-file>` and tell the captain the tab is open, or that the existing one was focused.
   A refusal names its reason, such as a folder outside the workspace roots, a firstmate home, or no Herdr pane; relay it plainly rather than working around it.

## Work arriving from a topic tab

An inbox note starting with `[topic:<topic>]` is an ordinary captain request that came from that tab.
Resolve, route, brief, and supervise it exactly like any other request, keeping the topic name in the backlog item note so its result can find its way back.

## Reporting a topic's results

Whenever a result lands for work that came from a topic tab - a finished investigation, a PR ready for review, a merge, a blocker, or a decision the captain must make - append it with `bin/fm-topic.sh log <topic> "<text>"` in plain captain-facing language with any full PR URL, and keep a one-line note in the main chat.
Approvals, merges, and other decisions still happen on the main screen; the topic log only mirrors them.
