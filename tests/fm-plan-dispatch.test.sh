#!/usr/bin/env bash
# Executable-interface tests for bin/fm-plan-dispatch.sh.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-plan-dispatch)
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '# Backlog' > "$home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' > "$home/.tasks.toml"
  printf '%s\n' "$home"
}
write_report() {
  mkdir -p "$1/data/plan-a1"
  cat > "$1/data/plan-a1/report.md" <<'EOF'
# Plan

## Components

### parser
- summary: Parse the report.
- scope: parser.
- depends-on: none
- acceptance: Parsing works.
- tier: reasoning
- reason: Schema work.

### dispatch
- summary: Dispatch tasks.
- scope: dispatch.
- depends-on: parser
- acceptance: Tasks dispatch.
- tier: standard
- reason: Workflow work.

### docs
- summary: Document the helper.
- scope: docs.
- depends-on: none
- acceptance: Documentation reads clearly.
- tier: lightweight
- reason: Writing work.

## Integration

Land parser first.
EOF
}
approve() {
  local home=$1 decision="$TMP_ROOT/decision.txt"
  printf '%s\n' 'Build the approved plan.' > "$decision"
  (cd "$home" && tasks-axi add plan-a1 'Original captain goal' --repo fixture --file "$home/data/backlog.md") >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold plan-a1 --reason 'approve plan' >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer plan-a1 --decision-file "$decision" --release >/dev/null
}
dispatch() { FM_HOME="$1" "$ROOT/bin/fm-plan-dispatch.sh" plan-a1 --project fixture --mode no-mistakes --yolo off; }

test_approved_plan_maps_components_to_observable_backlog_and_briefs() {
  local home out show
  home=$(make_home approved); write_report "$home"; approve "$home"
  out=$(dispatch "$home") || fail "approved plan dispatch failed: $out"
  for id in parser dispatch docs; do
    show=$(cd "$home" && tasks-axi show "plan-a1-$id" --full --file "$home/data/backlog.md") || fail "missing component task $id"
    assert_contains "$show" 'kind: ship' "$id was not filed as a ship task"
    assert_present "$home/data/plan-a1-$id/brief.md" "$id brief was not scaffolded"
  done
  show=$(cd "$home" && tasks-axi show plan-a1-dispatch --full --file "$home/data/backlog.md")
  assert_contains "$show" 'plan-a1-parser' 'dependency was not translated to --blocked-by'
  assert_contains "$(cat "$home/data/plan-a1-parser/brief.md")" '### parser' 'component block was not copied verbatim'
  assert_contains "$(cat "$home/data/plan-a1-parser/brief.md")" 'Build the approved plan.' 'recorded approval was not copied into captain intent'
  show=$(cd "$home" && tasks-axi show plan-a1 --full --file "$home/data/backlog.md")
  assert_contains "$show" 'plan-a1-parser' 'plan task was not blocked by its components'
  assert_contains "$out" 'resolve concrete Codex profiles' 'spawn output did not preserve Firstmate profile selection'
  assert_contains "$out" 'reasoning:' 'reasoning tier suggestion missing'
  assert_contains "$out" 'standard:' 'standard tier suggestion missing'
  assert_contains "$out" 'lightweight:' 'lightweight tier suggestion missing'
  pass 'fm-plan-dispatch: approved plan creates tasks, briefs, blockers, and suggestions'
}
test_unanswered_plan_is_refused_without_component_tasks() {
  local home out rc
  home=$(make_home unanswered); write_report "$home"
  (cd "$home" && tasks-axi add plan-a1 'Original captain goal' --repo fixture --file "$home/data/backlog.md") >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold plan-a1 --reason 'approve plan' >/dev/null
  out=$(dispatch "$home" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail 'unanswered plan dispatch should refuse'
  assert_contains "$out" 'still held for the captain' 'unanswered-plan refusal did not explain missing approval'
  if (cd "$home" && tasks-axi show plan-a1-parser --file "$home/data/backlog.md") >/dev/null 2>&1; then fail 'unanswered plan created a component task'; fi
  pass 'fm-plan-dispatch: refuses an unanswered captain-held plan'
}
test_approved_plan_maps_components_to_observable_backlog_and_briefs
test_unanswered_plan_is_refused_without_component_tasks
