# ============================================================
# Practitioner Taxonomy Repair Orchestrator
# Stages corrections via the repair jar, then loads them to HRP via
# Generic_HRP_WS_Call against the practitioner_taxonomy_repair call type.
# Lives in Practitioner_Taxonomy_Repair/ alongside env.properties.
# Mirrors run_pipeline.ps1's structure (lock, transcript, env parse,
# DB check, two phases, summary).
# ============================================================

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidDefaultValueSwitchParameter', '',
    Justification = 'Deliberate. This tool writes remediation rows to cpe_repair and pushes SOAP amends to HRP, so the safe state must be the default one: a bare invocation stages nothing. -Execute is the explicit opt-in for a real run.')]
param(
    [string]$LogOutput = "both",
    [string]$NpiFile = "",
    [string]$Description = "",
    # ---- SAFETY KNOB 1 of 2: does this run write to the database? ----------
    # EDIT THIS DEFAULT to change modes. $true is safe, matching $HrpCallsLogMode below;
    # both knobs read the same way -- true means "don't do the dangerous thing".
    #   $true  -> stage nothing, never invoke the loader (THE DEFAULT)
    #   $false -> stage cpe_repair rows and invoke the loader
    [switch]$DryRun = $true,

    # CLI-only convenience alias for -DryRun:$false, for one-off real runs without
    # editing the file. Mirrors -LogOnlyOverride below: an alias, not a second axis.
    # Script-driven runs should leave this alone and set $DryRun instead.
    [switch]$Execute,
    [string]$RunId = "",         # Resume mode: skip the stage phase, re-invoke the loader against an existing run.
                                  # TVF filters status NOT IN ('loaded','skipped') so previously-loaded rows complete instantly.
    # CLI-only convenience alias for -HrpCallsLogMode 'true'. Mirrors -Execute above:
    # an alias that can only tighten, not a second axis. Kept for compatibility.
    [switch]$LogOnlyOverride,

    # ---- SAFETY KNOB 2 of 2: does this run call HRP? ----------------------
    # Second gate on HRP calls, on top of env.properties LOG_ONLY.
    # EDIT THIS DEFAULT to change modes. Reads the same way as $DryRun above:
    # $true is safe.
    #   $true  -> log-only: envelopes logged, HRP never called (THE DEFAULT)
    #   $false -> request live HRP calls
    #
    # Live amends require BOTH gates open: this default set to $false AND
    # LOG_ONLY=false in env.properties. Neither file alone can put traffic on the
    # wire. Setting this to $false while env.properties still says LOG_ONLY=true
    # ABORTS the run -- a half-finished switch to live fails loudly instead of
    # silently staying safe (which would look like a broken live run) or silently
    # going live (which would be far worse).
    [switch]$HrpCallsLogMode = $true
)

# ============================================================
# Dry-run is the DEFAULT. Staging real cpe_repair rows requires an explicit
# opt-in, so an accidental bare invocation can never write to the database.
#
# -Execute is the readable inverse; -DryRun:$false is the literal one. Passing
# both -Execute and an explicit -DryRun is contradictory, so fail loudly rather
# than silently picking one.
# ============================================================
$dryRunExplicit = $PSBoundParameters.ContainsKey('DryRun')
if ($Execute -and $dryRunExplicit -and $DryRun) {
    Write-Error "Contradictory parameters: -Execute requests a real run but -DryRun was also passed. Pass exactly one."
    exit 1
}
if ($Execute) { $DryRun = [switch]$false }

# Resume mode short-circuits the stage phase.
$RESUME_MODE = ($RunId -ne "")

# ============================================================
# Invocation record -- captured here at script scope, printed after the
# transcript opens further down.
#
# Start-Transcript runs INSIDE this script, so by the time it opens, the
# operator's command line has already scrolled past and is never captured.
# The transcript header's "Host Application" line reflects whatever launched
# the shell (often a stale ISE session), not this invocation. Without the
# echo below, a completed log gives no way to tell a -DryRun from a real
# staging run except by inferring it from downstream messages.
#
# Built from the EFFECTIVE parameter values, not $PSBoundParameters, because
# operators are expected to drive this script by editing the defaults in the
# param block above rather than by passing arguments. $PSBoundParameters would
# be empty in that workflow, so all three phases (dry-run / stage-only /
# live-send) would log an identical "no parameters" line -- exactly the
# ambiguity this record exists to remove. Effective values are truthful under
# both workflows; the trailing tag says which one produced them.
#
# Deliberately NOT $MyInvocation.Line: that returns the caller's ENTIRE command
# line, so an operator running `$env:SQLCMDPASSWORD='...'; .\run_repair.ps1`
# would write that secret straight into the transcript.
#
# Computed after the -Execute resolution above so $DryRun is already final.
# ============================================================
$effectiveParams = @()
if ($NpiFile)                { $effectiveParams += "-NpiFile '$NpiFile'" }
if ($Description)            { $effectiveParams += "-Description '$Description'" }
if ($RunId)                  { $effectiveParams += "-RunId '$RunId'" }
if ($Execute)                { $effectiveParams += "-Execute" }
if ($DryRun)                 { $effectiveParams += "-DryRun" }
if ($LogOnlyOverride)        { $effectiveParams += "-LogOnlyOverride" }
$effectiveParams += "-HrpCallsLogMode `$$($HrpCallsLogMode.ToString().ToLower())"
if ($LogOutput -ne "both")   { $effectiveParams += "-LogOutput '$LogOutput'" }

$INVOCATION_LINE = ".\$($MyInvocation.MyCommand.Name) $($effectiveParams -join ' ')".TrimEnd()
$INVOCATION_LINE += if ($PSBoundParameters.Count -gt 0) {
    "   [from command line]"
} else {
    "   [from script defaults -- no arguments passed]"
}

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
        "Invocation:   $INVOCATION_LINE",
        "Run ID:       $(if ($RUN_ID) { $RUN_ID } else { '(not assigned)' })"
    )
    if ($RESUME_MODE) {
        $lines += "Mode:         resume (stage skipped, loader-only retry)"
    }
    if ($DryRun) {
        $lines += "Mode:         dry-run (no DB writes; no loader call)"
    }

    # State the write footprint explicitly. -DryRun and LOG_ONLY are independent
    # flags that suppress different things, and reading a finished log should
    # never require inferring which one was in effect.
    # -not $RUN_ID is checked BEFORE $RESUME_MODE: a resume that aborts during validation
    # never reaches the loader, so claiming "status updates only" would overstate what happened.
    $lines += "DB writes:    $(
        if ($DryRun)          { 'NONE -- dry-run skipped all INSERTs' }
        elseif (-not $RUN_ID) { 'NONE -- run ended before any rows were written' }
        elseif ($RESUME_MODE) { 'cpe_repair status updates only (stage phase skipped)' }
        else                  { 'cpe_repair rows staged (repair_run + practitioner_repair + practitioner_taxonomy)' }
    )"
    $lines += "HRP calls:    $(
        if ($DryRun)                 { 'NONE -- dry-run; loader was not invoked' }
        elseif (-not $RUN_ID)        { 'NONE -- run ended before the loader was invoked' }
        elseif ($null -eq $LOG_ONLY) { '(undetermined -- LOG_ONLY was never parsed)' }
        elseif ($LOG_ONLY)           { 'NONE -- LOG_ONLY=true; envelopes logged, post-call SQL dry-run (rows stay pending)' }
        else                         { 'LIVE -- SOAP amends sent to HRP' }
    )"
    if ($LOG_ONLY_SOURCE -and -not $DryRun -and $RUN_ID) {
        $lines += "HRP decided by: $LOG_ONLY_SOURCE"
    }

    $lines += @(
        "Elapsed:      ${elapsed}s",
        "Log file:     $REPAIR_LOG",
        "Version:      $VERSION",
        ""
    )
    if ($ErrorMessage) { $lines += @("Error:", "  $ErrorMessage", "") }

    # Per-run counts from cpe_repair.practitioner_repair.
    if ($RUN_ID -and $DB_SERVER -and -not $DryRun) {
        try {
            $env:SQLCMDPASSWORD = $DB_PASSWORD
            $countsRaw = & $SQLCMD -S $DB_SERVER -d $DB_NAME -U $DB_USER -h -1 -W -s "|" -Q "SET NOCOUNT ON; SELECT status, COUNT(*) FROM cpe_repair.practitioner_repair WHERE run_id = $RUN_ID GROUP BY status ORDER BY status" 2>$null
            $env:SQLCMDPASSWORD = $null
            if ($countsRaw) {
                $lines += "Run $RUN_ID row counts by status:"
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
Write-Host "  Invocation:     $INVOCATION_LINE"

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
if ($RunId -and $RunId -notmatch '^\d+$') {
    $errors += "-RunId '$RunId' must be a positive integer"
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
# ============================================================
# Resolve HRP call mode. Two gates, and the SAFER one always wins:
#   gate 1 = env.properties LOG_ONLY   (the authority)
#   gate 2 = -HrpCallsLogMode          (this script; can only tighten)
#
# The script is deliberately incapable of enabling HRP calls. It can force
# log-only ON regardless of the config, but asking for live calls when the
# config says LOG_ONLY=true aborts the run instead of silently proceeding.
# Anything else would let a checked-in default quietly override the one file
# the operator treats as the authority on whether HRP gets touched.
# ============================================================
$LOG_ONLY_ENV = ($LOG_ONLY_VALUE.Trim().ToLower() -eq "true")

# Both gates must be open for HRP to be called. Disagreement is an error, never a
# silent resolution in either direction.
if (-not $HrpCallsLogMode -and $LOG_ONLY_ENV) {
    Remove-LockAndExit (
        "Refusing to run: the two HRP safety gates disagree." + [Environment]::NewLine +
        "  script  : `$HrpCallsLogMode = `$false  (requesting LIVE HRP calls)" + [Environment]::NewLine +
        "  config  : LOG_ONLY=true              (suppressing HRP calls)" + [Environment]::NewLine +
        [Environment]::NewLine +
        "Live HRP calls require BOTH gates open. To send live amends, set LOG_ONLY=false in " +
        $ENV_FILE + " as well. To stay in log-only mode, set `$HrpCallsLogMode = `$true in this script.")
}

# Log-only wins if either gate asks for it.
$LOG_ONLY = $HrpCallsLogMode -or $LOG_ONLY_ENV -or $LogOnlyOverride

# Record how the decision was reached -- the log should never leave this ambiguous.
$LOG_ONLY_SOURCE =
    if ($HrpCallsLogMode -and $LOG_ONLY_ENV) { "both gates: `$HrpCallsLogMode = `$true and env.properties LOG_ONLY=true" }
    elseif ($HrpCallsLogMode)                { "`$HrpCallsLogMode = `$true (env.properties said LOG_ONLY=false; script tightened it)" }
    elseif ($LogOnlyOverride)                { "-LogOnlyOverride (env.properties said LOG_ONLY=false; script tightened it)" }
    else                                     { "both gates open: `$HrpCallsLogMode = `$false and env.properties LOG_ONLY=false" }

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
$RUN_ID = $null

if ($DryRun) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  DRY-RUN MODE ACTIVE$(if (-not $dryRunExplicit) { '  (THE DEFAULT)' })" -ForegroundColor Yellow
    Write-Host "  - NOTHING will be written to cpe_repair" -ForegroundColor Yellow
    Write-Host "  - The loader will NOT be invoked; no run_id is assigned" -ForegroundColor Yellow
    Write-Host "  - The jar still calls NPPES and diffs against cpe_master," -ForegroundColor Yellow
    Write-Host "    so the staged/skipped counts below are accurate" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "  To perform a REAL run:  set `$DryRun = `$false in this script's param block" -ForegroundColor Yellow
    Write-Host "                          (or, one-off:  .\run_repair.ps1 -Execute $(if ($NpiFile) { "-NpiFile $NpiFile" }))" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
}
elseif ($LOG_ONLY) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  LOG-ONLY MODE ACTIVE" -ForegroundColor Yellow
    Write-Host "  - Decided by: $LOG_ONLY_SOURCE" -ForegroundColor Yellow
    Write-Host "  - Loader will be invoked with --LOG_ONLY=true" -ForegroundColor Yellow
    Write-Host "  - HRP receives no SOAP calls; envelopes are logged instead" -ForegroundColor Yellow
    Write-Host "  - cpe_repair rows still get inserted by the stage step" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  REAL RUN -- LOG_ONLY=false" -ForegroundColor Red
    Write-Host "  - Decided by: $LOG_ONLY_SOURCE" -ForegroundColor Red
    Write-Host "  - cpe_repair rows will be staged" -ForegroundColor Red
    Write-Host "  - LIVE SOAP amends will be sent to HRP" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
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

    # Run jar; capture stdout so we can parse RUN_ID, while also tee'ing it
    # to the host so the operator sees progress + the transcript captures it.
    $jarOutput = & java @jarArgs 2>&1
    $jarExit = $LASTEXITCODE
    foreach ($line in $jarOutput) { Write-Host $line }

    if ($jarExit -ne 0) {
        Remove-LockAndExit "Repair jar exited $jarExit. See log for details: $REPAIR_LOG"
    }

    if ($DryRun) {
        Write-Step "DRY-RUN COMPLETE (no run created; no loader call)"
        Write-RunSummary -Status "DRY-RUN"
        Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
        try { Stop-Transcript | Out-Null } catch {}
        exit 0
    }

    # Parse RUN_ID=<n> line from jar stdout
    $runLine = $jarOutput | Where-Object { $_ -match '^RUN_ID=\d+$' } | Select-Object -First 1
    if (-not $runLine) {
        # Could be the "nothing to persist" case (every NPI already matches NPPES).
        # Jar exits 0 in that case without printing RUN_ID. Treat as success-no-op.
        Write-Step "STAGING COMPLETE (no run created -- nothing to amend)"
        Write-Host "  Repair jar found no work to stage. See log for the decision summary line." -ForegroundColor Yellow
        Write-RunSummary -Status "NO-OP"
        Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
        try { Stop-Transcript | Out-Null } catch {}
        exit 0
    }
    $RUN_ID = ($runLine -replace '^RUN_ID=', '').Trim()
    Write-Host ""
    Write-Host "Captured RUN_ID: $RUN_ID" -ForegroundColor Green

} else {
    # Resume: use the provided run_id, skip the stage phase
    $RUN_ID = $RunId
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RESUME MODE: Re-invoking loader for run_id=$RUN_ID" -ForegroundColor Cyan
    Write-Host "  Skipping STEP 2 (stage phase)" -ForegroundColor Cyan
    Write-Host "  TVF filter (status NOT IN 'loaded','skipped') means already-loaded" -ForegroundColor Cyan
    Write-Host "  and already-skipped rows are picked up only if pending/failed." -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # Sanity-check the run exists.
    try {
        $env:SQLCMDPASSWORD = $DB_PASSWORD
        $runCheck = & $SQLCMD -S $DB_SERVER -d $DB_NAME -U $DB_USER -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM cpe_repair.repair_run WHERE run_id = $RUN_ID" 2>$null
        $env:SQLCMDPASSWORD = $null
        if (-not $runCheck -or ([int](($runCheck | Select-Object -First 1).Trim()) -eq 0)) {
            Remove-LockAndExit "Run $RUN_ID not found in cpe_repair.repair_run. Cannot resume."
        }
    } catch {
        $env:SQLCMDPASSWORD = $null
        Remove-LockAndExit "Could not verify run $RUN_ID exists: $_"
    }
}

# ============================================================
# Dry-run stop for RESUME mode.
#
# The non-resume dry-run exit lives inside the STEP 2 block above, which resume
# skips entirely. Without this guard, `.\run_repair.ps1 -RunId 7` would inherit
# the dry-run default and then fall straight through to a LIVE loader call --
# the exact opposite of what the operator asked for. Resume re-sends real SOAP
# amends, so it requires the same explicit opt-in as any other real run.
# ============================================================
if ($RESUME_MODE -and $DryRun) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  DRY-RUN: stopping before the loader" -ForegroundColor Yellow
    Write-Host "  Run $RUN_ID exists and is resumable, but resuming re-sends" -ForegroundColor Yellow
    Write-Host "  real SOAP amends for its pending/failed rows." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "  To actually resume:  .\run_repair.ps1 -RunId $RUN_ID -Execute" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-RunSummary -Status "DRY-RUN"
    Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

# ============================================================
# STEP 3: Invoke loader (Generic_HRP_WS_Call) against the new call type
# ============================================================
Write-Step "STEP 3: Loading practitioner_taxonomy_repair (run_id=$RUN_ID)"

# Build loader args. --LOG_ONLY=true is honored when env says LOG_ONLY=true OR -LogOnlyOverride passed.
$loaderArgs = @("-jar", $WS_JAR, $CALL_DIR, "--RUN_ID=$RUN_ID", "--log-output=$LogOutput", "--env-file=$ENV_FILE")
if ($LOG_ONLY) { $loaderArgs += "--LOG_ONLY=true" }

& java @loaderArgs 2>&1 | Out-Host
$loaderExit = $LASTEXITCODE

if ($loaderExit -ne 0) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  FATAL: loader returned exit code $loaderExit" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  To resume after fixing the issue:" -ForegroundColor Yellow
    Write-Host "    .\run_repair.ps1 -RunId $RUN_ID" -ForegroundColor Yellow
    Write-Host "  TVF filter skips already-loaded rows; only pending/failed retry." -ForegroundColor Yellow
    Remove-LockAndExit "Loader failed for run_id=$RUN_ID (exit $loaderExit)"
}

Write-Step "REPAIR COMPLETE (run_id=$RUN_ID)"

# Finalize the run: aggregate practitioner_repair statuses into repair_run.status
# (completed / partial / failed / pending). Best-effort -- a failure here doesn't
# fail the overall run.
try {
    $env:SQLCMDPASSWORD = $DB_PASSWORD
    & $SQLCMD -b -S $DB_SERVER -d $DB_NAME -U $DB_USER -h -1 -Q "EXEC cpe_repair.sp_finalize_repair_run @run_id = $RUN_ID" 2>&1 | Out-Host
    $env:SQLCMDPASSWORD = $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  repair_run.status finalized" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: sp_finalize_repair_run returned $LASTEXITCODE -- repair_run.status may stay 'pending'" -ForegroundColor Yellow
    }
} catch {
    $env:SQLCMDPASSWORD = $null
    Write-Host "  WARNING: could not finalize repair_run: $_" -ForegroundColor Yellow
}

if ($LOG_ONLY) {
    Write-Host ""
    Write-Host "LOG-ONLY MODE REMINDER:" -ForegroundColor Yellow
    Write-Host "  - No SOAP calls were made to HRP for run $RUN_ID" -ForegroundColor Yellow
    Write-Host "  - cpe_repair rows for this run may still show pending depending on the call's post-call SQL" -ForegroundColor Yellow
    Write-Host "  - To re-run for real: set LOG_ONLY=false in env.properties, then:" -ForegroundColor Yellow
    Write-Host "      .\run_repair.ps1 -RunId $RUN_ID" -ForegroundColor Yellow
}

# ============================================================
# Verify the live run actually delivered.
#
# The loader exits 0 even when every record failed: if the web-service call
# throws (endpoint down, DNS, TLS, connection refused), Generic_HRP_WS_Call
# logs SEVERE and swallows the exception, and because its post-call SQL runs
# INSIDE that same try block, no error is recorded either. Rows are left
# 'pending' with a NULL error_message and the process returns 0.
#
# Without this check a total HRP outage reports "Status: SUCCESS". We cannot
# fix the loader (this project does not modify sibling projects), so verify
# the outcome from the database instead: after a LIVE run, every row the TVF
# would have sent should have moved off 'pending'.
#
# Only meaningful for a live run -- in log-only mode rows are SUPPOSED to
# stay pending, since the post-call SQL is deliberately dry-run.
# ============================================================
$UNDELIVERED = 0
if (-not $LOG_ONLY) {
    try {
        $env:SQLCMDPASSWORD = $DB_PASSWORD
        $raw = & $SQLCMD -b -S $DB_SERVER -d $DB_NAME -U $DB_USER -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM cpe_repair.practitioner_repair WHERE run_id = $RUN_ID AND status IN ('pending','failed')" 2>$null
        $env:SQLCMDPASSWORD = $null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $parsed = 0
            if ([int]::TryParse((($raw | Select-Object -First 1) -as [string]).Trim(), [ref]$parsed)) { $UNDELIVERED = $parsed }
        }
    } catch {
        $env:SQLCMDPASSWORD = $null
        Write-Host "  WARNING: could not verify delivery for run $RUN_ID : $_" -ForegroundColor Yellow
    }
}

if ($UNDELIVERED -gt 0) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  LOADER REPORTED SUCCESS BUT $UNDELIVERED ROW(S) WERE NOT DELIVERED" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  Run $RUN_ID still has $UNDELIVERED row(s) in pending/failed after a LIVE run." -ForegroundColor Red
    Write-Host "  The loader exits 0 even when every SOAP call fails (endpoint down," -ForegroundColor Red
    Write-Host "  refused, TLS, DNS), so treat its exit code as unreliable here." -ForegroundColor Red
    Write-Host "  Check the STEP 3 output above for 'error:' / 'failed' lines." -ForegroundColor Red
    Write-Host ""
    Write-Host "  To retry after fixing the cause:" -ForegroundColor Yellow
    Write-Host "    .\run_repair.ps1 -RunId $RUN_ID -Execute" -ForegroundColor Yellow
    Write-Host "  Already-loaded rows are skipped by the TVF, so only these retry." -ForegroundColor Yellow
    Write-RunSummary -Status "FAILED -- $UNDELIVERED row(s) undelivered"
    Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

Write-RunSummary -Status "SUCCESS"
Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
try { Stop-Transcript | Out-Null } catch {}
