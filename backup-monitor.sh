#!/bin/bash

VERSION="0.0.1"

MONITOR_PATH="${HOME}/.config/backup-tool"
MONITOR_LOG="${MONITOR_PATH}/monitor.log"
MONITOR_SCENARIOS="${MONITOR_PATH}/scenarios"

LOCKFD=200
LOCK_FILE="${MONITOR_PATH}/file.lock"

lock_acquire() {
  # Open a file descriptor to lock file
  exec {LOCKFD}>${LOCK_FILE} || return 1

  # Block until an exclusive lock can be obtained on the file descriptor
  flock -x ${LOCKFD}
}

lock_release() {
  test "${LOCKFD}" || return 1
  
  # Close lock file descriptor, thereby releasing exclusive lock
  exec {LOCKFD}>&- && unset LOCKFD
}

lock_acquire || { echo >&2 "Error: failed to acquire lock"; exit 1; }

while IFS= read -r path; do
  backup create "$path" &
done < "${MONITOR_SCENARIOS}"

wait

lock_release
