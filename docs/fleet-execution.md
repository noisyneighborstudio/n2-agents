# Task handoff and monitoring contract

The native dispatch form accepts an agent task or shell command, workspace,
continuation context, required managed tools, and optional machine/agent pins.
The planner must return an eligible candidate before dispatch. Agents installed
only on another peer remain available as pins.

A linked Git worktree is packaged with independent Git metadata. Staged changes,
working changes, deletions, and untracked files survive without access to the
source repository. Packing disables Git hooks and fsmonitor. Nested submodule
metadata is not materialized by this helper; this check establishes ordinary
linked-worktree portability only.

A worker receives `N2_FLEET_OUTPUTS`, a task-specific directory. Put deliverables
there to include them in explicit fetch and distribution. Source edits remain
in the worker workspace. Outputs are never broadcast automatically. Every
submitted request bundle is retained on its dispatcher, including retries, so
retrying a retry preserves the request and records a new task identity.

Approved peers keep monitoring copies of started tasks. A background sync tick
also discovers active worker tasks whose start announcement was missed, then
checks their status. Monitoring continues without the original dispatcher.
An unreachable worker produces a notice and never causes automatic resubmission.
Only the recorded worker can report an execution outcome. Monitoring peers show
state and notices; retry and result-copy actions stay with the dispatcher.

Task preparation and managed installation share an admission lock. Preparation
reserves the active task before releasing the lock, preventing a disruptive
installer from entering between preparation and process startup.

Embedded MCP configuration is credential-bearing even when stored in a general
settings file. Sender and receiver credential permissions both apply, including
JSON and TOML escaped keys. Settings-only QA import uses the same gate.
