# ============================================================
# Practitioner Taxonomy Repair Orchestrator
# Stages corrections via the repair jar, then loads them to HRP via
# Generic_HRP_WS_Call against the practitioner_taxonomy_repair call type.
# Lives in Practitioner_Taxonomy_Repair/ alongside env.properties.
# Mirrors run_pipeline.ps1's structure (lock, transcript, env parse,
# DB check, two phases, summary).
# ============================================================

param(
    [string]$LogOutput = "both",
    [string]$NpiFile = "",
    [string]$Description = "",
    [switch]$DryRun,
    [string]$BatchId = "",       # Resume mode: skip the stage phase, re-invoke the loader against an existing batch.
                                  # TVF filters status NOT IN ('loaded','skipped') so previously-loaded rows complete instantly.
    [switch]$LogOnlyOverride     # Override env.properties LOG_ONLY=false for one run. The loader's --LOG_ONLY=true wins regardless.
)

# Resume mode short-circuits the stage phase.
$RESUME_MODE = ($BatchId -ne "")

# ============================================================
# Directory configuration (all paths relative to script location)
# ============================================================
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $SCRIPT_DIR

# Sibling folder (existing pipeline install)
$LOADER_DIR = "..\Claim_Provider_Data_Loader"

# Jars
$REPAIR_JAR_CANDIDATES = @(Get-ChildItem -Path $SCRIPT_DIR -Filter "practitioner-taxonomy-repair-*-jar-with-dependencies.jar" -ErrorAction SilentlyContinue)
$REPAIR_JAR = if ($REPAIR_JAR_CANDIDATES.Count -gt 0) { $REPAIR_JAR_CANDIDATES[0].FullName } else { $null }
$WS_JAR     = "$LOADER_DIR\generic-hrp-ws-call.jar"

# Call folder for THIS call type (installed by install.ps1 into the loader sibling)
$CALL_DIR = "$LOADER_DIR\practitioner_taxonomy_repair"

# env.properties lives next to this script (absolute path for passing to the loader)
$ENV_FILE = "$SCRIPT_DIR\env.properties"

# Database tool (substituted at install time by install.ps1 from install.config SQLCMD_PATH)
$SQLCMD = "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe"

# ============================================================
# Helper functions
# ============================================================
function Write-Step {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host ""
    Write-Host "[$timestamp] === $Message ===" -ForegroundColor Cyan
}

function Remove-LockAndExit {
    param([string]$Message, [int]$Code = 1)
    Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
    if ($Message) { Write-Error $Message }
    try { Write-RunSummary -Status "FAILED" -ErrorMessage $Message } catch {}
    try { Stop-Transcript | Out-Null } catch {}
    exit $Code
}

function Get-RunSummaryLines {
    param([string]$Status, [string]$ErrorMessage)
    $elapsed = if ($REPAIR_START) { [int]((Get-Date) - $REPAIR_START).TotalSeconds } else { 0 }
    $lines = @(
        "Status:       $Status",
        "Batch ID:     $(if ($BATCH_ID) { $BATCH_ID } else { '(not assigned)' })"
    )
    if ($RESUME_MODE) {
        $lines += "Mode:         resume (stage skipped, loader-only retry)"
    }
    if ($DryRun) {
        $lines += "Mode:         dry-run (no DB writes; no loader call)"
    }
    $lines += @(
        "Elapsed:      ${elapsed}s",
        "Log file:     $REPAIR_LOG",
        "Version:      $VERSION",
        ""
    )
    if ($ErrorMessage) { $lines += @("Error:", "  $ErrorMessage", "") }

    # Per-batch counts from cpe_repair.practitioner_repair.
    if ($BATCH_ID -and $DB_SERVER -and -not $DryRun) {
        try {
            $env:SQLCMDPASSWORD = $DB_PASSWORD
            $countsRaw = & $SQLCMD -S $DB_SERVER -d $DB_NAME -U $DB_USER -h -1 -W -s "|" -Q "SET NOCOUNT ON; SELECT status, COUNT(*) FROM cpe_repair.practitioner_repair WHERE batch_id = $BATCH_ID GROUP BY status ORDER BY status" 2>$null
            $env:SQLCMDPASSWORD = $null
            if ($countsRaw) {
                $lines += "Batch $BATCH_ID row counts by status:"
                foreach ($line in $countsRaw) {
                    $p = $line.Trim() -split '\|'
                    if ($p.Count -eq 2 -and $p[0].Trim() -ne '') {
                        $lines += ("  {0,-10}  {1}" -f $p[0].Trim(), $p[1].Trim())
                    }
                }
                $lines += ""
            }
        } catch { $env:SQLCMDPASSWORD = $null }
    }

    return $lines
}

function Write-RunSummary {
    param([string]$Status, [string]$ErrorMessage)
    $lines = Get-RunSummaryLines -Status $Status -ErrorMessage $ErrorMessage
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RUN SUMMARY" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    foreach ($l in $lines) { Write-Host $l }
}

# ============================================================
# Move stale generated files (logs, lock files) into ./logs/ at startup
# so today's freshly-written log stands alone. Matches pipeline pattern.
# ============================================================
function Move-StaleFilesToLogs {
    param(
        [Parameter(Mandatory)] [string]  $SourceDir,
        [Parameter(Mandatory)] [string[]]$Patterns
    )
    if (-not (Test-Path $SourceDir)) { return }
    $logsDir = Join-Path $SourceDir "logs"
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    foreach ($pattern in $Patterns) {
        Get-ChildItem -Path $SourceDir -Filter $pattern -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                try { Move-Item -Path $_.FullName -Destination $logsDir -Force }
                catch { Write-Host "  WARNING: could not archive $($_.Name) to $logsDir : $_" -ForegroundColor Yellow }
            }
    }
}

# ============================================================
# Read version (informational only)
# ============================================================
$VERSION = "unknown"
if (Test-Path "version.txt") {
    foreach ($line in Get-Content "version.txt") {
        if ($line -match '^VERSION=(.+)$') { $VERSION = $Matches[1].Trim(); break }
    }
}

# ============================================================
# Concurrency lock -- prevent two repair runs from overlapping
# ============================================================
$LOCK_FILE = "$SCRIPT_DIR\repair.lock"
if (Test-Path $LOCK_FILE) {
    $lockContent = Get-Content $LOCK_FILE -Raw
    Write-Error "Another repair run is already in progress (lock file exists: $LOCK_FILE). Contents: $lockContent"
    exit 1
}
$lockInfo = "PID=$PID Started=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Set-Content -Path $LOCK_FILE -Value $lockInfo

# ============================================================
# Transcript -- capture everything shown in the console.
# Archive prior repair_*.log and PractitionerTaxonomyRepair.*.log into ./logs/
# so today's logs stand alone. *.properties / *.config never moved.
# ============================================================
Move-StaleFilesToLogs -SourceDir $SCRIPT_DIR -Patterns @("repair_*.log", "PractitionerTaxonomyRepair.*.log*")

$REPAIR_LOG = "$SCRIPT_DIR\repair_$(Get-Date -Format 'yyyyMMddHHmmss').log"
try { Start-Transcript -Path $REPAIR_LOG -Force | Out-Null } catch {}

# ============================================================
# Step 1: Validate prerequisites
# ============================================================
Write-Step "STEP 1: Validating prerequisites"
Write-Host "  Repair version: $VERSION"

$errors = @()

if (-not $REPAIR_JAR) {
    $errors += "Repair jar not found: $SCRIPT_DIR\practitioner-taxonomy-repair-*-jar-with-dependencies.jar"
}
if (-not (Test-Path $WS_JAR)) {
    $errors += "Loader jar not found: $WS_JAR (this script expects ..\Claim_Provider_Data_Loader\generic-hrp-ws-call.jar)"
}
if (-not (Test-Path $ENV_FILE)) {
    $errors += "env.properties not found: $ENV_FILE"
}
if (-not (Test-Path $CALL_DIR)) {
    $errors += "Call folder not found: $CALL_DIR (run install.ps1 to install it)"
}
if ($NpiFile -and -not (Test-Path $NpiFile)) {
    $errors += "-NpiFile '$NpiFile' does not exist"
}
if ($BatchId -and $BatchId -notmatch '^\d+$') {
    $errors += "-BatchId '$BatchId' must be a positive integer"
}

# Functional sqlcmd check
Write-Host "  Verifying sqlcmd (this may take a few seconds)..."
try {
    & $SQLCMD -? 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $errors += "sqlcmd at '$SQLCMD' returned exit code $LASTEXITCODE" }
} catch {
    $errors += "sqlcmd not found or not executable: $SQLCMD"
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Host "  ERROR: $e" -ForegroundColor Red }
    Remove-LockAndExit "Prerequisites check failed with $($errors.Count) error(s)"
}
Write-Host "  All prerequisites OK" -ForegroundColor Green

# ============================================================
# Parse env.properties
# ============================================================
$envProps = @{}
Get-Content $ENV_FILE | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $key = $line.Substring(0, $line.IndexOf("="))
        $value = $line.Substring($line.IndexOf("=") + 1)
        $envProps[$key] = $value
    }
}

$DB_URL = $envProps["DB_URL"]
if ($DB_URL -match 'jdbc:sqlserver://([^;]+);databaseName=([^;]+)') {
    # sqlcmd uses comma for port, JDBC uses colon
    $DB_SERVER = $Matches[1] -replace ':', ','
    $DB_NAME = $Matches[2]
} else {
    Remove-LockAndExit "Could not parse DB_URL from env.properties: $DB_URL"
}
$DB_USER     = $envProps["DB_USER"]
$DB_PASSWORD = $envProps["DB_PASSWORD"]

$LOG_ONLY_VALUE = $envProps["LOG_ONLY"]
if (-not $LOG_ONLY_VALUE) {
    Remove-LockAndExit "LOG_ONLY is not defined in env.properties. It must be set to true or false."
}
$LOG_ONLY = ($LOG_ONLY_VALUE.Trim().ToLower() -eq "true") -or $LogOnlyOverride

# ============================================================
# Verify database connectivity NOW, before any work begins.
# ============================================================
Write-Host "  Verifying database connection..."
try {
    $env:SQLCMDPASSWORD = $DB_PASSWORD
    $dbCheckOutput = & $SQLCMD -b -S $DB_SERVER -d $DB_NAME -U $DB_USER -h -1 -Q "SET NOCOUNT ON; SELECT 1" 2>&1
    $dbCheckExit = $LASTEXITCODE
    $env:SQLCMDPASSWORD = $null
    if ($dbCheckExit -ne 0) {
        $errMsg = ($dbCheckOutput | Out-String).Trim()
        $hint = ""
        if ($errMsg -match "(?i)expired")                { $hint = " (PASSWORD APPEARS TO BE EXPIRED -- rotate DB_PASSWORD on the SQL Server, then update env.properties)" }
        elseif ($errMsg -match "(?i)Login failed")        { $hint = " (login failed -- check DB_USER / DB_PASSWORD in env.properties)" }
        elseif ($errMsg -match "(?i)could not open a connection|TCP Provider|server was not found") { $hint = " (server unreachable -- check DB_URL and SQL Server network access)" }
        elseif ($errMsg -match "(?i)Cannot open database") { $hint = " (database name from DB_URL not found on this server -- check DB_URL)" }
        Remove-LockAndExit ("Database connection failed{0}. sqlcmd output: {1}" -f $hint, $errMsg)
    }
    Write-Host "  Database connection OK" -ForegroundColor Green
} catch {
    $env:SQLCMDPASSWORD = $null
    Remove-LockAndExit "Database connection check threw exception: $_"
}

$REPAIR_START = Get-Date
$BATCH_ID = $null

if ($LOG_ONLY) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  LOG-ONLY MODE ACTIVE" -ForegroundColor Yellow
    Write-Host "  - Loader will be invoked with --LOG_ONLY=true" -ForegroundColor Yellow
    Write-Host "  - HRP receives no SOAP calls; envelopes are logged instead" -ForegroundColor Yellow
    Write-Host "  - cpe_repair rows still get inserted by the stage step" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
}

# ============================================================
# STEP 2: Stage corrections (skipped in resume mode)
# ============================================================
if (-not $RESUME_MODE) {

    Write-Step "STEP 2: Staging corrections (java -jar $(Split-Path -Leaf $REPAIR_JAR))"

    # Build jar args
    $jarArgs = @("-jar", $REPAIR_JAR, "--log-output=$LogOutput")
    if ($NpiFile)     { $jarArgs += "--npi-file=$NpiFile" }
    if ($Description) { $jarArgs += "--description=$Description" }
    if ($DryRun)      { $jarArgs += "--dry-run" }

    # Run jar; capture stdout so we can parse BATCH_ID, while also tee'ing it
    # to the host so the operator sees progress + the transcript captures it.
    $jarOutput = & java @jarArgs 2>&1
    $jarExit = $LASTEXITCODE
    foreach ($line in $jarOutput) { Write-Host $line }

    if ($jarExit -ne 0) {
        Remove-LockAndExit "Repair jar exited $jarExit. See log for details: $REPAIR_LOG"
    }

    if ($DryRun) {
        Write-Step "DRY-RUN COMPLETE (no batch created; no loader call)"
        Write-RunSummary -Status "DRY-RUN"
        Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
        try { Stop-Transcript | Out-Null } catch {}
        exit 0
    }

    # Parse BATCH_ID=<n> line from jar stdout
    $batchLine = $jarOutput | Where-Object { $_ -match '^BATCH_ID=\d+$' } | Select-Object -First 1
    if (-not $batchLine) {
        # Could be the "nothing to persist" case (everything would-be-skipped already match).
        # Jar exits 0 in that case without printing BATCH_ID. Treat as success-no-op.
        Write-Step "STAGING COMPLETE (no batch created -- nothing to amend)"
        Write-Host "  Repair jar found no work to stage. See log for the decision summary line." -ForegroundColor Yellow
        Write-RunSummary -Status "NO-OP"
        Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
        try { Stop-Transcript | Out-Null } catch {}
        exit 0
    }
    $BATCH_ID = ($batchLine -replace '^BATCH_ID=', '').Trim()
    Write-Host ""
    Write-Host "Captured BATCH_ID: $BATCH_ID" -ForegroundColor Green

} else {
    # Resume: use the provided batch_id, skip the stage phase
    $BATCH_ID = $BatchId
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RESUME MODE: Re-invoking loader for batch_id=$BATCH_ID" -ForegroundColor Cyan
    Write-Host "  Skipping STEP 2 (stage phase)" -ForegroundColor Cyan
    Write-Host "  TVF filter (status NOT IN 'loaded','skipped') means already-loaded" -ForegroundColor Cyan
    Write-Host "  and already-skipped rows are picked up only if pending/failed." -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # Sanity-check the batch exists.
    try {
        $env:SQLCMDPASSWORD = $DB_PASSWORD
        $batchCheck = & $SQLCMD -S $DB_SERVER -d $DB_NAME -U $DB_USER -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM cpe_repair.batch WHERE batch_id = $BATCH_ID" 2>$null
        $env:SQLCMDPASSWORD = $null
        if (-not $batchCheck -or ([int](($batchCheck | Select-Object -First 1).Trim()) -eq 0)) {
            Remove-LockAndExit "Batch $BATCH_ID not found in cpe_repair.batch. Cannot resume."
        }
    } catch {
        $env:SQLCMDPASSWORD = $null
        Remove-LockAndExit "Could not verify batch $BATCH_ID exists: $_"
    }
}

# ============================================================
# STEP 3: Invoke loader (Generic_HRP_WS_Call) against the new call type
# ============================================================
Write-Step "STEP 3: Loading practitioner_taxonomy_repair (batch_id=$BATCH_ID)"

# Build loader args. --LOG_ONLY=true is honored when env says LOG_ONLY=true OR -LogOnlyOverride passed.
$loaderArgs = @("-jar", $WS_JAR, $CALL_DIR, "--RUN_ID=$BATCH_ID", "--log-output=$LogOutput", "--env-file=$ENV_FILE")
if ($LogOnlyOverride) { $loaderArgs += "--LOG_ONLY=true" }

& java @loaderArgs 2>&1 | Out-Host
$loaderExit = $LASTEXITCODE

if ($loaderExit -ne 0) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  FATAL: loader returned exit code $loaderExit" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  To resume after fixing the issue:" -ForegroundColor Yellow
    Write-Host "    .\run_repair.ps1 -BatchId $BATCH_ID" -ForegroundColor Yellow
    Write-Host "  TVF filter skips already-loaded rows; only pending/failed retry." -ForegroundColor Yellow
    Remove-LockAndExit "Loader failed for batch_id=$BATCH_ID (exit $loaderExit)"
}

Write-Step "REPAIR COMPLETE (batch_id=$BATCH_ID)"

if ($LOG_ONLY) {
    Write-Host ""
    Write-Host "LOG-ONLY MODE REMINDER:" -ForegroundColor Yellow
    Write-Host "  - No SOAP calls were made to HRP for batch $BATCH_ID" -ForegroundColor Yellow
    Write-Host "  - cpe_repair rows for this batch may still show pending depending on the call's post-call SQL" -ForegroundColor Yellow
    Write-Host "  - To re-run for real: set LOG_ONLY=false in env.properties, then:" -ForegroundColor Yellow
    Write-Host "      .\run_repair.ps1 -BatchId $BATCH_ID" -ForegroundColor Yellow
}

Write-RunSummary -Status "SUCCESS"
Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
try { Stop-Transcript | Out-Null } catch {}
