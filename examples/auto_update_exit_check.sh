#!/usr/bin/env bash
#
# An auto-update restart exits 75 while stdin is a real pipe whose writer stays open, as a
# panel attaches it; a supervisor restarts on exactly that code. The stdin console half
# (the reader that used to swallow the code) is in dot-server/examples/exit_code_check.sh.
#
#   examples/auto_update_exit_check.sh     exit 0 when the run ends 75, 1 otherwise
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
sleep 25 | timeout 20 godot --headless --path . res://examples/auto_update_exit_probe.tscn >/dev/null 2>&1
rc=${PIPESTATUS[1]}
if [ "$rc" = 75 ]; then echo "  ok   auto-update over an open pipe: exit 75"; exit 0; fi
echo "  FAIL auto-update over an open pipe: exit $rc (want 75)"; exit 1
