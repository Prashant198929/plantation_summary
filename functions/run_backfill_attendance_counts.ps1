# Wrapper for the Windows Scheduled Task that runs the attendance-count
# backfill (functions/backfill_attendance_counts.js). Safe to run repeatedly —
# the script checkpoints progress in _backfill_attendance_counts_checkpoint.json
# and resumes cleanly whether it's mid-way through tallying months or already
# ready to diff Shree_Sadasya. Dry-run only (no --commit) so a scheduled fire
# never writes to Firestore unattended — commit is run manually once tallying
# is done and the diff has been reviewed.
$logPath = Join-Path $PSScriptRoot "backfill_attendance_counts_log.txt"
Add-Content -Path $logPath -Value "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] --- triggered by scheduled task ---"
Set-Location $PSScriptRoot
node backfill_attendance_counts.js *>> $logPath
