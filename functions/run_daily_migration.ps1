# Wrapper for the Windows Scheduled Task that resumes the sevakdb -> Firebase
# migration once a day. Safe to run even after the migration is fully done or
# if today's Firestore quota is already exhausted — batch_migrate_full.js
# reads _migration_checkpoint.json and no-ops/halts cleanly in both cases.
#
# Logging lives inside batch_migrate_full.js itself (migration_log.txt), so
# it's identical whether triggered by this scheduled task or run manually —
# this wrapper just marks that a run was scheduled-task-triggered.
$logPath = Join-Path $PSScriptRoot "migration_log.txt"
Add-Content -Path $logPath -Value "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] --- triggered by scheduled task ---"
Set-Location $PSScriptRoot
node batch_migrate_full.js
