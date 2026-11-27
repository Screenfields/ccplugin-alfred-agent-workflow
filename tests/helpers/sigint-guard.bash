# SIGINT start-mode guard (CCW-276). A non-interactive shell starts a background
# job (`cmd &`) with SIGINT ignored, and bash cannot trap or reset a signal that was
# ignored at entry. The INT tests would then fail only after a 10 s reap, or hang.
# Call this as the first statement of a test that sends INT: it fails at once, with
# the cause named, when this shell has SIGINT ignored (bit 0x2 of SigIgn).

require_sigint_not_ignored() {
  local mask
  mask=$(awk '/^SigIgn/{print $2}' /proc/$$/status)
  if [ $(( 0x$mask & 0x2 )) -ne 0 ]; then
    echo "SIGINT is ignored in this shell; start bats in the foreground or under \`timeout\`"
    return 1
  fi
}
