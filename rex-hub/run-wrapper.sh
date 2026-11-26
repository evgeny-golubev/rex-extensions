#!/usr/bin/env bash
# Runs a delegated agent inside a Rex Hub floating layer:
#   run-wrapper.sh STATE_DIR RUN_ID MODE WORK_DIR TIMEOUT -- AGENT ARGS...
# A oneshot run's answer (its stdout) is saved as <id>.md and its stderr as
# <id>.err; both still show in the float. A oneshot run still going after
# TIMEOUT seconds (0 for none) is ended as "timeout". When the agent ends,
# "<status> <exit code> <finished epoch>" is recorded once in <id>.exit. The
# run's <id>.json belongs to rex-hub/init.lua alone; core.load_run merges the
# two, so neither side can overwrite the other's update.
set -uo pipefail

STATE_DIR="$1"
RUN_ID="$2"
MODE="$3"
WORK_DIR="$4"
TIMEOUT="$5"
shift 5
if [ "${1:-}" = "--" ]; then
	shift
fi

EXIT_FILE="$STATE_DIR/$RUN_ID.exit"
OUT_FILE="$STATE_DIR/$RUN_ID.md"
ERR_FILE="$STATE_DIR/$RUN_ID.err"

mkdir -p "$STATE_DIR"

# The first record wins: noclobber makes creating the file the one atomic step.
record() {
	(set -C; printf '%s %s %s\n' "$1" "$2" "$(date +%s)" > "$EXIT_FILE") 2>/dev/null
}

WATCHDOG=
stop_watchdog() {
	[ -n "$WATCHDOG" ] && kill "$WATCHDOG" 2>/dev/null
}
trap stop_watchdog EXIT

# Closing the float hangs up the terminal, and Ctrl-C interrupts a oneshot
# run: record the run as stopped, once.
on_signal() {
	trap - HUP TERM INT
	record stopped "$1"
	exit "$1"
}
trap 'on_signal 129' HUP
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

if ! cd "$WORK_DIR"; then
	record failed 1
	exit 1
fi

# Ends the whole run (agent, tee and this script) once TIMEOUT has passed. It
# shares the process group it ends, so it ignores TERM while doing so.
watchdog() {
	local group="$1" sleeper=
	trap 'kill "${sleeper:-}" 2>/dev/null; exit 0' TERM HUP INT
	trap - EXIT
	sleep "$TIMEOUT" &
	sleeper=$!
	wait "$sleeper" || exit 0
	trap '' TERM
	record timeout 124
	kill -TERM -- "-$group" 2>/dev/null
	sleep 2
	kill -KILL -- "-$group" 2>/dev/null
}

if [ "$MODE" = "oneshot" ]; then
	if [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
		group=$(ps -o pgid= -p $$ | tr -d ' ')
		watchdog "$group" </dev/null >/dev/null 2>&1 &
		WATCHDOG=$!
	fi
fi
# The agent runs as a job this script waits for: Rex sends a closed float's
# terminal SIGHUP and SIGKILL a second later, and bash runs the HUP trap only
# once a foreground command returns, which an agent may take longer than that
# to do; `wait` returns at once. Without job control the job keeps the
# terminal: it stays in the foreground group, and <&0 keeps the terminal as
# its input instead of /dev/null.
if [ "$MODE" = "oneshot" ]; then
	(
		"$@" 2> >(tee "$ERR_FILE" >&2) | tee "$OUT_FILE"
		exit "${PIPESTATUS[0]}"
	) <&0 &
else
	"$@" <&0 &
fi
wait $!
code=$?

if [ "$code" -eq 0 ]; then
	record done 0
else
	record failed "$code"
fi
exit "$code"
