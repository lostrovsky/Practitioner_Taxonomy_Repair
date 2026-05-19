# ============================================================
# Practitioner Taxonomy Repair -- automated installer
# ============================================================
# Automates INSTALL.txt steps 2-4 (apply DDL, configure DB creds,
# copy the call folder to your loader install) into one command.
#
# Run this FROM the extracted release zip directory -- it expects
# the jar, PractitionerTaxonomyRepair.properties, sql\ and calls\
# as siblings of this script.
#
# DB connection is read from PractitionerTaxonomyRepair.properties
# (db.url / db.user / db.password) -- the same file the Java tool
# uses. So the normal flow is: fill in that file once, then:
#
#   .\install.ps1 -LoaderInstallPath 'C:\Tools\Claim_Provider_Data_Loader'
#
# Any of -SqlServer / -Database / -DbUser / -DbPassword you DO pass
# override the corresponding value from the properties file (and, if
# the file still has placeholders, get written into it).
#
# Idempotent and upgrade-safe:
#   * DDL is idempotent (the .sql guards every object).
#   * The properties file is only modified if you pass DB params AND
#     it still has placeholders (or you pass -Force). A file you've
#     already filled in is treated as the source of truth, untouched.
#   * An existing (possibly operator-customized) call folder is backed
#     up to a timestamped sibling before replacement, and only replaced
#     when -Force is passed.
#
# Supports -WhatIf for a no-side-effect dry run.
# ============================================================

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'DbPassword',
    Justification = 'The DB password must be passed to sqlcmd -P and written verbatim into ' +
    'PractitionerTaxonomyRepair.properties (db.password=) for the Java tool to connect. It ends up ' +
    'cleartext regardless; SecureString would add ceremony without protection and is inconsistent ' +
    'with the documented INSTALL.txt usage and the project sqlcmd -P convention.')]
param(
    [Parameter(Mandatory = $true)] [string] $LoaderInstallPath,

    # All optional -- fall back to PractitionerTaxonomyRepair.properties.
    [string] $SqlServer,
    [string] $Database,
    [string] $DbUser,
    [string] $DbPassword,

    [int]    $DbPort    = 1433,
    [string] $SqlcmdPath,
    [switch] $SkipDdl,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step  ($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "    $m"   -ForegroundColor Green }
function Write-Note  ($m) { Write-Host "    $m"   -ForegroundColor Yellow }
function Write-Fail  ($m) { Write-Host "`nERROR: $m" -ForegroundColor Red; exit 1 }

$InstallDir = $PSScriptRoot

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Practitioner Taxonomy Repair -- installer" -ForegroundColor Cyan
Write-Host " Install dir: $InstallDir" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ------------------------------------------------------------
# 0. Validate this is a real extracted release dir
# ------------------------------------------------------------
Write-Step "Validating package layout"

$propsFile = Join-Path $InstallDir 'PractitionerTaxonomyRepair.properties'
$ddlFile   = Join-Path $InstallDir 'sql\create_cpe_repair_objects.sql'
$callSrc   = Join-Path $InstallDir 'calls\practitioner_taxonomy_repair'
$jarGlob   = Join-Path $InstallDir 'practitioner-taxonomy-repair-*-jar-with-dependencies.jar'

$missing = @()
if (-not (Test-Path $propsFile))            { $missing += 'PractitionerTaxonomyRepair.properties' }
if (-not (Test-Path $ddlFile))              { $missing += 'sql\create_cpe_repair_objects.sql' }
if (-not (Test-Path $callSrc))              { $missing += 'calls\practitioner_taxonomy_repair\' }
if (-not (Get-ChildItem $jarGlob -ErrorAction SilentlyContinue)) { $missing += 'practitioner-taxonomy-repair-*-jar-with-dependencies.jar' }

if ($missing.Count -gt 0) {
    Write-Fail ("This does not look like an extracted release directory. Missing:`n  - " +
        ($missing -join "`n  - ") +
        "`n  Run install.ps1 from the directory where you extracted the release zip.")
}
Write-Ok "Package layout OK."

# ------------------------------------------------------------
# 1. Resolve DB connection
#    Source of truth = PractitionerTaxonomyRepair.properties.
#    Any CLI param overrides the matching field from the file.
# ------------------------------------------------------------
Write-Step "Resolving DB connection"

$lines  = Get-Content $propsFile
$joined = ($lines -join "`n")

function Get-PropValue ($key) {
    $m = [regex]::Match($joined, "(?m)^\s*$([regex]::Escape($key))\s*=\s*(.+?)\s*$")
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

$fileUrl  = Get-PropValue 'db.url'
$fileUser = Get-PropValue 'db.user'
$filePass = Get-PropValue 'db.password'

# Parse jdbc:sqlserver://<host[\inst][:port|,port]>;databaseName=<db>;...
$fileHost = $null; $filePort = $null; $fileDb = $null
if ($fileUrl) {
    $u = [regex]::Match($fileUrl, '^jdbc:sqlserver://([^;]+);')
    if ($u.Success) {
        $serverPart = $u.Groups[1].Value
        $sp = [regex]::Match($serverPart, '^([^,:]+(?:\\[^,:]+)?)(?:[,:](\d+))?$')
        if ($sp.Success) {
            $fileHost = $sp.Groups[1].Value
            if ($sp.Groups[2].Success) { $filePort = [int]$sp.Groups[2].Value }
        }
    }
    $d = [regex]::Match($fileUrl, 'databaseName=([^;]+)')
    if ($d.Success) { $fileDb = $d.Groups[1].Value }
}

$gaveCliDb = $PSBoundParameters.ContainsKey('SqlServer') -or
             $PSBoundParameters.ContainsKey('Database')  -or
             $PSBoundParameters.ContainsKey('DbUser')     -or
             $PSBoundParameters.ContainsKey('DbPassword')

# Effective values: CLI wins, else properties file.
$EffHost = if ($PSBoundParameters.ContainsKey('SqlServer'))  { $SqlServer }  else { $fileHost }
$EffDb   = if ($PSBoundParameters.ContainsKey('Database'))   { $Database }   else { $fileDb }
$EffUser = if ($PSBoundParameters.ContainsKey('DbUser'))     { $DbUser }     else { $fileUser }
$EffPass = if ($PSBoundParameters.ContainsKey('DbPassword')) { $DbPassword } else { $filePass }
$EffPort = if ($PSBoundParameters.ContainsKey('DbPort'))     { $DbPort }
           elseif ($filePort)                                { $filePort }
           else                                              { 1433 }

# Validate -- reject empty or still-placeholder values.
$bad = @()
foreach ($p in @(
        @{ n = 'server (db.url host / -SqlServer)';  v = $EffHost },
        @{ n = 'database (db.url / -Database)';       v = $EffDb   },
        @{ n = 'user (db.user / -DbUser)';            v = $EffUser },
        @{ n = 'password (db.password / -DbPassword)'; v = $EffPass })) {
    if ([string]::IsNullOrWhiteSpace($p.v) -or $p.v -match 'YOUR_DB_') { $bad += $p.n }
}
if ($bad.Count -gt 0) {
    Write-Fail ("DB connection is not fully resolved. Unset/placeholder:`n  - " +
        ($bad -join "`n  - ") +
        "`n  Fix by EITHER editing the db.url / db.user / db.password lines in:`n    $propsFile`n" +
        "  OR passing -SqlServer / -Database / -DbUser / -DbPassword on the command line.")
}

if ($gaveCliDb) { Write-Note "Using CLI-supplied DB value(s); rest from properties file." }
else            { Write-Note "DB connection read from PractitionerTaxonomyRepair.properties." }
Write-Ok "Target: server=$EffHost port=$EffPort db=$EffDb user=$EffUser"

# sqlcmd -S form: host[\inst][,port]. Only append port if non-default.
$serverArg = if ($EffPort -and $EffPort -ne 1433) { "$EffHost,$EffPort" } else { $EffHost }

# ------------------------------------------------------------
# 2. Apply DDL (idempotent)
# ------------------------------------------------------------
Write-Step "Applying database DDL (cpe_repair schema, tables, TVF, proc)"

if ($SkipDdl) {
    Write-Note "-SkipDdl set: skipping DDL. Ensure cpe_repair objects already exist."
}
else {
    # Resolve sqlcmd: explicit param > PATH > common ODBC install location
    $sqlcmd = $null
    if ($SqlcmdPath) {
        if (-not (Test-Path $SqlcmdPath)) { Write-Fail "-SqlcmdPath '$SqlcmdPath' not found." }
        $sqlcmd = $SqlcmdPath
    }
    else {
        $onPath = Get-Command sqlcmd -ErrorAction SilentlyContinue
        if ($onPath) {
            $sqlcmd = $onPath.Source
        }
        else {
            $common = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE'
            if (Test-Path $common) { $sqlcmd = $common }
        }
    }
    $target = "sqlcmd -S $serverArg -d $EffDb (user $EffUser) -i sql\create_cpe_repair_objects.sql"

    if (-not $sqlcmd) {
        $msg = ("sqlcmd not found on PATH or at the common ODBC location. " +
            "Install the SQL Server command-line tools, or pass -SqlcmdPath, or run the DDL manually:`n" +
            "  sqlcmd -S $serverArg -d $EffDb -U $EffUser -P <pwd> -b -i `"$ddlFile`"")
        if ($WhatIfPreference) {
            Write-Note "[WhatIf] $msg"
            Write-Note "[WhatIf] Continuing -- would apply: $target"
        }
        else {
            Write-Fail $msg
        }
    }
    elseif ($PSCmdlet.ShouldProcess($target, "Apply DDL")) {
        Write-Note "Using sqlcmd: $sqlcmd"
        & $sqlcmd -S $serverArg -d $EffDb -U $EffUser -P $EffPass -b -i $ddlFile
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "sqlcmd returned exit code $LASTEXITCODE. DDL was NOT applied cleanly. Aborting."
        }
        Write-Ok "DDL applied (idempotent -- safe to re-run)."
    }
}

# ------------------------------------------------------------
# 3. Configure PractitionerTaxonomyRepair.properties
#    The file is the source of truth. Only write it when the operator
#    explicitly passed DB params AND the file still has placeholders
#    (or -Force). Targeted-preserve: only db.url/user/password lines.
# ------------------------------------------------------------
Write-Step "Configuring DB connection in PractitionerTaxonomyRepair.properties"

$hasPlaceholders = ($joined -match 'YOUR_DB_HOST' -or $joined -match 'YOUR_DB_NAME' -or
                    $joined -match 'YOUR_DB_USER' -or $joined -match 'YOUR_DB_PASSWORD')

if (-not $gaveCliDb) {
    Write-Note "No DB params on the command line -- properties file is the source of truth, leaving it untouched."
}
elseif (-not $hasPlaceholders -and -not $Force) {
    Write-Note "CLI DB params given, but the properties file already has real values."
    Write-Note "Preserving the file. Pass -Force to overwrite it with the CLI values."
}
else {
    $newUrl = "jdbc:sqlserver://${EffHost}:${EffPort};databaseName=${EffDb};trustServerCertificate=true;"
    $rewritten = $lines | ForEach-Object {
        if    ($_ -match '^\s*db\.url\s*=')       { "db.url=$newUrl" }
        elseif ($_ -match '^\s*db\.user\s*=')     { "db.user=$EffUser" }
        elseif ($_ -match '^\s*db\.password\s*=') { "db.password=$EffPass" }
        else { $_ }
    }
    if ($PSCmdlet.ShouldProcess($propsFile, "Write db.url / db.user / db.password")) {
        # Preserve CRLF; do not append a trailing blank line.
        [System.IO.File]::WriteAllText($propsFile, ($rewritten -join "`r`n") + "`r`n")
        if ($hasPlaceholders) { Write-Ok "DB credentials written (placeholders replaced)." }
        else                  { Write-Ok "DB credentials overwritten (-Force)." }
        Write-Note "Schema lines (db.master.schema / db.repair.schema / db.xref.schema) left untouched."
    }
}

# ------------------------------------------------------------
# 4. Copy call folder into the loader install
#    Mindful replacement: never silently destroy an operator-customized
#    call folder (the <maintenanceReasonCode> TODO lives there). On a
#    fresh target, copy. On an existing target, require -Force and back
#    up the old folder to a timestamped sibling first.
# ------------------------------------------------------------
Write-Step "Installing call folder into the loader"

if (-not (Test-Path $LoaderInstallPath)) {
    Write-Fail "-LoaderInstallPath '$LoaderInstallPath' does not exist. Point this at your existing Claim_Provider_Data_Loader install directory."
}

$callDest = Join-Path $LoaderInstallPath 'practitioner_taxonomy_repair'

if (Test-Path $callDest) {
    if (-not $Force) {
        Write-Note "A call folder already exists at:"
        Write-Note "  $callDest"
        Write-Note "It may contain operator edits (e.g. the <maintenanceReasonCode> values)."
        Write-Note "Re-run with -Force to replace it. The existing folder will be backed up first."
        Write-Note "Compare before overwriting, e.g.:"
        Write-Note "  Compare-Object (Get-Content '$callSrc\practitioner_taxonomy_repair.properties') (Get-Content '$callDest\practitioner_taxonomy_repair.properties')"
    }
    else {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$callDest.bak.$stamp"
        if ($PSCmdlet.ShouldProcess($callDest, "Back up to $backup then replace")) {
            Move-Item -Path $callDest -Destination $backup
            Write-Note "Existing call folder backed up to: $backup"
            Copy-Item -Recurse -Path $callSrc -Destination $callDest
            Write-Ok "Call folder replaced. Re-apply any operator edits from the backup if needed."
        }
    }
}
else {
    if ($PSCmdlet.ShouldProcess($callDest, "Copy call folder")) {
        Copy-Item -Recurse -Path $callSrc -Destination $callDest
        Write-Ok "Call folder installed at: $callDest"
    }
}

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " Install complete." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host @"

Next steps (see INSTALL.txt for detail):

  1. Dry run -- counts target practitioners, calls NPPES, no DB writes:
       java -jar practitioner-taxonomy-repair-*-jar-with-dependencies.jar --dry-run

  2. Stage a batch (prints BATCH_ID=<n>):
       java -jar practitioner-taxonomy-repair-*-jar-with-dependencies.jar --description="Pilot"

  3. Push amends in LOG_ONLY mode first, then for real, from your loader install:
       java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair --RUN_ID=<n> --LOG_ONLY=true --env-file=<env>

"@ -ForegroundColor Gray
