#!/bin/bash

# Monitor remote OpenMRS backups stored in OneDrive via rclone and send alerts when needed.
# The script traverses the backup hierarchy, reports the latest backup per facility, and emails alerts when issues arise.
# Assumes rclone, mail/sendmail, and GNU date (or gdate) are available.

set -uo pipefail

REMOTE_PATH="hisbackups:/Gaza/openmrs_backups"
ALERT_SUBJECT_DATE_FORMAT="+%Y-%m-%d"
AGE_THRESHOLD_DAYS=7

DATE_BIN="date"
OS_NAME=$(uname -s 2>/dev/null || echo "")

if [[ $OS_NAME == "Darwin" ]]; then
  if command -v gdate >/dev/null 2>&1; then
    DATE_BIN="gdate"
  else
    printf "ERROR: GNU date (gdate from coreutils) is required on macOS for time comparisons.\n" >&2
    exit 1
  fi
else
  if ! date -d "1970-01-01" +%s >/dev/null 2>&1; then
    if command -v gdate >/dev/null 2>&1; then
      DATE_BIN="gdate"
    else
      printf "ERROR: GNU date (coreutils) is required for time comparisons.\n" >&2
      exit 1
    fi
  fi
fi

NOW_EPOCH=$($DATE_BIN -u +%s)
AGE_THRESHOLD_SEC=$((AGE_THRESHOLD_DAYS * 24 * 3600))

FORMAT="%-15s | %-16s | %-46s | %s"
SEPARATOR="--------------------------------------------------------------------------------------"
TABLE_LINES=()
ALERTS=()

printf -v HEADER "$FORMAT" "District" "Health Facility" "File name" "Last Backup Date"
TABLE_LINES+=("$HEADER" "$SEPARATOR")

shopt -s nocasematch  # Case-insensitive matching for file extensions.

list_entries() {
  local path=$1
  local flags=$2
  local output

  if ! output=$(rclone lsf "$path" $flags --format=p 2>&1); then
    printf "ERROR: Failed to list entries for %s: %s\n" "$path" "$output" >&2
    exit 1
  fi

  printf "%s" "$output"
}

districts_raw=$(list_entries "$REMOTE_PATH" "--dirs-only")
DISTRICTS=()
while IFS= read -r district_line; do
  DISTRICTS+=("$district_line")
done <<<"$districts_raw"

if [[ ${#DISTRICTS[@]} -eq 0 ]]; then
  printf "WARNING: No district directories found under %s\n" "$REMOTE_PATH" >&2
fi

for district_entry in "${DISTRICTS[@]}"; do
  [[ -z $district_entry ]] && continue
  district=${district_entry%/}

  facilities_raw=$(list_entries "${REMOTE_PATH}/${district}" "--dirs-only")
  FACILITIES=()
  while IFS= read -r facility_line; do
    FACILITIES+=("$facility_line")
  done <<<"$facilities_raw"

  if [[ ${#FACILITIES[@]} -eq 0 ]]; then
    printf -v line "$FORMAT" "$district" "-" "No backup found" "No backup found"
    TABLE_LINES+=("$line")
    ALERTS+=("No health facilities found in ${district}; no backups to report.")
    continue
  fi

  for facility_entry in "${FACILITIES[@]}"; do
    [[ -z $facility_entry ]] && continue
    facility=${facility_entry%/}

    files_err=$(mktemp)  # Capture stderr separately to keep parsed output clean.
    if ! files_output=$(rclone lsf "${REMOTE_PATH}/${district}/${facility}" --files-only --format=pt --separator '|' 2>"$files_err"); then
      err_msg=$(<"$files_err")
      rm -f "$files_err"
      printf "ERROR: Failed to list backups for %s/%s: %s\n" "$district" "$facility" "$err_msg" >&2
      ALERTS+=("Failed to access backups for ${district}/${facility}: ${err_msg}")
      printf -v line "$FORMAT" "$district" "$facility" "No backup found" "No backup found"
      TABLE_LINES+=("$line")
      continue
    fi
    err_msg=$(<"$files_err")
    rm -f "$files_err"
    if [[ -n $err_msg ]]; then
      printf "WARNING: rclone returned diagnostics for %s/%s: %s\n" "$district" "$facility" "$err_msg" >&2
    fi

    latest_name=""
    latest_time=""

    while IFS='|' read -r name mtime; do
      [[ -z $name ]] && continue
      if [[ ! $name =~ \.(zip|rar|sql)$ ]]; then
        continue
      fi
      if [[ -z $latest_time || $mtime > $latest_time ]]; then
        latest_time=$mtime
        latest_name=$name
      fi
    done <<<"$files_output"

    if [[ -z $latest_name ]]; then
      printf -v line "$FORMAT" "$district" "$facility" "No backup found" "No backup found"
      TABLE_LINES+=("$line")
      ALERTS+=("No backups found in ${district}/${facility}.")
      continue
    fi

    backup_date=${latest_time%% *}
    parsed_epoch=""
    if [[ -n $latest_time ]]; then
      if parsed_epoch=$($DATE_BIN -u -d "$latest_time" +%s 2>/dev/null); then
        :
      else
        parsed_epoch=""
      fi
    fi

    if [[ -z $parsed_epoch ]]; then
      if [[ $latest_name =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        backup_date=${BASH_REMATCH[1]}
        parsed_epoch=$($DATE_BIN -u -d "${backup_date} 00:00:00" +%s 2>/dev/null || echo "")
      else
        backup_date="Unknown"
      fi
    fi

    if [[ -n $parsed_epoch ]]; then
      age=$((NOW_EPOCH - parsed_epoch))
      if (( age > AGE_THRESHOLD_SEC )); then
        ALERTS+=("Backup in ${district}/${facility} is outdated: ${backup_date}")
      fi
    else
      ALERTS+=("Could not confirm backup age for ${district}/${facility} (${latest_name}).")
    fi

    printf -v line "$FORMAT" "$district" "$facility" "$latest_name" "$backup_date"
    TABLE_LINES+=("$line")
  done
done

printf "%s\n" "${TABLE_LINES[@]}"

shopt -u nocasematch

if [[ ${#ALERTS[@]} -gt 0 ]]; then
  subject_date=$(date "$ALERT_SUBJECT_DATE_FORMAT")
  subject="Backup Monitoring Alert - ${subject_date}"

  email_tmp=$(mktemp)
  {
    printf "Backup monitoring detected issues:\n\n"
    printf "%s\n" "${TABLE_LINES[@]}"
    printf "\nIssues:\n"
    for alert in "${ALERTS[@]}"; do
      printf " - %s\n" "$alert"
    done
  } >"$email_tmp"

  body=$(<"$email_tmp")
  rm -f "$email_tmp"

  send_email() {
    local subj=$1
    local message=$2
    if command -v mail >/dev/null 2>&1; then
      printf "%s\n" "$message" | mail -s "$subj" -r "$EMAIL_FROM" "$EMAIL_TO"
      return $?
    elif command -v sendmail >/dev/null 2>&1; then
      {
        printf "From: %s\n" "$EMAIL_FROM"
        printf "To: %s\n" "$EMAIL_TO"
        printf "Subject: %s\n" "$subj"
        printf "\n%s\n" "$message"
      } | sendmail -t
      return $?
    else
      printf "ERROR: Neither mail nor sendmail command is available for notifications.\n" >&2
      return 1
    fi
  }

  if ! send_email "$subject" "$body"; then
    printf "ERROR: Failed to send alert email.\n" >&2
    exit 1
  fi
fi

exit 0
