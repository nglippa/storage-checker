#!/bin/sh
# QA tooling activation matrix, executed: development-compiled and distribution-compiled viewer sources.
set -u
DEV=$1; DIST=$2; QADB=$3; ID=local.macbook.storage-monitor.viewer.dev
row() { # build-label work database-label flags-label args...
  label=$1; work=$2; dblabel=$3; flagslabel=$4; shift 4
  log=/private/tmp/storage-monitor-matrix-$$-$label-$dblabel-$flagslabel.log
  set -- "$@"
  args=""; for a in "$@"; do [ "$a" = LOG ] && a=$log; args="$args $a"; done
  # shellcheck disable=SC2086
  out=$("$work/$ID.app/Contents/MacOS/probe" $args)
  created=$([ -e "$log" ] && echo yes || echo no)
  printf '%-12s %-11s %-9s isQA=%s log_honored=%s script_enabled=%s trace_logging=%s log_file_created=%s\n' "$label" "$dblabel" "$flagslabel" \
    "$(echo "$out" | /usr/bin/sed -n 's/.*"isQA":\([a-z]*\).*/\1/p')" "$(echo "$out" | /usr/bin/sed -n 's/.*"perf_log_honored":\([a-z]*\).*/\1/p')" \
    "$(echo "$out" | /usr/bin/sed -n 's/.*"perf_script_enabled":\([a-z]*\).*/\1/p')" "$(echo "$out" | /usr/bin/sed -n 's/.*"trace_logging":\([a-z]*\).*/\1/p')" "$created"
}
row release "$DIST" production none
row release "$DIST" production qa-flags --perf-log LOG --perf-script
row release "$DIST" qa qa-flags --database-path "$QADB" --perf-log LOG --perf-script
row release "$DIST" qa none --database-path "$QADB"
row development "$DEV" production qa-flags --perf-log LOG --perf-script
row development "$DEV" qa none --database-path "$QADB"
row qa-tooling "$DEV" qa qa-flags --database-path "$QADB" --perf-log LOG --perf-script
