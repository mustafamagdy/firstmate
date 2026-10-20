Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, follow `WAKE_ACK_REQUIRED`, supplying `--receipt` assembled from the fragments on every complete row as described in `bin/fm-wake-drain.sh`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
   If the tool returns a running session id, wait on that exact session until completion; do not treat the yielded id as a completion-driven callback or send a final response.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. A Stop refusal means keep the current handling turn open, including when Codex marks a repeated Stop `stop_hook_active=true`.
   Continue the existing foreground tool session until it completes, then follow the drain and checkpoint steps above.
9. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

A bounded watcher can be live when a turn ends and expire afterward without waking Codex.
The native Stop guard therefore refuses every unsafe final while supervision is needed; a live PID alone never proves future handling.
Explicit user cancellation remains available, and an intentionally cancelled or exited session has no automatic supervision guarantee.
A tool's running-session result is an unfinished foreground operation.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
