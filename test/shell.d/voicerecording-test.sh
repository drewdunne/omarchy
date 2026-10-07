#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

tmp_dir=$(mktemp -d)
stub_bin="$tmp_dir/bin"
# pkill is stubbed below, so clean up with the real one
real_pkill=$(command -v pkill)
trap '"$real_pkill" -f "$stub_bin/ffmpeg" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

mkdir -p "$stub_bin"

# The recorder counts as running while its marker file exists
cat >"$stub_bin/pgrep" <<'SH'
#!/bin/bash
[[ -e $OMARCHY_TEST_RECORDER_RUNNING ]]
SH

# SIGINT stops the recorder cleanly unless the test says it hangs; SIGKILL
# always does
cat >"$stub_bin/pkill" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_PKILL_ARGS"
case $1 in
-SIGINT) [[ ${OMARCHY_TEST_RECORDER_HANGS:-false} == "true" ]] || rm -f "$OMARCHY_TEST_RECORDER_RUNNING" ;;
-9) rm -f "$OMARCHY_TEST_RECORDER_RUNNING" ;;
esac
SH

# Stands in for both ffmpeg runs. The audio cleanup (-af) logs when it starts
# and ends and writes its -processed output; the recorder creates its output file (the
# last argument) the way ffmpeg does once capture starts, then keeps running.
cat >"$stub_bin/ffmpeg" <<'SH'
#!/bin/bash
if [[ " $* " == *" -af "* ]]; then
  echo "finalize-begin" >>"$OMARCHY_TEST_ORDER"
  sleep "${OMARCHY_TEST_FINALIZE_SECONDS:-0}"
  for arg in "$@"; do
    [[ $arg == *-processed.m4a ]] && echo "processed" >"$arg"
  done
  echo "finalize-end" >>"$OMARCHY_TEST_ORDER"
else
  printf '%s\n' "$@" >"$OMARCHY_TEST_FFMPEG_ARGS"
  echo "capture" >>"$OMARCHY_TEST_ORDER"
  : >"${@: -1}"
  : >"$OMARCHY_TEST_RECORDER_RUNNING"
  sleep 30
fi
SH

cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >>"$OMARCHY_TEST_NOTIFICATION_ARGS"
SH

cat >"$stub_bin/omarchy-shell" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_SHELL_ARGS"
SH

chmod +x "$stub_bin"/*

export PATH="$stub_bin:$ROOT/bin:$PATH"
export XDG_RUNTIME_DIR="$tmp_dir/runtime"
export OMARCHY_TEST_RECORDER_RUNNING="$tmp_dir/recorder-running"
export OMARCHY_TEST_PKILL_ARGS="$tmp_dir/pkill-args"
export OMARCHY_TEST_FFMPEG_ARGS="$tmp_dir/ffmpeg-args"
export OMARCHY_TEST_ORDER="$tmp_dir/order"
export OMARCHY_TEST_NOTIFICATION_ARGS="$tmp_dir/notification-args"
export OMARCHY_TEST_SHELL_ARGS="$tmp_dir/shell-args"
mkdir -p "$XDG_RUNTIME_DIR"

recording_dir="$tmp_dir/recordings"
mkdir -p "$recording_dir"
export OMARCHY_VOICERECORD_DIR="$recording_dir"
state_file="$XDG_RUNTIME_DIR/omarchy-voicerecord-filename"

reset_logs() {
  rm -f "$OMARCHY_TEST_PKILL_ARGS" "$OMARCHY_TEST_FFMPEG_ARGS" "$OMARCHY_TEST_ORDER" \
    "$OMARCHY_TEST_NOTIFICATION_ARGS" "$OMARCHY_TEST_SHELL_ARGS"
}

start_recording() {
  reset_logs
  "$ROOT/bin/omarchy-capture-voicerecording" >/dev/null 2>&1 ||
    fail "voice recording starts" "$(cat "$OMARCHY_TEST_NOTIFICATION_ARGS" 2>/dev/null || true)"
  # Distinct timestamps for each recording
  sleep 1
}

stop_recorder_stubs() {
  "$real_pkill" -f "$stub_bin/ffmpeg" 2>/dev/null || true
  rm -f "$OMARCHY_TEST_RECORDER_RUNNING"
}

# ---------------------------------------------------------------- start

start_recording
pass "voice recording starts"

grep -Fx -- "pulse" "$OMARCHY_TEST_FFMPEG_ARGS" >/dev/null && grep -Fx -- "default" "$OMARCHY_TEST_FFMPEG_ARGS" >/dev/null ||
  fail "voice recording captures the default input" "$(cat "$OMARCHY_TEST_FFMPEG_ARGS")"
pass "voice recording captures the default input"

grep -Fx -- "-frag_duration" "$OMARCHY_TEST_FFMPEG_ARGS" >/dev/null && grep -Fx -- "-flush_packets" "$OMARCHY_TEST_FFMPEG_ARGS" >/dev/null ||
  fail "voice recording writes flushed fragments that survive a hard kill" "$(cat "$OMARCHY_TEST_FFMPEG_ARGS")"
pass "voice recording writes flushed fragments that survive a hard kill"

[[ -s $state_file && $(<"$state_file") == "$recording_dir"/voicerecording-*.m4a ]] ||
  fail "the recording state file names the recording that was started" "$(cat "$state_file" 2>/dev/null || true)"
recording=$(<"$state_file")
pass "the recording state file names the recording that was started"

[[ -f $recording ]] || fail "the recording lands in the voice recording directory" "$(ls -a "$recording_dir")"
pass "the recording lands in the voice recording directory"

grep -Fx "Voice recording started" "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null ||
  fail "starting a voice recording says so" "$(cat "$OMARCHY_TEST_NOTIFICATION_ARGS")"
grep -Fx -- "-q omarchy.indicators refresh" "$OMARCHY_TEST_SHELL_ARGS" >/dev/null ||
  fail "starting a voice recording refreshes the bar indicator"
pass "starting a voice recording says so and refreshes the bar indicator"

# ---------------------------------------------------------------- stop

reset_logs
saved=$("$ROOT/bin/omarchy-capture-voicerecording" --stop-recording 2>/dev/null) ||
  fail "stopping an active voice recording succeeds"

grep -Fx -- "-SIGINT -f ^omarchy-voicerecorder " "$OMARCHY_TEST_PKILL_ARGS" >/dev/null ||
  fail "stopping sends the recorder SIGINT so ffmpeg finishes the file" "$(cat "$OMARCHY_TEST_PKILL_ARGS")"
! grep -F -- "-9" "$OMARCHY_TEST_PKILL_ARGS" >/dev/null ||
  fail "a recorder that stops cleanly is not force-killed" "$(cat "$OMARCHY_TEST_PKILL_ARGS")"
pass "stopping sends the recorder SIGINT and nothing harsher"

[[ $saved == "$recording" ]] || fail "stopping prints the saved recording" "expected: $recording\nactual:   $saved"
[[ $(<"$recording") == "processed" ]] || fail "stopping replaces the recording with the cleaned-up audio"
[[ ! -e ${recording%.m4a}-processed.m4a ]] || fail "stopping leaves no intermediate file behind"
pass "stopping saves the cleaned-up recording under its original name"

[[ ! -e $state_file ]] || fail "stopping removes the recording state file"
grep -Fx -- "-q omarchy.indicators refresh" "$OMARCHY_TEST_SHELL_ARGS" >/dev/null ||
  fail "stopping refreshes the bar indicator"
grep -Fx "Voice recording saved" "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null &&
  grep -Fx -- "$recording" "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null ||
  fail "stopping offers to play the saved recording" "$(cat "$OMARCHY_TEST_NOTIFICATION_ARGS")"
pass "stopping clears its state, refreshes the bar, and offers the saved recording"

stop_recorder_stubs

# ---------------------------------------------------------------- force-kill

start_recording
recording=$(<"$state_file")
reset_logs
saved=$(OMARCHY_TEST_RECORDER_HANGS=true "$ROOT/bin/omarchy-capture-voicerecording" --stop-recording 2>/dev/null) ||
  fail "stopping a hung recorder succeeds"

grep -Fx -- "-9 -f ^omarchy-voicerecorder " "$OMARCHY_TEST_PKILL_ARGS" >/dev/null ||
  fail "a recorder that ignores SIGINT is force-killed" "$(cat "$OMARCHY_TEST_PKILL_ARGS")"
grep -Fx "Voice recording force-stopped" "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null ||
  fail "force-killing the recorder says so" "$(cat "$OMARCHY_TEST_NOTIFICATION_ARGS")"
[[ $saved == "$recording" && $(<"$recording") == "processed" ]] ||
  fail "a force-killed recording is still cleaned up and saved"
[[ ! -e $state_file ]] || fail "force-killing removes the recording state file"
pass "a recorder that ignores SIGINT is force-killed and its recording still saved"

stop_recorder_stubs

# ---------------------------------------------------------------- overlap

# A recording started while the last one is still being cleaned up has to wait
# for that stop to finish, or the two would trade state files.
start_recording
first_recording=$(<"$state_file")
reset_logs
OMARCHY_TEST_FINALIZE_SECONDS=2 "$ROOT/bin/omarchy-capture-voicerecording" --stop-recording >"$tmp_dir/first-saved" 2>/dev/null &
stop_pid=$!

for _ in {1..50}; do
  grep -qx "finalize-begin" "$OMARCHY_TEST_ORDER" 2>/dev/null && break
  sleep 0.1
done
grep -qx "finalize-begin" "$OMARCHY_TEST_ORDER" || fail "the first recording reaches its cleanup"

"$ROOT/bin/omarchy-capture-voicerecording" >/dev/null 2>&1 || fail "a recording starts while the last one is saved"
wait "$stop_pid" || fail "the overlapped stop succeeds"

[[ $(paste -sd' ' "$OMARCHY_TEST_ORDER") == "finalize-begin finalize-end capture" ]] ||
  fail "a new recording waits for the last one to finish saving" "$(cat "$OMARCHY_TEST_ORDER")"
[[ $(<"$tmp_dir/first-saved") == "$first_recording" ]] ||
  fail "the overlapped stop saves its own recording" "$(<"$tmp_dir/first-saved")"
[[ -s $state_file && $(<"$state_file") != "$first_recording" && -f $(<"$state_file") ]] ||
  fail "the new recording keeps its state file" "$(cat "$state_file" 2>/dev/null || echo missing)"
pass "a recording started during a save waits for it and keeps its own state"

stop_recorder_stubs
rm -f "$state_file"

# ---------------------------------------------------------------- idle

reset_logs
if "$ROOT/bin/omarchy-capture-voicerecording" --stop-recording >/dev/null 2>&1; then
  fail "stopping with nothing recording fails"
fi
[[ ! -e $OMARCHY_TEST_FFMPEG_ARGS ]] || fail "stopping with nothing recording does not start a recording"
grep -Fx -- "-q omarchy.indicators refresh" "$OMARCHY_TEST_SHELL_ARGS" >/dev/null ||
  fail "stopping with nothing recording clears a stale bar indicator"
pass "stopping with nothing recording fails and clears a stale bar indicator"

reset_logs
if OMARCHY_VOICERECORD_DIR="$tmp_dir/missing" "$ROOT/bin/omarchy-capture-voicerecording" >/dev/null 2>&1; then
  fail "voice recording refuses a missing output directory"
fi
[[ ! -e $OMARCHY_TEST_FFMPEG_ARGS ]] || fail "voice recording does not start without an output directory"
grep -F "Voice recording directory does not exist: $tmp_dir/missing" "$OMARCHY_TEST_NOTIFICATION_ARGS" >/dev/null ||
  fail "voice recording reports the missing output directory" "$(cat "$OMARCHY_TEST_NOTIFICATION_ARGS")"
pass "voice recording refuses a missing output directory"

# ---------------------------------------------------------------- wiring

# The menu, the bar indicator, and the command find the recorder by the name
# ffmpeg runs under, so all of them have to agree on it.
recorder_name=$(sed -n 's/^RECORDER_NAME="\(.*\)"$/\1/p' "$ROOT/bin/omarchy-capture-voicerecording")
[[ -n $recorder_name ]] || fail "voice recording names its recorder process"

grep -F "\"when\":\"pgrep -f '^$recorder_name '\"" "$ROOT/default/omarchy/omarchy-menu.jsonc" >/dev/null ||
  fail "the menu shows Stop Recording while the voice recorder runs"
grep -F "\"when\":\"! pgrep -f '^$recorder_name '\"" "$ROOT/default/omarchy/omarchy-menu.jsonc" >/dev/null ||
  fail "the menu hides Voice Recording while the recorder runs"
grep -F "\"^$recorder_name \"" "$ROOT/shell/plugins/bar/indicators/VoiceRecording.qml" >/dev/null ||
  fail "the bar indicator watches the voice recorder"
pass "the menu and bar indicator watch the recorder the command starts"
