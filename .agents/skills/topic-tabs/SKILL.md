---
name: topic-tabs
description: Load when the captain says "open <topic>" or asks for a separate tab or chat for one topic, when an inbox note starts with `[topic:<topic>]`, and before reporting a result or asking the captain a decision for work that came from a topic tab.
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
   A closed tab reopens on its last chat, with that chat's history, when one is recorded for the folder; tell the captain in plain words whether it resumed that chat or started a new one, as the output says.
   A refusal names its reason, such as a folder outside the workspace roots, a firstmate home, or no Herdr pane; relay it plainly rather than working around it.

## Work arriving from a topic tab

An inbox note starting with `[topic:<topic>]` is an ordinary captain request that came from that tab, or the captain's answer to a decision asked there.
An answer is the captain's own word on that decision: record and act on it exactly as if given in the main chat.
Resolve, route, brief, and supervise it exactly like any other request, keeping the topic name in the backlog item note.
In the same turn you dispatch it, link the work to the topic with `bin/fm-topic.sh link <topic> <id>`, where `<id>` is the task id you spawned or the second mate id you routed it to.
From then on the wake drain prints a `TOPIC RESULT` line with the exact log command whenever that task or second mate reports an outcome, so the result goes back to the tab without relying on memory.

## Reporting a topic's results

Whenever a result lands for work that came from a topic tab - a finished investigation, a PR ready for review, a merge, or a blocker - append it with `bin/fm-topic.sh log <topic> "<text>"` in plain captain-facing language with any full PR URL, and keep a one-line note in the main chat.
Logging also rings the topic tab, so its agent tells the captain the outcome there; the second output line says whether it was delivered or why not, and an undelivered result is shown with the captain's next message in the tab or when the topic is opened again, so never retry or type into the tab yourself.
Add `--done <id>` with the final result for a linked request so its `TOPIC RESULT` reminders stop.

## Decisions for topic work

Ask every decision, approval, or merge question about work that came from a topic tab in that tab, so the captain answers it beside its project.
Log it with `bin/fm-topic.sh log <topic> --decision "<question>"`, standalone with the options, your recommendation, and any full PR URL; the tab presents it as a decision and sends the captain's answer back as a `[topic:<topic>]` inbox note.
In the main chat keep at most one line naming the topic and that a decision waits there, and hold the item for the captain as usual.
If the tab cannot receive it - the log says it was not delivered and the topic is not reopened - the decision still waits in that topic's log, so say in the main line where it waits.
