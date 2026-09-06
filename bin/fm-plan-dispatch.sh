#!/usr/bin/env bash
# Turn an approved planning-scout report into independently reviewable ship tasks.
# Usage: fm-plan-dispatch.sh <plan-task-id> [--project <repo>] [--mode <no-mistakes|direct-PR|local-only>] [--yolo <on|off>]
#
# The plan-execution skill owns when this helper is used and profile selection.
# This helper reads an approved `## Components` report, creates one ship task and
# brief per component, and prints - never runs - tier-grouped spawn suggestions.
# Tier remains a planning hint: Firstmate resolves every concrete Codex profile.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
slug() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
PLAN_ID=${1:-}; shift || true
slug "$PLAN_ID" || fail "plan task id must be a non-empty privacy-safe slug"
PROJECT=''
MODE=''
YOLO=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project|--mode|--yolo)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in --project) PROJECT=$2 ;; --mode) MODE=$2 ;; --yolo) YOLO=$2 ;; esac
      shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

REPORT="$DATA/$PLAN_ID/report.md"
[ -f "$REPORT" ] || fail "plan report is absent: $REPORT"
fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
DATA=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved"
BACKLOG_ROOT=$(fm_backlog_root "$DATA") || fail "$FM_BACKLOG_TRANSITION_ERROR"
tasks_axi() {
  if [ "$(fm_tasks_axi_backend "$BACKLOG_ROOT")" = markdown ]; then
    (cd "$BACKLOG_ROOT" && command tasks-axi "$@" --file "$(fm_backlog_file "$DATA")")
  else
    (cd "$BACKLOG_ROOT" && command tasks-axi "$@")
  fi
}

if FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-captain-hold.sh" open "$PLAN_ID"; then
  fail "plan task $PLAN_ID is still held for the captain"
else
  rc=$?
  [ "$rc" -eq 1 ] || fail "could not determine whether plan task $PLAN_ID is held for the captain"
fi
SHOW=$(tasks_axi show "$PLAN_ID" --full 2>/dev/null) || fail "plan task $PLAN_ID is absent from the configured backlog"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-plan-dispatch.XXXXXX") || fail "cannot stage plan mapping"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
printf '%s\n' "$SHOW" > "$TMP/show"
perl -MJSON::PP - "$TMP/show" "$TMP/approval" <<'PERL' || fail "plan task has no recorded captain answer released for execution"
use strict; use warnings;
my ($input, $out) = @ARGV;
open my $in, '<:raw', $input or die "$input: $!";
my $show = do { local $/; <$in> };
my ($raw) = $show =~ /^  body: (.*)$/m;
exit 1 unless defined $raw;
my $body = $raw =~ /^"/ ? decode_json($raw) : $raw;
exit 1 unless $body =~ /^Resolution recorded by fm-(?:captain|decision)-hold\.\nDecision digest: .*\nResolution mode: released\n\nCaptain decision:\n(.*)\z/s;
exit 1 unless length $1;
open my $fh, '>:raw', $out or die "$out: $!";
print {$fh} $1;
PERL

perl - "$REPORT" "$TMP" <<'PERL' || fail "malformed ## Components section in $REPORT"
use strict; use warnings;
my ($report, $dir) = @ARGV;
open my $fh, '<:raw', $report or die "$report: $!";
my @lines = <$fh>; chomp @lines;
my ($start, $end);
for my $i (0 .. $#lines) { $start = $i + 1 if !defined($start) && $lines[$i] eq '## Components'; }
die "missing ## Components\n" unless defined $start;
for my $i ($start .. $#lines) { if ($lines[$i] =~ /^##\s+/) { $end = $i; last; } }
$end //= scalar @lines;
my @parts; my $i = $start;
while ($i < $end) {
  if ($lines[$i] =~ /^### ([A-Za-z0-9._-]+)$/) {
    my ($id, $from) = ($1, $i++);
    $i++ while $i < $end && $lines[$i] !~ /^### /;
    push @parts, [$id, $from, $i]; next;
  }
  die "unexpected content in Components\n" if $lines[$i] !~ /^\s*$/;
  $i++;
}
die "no component blocks\n" unless @parts;
my (%known, %seen); $known{$_->[0]} = 1 for @parts;
open my $index, '>:raw', "$dir/components.tsv" or die "$dir/components.tsv: $!";
for my $part (@parts) {
  my ($id, $from, $to) = @$part;
  die "duplicate component $id\n" if $seen{$id}++;
  my @block = @lines[$from .. $to - 1]; my %field;
  for my $line (@block[1 .. $#block]) {
    next if $line =~ /^\s*$/;
    $line =~ /^- (summary|scope|depends-on|acceptance|tier|reason): (.+)$/ or die "invalid field in $id\n";
    die "duplicate $1 in $id\n" if exists $field{$1}; $field{$1} = $2;
  }
  for my $field (qw(summary scope depends-on acceptance tier reason)) { die "missing $field in $id\n" unless exists $field{$field}; }
  die "invalid tier in $id\n" unless $field{tier} =~ /^(?:reasoning|standard|lightweight)$/;
  my @deps;
  if ($field{'depends-on'} ne 'none') {
    @deps = split /, /, $field{'depends-on'};
    die "invalid depends-on in $id\n" unless @deps && !grep { !/^[A-Za-z0-9._-]+$/ || $_ eq $id || !$known{$_} } @deps;
    my %deps; die "duplicate dependency in $id\n" if grep { $deps{$_}++ } @deps;
  }
  open my $component, '>:raw', "$dir/$id.md" or die "$dir/$id.md: $!";
  print {$component} join("\n", @block), "\n";
  print {$index} join("\t", $id, $field{summary}, $field{tier}, join(',', @deps)), "\n";
}
PERL

if [ -z "$PROJECT" ] && [ -f "$STATE/$PLAN_ID.meta" ]; then PROJECT=$(sed -n 's/^project=//p' "$STATE/$PLAN_ID.meta" | tail -1); fi
[ -n "$PROJECT" ] || fail "--project is required when plan metadata has no project"
PROJECT=${PROJECT%/}; PROJECT=${PROJECT##*/}
if [ -z "$MODE" ] || [ -z "$YOLO" ]; then
  read -r registered_mode registered_yolo <<EOF
$("$SCRIPT_DIR/fm-project-mode.sh" "$PROJECT")
EOF
  MODE=${MODE:-$registered_mode}; YOLO=${YOLO:-$registered_yolo}
fi
case "$MODE" in no-mistakes|direct-PR|local-only) ;; *) fail "--mode must be no-mistakes, direct-PR, or local-only" ;; esac
case "$YOLO" in on|off) ;; *) fail "--yolo must be on or off" ;; esac

TITLE=$(printf '%s\n' "$SHOW" | sed -n 's/^  title: //p' | head -1)
APPROVAL=$(cat "$TMP/approval")
while IFS=$'\t' read -r id summary _tier deps; do
  task_id="$PLAN_ID-$id"
  [ -z "$deps" ] || for dep in ${deps//,/ }; do tasks_axi show "$PLAN_ID-$dep" >/dev/null 2>&1 || fail "component $id depends on $dep, which must appear earlier in the report"; done
  args=(add "$task_id" "$summary" --kind ship --repo "$PROJECT")
  [ -z "$deps" ] || for dep in ${deps//,/ }; do args+=(--blocked-by "$PLAN_ID-$dep"); done
  tasks_axi "${args[@]}" >/dev/null || fail "could not create task $task_id"
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-brief.sh" "$task_id" "$PROJECT" --mode "$MODE" >/dev/null || fail "could not scaffold brief for $task_id"
  intent=$(printf '%s\n\nCaptain approval:\n%s\n' "$TITLE" "$APPROVAL")
  FM_FILL_INTENT="$intent" FM_FILL_SPEC="$(cat "$TMP/$id.md")" perl -0pi -e 's/\Q{TASK}\E/$ENV{FM_FILL_INTENT}/; s/\Q{FIRSTMATE_SPEC}\E/$ENV{FM_FILL_SPEC}/' "$DATA/$task_id/brief.md"
done < "$TMP/components.tsv"
while IFS=$'\t' read -r id _summary _tier _deps; do
  tasks_axi block "$PLAN_ID" --by "$PLAN_ID-$id" >/dev/null || fail "could not block plan task by $PLAN_ID-$id"
done < "$TMP/components.tsv"

printf 'Suggested spawn commands - resolve concrete Codex profiles and quota before running:\n'
for tier in reasoning standard lightweight; do
  ids=$(awk -F '\t' -v tier="$tier" -v plan="$PLAN_ID" -v project="$PROJECT" '$3 == tier { printf "%s%s=%s", separator, plan "-" $1, project; separator=" " }' "$TMP/components.tsv")
  [ -z "$ids" ] || printf '%s:\n  %s\n' "$tier" "$SCRIPT_DIR/fm-spawn.sh $ids --mode $MODE --yolo $YOLO --harness <resolved-codex-harness> [--model <model>] [--effort <effort>]"
done
