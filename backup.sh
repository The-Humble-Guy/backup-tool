#!/bin/bash

VERSION="0.0.1"

BACKUP_STORAGE="${HOME}/.backups"
BACKUP_ROOT_DIR=
CURRENT_BACKUP_NAME=
TEMP_DIR=
BACKUP_NAME=

BACKUP_MONITOR="backup-monitor"
MONITOR_PATH="${HOME}/.config/backup-tool"
MONITOR_LOG="${MONITOR_PATH}/monitor.log"
MONITOR_SCENARIOS="${MONITOR_PATH}/scenarios"
UNIQUE_COMMENT="BACKUP_TOOL"

CONFIG_FILE=
TIMESTAMP_FILE=
BACKUP_HISTORY_FILE=
IS_PARALLEL=false

readonly INCLUDE_FILES=$(mktemp)
readonly EXCLUDE_FILES=$(mktemp)
LOG_FILE=
LOG_VERBOSE=false

DEFAULT_COMPRESS_METHOD="tar"
DEFAULT_COMPRESS_LEVEL="none"

# $1 - key
# $2 - default value
get_config_value() {
  local query="$1"
  local default="$2"
  local result

  result=$(yq -r -e "$query" "$CONFIG_FILE" 2> /dev/null)

  if [[ $? -eq 0 ]] && [[ -n "$result" ]]; then
    echo "$result"
  else
    echo "$default"
  fi
}

# $1 - key
# $2 - array to save
get_config_array() {
  local query="$1"
  local -n arr_ref="$2"

  arr_ref=()

  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      arr_ref+=("$(printf "%s\0" "$line")")
    fi
  done < <(yq -r "$query" "$CONFIG_FILE" 2> /dev/null)
}

# $1 - path
expand_path() {
  local path="$1"
  path="${path/#~/${HOME}}"

  [[ "$path" == /* ]] && path=$(realpath -m --no-symlinks "$path")

  echo "$path"
}

# $1 - child directory
# $2 - parent directory
# Note: No expand symlinks. You should do it manually before function call
is_subpath() {
  local child_abs=$(realpath -m --no-symlinks $(expand_path "$1"))
  local parent_abs=$(realpath -m --no-symlinks $(expand_path "$2"))

  [[ -f "$child_abs"  || -d "$child_abs"  ]] || return 1
  [[ -f "$parent_abs" || -d "$parent_abs" ]] || return 1

  [[ "$child_abs" == "$parent_abs"/* ]]
}

# $1 - path to file or directory
safe_delete() {
  local path=$(realpath -m "$1")

  case "$path" in
    /|/home|/etc|/etc/*|/root|/root/*|/var|/var/log|/var/log/*)
        log_error "Attempt to remove system path: $path. Operation canceled."
        return 1
        ;;
  esac

  if [[ "$path" == "/tmp/"* ]]; then
    log_info "Remove $path"
    rm -rf "$path"
    return 0
  fi

  if is_var_set "MONITOR_PATH" && is_subpath "$path" "$MONITOR_PATH"; then
    log_info "Remove $path"
    rm -rf "$path"
    return 0
  fi

  if is_var_set "BACKUP_ROOT_DIR" && is_subpath "$path" "$BACKUP_ROOT_DIR"; then
    log_info "Remove $path"
    rm -rf "$path"
    return 0
  fi

  log_info "File $path was not deleted"
  return 0
}

die() {
  log_error "$@"
  echo "$@"
  exit 1
}

log() {
  [[ -f "$LOG_FILE" ]] && printf "$1\n" >> "$LOG_FILE" || printf "$1\n"
}

log_info() {
  log "[$(date +'%F-%H-%M-%S')][${FUNCNAME[1]}] INFO: $@"
}

log_error() {
  log "[$(date +'%F-%H-%M-%S')][${FUNCNAME[1]}] ERROR: $@"
}

# $1 - command to check for availability
check_command() {
  local cmd="$1"
  command -v "$cmd" > /dev/null && return 0 || return 1
}

# $1 - src
# $2 - dst
copy_command() {
  local src="$1"
  local dst="$2"

  is_var_set "EXCLUDE_FILES" || die "EXCLUDE_FILES is not set"
  is_var_set "TEMP_DIR" || die "Temporary directory is not set"

  local copy_parallel="${IS_PARALLEL,,}"
  declare -a included_files
  find_with_inverse_patterns "$src" "$EXCLUDE_FILES" included_files

  if [[ "${copy_parallel}" == true ]]; then
    if ! check_command "parallel"; then
      log_info "Parallel not installed. Fallback to single thread"
      copy_parallel="false"
      break
    fi
    export TEMP_DIR
    printf "%s\0" "${included_files[@]}" | xargs -0 -P $(( $(nproc) * 4 )) -n 100 \
    ionice -c 2 -n 7 cp --parents --no-dereference -t "$TEMP_DIR/"
    return 0
  fi

  declare -a excluded_files
  find_with_patterns "$src" "$EXCLUDE_FILES" excluded_files
  local excluded_files_total_bytes=$(du -c "${excluded_files[@]}" | grep total | cut -f1)

  if ((excluded_files_total_bytes < 1*1024*1024*1024)) && ((5 * ${#excluded_files[@]} < ${#included_files[@]})); then
    # 1. The exclusion files weigh less than 1 GB in total and their number is less than 20% of the total.
    # So, it's better to copy everything, then delete what we don't need.
    cp -r "$src" "$dst"
    for file in "${excluded_files[@]}"; do
      safe_delete "${TEMP_DIR}${file}"
    done
  else
    # 2. Copy file by file
    for file in "${included_files[@]}"; do
      dir="$(dirname "$file")"
      mkdir -p "$TEMP_DIR/$dir"
      cp -r "$file" "$TEMP_DIR/$dir"
    done
  fi
}

prepare_files_lists() {
  is_var_set "INCLUDE_FILES" || die "INCLUDE_FILES variable is not initialized"
  is_var_set "EXCLUDE_FILES" || die "EXCLUDE_FILES variable is not initialized"
  is_var_set "CONFIG_FILE"   || die "Config file variable should be set"

  > "$INCLUDE_FILES"
  > "$EXCLUDE_FILES"

  log_info "Prepare lists of included and excluded files for backup"
  log_info "Direct include filepaths:"
  declare -a direct_filepaths
  get_config_array ".files.include[]" direct_filepaths
  for path in "${direct_filepaths[@]}"; do
    log_info "\t$path"
    expand_path "$path" >> "$INCLUDE_FILES"
  done
  log_info "Done"

  log_info "Filepaths from input files:"
  declare -a include_from_files
  get_config_array ".files.include_from[]" include_from_files
  for file in "${include_from_files[@]}"; do
    file=$(expand_path "$file")
    log_info "\tFile: $file"
    while IFS= read -r path; do
      log_info "\t\t$path"
      expand_path "$path" >> "$INCLUDE_FILES"
    done < "$file"
  done
  log_info "Done"

  log_info "Direct exclude filepaths:"

  declare -a direct_exclude_filepaths
  get_config_array ".files.exclude[]" direct_exclude_filepaths
  for path in "${direct_exclude_filepaths[@]}"; do
    log_info "\t$path"
    full_path="$(expand_path "$path")"
    if [[ -d "$full_path" ]]; then
      echo "$full_path/*" >> "$EXCLUDE_FILES"
    else
      echo "$full_path" >> "$EXCLUDE_FILES"
    fi
  done
  log_info "Done"
  
  [[ ! -s "$INCLUDE_FILES" ]] && die "Empty list of files. Nothing to backup"
}

# $1 - search directory
# $2 - file with exclude paths
# $3 - array to store find results
find_with_inverse_patterns() {
  find_with_patterns "$1" "$2" "$3" true
}

find_with_patterns() {
  local search_dir="$1"
  local exclude_file="$2"
  local -n arr_ref="$3"
  local inverse="${4:-false}"
  local file_type="${5:-f}"

  local find_args=("$search_dir" "-type" "$file_type")
  local patterns=()
  
  while IFS= read -r pattern; do
    if [[ -z "$pattern" || $pattern == \#* ]]; then
      continue
    fi
    patterns+=("$pattern")
  done < "$exclude_file"

  if [[ ${#patterns[@]} -gt 0 ]]; then
    local condition_args=()
    local first_pattern=true

    for pattern in "${patterns[@]}"; do
      if [[ $first_pattern == false ]]; then
        condition_args+=("-o")
      else
        first_pattern=false
      fi

      if [[ $pattern == /* ]]; then
        condition_args+=("-path" "$pattern")
      else
        condition_args+=("-name" "$pattern")
      fi
    done

    if [[ $inverse == true ]]; then
      find_args+=("!" "(" "${condition_args[@]}" ")")
    else
      find_args+=("(" "${condition_args[@]}" ")")
    fi

    if [[ $file_type == "l" ]]; then
      find_args+=("-exec" "test" "-e" "{}" ";")
    fi
  fi

  find_args+=("-print0")

  arr_ref=()
  while IFS= read -r -d '' file; do
    arr_ref+=("$file")
  done < <(find "${find_args[@]}" 2>/dev/null)
}

# $1 - path to temp directory
copy_files_to_temp() {
  log_info "Copying files to temporary directory"

  local tmpdir="$1"
  mkdir -p "$tmpdir"

  while IFS= read -r path; do
    log_info "Copying $path to $tmpdir"
    abspath="$(expand_path "$path")"
    dirpath="$(dirname "$abspath" | cut -c2-)"

    mkdir -p "$tmpdir/$dirpath"
    copy_command "$abspath" "$tmpdir/$dirpath"

    declare -a symlinks
    find_with_patterns "$abspath" "$EXCLUDE_FILES" symlinks true "l"

    for symlink in "${symlinks[@]}"; do
      log_info "Directory $abspath contains symlink $symlink"

      symlink_dir="$(dirname "$symlink")"
      mkdir -p "$tmpdir$symlink_dir"
      cp -P "$symlink" "$tmpdir$symlink_dir"

      symlink_originate_path="$(realpath -m "$symlink")"
      symlink_originate_dir="$(dirname "$symlink_originate_path" | cut -c2-)"
      mkdir -p "$tmpdir/$symlink_originate_dir"

      log_info "Copying $symlink_originate_path to $tmpdir/$symlink_originate_dir"
      copy_command "$symlink_originate_path" "$tmpdir/$symlink_originate_dir"
    done
  done < "$INCLUDE_FILES"

  if [[ "$LOG_VERBOSE" == "true" ]]; then
    log_info "Full list of backup files:"
    ls -lah -R "$tmpdir" 2>& 1 | {
      while read -r line; do
        log_info "$line"
      done
    }
  fi
  log_info "Success!"

  return 0
}

# $1 - archive name
# $@ - files to archive
zip_compress() {
  is_var_set "CONFIG_FILE" || die "Config file variable should be set"
  is_var_set "LOG_FILE" || die "Log file is not set"

  log_info "Create zip archive"
  local err=1

  local archive_name="$1"
  shift;

  local zip_options=
  local compress_level=$(get_config_value ".compression.level" "$DEFAULT_COMPRESS_LEVEL")

  case "$compress_level" in
    "none")    zip_options+="-0" ;;
    "minimum") zip_options+="-3" ;;
    "medium")  zip_options+="-6" ;;
    "maximum") zip_options+="-9" ;;
  esac

  log_info "Compression level: $compress_level"

  zip -r "$zip_options" "$archive_name" "$@" 2>&1 | {
    if [[ "$LOG_VERBOSE" == "true" ]]; then
      while read -r line; do
        log_info "$line"
      done
    else
      cat > /dev/null
    fi
  }
  err=${PIPESTATUS[0]}

  [[ $err -eq 0 ]] && log_info "Success!" || log_error "Failed!"
  return $err
}

# $1 - archive name
# $2 - compressor (none, bzip, gzip)
# $@ - files to archive
tar_compress() {
  is_var_set "CONFIG_FILE" || die "Config file variable should be set"
  is_var_set "LOG_FILE" || die "Log file is not set"

  log_info "Create tar archive"

  local tar_env=
  local tar_options=

  local archive_name="$1"
  local compressor="$2"
  shift;shift
  local files="$@"
  local compress_level=$(get_config_value ".compression.level" "$DEFAULT_COMPRESS_LEVEL")
  
  local err=1
  local parallel_tar="${IS_PARALLEL,,}"
  declare -a parallel_command

  if [[ "$compressor" == "none" ]]; then
    compress_level="none"
  fi

  if [[ "$parallel_tar" == true ]]; then
    case "$compressor" in
      "gzip") 
        if ! check_command "pigz"; then
          log_info "pigz command not available. Fallback to classic gzip"
          parallel_tar="false"
        fi
        ;;
      "bzip")
        if ! check_command "pbzip2"; then
          log_info "pigz command not available. Fallback to classic bzip"
          parallel_tar="false"
        fi
        ;;
      "none"|*)
        log_info "Run tar without compressor. Fallback to single thread tar"
          parallel_tar="false"
        ;;
    esac
  fi

  log_info "Compressor: $compressor"
  log_info "Compression level: $compress_level"

  case "$compressor" in
    "none") ;;
    "gzip")
      if [[ "$parallel_tar" == true ]]; then
        parallel_command=("pigz" "-p" "$(nproc)")
        case "$compress_level" in
          "none")    parallel_command+=("-1") ;;
          "minimum") parallel_command+=("-3") ;;
          "medium")  parallel_command+=("-6") ;;
          "maximum") parallel_command+=("-11") ;;
          *)         parallel_command+=("-1") ;;
        esac
      else
        tar_options+="--gzip"
        tar_env="GZIP="
        case "$compress_level" in
          "none")    tar_env+="-0" ;;
          "minimum") tar_env+="-1" ;;
          "medium")  tar_env+="-6" ;;
          "maximum") tar_env+="-9" ;;
          *)         tar_env+="-0" ;;
        esac
      fi
      ;;
    "bzip")
      if [[ "$parallel_tar" == true ]]; then
        parallel_command=("pbzip2" "-c")
      else
        tar_options+="--bzip2"
        tar_env="BZIP2="
        case "$compress_level" in
          "none")    tar_env+="-1" ;;
          "minimum") tar_env+="-1" ;;
          "medium")  tar_env+="-6" ;;
          "maximum") tar_env+="-9" ;;
          *)         tar_env+="-1" ;;
        esac
      fi
      ;;
  esac

  if [[ "$parallel_tar" == true ]]; then
    tar -cf - "$files" | "${parallel_command[@]}" > "$archive_name"
    err=${PIPESTATUS[0]}
    if [[ ! $err -eq 0 ]]; then log_error "Failed to create tar archive"; break; fi
    err=${PIPESTATUS[1]}
    if [[ ! $err -eq 0 ]]; then log_error "Failed to compress tar archive"; break; fi
  else
    set "$tar_env"
    tar -cv $tar_options -f "$archive_name" "$files" 2>&1 | {
      if [[ "$LOG_VERBOSE" == "true" ]]; then
        while read -r line; do
          log_info "$line"
        done
      else
        cat > /dev/null
      fi
    }
    err=${PIPESTATUS[0]}
    unset "$tar_env"
  fi

  [[ $err -eq 0 ]] && log_info "Success!" || log_error "Failed!"
  return $err
}

# $1 - filepath
calc_hash() {
  # TODO: support sha1 or another hash
  local path="$1"
  local hash=""

  [[ ! -f "$path" ]] && log_error "No such file: $path" && log_error "Failed!" && return 1

  log_info "Calculate md5 sum of archive"
  hash="$(md5sum "$path" | cut -d' ' -f1 | cut -c1-7)"
  echo "md5-$hash"
  log_info "Success!"
  return 0
}

# $1 - directory in which archive will be created
# $2 - archive name
# $@ - files to archive
create_archive() {
  is_var_set "CONFIG_FILE" || die "Config file variable should be set"

  local archive_dir="$1"
  local archive_name="$2"
  shift;shift
  local archive_type="$(get_config_value ".compression.method" "$DEFAULT_COMPRESS_METHOD")"
  local add_hash="$(get_config_value ".general.add_hashsum" "false")"

  local err=1
  local extenstion=""

  log_info "Creating backup archive"
  log_info "Archive type: $archive_type"

  pushd "$archive_dir" > /dev/null

  case "$archive_type" in
    "zip")
      extenstion="zip"
      archive_name="${archive_name}.${extenstion}"
      zip_compress "$archive_name" "$@"
      err=$?
      ;;
    "tar")
      extenstion="tar"
      archive_name="${archive_name}.${extenstion}"
      tar_compress "$archive_name" none "$@"
      err=$?
      ;;
    "tar.gz")
      extenstion="tar.gz"
      archive_name="${archive_name}.${extenstion}"
      tar_compress "$archive_name" gzip "$@"
      err=$?
      ;;
    "tar.bz")
      extenstion="tar.bz"
      archive_name="${archive_name}.${extenstion}"
      tar_compress "$archive_name" bzip "$@"
      err=$?
      ;;
    *)
      die "Unknown archive type"
  esac

  if [[ "${add_hash,,}" == "true" ]]; then
    log_info "Adding hash to archive name"
    hash=$(calc_hash "$archive_name")
    if [[ $? -eq 0 ]]; then
      base="$(basename "$archive_name" .$extenstion)"
      new_filename="${base}-${hash}.${extenstion}"
      mv "$archive_name" "$new_filename"
      archive_name="$new_filename"
    else
      log_error "Failed to calculate hash"
    fi
  fi

  if [[ $err -eq  0 ]]; then
    timestamp=$(date +'%s')
    printf "$timestamp $archive_name\n" >> "${BACKUP_HISTORY_FILE}" 
    printf "$timestamp" > "${TIMESTAMP_FILE}" 
    log_info "Success!"
  else
    log_error "An error occured while creating archive"
  fi

  popd > /dev/null
}

parse_duration() {
  local input="$1"
  local total_seconds=0

  is_var_set "input" || die "Not initialized input string"

  log_info "Calculate required backup period"

  while [[ $input =~ ([0-9]+)([a-zA-Z]+) ]]; do
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"

    case "${unit,,}" in
      s|sec|second|seconds) total_seconds=$((total_seconds + value)) ;;
      min|minute|minutes)   total_seconds=$((total_seconds + value * 60)) ;;
      h|hour|hours)         total_seconds=$((total_seconds + value * 3600)) ;;
      d|day|days)           total_seconds=$((total_seconds + value * 86400)) ;;
      w|week|weeks)         total_seconds=$((total_seconds + value * 604800)) ;;
      mo|months)            total_seconds=$((total_seconds + value * 2592000)) ;;
      *)                    log "Unknown unit: $unit" ; return 1 ;;
    esac

    # Remove assembled part of string with spaces
    input=${input#*${BASH_REMATCH[0]}}
    input=${input## }
  done

  log_info "Success!"
  echo $total_seconds
}

check_timestamp() {
  is_var_set "CONFIG_FILE" || die "Config file variable should be set"
  is_var_set "TIMESTAMP_FILE" || die "Timestamp file variable should be set"

  log_info "Checking timestamp from last execution"

  local is_schedule_enabled=$(get_config_value ".schedule.enabled" "false")
  local true="true"
  local need_backup=0
  local no_need_backup=1

  if [[ ! "${is_schedule_enabled,,}" == "${true,,}" ]]; then
    log_info "Backup schedule is disabled... Nothing to do"
    return $no_need_backup
  fi

  if [[ ! -f "${TIMESTAMP_FILE}" ]]; then
    log_info "Timestamp file not found. Need to backup immediately"
    return $need_backup
  fi

  local last_timestamp=$(cat "${TIMESTAMP_FILE}")
  local current_timestamp=$(date +'%s')
  local period=$(parse_duration $(get_config_value '.schedule.interval' '0'))
  local diff=$((current_timestamp - last_timestamp ))

  log_info "Last execution timestamp: $last_timestamp"
  log_info "Current timestamp: $current_timestamp"
  log_info "Time diff: $diff"
  log_info "Backup period: $period"

  if ((diff < period)); then
    log_info "Time spent too short. Skipping execution"
    return $no_need_backup
  fi

  log_info "Need to create backup"
  return $need_backup
}

cleanup_resourses() {
  log_info "Clean up resourses"

  safe_delete "$INCLUDE_FILES"
  safe_delete "$EXCLUDE_FILES"
  [[ -d "$TEMP_DIR" ]] && safe_delete "$TEMP_DIR"

  log_info "Success!"
  return 0
}

# $1 - Variable (not a variable value)
is_var_set() {
  local var_name="$1"
  [[ -n "${!var_name:+x}" ]] && return 0 || return 1
}

check_retention_scheme() {
  log_info "Checking retention scheme: removing unnecessary backups"

  is_var_set "BACKUP_HISTORY_FILE" || die "Backup history file is not set"
  is_var_set "BACKUP_ROOT_DIR" || die "Backup root directory is not set"

  sorted_history=$(mktemp)
  sort -n "${BACKUP_HISTORY_FILE}" > "$sorted_history"

  pushd "$BACKUP_ROOT_DIR" > /dev/null

  stored_files=()
  while IFS= read -r line; do
    filename=$(echo "$line" | cut -d' ' -f2)
    stored_files+=("$filename")
  done < "$sorted_history"

  stored_files_count=${#stored_files[@]}
  let allowed_count=$(get_config_value ".retention.keep_last" "0")
  let diff=$(( $stored_files_count - $allowed_count ))

  log_info "Count of backups: $stored_files_count"
  log_info "Allowed backups on disk: $allowed_count"

  if (( $diff > 0 )); then
    if (( $diff > 1 )); then
      log_info "There are $diff backups to remove:"
    else
      log_info "There is $diff backup to remove:"
    fi

    for i in $(seq 0 1 $(( $diff - 1 ))); do
      log_info "Deleting ${stored_files[$i]}"
      safe_delete "${stored_files[$i]}"
    done

    log_info "Update history file"
    tail -n +$(( $diff + 1 )) "$sorted_history" > "${BACKUP_HISTORY_FILE}"
  fi

  safe_delete "$sorted_history"

  popd > /dev/null
  log_info "Success!"
}

cmd_version() {
  LOG_FILE="/dev/null"
  cat << EOF
============================================
= backup:     simple backup tool           =
=                                          =
=                  v${VERSION}                  =
=           Alexander Kutsenko             =
=          ftruf357ft@gmail.com            =
============================================
EOF
}

# $1 - count of seconds
format_seconds() {
  local seconds=$1
  local days=$((seconds / 86400))
  local hours=$((seconds % 86400 / 3600))
  local minutes=$((seconds % 3600 / 60))
  local secs=$((seconds % 60))

  local result=""

  [ $days -gt 0 ] && result+="${days}d "
  [ $hours -gt 0 ] && result+="${hours}h "
  [ $minutes -gt 0 ] && result+="${minutes}min "
  [ $secs -gt 0 ] && result+="${secs}sec"

  echo "${result:-0с}"
}

cmd_create() {
  tabs -4
  CONFIG_FILE="$(realpath -m $1)"
  let time_start=$(date +'%s')

  is_var_set "CONFIG_FILE" && [[ -f "${CONFIG_FILE}" ]] || die "Config file should be given"

  BACKUP_STORAGE=$(expand_path $(get_config_value ".general.backup_storage" "${BACKUP_STORAGE}"))
  BACKUP_NAME=$(get_config_value ".name" "")

  [[ -z "$BACKUP_NAME" ]] && die "Backup name should be given"

  BACKUP_ROOT_DIR="${BACKUP_STORAGE}/${BACKUP_NAME}"
  mkdir -p "${BACKUP_ROOT_DIR}"
  
  LOG_FILE="${BACKUP_ROOT_DIR}/last_backup.log"
  TIMESTAMP_FILE="${BACKUP_ROOT_DIR}/.timestamp"
  BACKUP_HISTORY_FILE="${BACKUP_ROOT_DIR}/.backup_history"
  CREATION_TIME=$(date +'%F-%H-%M-%S')
  CURRENT_BACKUP_NAME="${BACKUP_NAME}_${CREATION_TIME}"
  TEMP_DIR="${BACKUP_ROOT_DIR}/${CURRENT_BACKUP_NAME}"

  IS_PARALLEL="$(get_config_value ".general.parallel" "false")"
  LOG_VERBOSE="$(get_config_value ".general.verbose" "false")"

  readonly BACKUP_ROOT_DIR TIMESTAMP_FILE BACKUP_HISTORY_FILE
  readonly CURRENT_BACKUP_NAME TEMP_DIR LOG_FILE IS_PARALLEL

  > "$LOG_FILE"

  log_info "Create new backup"
  log_info "Start execution at ${CREATION_TIME}"
  log_info "Use multithread: ${IS_PARALLEL}"

  check_timestamp
  local err=$?

  [[ ! $err -eq 0 ]] && exit 0

  prepare_files_lists
  copy_files_to_temp "$TEMP_DIR"
  create_archive "${BACKUP_ROOT_DIR}" "${CURRENT_BACKUP_NAME}" $(realpath --relative-to="${BACKUP_ROOT_DIR}" "${TEMP_DIR}")
  check_retention_scheme

  let time_end=$(date +'%s')
  log_info "Elapsed time: $(format_seconds $(( time_end - time_start )) )"
  
  log_info "Success!"
}

# Function that add backup monitor to cron
cmd_init() {
  LOG_FILE="${MONITOR_LOG}"
  > "$LOG_FILE"
  log_info "Initialize backup monitor tool"

  log_info "Create settings directory"
  mkdir -p "${MONITOR_PATH}"
  [[ ! -f "${MONITOR_SCENARIOS}" ]] && touch "${MONITOR_SCENARIOS}"

  if crontab -l 2>/dev/null | grep -q "$UNIQUE_COMMENT"; then
    log_info "Cron job was added previously. Skipping"
  else
    log_info "Add rule to cron"
    cron_job="$(mktemp)"
    echo "*/5 * * * * ${BACKUP_MONITOR} #${UNIQUE_COMMENT}" > "$cron_job"
    crontab "$cron_job"
    [[ $? -eq 0 ]] && log_info "Success!" || log_error "Failed to add cron job"
    safe_delete "$cron_job"
  fi

  return 0
}

cmd_deinit() {
  LOG_FILE="${MONITOR_LOG}"
  > "$LOG_FILE"
  log_info "Deinit backup monitor tool"
  
  if crontab -l 2>/dev/null | grep -q "$UNIQUE_COMMENT"; then
    log_info "Removing cron job"
    (crontab -l | grep -v "$UNIQUE_COMMENT") | crontab -
    log_info "Job removed successfully"
  else
    log_info "Job not found in crontab"
  fi

  is_var_set "MONITOR_SCENARIOS" || die "Monitor scenarios path is empty"
  log_info "Deleting backup monitor scenarios file"
  safe_delete "${MONITOR_SCENARIOS}"

  return 0
}

# $1 - path to backup scenario
cmd_add_scenario() {
  LOG_FILE="${MONITOR_LOG}"
  > "$LOG_FILE"

  local path="$(expand_path "$1")"

  if [[ -n "$path" && "$path" = /* ]]; then
    is_var_set "MONITOR_SCENARIOS" || die "Monitor scenarios file not set. Run '${PROGRAM} init' first"

    CONFIG_FILE="$path"
    scenario_name="$(get_config_value ".name" "")"
    [[ -z "$scenario_name" ]] && echo "Scenario name should be given..." && exit 1

    while IFS= read -r scenario; do
      CONFIG_FILE="$scenario"
      name=$(get_config_value ".name" "")
      if [[ "$scenario_name" == "$name" ]]; then
        echo "A scenario with that name already exists. Please rename new one..."
        exit 1
      fi
    done < "${MONITOR_SCENARIOS}"
    echo "$path" >> "${MONITOR_SCENARIOS}"
  else
    log_error "Path to backup config file should be absolute or relative to the user's home directory"
  fi
  return 0
}

yesno() {
  [[ -t 0 ]] || return 0
  local response
  read -r -p "$1 [y/N] " response
  [[ $response == [yY] ]] || exit 1
}

# $1 - path to config
cmd_delete_scenario() {
  LOG_FILE="${MONITOR_LOG}"
  > "$LOG_FILE"

  local path=""

  if [[ $# -eq 0 ]]; then
    cmd_list
    read -p "Input scenario number which you want to delete: " scenario_number
    is_var_set "MONITOR_SCENARIOS" || die "Monitor scenarios file not set"
    path=$(head -n $(( scenario_number )) "${MONITOR_SCENARIOS}" | tail -n 1)
    yesno "Do you really want to remove scenario: $path ?"
  else
    path=$(expand_path "$1")
  fi

  if cat "${MONITOR_SCENARIOS}" 2>/dev/null | grep -q "$path"; then
    log_info "Removing backup config at path: $path"
    (cat "${MONITOR_SCENARIOS}" | grep -v "$path") > "${MONITOR_SCENARIOS}"
  else
    log_error "Backup config by path $path not found"
  fi

  return 0
}

green_check() {
  local green=$(tput setaf 2)
  local reset=$(tput sgr0)
  echo "${green}✓${reset}"
}

red_check() {
  local red=$(tput setaf 1)
  local reset=$(tput sgr0)
  echo "${red}✗${reset}"
}

cmd_checkhealth() {
  declare -a tools
  tools=("bzip2" "cat" "cp" "crontab" "du" "find" "grep" "gzip" "head" "mv" "parallel" "pbzip2" "pigz" "tail" "tar" "yq" "zip")
  local max_length=0
  local bold=$(tput bold)

  for element in "${tools[@]}"; do
    length=${#element}
    if ((length > max_length)); then
      max_length=$length
    fi
  done

  printf "Checking the availability of utilities:\n"

  for tool in "${tools[@]}"; do
    printf "%-$((max_length + 10))s" "${bold}${tool}"
    check_command "$tool" && green_check || red_check
  done

  return 0
}

cmd_list() {
  is_var_set "MONITOR_SCENARIOS" || die "Monitor scenarios file not set"

  [[ ! -f "${MONITOR_SCENARIOS}" || ! -s "${MONITOR_SCENARIOS}" ]] && echo "There is no backup scenarios" && exit 0

  if (( $( cat "${MONITOR_SCENARIOS}" | wc -l) > 0 )); then
    echo "List of backup scenarios:"
    cat -n "${MONITOR_SCENARIOS}"
  else
    echo "There is no backup scenarios"
  fi
  return 0
}

PROGRAM="${0##*/}"
COMMAND="$1"

trap cleanup_resourses SIGINT EXIT

case "$COMMAND" in
  init)            shift; cmd_init "$@" ;;
  deinit)          shift; cmd_deinit "$@" ;;
  add-scenario)    shift; cmd_add_scenario "$@" ;;
  delete-scenario) shift; cmd_delete_scenario "$@" ;;
  ls|list|--list)  shift; cmd_list "$@" ;;
  create)          shift; cmd_create "$@" ;;
  checkhealth)     shift; cmd_checkhealth "$@" ;;
  version)         shift; cmd_version "$@" ;;
esac

exit 0
