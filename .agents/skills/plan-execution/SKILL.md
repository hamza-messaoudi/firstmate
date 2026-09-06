---
name: plan-execution
description: >-
  Agent-only procedure for the three-tier fleet's planning-to-execution lifecycle.
  Use before dispatching a planning scout, on a planning scout's done wake, and before mapping an approved plan to ship tasks.
  Owns intake, the captain hold/present/negotiate/approve cycle for the plan, mapping approved components to dispatch profiles, and closing the plan once every component lands.
user-invocable: false
metadata:
  internal: true
---

# Plan execution

A plan is an ordinary scout task whose report is machine-shaped for parallel execution, not a persistent role.
This skill owns the lifecycle from raw goal to landed components; `AGENTS.md` section 7 owns everything else about ship and scout tasks in general, and this skill never restates it.

## 1. Intake

Dispatch a planning scout when the captain asks for a plan, or when a goal is large enough that unresolved design uncertainty could materially change what to build (`AGENTS.md` section 7's scout criteria).
Scaffold with `bin/fm-brief.sh <id> <repo> --scout --plan`; its `--help` owns the exact report contract this adds (a `## Components` section with one `### <component-id>` block per component, a `## Integration` section, and a `## Open questions for the captain` section).
Resolve the planner's dispatch profile the normal way (`AGENTS.md` section 4): a rule in `config/crew-dispatch.json` whose `when` describes planning or design work selects the planner tier, otherwise fall through to the configured default.

## 2. Hold and present

On the scout's `done` wake, read the report, then hold the planning task itself with `bin/fm-captain-hold.sh hold <id> --reason "<one-line plan summary plus the open questions>"`.
Present the plan in chat when it is small; use Lavish's `plan` playbook for a larger one, and bind the Lavish source with `bin/fm-captain-hold.sh bind <source-id>` so a captured answer closes the hold directly.
Follow `captain-hold-lifecycle` for the completion gate and close mechanics; this step only decides what to hold and how to present it.

## 3. Negotiate

Send captain changes back to the same scout with `bin/fm-send.sh` while it stays alive - do not tear it down mid-negotiation.
`data/<id>/report.md` is the single source of truth for the plan; each revision replaces it in place rather than appending a changelog.

## 4. Approve

Tear the scout down first, while the plan task is still held: `bin/fm-teardown.sh` retains a held row but closes an unheld scout's row, so tearing down after the release would close the plan task before any component exists.
The report survives teardown and remains the plan's record.
Then record the captain's exact words with `bin/fm-captain-hold.sh answer <id> --decision-file <file> --release`; `--release` lifts the hold without closing the plan task, which stays open until step 6.
Components may be dispatched only after this call succeeds.

## 5. Map to executors

For each approved component:

1. File a backlog item with `tasks-axi add <plan-id>-<component-id> "<summary>" --kind ship --repo <repo>`, translating that component's `depends-on` ids into task ids and passing each one as its own `--blocked-by <id>` flag (`none` means no `--blocked-by` at all).
   File components in dependency order, dependencies before dependents, because `--blocked-by` refuses an id that does not exist yet.
2. Scaffold its ship brief with `bin/fm-brief.sh`, using the project's resolved `--mode` (`AGENTS.md` section 7).
   Its `## Captain's intent` carries the captain's original goal plus their recorded approval words; its `## Firstmate spec` carries that component's block verbatim plus the integration notes that concern it.
3. Resolve a concrete harness/model/effort for the component through the dispatch-profile contract in `AGENTS.md` section 4 and `docs/configuration.md`, using the component's `tier` only as a routing hint: `reasoning` favors the strongest configured profile, `standard` the default profile, `lightweight` the cheapest configured profile.
   `tier` is never schema the scripts read - firstmate's judgment applies it.
4. Spawn with `bin/fm-spawn.sh` batch pairs (`id=repo` per component), grouped so every pair sharing one fully resolved profile (harness, model, and effort) ships in the same batch call, because a batch's shared `--harness/--model/--effort` apply to every pair in it; each batch carries the project's resolved `--mode` and `--yolo`.

Once every component is filed, block the plan task by each of them with `tasks-axi block <plan-id> --by <plan-id>-<component-id>`, so the plan task stays out of `tasks-axi ready` until its last component lands.

Every approved component ships as its own PR - never an integration branch or a combined PR - so nothing here builds one.

## 6. Complete

Each component lands through its own PR or local landing under the project's delivery mode, exactly like any other ship task.
Close the plan task itself with `tasks-axi done <plan-id> --report data/<plan-id>/report.md` only once the last component lands; it is the one close in this lifecycle, since teardown retained the held row and `answer --release` only lifted the hold.
A component that fails or needs re-scoping is a re-plan question back to the captain - hold it and get an answer through steps 2-4 above - never a silent edit to the plan or a unilateral scope change by the executing worker.
