# Backups Monitor

Shell script for monitoring OpenMRS backup snapshots stored in OneDrive (or any rclone-accessible remote). The script enumerates districts and health facilities, reports the most recent backup per facility, saves the results to text/CSV reports, and emails alerts when issues are detected.

## Requirements

- Bash 4+
- [`rclone`](https://rclone.org/) configured with access to the target remote path
- GNU `date`
  - Linux: provided by `coreutils`
  - macOS: install `gdate` via `brew install coreutils`
- `mail` or `sendmail` command for email notifications (optional but recommended)

## Configuration

Update the variables at the top of `backup_monitor.sh` to match your environment:

- `REMOTE_PATH`: rclone remote and path to the backup root (e.g. `hisbackups:/Gaza/openmrs_backups`)
- `AGE_THRESHOLD_DAYS`: maximum acceptable age (in days) for the latest backup before an alert is raised
- `EMAIL_FROM` / `EMAIL_TO`: sender and recipient addresses used when alerts are emailed
- `REPORT_TXT` / `REPORT_CSV`: filenames for the generated reports

The script automatically selects GNU `date` or `gdate` depending on the OS, exiting with guidance if neither is available.

## Running

```bash
chmod +x backup_monitor.sh
./backup_monitor.sh
```

On completion the script:

- Prints a table of the latest backup per facility to the terminal
- Writes the table to `backup_monitor_report.txt`
- Writes a CSV version to `backup_monitor_report.csv`

## Alerts

If no backups are found, backups cannot be listed, or a backup is older than `AGE_THRESHOLD_DAYS`, a summary email is sent using `mail` or `sendmail`. The email body includes the table output plus a bullet list of detected issues.

## Scheduling

Run the script manually or schedule it (e.g. via `cron`) to perform regular checks:

```cron
0 6 * * * /path/to/backup_monitor.sh >> /path/to/backup_monitor.log 2>&1
```

Ensure the environment used by the scheduler has the necessary PATH entries for `rclone`, `gdate`, and mail utilities.
