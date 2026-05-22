# ============================================================
# Practitioner Taxonomy Repair -- Installer
# Creates the Practitioner_Taxonomy_Repair sibling folder alongside the
# existing Claim_Provider_Data_Extractor / Claim_Provider_Data_Loader,
# deploys components, generates env.properties + PractitionerTaxonomyRepair.properties
# from install.config, copies the call folder into the loader, optionally applies DDL.
# Mirrors the install pattern from Claim_Provider_Data_Pipeline.
# ============================================================

$ErrorActionPreference = "Stop"
$INSTALL_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================
# Read install.config
# ============================================================
$configFile = Join-Path $INSTALL_DIR "install.config"
if (-not (Test-Path $configFile)) {
    Write-Error "install.config not found. It should be in the same folder as install.ps1."
    exit 1
}

$config = @{}
Get-Content $configFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $key = $line.Substring(0, $line.IndexOf("="))
        $value = $line.Substring($line.IndexOf("=") + 1)
        $config[$key] = $value
    }
}

# Validate required fields
$required = @("DB_URL", "DB_USER", "DB_PASSWORD", "WS_BASE_URL", "CONNECTOR_ADMIN_PASSWORD",
              "LOG_ONLY", "WS_RETRY_COUNT", "WS_RETRY_HTTP_CODES", "WS_RETRY_BACKOFF_MS",
              "WS_RETRY_MAX_BACKOFF_MS", "SQLCMD_PATH")
$missing = @()
foreach ($key in $required) {
    if (-not $config[$key] -or $config[$key].Trim() -eq "") { $missing += $key }
}
if ($missing.Count -gt 0) {
    Write-Error "Missing required values in install.config: $($missing -join ', ')"
    exit 1
}

# LOG_ONLY must be true/false
$logOnlyValue = $config["LOG_ONLY"].Trim().ToLower()
if ($logOnlyValue -ne "true" -and $logOnlyValue -ne "false") {
    Write-Error "LOG_ONLY in install.config must be 'true' or 'false', got: $($config['LOG_ONLY'])"
    exit 1
}

# Retry integers
foreach ($k in @("WS_RETRY_COUNT", "WS_RETRY_BACKOFF_MS", "WS_RETRY_MAX_BACKOFF_MS")) {
    $v = $config[$k].Trim()
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n) -or $n -lt 0) {
        Write-Error "$k must be a non-negative integer, got: $v"
        exit 1
    }
}
foreach ($tok in ($config["WS_RETRY_HTTP_CODES"] -split ",")) {
    $t = $tok.Trim()
    if ($t -eq "") { continue }
    $n = 0
    if (-not [int]::TryParse($t, [ref]$n)) {
        Write-Error "WS_RETRY_HTTP_CODES contains non-integer token: '$t'"
        exit 1
    }
}

# Schema defaults
$DB_MASTER_SCHEMA = if ($config["DB_MASTER_SCHEMA"] -and $config["DB_MASTER_SCHEMA"].Trim() -ne "") { $config["DB_MASTER_SCHEMA"].Trim() } else { "cpe_master" }
$DB_REPAIR_SCHEMA = if ($config["DB_REPAIR_SCHEMA"] -and $config["DB_REPAIR_SCHEMA"].Trim() -ne "") { $config["DB_REPAIR_SCHEMA"].Trim() } else { "cpe_repair" }

# Taxonomy lookup overrides (blank => jar uses its built-in defaults that match
# the daily pipeline: [HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY] /
# PROVIDER_TAXONOMY_CODE / PROVIDER_TAXONOMY_NAME).
$TAXONOMY_LOOKUP_TABLE = if ($config["TAXONOMY_LOOKUP_TABLE"]) { $config["TAXONOMY_LOOKUP_TABLE"].Trim() } else { "" }
$TAXONOMY_CODE_COLUMN  = if ($config["TAXONOMY_CODE_COLUMN"])  { $config["TAXONOMY_CODE_COLUMN"].Trim()  } else { "" }
$TAXONOMY_NAME_COLUMN  = if ($config["TAXONOMY_NAME_COLUMN"])  { $config["TAXONOMY_NAME_COLUMN"].Trim()  } else { "" }

# ============================================================
# Validate package layout (extracted release zip)
# ============================================================
$jarCandidates = @(Get-ChildItem -Path $INSTALL_DIR -Filter "practitioner-taxonomy-repair-*-jar-with-dependencies.jar" -ErrorAction SilentlyContinue)
if ($jarCandidates.Count -ne 1) {
    Write-Error "Expected exactly one practitioner-taxonomy-repair-*-jar-with-dependencies.jar in $INSTALL_DIR, found $($jarCandidates.Count). Did the release zip extract correctly?"
    exit 1
}
$REPAIR_JAR_SRC  = $jarCandidates[0].FullName
$REPAIR_JAR_NAME = $jarCandidates[0].Name

$RUN_REPAIR_SRC  = Join-Path $INSTALL_DIR "run_repair.ps1"
$DDL_SRC         = Join-Path $INSTALL_DIR "sql\create_cpe_repair_objects.sql"
$CALL_SRC        = Join-Path $INSTALL_DIR "calls\practitioner_taxonomy_repair"

$missingFiles = @()
if (-not (Test-Path $RUN_REPAIR_SRC)) { $missingFiles += "run_repair.ps1" }
if (-not (Test-Path $DDL_SRC))        { $missingFiles += "sql\create_cpe_repair_objects.sql" }
if (-not (Test-Path $CALL_SRC))       { $missingFiles += "calls\practitioner_taxonomy_repair\" }
if ($missingFiles.Count -gt 0) {
    Write-Error "Missing files in install package: $($missingFiles -join ', ')"
    exit 1
}

# ============================================================
# Prompt for target directory + display banner
# ============================================================
Write-Host ""
Write-Host "=== Practitioner Taxonomy Repair Installer ===" -ForegroundColor Cyan

if (Test-Path "$INSTALL_DIR\version.txt") {
    foreach ($line in Get-Content "$INSTALL_DIR\version.txt") {
        if ($line -match '^VERSION=(.+)$')    { Write-Host ("Version: " + $Matches[1].Trim()) -ForegroundColor Cyan }
        if ($line -match '^BUILD_DATE=(.+)$') { Write-Host ("Built:   " + $Matches[1].Trim()) -ForegroundColor Cyan }
    }
}
Write-Host ""
Write-Host "This is an add-on to your existing Claim Provider Data Pipeline install."
Write-Host "Point this installer at the SAME base directory that already contains:"
Write-Host "  <base>\Claim_Provider_Data_Extractor\"
Write-Host "  <base>\Claim_Provider_Data_Loader\"
Write-Host ""
Write-Host "It will create a new sibling folder:"
Write-Host "  <base>\Practitioner_Taxonomy_Repair\   (repair jar, env.properties, run_repair.ps1)"
Write-Host "and drop the new call type into your loader:"
Write-Host "  <base>\Claim_Provider_Data_Loader\practitioner_taxonomy_repair\"
Write-Host ""

$targetDir = Read-Host "Enter installation directory"
$targetDir = $targetDir.Trim().TrimEnd('\')

if (-not $targetDir) {
    Write-Error "Installation directory is required."
    exit 1
}

# ============================================================
# Define paths + verify loader sibling exists
# ============================================================
$LOADER_DIR = "$targetDir\Claim_Provider_Data_Loader"
$REPAIR_DIR = "$targetDir\Practitioner_Taxonomy_Repair"

if (-not (Test-Path $LOADER_DIR)) {
    Write-Error ("Loader install not found at: $LOADER_DIR`n" +
                 "  This installer is an add-on; the Generic_HRP_WS_Call install must exist already.`n" +
                 "  Install the daily pipeline first, or point -InstallDir at the correct base.")
    exit 1
}

# Existing repair folder -- prompt overwrite y/N
if (Test-Path $REPAIR_DIR) {
    Write-Host ""
    Write-Host "WARNING: A Practitioner_Taxonomy_Repair folder already exists at:" -ForegroundColor Yellow
    Write-Host "  $REPAIR_DIR"
    Write-Host "Re-installing will REPLACE the jar, run_repair.ps1, install.ps1, install.config,"
    Write-Host "sql\, version.txt, and REGENERATE env.properties + PractitionerTaxonomyRepair.properties"
    Write-Host "from install.config (any local edits to those two files will be lost)."
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne "y") { Write-Host "Installation cancelled."; exit 0 }
}

Write-Host ""
Write-Host "Installing to: $REPAIR_DIR" -ForegroundColor Green
Write-Host "Call folder destination: $LOADER_DIR\practitioner_taxonomy_repair\" -ForegroundColor Green
Write-Host ""

# ============================================================
# Create directory structure
# ============================================================
Write-Host "Creating directory structure..." -ForegroundColor Cyan
New-Item -Path "$REPAIR_DIR\sql" -ItemType Directory -Force | Out-Null
Write-Host "  $REPAIR_DIR\sql created"

# ============================================================
# Deploy jar + version + installer self + DDL
# ============================================================
Write-Host "Deploying components..." -ForegroundColor Cyan
Copy-Item $REPAIR_JAR_SRC  "$REPAIR_DIR\$REPAIR_JAR_NAME"             -Force
Copy-Item $DDL_SRC         "$REPAIR_DIR\sql\"                          -Force
Copy-Item $configFile      "$REPAIR_DIR\install.config"                -Force
Copy-Item "$INSTALL_DIR\install.ps1" "$REPAIR_DIR\install.ps1"         -Force
if (Test-Path "$INSTALL_DIR\version.txt") {
    Copy-Item "$INSTALL_DIR\version.txt" "$REPAIR_DIR\version.txt"     -Force
}
Write-Host "  Jar + DDL + installer + config deployed"

# ============================================================
# Deploy run_repair.ps1 with SQLCMD_PATH substituted
# ============================================================
$sqlcmdPath = $config["SQLCMD_PATH"]
$runRepairContent = Get-Content $RUN_REPAIR_SRC -Raw
$runRepairContent = $runRepairContent -replace '\$SQLCMD = ".*"', "`$SQLCMD = `"$sqlcmdPath`""
Set-Content -Path "$REPAIR_DIR\run_repair.ps1" -Value $runRepairContent
Write-Host "  run_repair.ps1 deployed (SQLCMD path substituted)"

# ============================================================
# Generate env.properties (consumed by the loader at run time via --env-file)
# ============================================================
$envContent = @(
    "# env.properties for Practitioner_Taxonomy_Repair",
    "# Generated by install.ps1 from install.config -- regenerate by re-running install.ps1.",
    '# Referenced from the call folder properties via ${VARIABLE_NAME}',
    "",
    "# Database connection (loader uses these to query the cpe_repair TVF)",
    "DB_URL=$($config['DB_URL'])",
    "DB_USER=$($config['DB_USER'])",
    "DB_PASSWORD=$($config['DB_PASSWORD'])",
    "",
    "# HRP web service base URL (no trailing slash)",
    "WS_BASE_URL=$($config['WS_BASE_URL'])",
    "",
    "# WS credentials (password keyed by username; practitioner_taxonomy_repair uses connector_admin)",
    "CONNECTOR_ADMIN_PASSWORD=$($config['CONNECTOR_ADMIN_PASSWORD'])",
    "",
    "# Log-only mode -- when true, loader logs SOAP envelopes instead of sending them to HRP.",
    "LOG_ONLY=$logOnlyValue",
    "",
    "# WS call retry. count=0 disables retries (single attempt).",
    "WS_RETRY_COUNT=$($config['WS_RETRY_COUNT'])",
    "WS_RETRY_HTTP_CODES=$($config['WS_RETRY_HTTP_CODES'])",
    "WS_RETRY_BACKOFF_MS=$($config['WS_RETRY_BACKOFF_MS'])",
    "WS_RETRY_MAX_BACKOFF_MS=$($config['WS_RETRY_MAX_BACKOFF_MS'])"
) -join "`r`n"
Set-Content -Path "$REPAIR_DIR\env.properties" -Value $envContent
Write-Host "  env.properties generated"

# ============================================================
# Generate PractitionerTaxonomyRepair.properties (consumed by the repair jar directly)
# ============================================================
$npiQuery = if ($config["NPI_QUERY"] -and $config["NPI_QUERY"].Trim() -ne "") { $config["NPI_QUERY"].Trim() } else { $null }
$repairPropsLines = @(
    "# PractitionerTaxonomyRepair.properties",
    "# Generated by install.ps1 from install.config -- regenerate by re-running install.ps1.",
    "",
    "# --- Database connection ---",
    "db.url=$($config['DB_URL'])",
    "db.user=$($config['DB_USER'])",
    "db.password=$($config['DB_PASSWORD'])",
    "",
    "# --- Schemas ---",
    "db.master.schema=$DB_MASTER_SCHEMA",
    "db.repair.schema=$DB_REPAIR_SCHEMA"
)
# Taxonomy lookup overrides -- only emit if the operator set them in install.config;
# otherwise the jar's built-in defaults match the daily pipeline's source.
if ($TAXONOMY_LOOKUP_TABLE -or $TAXONOMY_CODE_COLUMN -or $TAXONOMY_NAME_COLUMN) {
    $repairPropsLines += @("", "# --- Taxonomy lookup overrides (from install.config) ---")
    if ($TAXONOMY_LOOKUP_TABLE) { $repairPropsLines += "db.taxonomy.lookup.table=$TAXONOMY_LOOKUP_TABLE" }
    if ($TAXONOMY_CODE_COLUMN)  { $repairPropsLines += "db.taxonomy.lookup.code_column=$TAXONOMY_CODE_COLUMN" }
    if ($TAXONOMY_NAME_COLUMN)  { $repairPropsLines += "db.taxonomy.lookup.name_column=$TAXONOMY_NAME_COLUMN" }
}
if ($npiQuery) {
    $repairPropsLines += @(
        "",
        "# --- Custom NPI auto-derive query (from install.config NPI_QUERY) ---",
        "# Used by the jar when --npi-file is NOT passed. Verbatim; no schema substitution.",
        "db.npi_query=$npiQuery"
    )
}
Set-Content -Path "$REPAIR_DIR\PractitionerTaxonomyRepair.properties" -Value ($repairPropsLines -join "`r`n")
Write-Host "  PractitionerTaxonomyRepair.properties generated"

# ============================================================
# Copy call folder into the loader install
# ============================================================
$CALL_DEST = "$LOADER_DIR\practitioner_taxonomy_repair"
if (Test-Path $CALL_DEST) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$CALL_DEST.bak.$stamp"
    Move-Item -Path $CALL_DEST -Destination $backup
    Write-Host "  Existing call folder backed up to: $backup" -ForegroundColor Yellow
}
Copy-Item -Recurse $CALL_SRC $CALL_DEST
Write-Host "  Call folder installed at: $CALL_DEST"

# ============================================================
# Optionally run DDL
# ============================================================
Write-Host ""
$runDdl = Read-Host "Apply database DDL now (creates cpe_repair schema, tables, TVF, proc)? (y/N)"
if ($runDdl -eq "y") {
    Write-Host ""
    Write-Host "Applying DDL..." -ForegroundColor Cyan

    $sqlcmd = $config["SQLCMD_PATH"]
    Write-Host "  Verifying sqlcmd (this may take a few seconds)..."
    $sqlcmdOk = $false
    try {
        & $sqlcmd -? 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $sqlcmdOk = $true }
    } catch {}
    if (-not $sqlcmdOk) {
        Write-Host "  WARNING: sqlcmd at '$sqlcmd' is not executable -- skipping DDL" -ForegroundColor Yellow
    } else {
        # Parse server + database from DB_URL
        $dbUrl = $config["DB_URL"]
        if ($dbUrl -match 'jdbc:sqlserver://([^;]+);databaseName=([^;]+)') {
            $dbServer = $Matches[1] -replace ':', ','
            $dbName   = $Matches[2]
        } else {
            Write-Host "  WARNING: Could not parse DB_URL -- skipping DDL" -ForegroundColor Yellow
            $dbServer = $null
        }

        if ($dbServer) {
            $dbUser = $config["DB_USER"]
            $env:SQLCMDPASSWORD = $config["DB_PASSWORD"]
            & $sqlcmd -b -S $dbServer -d $dbName -U $dbUser -i "$REPAIR_DIR\sql\create_cpe_repair_objects.sql"
            $env:SQLCMDPASSWORD = $null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  cpe_repair objects created" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: DDL script returned errors -- check output above" -ForegroundColor Yellow
            }
        }
    }
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Installed to:"
Write-Host "  Repair:       $REPAIR_DIR"
Write-Host "  Call folder:  $CALL_DEST"
Write-Host ""
Write-Host "Next steps:"
if ($runDdl -ne "y") {
    Write-Host "  1. Apply the DDL:"
    Write-Host "     sqlcmd -S <server> -d <database> -U <user> -P <password> -i `"$REPAIR_DIR\sql\create_cpe_repair_objects.sql`""
}
Write-Host "  2. Run the repair orchestrator:"
Write-Host "       cd `"$REPAIR_DIR`""
Write-Host "       .\run_repair.ps1                                # auto-derive NPI list, real run"
Write-Host "       .\run_repair.ps1 -NpiFile pilot.txt -DryRun     # dry-run a pilot list"
Write-Host "       .\run_repair.ps1 -RunId 7                       # resume the loader for run 7"
Write-Host ""
Write-Host "  See INSTALL.txt and README.md for detail; CLAUDE_NOTES.md for design notes."
Write-Host ""
