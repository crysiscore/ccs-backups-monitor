# Backups Monitor

Shell script for monitoring OpenMRS backup snapshots stored in OneDrive (or any rclone-accessible remote). The script enumerates districts and health facilities, reports the most recent backup per facility based on file creation/upload time, and saves the results to text/CSV reports.

## Requirements

- Bash 4+
- [`rclone`](https://rclone.org/) configured with access to the target remote path
- [`jq`](https://jqlang.org/) for parsing metadata returned by `rclone lsjson`
- Python 3
- [`openpyxl`](https://pypi.org/project/openpyxl/) for generating the formatted `.xlsx` report
- GNU `date`
  - Linux: provided by `coreutils`
  - macOS: install `gdate` via `brew install coreutils`
- `mail` or `sendmail` command for email notifications (optional but recommended)

## Installing dependencies

### macOS

```bash
brew install rclone jq coreutils python3
python3 -m pip install openpyxl
```

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y rclone jq python3 python3-pip coreutils mailutils
python3 -m pip install openpyxl
```

After installation, configure the rclone remote used by the script:

```bash
rclone config
rclone lsd hisbackups:
```

## Configuration

Update the variables at the top of `backup_monitor.sh` to match your environment:

- `--province`: required runtime argument (`Gaza` or `Maputo`) used to build the remote path dynamically:
  - `hisbackups:/Gaza/openmrs_backups`
  - `hisbackups:/Maputo/openmrs_backups`
- `maputo_us_mapping.csv`: Maputo-only mapping file (`onedrive_name -> canonical_us_name + district`)
- `AGE_THRESHOLD_DAYS`: status and alert threshold (in days) for the latest backup age (`>= 9` is outdated by default)
- `EMAIL_FROM` / `EMAIL_TO`: sender and recipient addresses used when alerts are emailed
- `REPORT_TXT` / `REPORT_CSV` / `REPORT_XLSX`: filenames for the generated reports

The script automatically selects GNU `date` or `gdate` depending on the OS, exiting with guidance if neither is available.

## How backup age is calculated

For each backup file (`.zip`, `.rar`, `.sql`, `.7z`) the script reads metadata from OneDrive using:

- `rclone lsjson --files-only --metadata`

It then chooses an effective timestamp using:

- `Metadata.btime` (creation/upload time) as primary source
- `ModTime` as fallback when `btime` is not available

The most recent backup is selected by the largest effective timestamp, and report dates are shown in UTC (`YYYY-MM-DD HH:MM:SS UTC`).

## Maputo mapping

For `--province Maputo`, unit folders are read directly from `hisbackups:/Maputo/openmrs_backups` and mapped with `maputo_us_mapping.csv`.

- `District` comes from the mapping file
- `Health Facility` uses `canonical_us_name` from the mapping file
- If a OneDrive folder is not mapped, the report shows `District=UNMAPPED`, adds an alert, lists unmapped names at the end, and exits with code `1`

## File size column

All outputs include a `File Size` column immediately after `File name`.

- Size uses binary units: `B`, `KiB`, `MiB`, `GiB`, `TiB`
- Rows without a valid backup use `N/A`

## Backup status rule

Each row includes a `Backup Status` column:

- `Actualizado` when backup age is less than 9 days
- `Desactualizado` when backup age is equal to or greater than 9 days

Rows without valid backup files or without parseable backup dates are marked as `Desactualizado`.

## Running

```bash
chmod +x backup_monitor.sh
./backup_monitor.sh --province Gaza
./backup_monitor.sh --province Maputo
```

### Progress output

During execution, the script shows progress messages on `stderr` (not `stdout`).

- `stdout` remains reserved for the final table output
- This keeps redirection safe while still showing progress in the terminal

Example:

```bash
./backup_monitor.sh --province Gaza > backup_monitor_table.txt
```

The progress remains visible in the terminal, while `backup_monitor_table.txt` receives only the final table.

On completion the script:

- Prints a table of the latest backup per facility to the terminal
- Writes the table to `backup_monitor_report.txt`
- Writes a CSV version to `backup_monitor_report.csv`
- Writes a formatted Excel workbook to `backup_monitor_report.xlsx`
- `Backup Report` sheet includes styled header, filters, and frozen top row
- `Backup Report` includes `File Size` after `File name`
- Rows with `Backup Status = Desactualizado` are highlighted in yellow in `Backup Report`
- `Issues` sheet includes detected issues/alerts (or "No issues detected")

## Alerts

If no backups are found, backups cannot be listed, or a backup is older than `AGE_THRESHOLD_DAYS`, a summary email is sent using `mail` or `sendmail`. The email body includes the table output plus a bullet list of detected issues.

## Scheduling

Run the script manually or schedule it (e.g. via `cron`) to perform regular checks:

```cron
0 6 * * * /path/to/backup_monitor.sh >> /path/to/backup_monitor.log 2>&1
```

Ensure the environment used by the scheduler has the necessary PATH entries for `rclone`, `gdate`, and mail utilities.
