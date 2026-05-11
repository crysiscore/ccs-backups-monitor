#!/bin/bash

# Monitor remote OpenMRS backups stored in OneDrive via rclone and send alerts when needed.
# The script traverses the backup hierarchy, reports the latest backup per facility using creation time,
# and emails alerts when issues arise.
# Assumes rclone, jq, python3 (with openpyxl), mail/sendmail, and GNU date (or gdate) are available.

set -uo pipefail

REMOTE_NAME="hisbackups"
BACKUP_DIR="openmrs_backups"
PROVINCE=""
REMOTE_PATH=""
ALERT_SUBJECT_DATE_FORMAT="+%Y-%m-%d"
AGE_THRESHOLD_DAYS=9
EMAIL_FROM="agnaldosamuel@ccsaude.org.mz"
EMAIL_TO="agnaldosamuel@ccsaude.org.mz"
REPORT_TXT="backup_monitor_report.txt"
REPORT_CSV="backup_monitor_report.csv"
REPORT_XLSX="backup_monitor_report.xlsx"
MAPUTO_MAPPING_FILE="maputo_us_mapping.csv"
STATUS_UPDATED="Actualizado"
STATUS_OUTDATED="Desactualizado"

DATE_BIN="date"
OS_NAME=$(uname -s 2>/dev/null || echo "")
PROGRESS_TTY=0
PROGRESS_LINE_ACTIVE=0
PROGRESS_LAST_LEN=0
PROGRESS_ENABLED=1

progress_init() {
  if [[ -t 2 ]]; then
    PROGRESS_TTY=1
  else
    PROGRESS_TTY=0
  fi
  PROGRESS_LINE_ACTIVE=0
  PROGRESS_LAST_LEN=0
}

progress_break_line() {
  if (( PROGRESS_ENABLED && PROGRESS_TTY && PROGRESS_LINE_ACTIVE )); then
    printf "\n" >&2
    PROGRESS_LINE_ACTIVE=0
    PROGRESS_LAST_LEN=0
  fi
}

progress_update() {
  local msg="Progress: $1"
  local msg_len=${#msg}

  (( PROGRESS_ENABLED )) || return 0

  if (( PROGRESS_TTY )); then
    local pad=""
    if (( PROGRESS_LAST_LEN > msg_len )); then
      printf -v pad "%*s" $((PROGRESS_LAST_LEN - msg_len)) ""
    fi
    printf "\r%s%s" "$msg" "$pad" >&2
    PROGRESS_LINE_ACTIVE=1
    PROGRESS_LAST_LEN=$msg_len
  else
    printf "%s\n" "$msg" >&2
  fi
}

progress_phase() {
  progress_update "$1"
}

progress_done() {
  local final_msg=${1:-}

  (( PROGRESS_ENABLED )) || return 0

  if [[ -n $final_msg ]]; then
    progress_update "$final_msg"
  fi

  if (( PROGRESS_TTY && PROGRESS_LINE_ACTIVE )); then
    printf "\n" >&2
  fi
  PROGRESS_LINE_ACTIVE=0
  PROGRESS_LAST_LEN=0
}

stderr_printf() {
  progress_break_line
  printf "$@" >&2
}

print_usage() {
  cat <<'EOF'
Usage: ./backup_monitor.sh --province <Gaza|Maputo>

Options:
  --province NAME   Province to scan (Gaza or Maputo)
  -h, --help        Show this help message
EOF
}

parse_args() {
  local province_lc=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --province)
        shift
        if [[ $# -eq 0 ]]; then
          stderr_printf "ERROR: Missing value for --province.\n"
          print_usage >&2
          exit 1
        fi
        PROVINCE=$1
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        stderr_printf "ERROR: Unknown argument: %s\n" "$1"
        print_usage >&2
        exit 1
        ;;
    esac
    shift
  done

  if [[ -z $PROVINCE ]]; then
    stderr_printf "ERROR: --province is required.\n"
    print_usage >&2
    exit 1
  fi

  province_lc=$(printf "%s" "$PROVINCE" | tr "[:upper:]" "[:lower:]")
  case "$province_lc" in
    gaza)
      PROVINCE="Gaza"
      ;;
    maputo)
      PROVINCE="Maputo"
      ;;
    *)
      stderr_printf "ERROR: Invalid province '%s'. Allowed values: Gaza, Maputo.\n" "$PROVINCE"
      exit 1
      ;;
  esac

  REMOTE_PATH="${REMOTE_NAME}:/${PROVINCE}/${BACKUP_DIR}"
}

progress_init
parse_args "$@"

if ! command -v rclone >/dev/null 2>&1; then
  stderr_printf "ERROR: rclone is required but not installed.\n"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  stderr_printf "ERROR: jq is required for parsing OneDrive metadata.\n"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  stderr_printf "ERROR: python3 is required to generate the XLSX report.\n"
  exit 1
fi

if ! python3 - <<'PY' >/dev/null 2>&1
import openpyxl
PY
then
  stderr_printf "ERROR: openpyxl is required for XLSX output. Install it with: python3 -m pip install openpyxl\n"
  exit 1
fi

if [[ $OS_NAME == "Darwin" ]]; then
  if command -v gdate >/dev/null 2>&1; then
    DATE_BIN="gdate"
  else
    stderr_printf "ERROR: GNU date (gdate from coreutils) is required on macOS for time comparisons.\n"
    exit 1
  fi
else
  if ! date -d "1970-01-01" +%s >/dev/null 2>&1; then
    if command -v gdate >/dev/null 2>&1; then
      DATE_BIN="gdate"
    else
      stderr_printf "ERROR: GNU date (coreutils) is required for time comparisons.\n"
      exit 1
    fi
  fi
fi

NOW_EPOCH=$($DATE_BIN -u +%s)
AGE_THRESHOLD_SEC=$((AGE_THRESHOLD_DAYS * 24 * 3600))

FORMAT="%-15s | %-16s | %-46s | %-10s | %-24s | %s"
SEPARATOR="----------------------------------------------------------------------------------------------------------------------------------"
TABLE_LINES=()
ALERTS=()
CSV_LINES=("District,Health Facility,File name,File Size,Last Backup Created (UTC),Backup Status")

printf -v HEADER "$FORMAT" "District" "Health Facility" "File name" "File Size" "Last Backup Created (UTC)" "Backup Status"
TABLE_LINES+=("$HEADER" "$SEPARATOR")

shopt -s nocasematch  # Case-insensitive matching for file extensions.

csv_quote() {
  local value=$1
  value=${value//\"/\"\"}
  printf '"%s"' "$value"
}

append_csv_line() {
  local district=$1
  local facility=$2
  local filename=$3
  local file_size=$4
  local backup_date=$5
  local backup_status=$6
  CSV_LINES+=("$(csv_quote "$district"),$(csv_quote "$facility"),$(csv_quote "$filename"),$(csv_quote "$file_size"),$(csv_quote "$backup_date"),$(csv_quote "$backup_status")")
}

human_size_binary() {
  local bytes=${1:-0}

  if [[ ! $bytes =~ ^[0-9]+$ ]]; then
    printf "N/A"
    return
  fi

  if (( bytes < 1024 )); then
    printf "%d B" "$bytes"
    return
  fi

  awk -v bytes="$bytes" '
    BEGIN {
      split("B KiB MiB GiB TiB", unit, " ")
      idx = 1
      value = bytes + 0
      while (value >= 1024 && idx < 5) {
        value /= 1024
        idx++
      }
      if (value >= 10 || value == int(value)) {
        printf "%.0f %s", value, unit[idx]
      } else {
        printf "%.1f %s", value, unit[idx]
      }
    }
  '
}

generate_xlsx_report() {
  local csv_file=$1
  local xlsx_file=$2
  local alerts_payload=$3

  if ! python3 - "$csv_file" "$xlsx_file" "$alerts_payload" <<'PY'
import csv
import json
import sys
from pathlib import Path

try:
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter
except ImportError:
    print("ERROR: openpyxl is required for XLSX output. Install it with: python3 -m pip install openpyxl", file=sys.stderr)
    sys.exit(1)

csv_path = Path(sys.argv[1])
xlsx_path = Path(sys.argv[2])
alerts = json.loads(sys.argv[3])

rows = []
with csv_path.open("r", newline="", encoding="utf-8") as handle:
    rows = list(csv.reader(handle))

workbook = Workbook()
sheet = workbook.active
sheet.title = "Backup Report"

for row in rows:
    sheet.append(row)

header_fill = PatternFill(fill_type="solid", fgColor="1F4E78")
header_font = Font(color="FFFFFF", bold=True)
body_font = Font(color="000000")
outdated_fill = PatternFill(fill_type="solid", fgColor="FFF2CC")
thin_side = Side(style="thin", color="D9D9D9")
cell_border = Border(left=thin_side, right=thin_side, top=thin_side, bottom=thin_side)
status_col_idx = rows[0].index("Backup Status") + 1 if rows and "Backup Status" in rows[0] else None

if rows:
    for cell in sheet[1]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center")
        cell.border = cell_border

for row in sheet.iter_rows(min_row=2, max_row=sheet.max_row, min_col=1, max_col=sheet.max_column):
    for cell in row:
        cell.font = body_font
        cell.alignment = Alignment(horizontal="left", vertical="center")
        cell.border = cell_border
    if status_col_idx is not None:
        status_value = row[status_col_idx - 1].value
        if isinstance(status_value, str) and status_value.strip().lower() == "desactualizado":
            for cell in row:
                cell.fill = outdated_fill

sheet.freeze_panes = "A2"
sheet.auto_filter.ref = sheet.dimensions
sheet.row_dimensions[1].height = 22

for col_idx in range(1, sheet.max_column + 1):
    col_letter = get_column_letter(col_idx)
    max_len = 0
    for cell in sheet[col_letter]:
        value_len = len(str(cell.value)) if cell.value is not None else 0
        if value_len > max_len:
            max_len = value_len
    sheet.column_dimensions[col_letter].width = min(max(max_len + 2, 16), 56)

issues = workbook.create_sheet(title="Issues")
issues.append(["Issue"])
issues["A1"].fill = header_fill
issues["A1"].font = header_font
issues["A1"].alignment = Alignment(horizontal="center", vertical="center")
issues["A1"].border = cell_border
issues.row_dimensions[1].height = 22

if alerts:
    for issue in alerts:
        issues.append([issue])
else:
    issues.append(["No issues detected."])

for row in issues.iter_rows(min_row=2, max_row=issues.max_row, min_col=1, max_col=1):
    for cell in row:
        cell.font = body_font
        cell.alignment = Alignment(horizontal="left", vertical="top", wrap_text=True)
        cell.border = cell_border

issues.column_dimensions["A"].width = 120
issues.freeze_panes = "A2"
issues.auto_filter.ref = issues.dimensions

workbook.save(xlsx_path)
PY
  then
    stderr_printf "ERROR: Failed to generate XLSX report: %s\n" "$xlsx_file"
    exit 1
  fi
}

list_entries() {
  local path=$1
  local flags=$2
  local output

  if ! output=$(rclone lsf "$path" $flags --format=p 2>&1); then
    stderr_printf "ERROR: Failed to list entries for %s: %s\n" "$path" "$output"
    exit 1
  fi

  printf "%s" "$output"
}

trim_whitespace() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf "%s" "$value"
}

load_maputo_mapping() {
  local mapping_file=$1

  if [[ ! -f $mapping_file ]]; then
    stderr_printf "ERROR: Maputo mapping file not found: %s\n" "$mapping_file"
    exit 1
  fi
}

get_maputo_mapping() {
  local mapping_file=$1
  local onedrive_name=$2

  awk -F',' -v key="$onedrive_name" '
    NR == 1 { next }
    {
      gsub(/\r/, "", $0)
      if ($1 == key) {
        print $2 "|" $3
        exit
      }
    }
  ' "$mapping_file"
}

add_seen_district() {
  local district=$1
  if ! printf "%s" "$MAPUTO_DISTRICT_LIST" | grep -Fxq "$district"; then
    MAPUTO_DISTRICT_LIST+="${district}"$'\n'
  fi
}

process_facility() {
  local district=$1
  local facility_label=$2
  local listing_path=$3
  local alert_context=$4
  local files_err=""
  local files_output=""
  local err_msg=""
  local parsed_files=""
  local latest_name=""
  local latest_size_human="N/A"
  local latest_epoch=""
  local latest_created_utc=""
  local fallback_size_human="N/A"
  local backup_status=$STATUS_OUTDATED
  local eligible_count=0
  local file_size="N/A"
  local age=0

  files_err=$(mktemp)  # Capture stderr separately to keep parsed output clean.
  if ! files_output=$(rclone lsjson "$listing_path" --files-only --metadata 2>"$files_err"); then
    err_msg=$(<"$files_err")
    rm -f "$files_err"
    stderr_printf "ERROR: Failed to list backups for %s: %s\n" "$alert_context" "$err_msg"
    ALERTS+=("Failed to access backups for ${alert_context}: ${err_msg}")
    printf -v line "$FORMAT" "$district" "$facility_label" "No backup found" "$file_size" "No backup found" "$backup_status"
    TABLE_LINES+=("$line")
    append_csv_line "$district" "$facility_label" "No backup found" "$file_size" "No backup found" "$backup_status"
    facilities_processed_total=$((facilities_processed_total + 1))
    return
  fi
  err_msg=$(<"$files_err")
  rm -f "$files_err"
  if [[ -n $err_msg ]]; then
    stderr_printf "WARNING: rclone returned diagnostics for %s: %s\n" "$alert_context" "$err_msg"
  fi

  if ! parsed_files=$(printf "%s" "$files_output" | jq -r '.[] | [.Name, (.Metadata.btime // ""), (.ModTime // ""), (.Size // 0)] | @tsv' 2>/dev/null); then
    stderr_printf "ERROR: Failed to parse backup metadata for %s.\n" "$alert_context"
    ALERTS+=("Failed to parse backup metadata for ${alert_context}.")
    printf -v line "$FORMAT" "$district" "$facility_label" "No backup found" "$file_size" "No backup found" "$backup_status"
    TABLE_LINES+=("$line")
    append_csv_line "$district" "$facility_label" "No backup found" "$file_size" "No backup found" "$backup_status"
    facilities_processed_total=$((facilities_processed_total + 1))
    return
  fi

  while IFS=$'\t' read -r name btime mtime size_bytes; do
    [[ -z $name ]] && continue
    if [[ ! $name =~ \.(zip|rar|sql|7z)$ ]]; then
      continue
    fi

    eligible_count=$((eligible_count + 1))
    if [[ $fallback_size_human == "N/A" ]]; then
      fallback_size_human=$(human_size_binary "$size_bytes")
    fi
    effective_time=$btime
    if [[ -z $effective_time ]]; then
      effective_time=$mtime
    fi
    [[ -z $effective_time ]] && continue

    if ! parsed_epoch=$($DATE_BIN -u -d "$effective_time" +%s 2>/dev/null); then
      continue
    fi

    if [[ -z $latest_epoch || $parsed_epoch -gt $latest_epoch ]]; then
      latest_epoch=$parsed_epoch
      latest_name=$name
      latest_size_human=$(human_size_binary "$size_bytes")
      latest_created_utc=$($DATE_BIN -u -d "@${parsed_epoch}" "+%Y-%m-%d %H:%M:%S UTC")
    fi
  done <<<"$parsed_files"

  if [[ $eligible_count -eq 0 ]]; then
    printf -v line "$FORMAT" "$district" "$facility_label" "No backup found" "$file_size" "No backup found" "$backup_status"
    TABLE_LINES+=("$line")
    ALERTS+=("No backups found in ${alert_context}.")
    append_csv_line "$district" "$facility_label" "No backup found" "$file_size" "No backup found" "$backup_status"
    facilities_processed_total=$((facilities_processed_total + 1))
    return
  fi

  if [[ -n $latest_epoch ]]; then
    age=$((NOW_EPOCH - latest_epoch))
    if (( age >= AGE_THRESHOLD_SEC )); then
      backup_status=$STATUS_OUTDATED
      ALERTS+=("Backup in ${alert_context} is outdated: ${latest_created_utc}")
    else
      backup_status=$STATUS_UPDATED
    fi
  else
    latest_name="Backup files found"
    latest_size_human=$fallback_size_human
    latest_created_utc="Unknown"
    backup_status=$STATUS_OUTDATED
    ALERTS+=("Could not confirm backup age for ${alert_context}: no parseable btime/mtime metadata.")
  fi

  printf -v line "$FORMAT" "$district" "$facility_label" "$latest_name" "$latest_size_human" "$latest_created_utc" "$backup_status"
  TABLE_LINES+=("$line")
  append_csv_line "$district" "$facility_label" "$latest_name" "$latest_size_human" "$latest_created_utc" "$backup_status"
  facilities_processed_total=$((facilities_processed_total + 1))
}

facilities_processed_total=0
district_count_total=0
EXIT_CODE=0
UNMAPPED_UNITS=()

if [[ $PROVINCE == "Maputo" ]]; then
  load_maputo_mapping "$MAPUTO_MAPPING_FILE"
  MAPUTO_DISTRICT_LIST=""
  progress_phase "listing Maputo unit directories..."
  units_raw=$(list_entries "$REMOTE_PATH" "--dirs-only")
  UNIT_DIRS=()
  unit_count_total=0
  while IFS= read -r unit_line; do
    UNIT_DIRS+=("$unit_line")
    if [[ -n $unit_line ]]; then
      unit_count_total=$((unit_count_total + 1))
    fi
  done <<<"$units_raw"

  progress_phase "found ${unit_count_total} unit directories"
  unit_index=0

  for unit_entry in "${UNIT_DIRS[@]}"; do
    [[ -z $unit_entry ]] && continue
    unit=${unit_entry%/}
    unit_index=$((unit_index + 1))

    mapping_pair=$(get_maputo_mapping "$MAPUTO_MAPPING_FILE" "$unit")
    if [[ -n $mapping_pair ]]; then
      facility_label=${mapping_pair%|*}
      district=${mapping_pair#*|}
    else
      district="UNMAPPED"
      facility_label=$unit
      UNMAPPED_UNITS+=("$unit")
      ALERTS+=("Unmapped Maputo unit directory: ${unit}. Add mapping to ${MAPUTO_MAPPING_FILE}.")
    fi

    add_seen_district "$district"
    progress_update "Maputo unit ${unit_index}/${unit_count_total} (${unit}) | processed ${facilities_processed_total} | alerts ${#ALERTS[@]}"
    process_facility "$district" "$facility_label" "${REMOTE_PATH}/${unit}" "${PROVINCE}/${unit}"
  done

  district_count_total=$(printf "%s" "$MAPUTO_DISTRICT_LIST" | sed '/^$/d' | wc -l | awk '{print $1}')
else
  progress_phase "listing districts for ${PROVINCE}..."
  districts_raw=$(list_entries "$REMOTE_PATH" "--dirs-only")
  DISTRICTS=()
  district_count_total=0
  while IFS= read -r district_line; do
    DISTRICTS+=("$district_line")
    if [[ -n $district_line ]]; then
      district_count_total=$((district_count_total + 1))
    fi
  done <<<"$districts_raw"

  if [[ ${#DISTRICTS[@]} -eq 0 ]]; then
    stderr_printf "WARNING: No district directories found under %s\n" "$REMOTE_PATH"
  fi

  district_index=0
  progress_phase "found ${district_count_total} districts"

  for district_entry in "${DISTRICTS[@]}"; do
    [[ -z $district_entry ]] && continue
    district=${district_entry%/}
    district_index=$((district_index + 1))
    progress_phase "district ${district_index}/${district_count_total} (${district}) | listing facilities..."

    facilities_raw=$(list_entries "${REMOTE_PATH}/${district}" "--dirs-only")
    FACILITIES=()
    facility_count_total=0
    while IFS= read -r facility_line; do
      FACILITIES+=("$facility_line")
      if [[ -n $facility_line ]]; then
        facility_count_total=$((facility_count_total + 1))
      fi
    done <<<"$facilities_raw"
    facility_index=0

    if [[ ${#FACILITIES[@]} -eq 0 ]]; then
      backup_status=$STATUS_OUTDATED
      file_size="N/A"
      printf -v line "$FORMAT" "$district" "-" "No backup found" "$file_size" "No backup found" "$backup_status"
      TABLE_LINES+=("$line")
      ALERTS+=("No health facilities found in ${district}; no backups to report.")
      append_csv_line "$district" "-" "No backup found" "$file_size" "No backup found" "$backup_status"
      continue
    fi

    for facility_entry in "${FACILITIES[@]}"; do
      [[ -z $facility_entry ]] && continue
      facility=${facility_entry%/}
      facility_index=$((facility_index + 1))
      progress_update "district ${district_index}/${district_count_total} (${district}) | facility ${facility_index}/${facility_count_total} (${facility}) | processed ${facilities_processed_total} | alerts ${#ALERTS[@]}"
      process_facility "$district" "$facility" "${REMOTE_PATH}/${district}/${facility}" "${district}/${facility}"
    done
  done
fi

if (( ${#UNMAPPED_UNITS[@]} > 0 )); then
  stderr_printf "ERROR: Found %d unmapped Maputo units in OneDrive:\n" "${#UNMAPPED_UNITS[@]}"
  for unmapped_unit in "${UNMAPPED_UNITS[@]}"; do
    stderr_printf " - %s\n" "$unmapped_unit"
  done
  EXIT_CODE=1
fi

progress_done
printf "%s\n" "${TABLE_LINES[@]}"
progress_phase "writing TXT report..."
printf "%s\n" "${TABLE_LINES[@]}" >"$REPORT_TXT"
progress_phase "writing CSV report..."
printf "%s\n" "${CSV_LINES[@]}" >"$REPORT_CSV"
if [[ ${#ALERTS[@]} -gt 0 ]]; then
  alerts_json=$(printf "%s\n" "${ALERTS[@]}" | jq -R . | jq -s .)
else
  alerts_json="[]"
fi
progress_phase "writing XLSX report..."
generate_xlsx_report "$REPORT_CSV" "$REPORT_XLSX" "$alerts_json"
progress_done "done | districts ${district_count_total} | facilities ${facilities_processed_total} | alerts ${#ALERTS[@]}"

shopt -u nocasematch

# # Send email alerts if any issues were detected during backup monitoring
# if [[ ${#ALERTS[@]} -gt 0 ]]; then
#   # Generate subject line with current date
#   subject_date=$(date "$ALERT_SUBJECT_DATE_FORMAT")
#   subject="Backup Monitoring Alert - ${subject_date}"
#
#   # Create temporary file to build email body
#   email_tmp=$(mktemp)
#   {
#     printf "Backup monitoring detected issues:\n\n"
#     # Include the full backup status table
#     printf "%s\n" "${TABLE_LINES[@]}"
#     printf "\nIssues:\n"
#     # List all detected issues/alerts
#     for alert in "${ALERTS[@]}"; do
#       printf " - %s\n" "$alert"
#     done
#   } >"$email_tmp"
#
#   # Read email body from temporary file and clean up
#   body=$(<"$email_tmp")
#   rm -f "$email_tmp"
#
#   # Function to send email using available mail command (mail or sendmail)
#   send_email() {
#     local subj=$1
#     local message=$2
#     # Try 'mail' command first (more common and simpler)
#     if command -v mail >/dev/null 2>&1; then
#       printf "%s\n" "$message" | mail -s "$subj" -r "$EMAIL_FROM" "$EMAIL_TO"
#       return $?
#     # Fall back to 'sendmail' if 'mail' is not available
#     elif command -v sendmail >/dev/null 2>&1; then
#       {
#         printf "From: %s\n" "$EMAIL_FROM"
#         printf "To: %s\n" "$EMAIL_TO"
#         printf "Subject: %s\n" "$subj"
#         printf "\n%s\n" "$message"
#       } | sendmail -t
#       return $?
#     else
#       printf "ERROR: Neither mail nor sendmail command is available for notifications.\n" >&2
#       return 1
#     fi
#   }
#
#   # Attempt to send the alert email and exit with error if it fails
#   if ! send_email "$subject" "$body"; then
#     printf "ERROR: Failed to send alert email.\n" >&2
#     exit 1
#   fi
# fi

exit "$EXIT_CODE"
