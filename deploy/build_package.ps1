# ============================================================
# Practitioner Taxonomy Repair -- Build deployment zip from source
# Run from the project root (or anywhere; paths resolve relative to this script).
# Produces a versioned zip in deploy/.
# ============================================================

$ErrorActionPreference = "Stop"

$PROJECT_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$STAGE_DIR    = "$PROJECT_ROOT\deploy\stage"

# ============================================================
# Determine version from git tags
# ============================================================
Push-Location $PROJECT_ROOT
try {
    $describe = & git describe --tags --always --dirty 2>$null
    if (-not $describe) { $describe = "v0.0.0-dev" }
    $VERSION = $describe
    $COMMIT  = & git rev-parse --short HEAD 2>$null
    if (-not $COMMIT) { $COMMIT = "unknown" }
} finally {
    Pop-Location
}
$BUILD_DATE = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "Version: $VERSION  Commit: $COMMIT  Built: $BUILD_DATE" -ForegroundColor Cyan

$OUTPUT_ZIP = "$PROJECT_ROOT\deploy\practitioner_taxonomy_repair_$VERSION.zip"

# ============================================================
# Build jar (requires claim-provider-data-extractor in local m2 already)
# ============================================================
Write-Host "Building jar..." -ForegroundColor Cyan
Push-Location $PROJECT_ROOT
try {
    & mvn clean package -DskipTests -q
    if ($LASTEXITCODE -ne 0) { Write-Error "Maven build failed"; exit 1 }
} finally {
    Pop-Location
}

$jar = "$PROJECT_ROOT\target\practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar"
if (-not (Test-Path $jar)) { Write-Error "Built jar not found at $jar"; exit 1 }

# ============================================================
# Stage zip contents
# ============================================================
Write-Host "Staging deployment package..." -ForegroundColor Cyan
if (Test-Path $STAGE_DIR) { Remove-Item $STAGE_DIR -Recurse -Force }
New-Item -Path $STAGE_DIR -ItemType Directory | Out-Null

# Fat jar
Copy-Item $jar "$STAGE_DIR\practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar"

# Properties template -- pulled from git HEAD (the canonical in-repo version
# with YOUR_* placeholders), NOT from the working tree. The working tree file
# is normally --skip-worktree'd with real local credentials; reading HEAD
# bypasses that without disturbing the working tree.
$placeholderContent = & git -C $PROJECT_ROOT show "HEAD:PractitionerTaxonomyRepair.properties"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to read PractitionerTaxonomyRepair.properties from git HEAD"
    Remove-Item $STAGE_DIR -Recurse -Force
    exit 1
}
$joined = ($placeholderContent -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText("$STAGE_DIR\PractitionerTaxonomyRepair.properties", $joined)

# Sanity check: belt-and-suspenders -- refuse to ship if real creds somehow ended up here
$propsContent = Get-Content "$STAGE_DIR\PractitionerTaxonomyRepair.properties" -Raw
if ($propsContent -notmatch "YOUR_DB_PASSWORD") {
    Write-Error "Staged properties file does NOT contain placeholder 'YOUR_DB_PASSWORD' -- refusing to package. Did the in-repo version get committed with real creds?"
    Remove-Item $STAGE_DIR -Recurse -Force
    exit 1
}

# DDL
New-Item -Path "$STAGE_DIR\sql" -ItemType Directory | Out-Null
Copy-Item "$PROJECT_ROOT\sql\create_cpe_repair_objects.sql" "$STAGE_DIR\sql\"

# Call folder (lives WITH this project, not in the Pipeline repo)
New-Item -Path "$STAGE_DIR\calls" -ItemType Directory | Out-Null
Copy-Item -Recurse "$PROJECT_ROOT\calls\practitioner_taxonomy_repair" "$STAGE_DIR\calls\"

# Install guide
if (Test-Path "$PROJECT_ROOT\deploy\INSTALL.txt") {
    Copy-Item "$PROJECT_ROOT\deploy\INSTALL.txt" "$STAGE_DIR\"
}

# Automated installer -- lands at the zip root so it sits beside the jar,
# properties, sql\ and calls\ that it expects as siblings.
if (-not (Test-Path "$PROJECT_ROOT\deploy\install.ps1")) {
    Write-Error "deploy\install.ps1 not found -- cannot package without the installer"
    Remove-Item $STAGE_DIR -Recurse -Force
    exit 1
}
Copy-Item "$PROJECT_ROOT\deploy\install.ps1" "$STAGE_DIR\"

# Version metadata
$versionContent = @(
    "VERSION=$VERSION",
    "COMMIT=$COMMIT",
    "BUILD_DATE=$BUILD_DATE"
) -join "`r`n"
Set-Content -Path "$STAGE_DIR\version.txt" -Value $versionContent -NoNewline

# ============================================================
# Compress
# ============================================================
# Use ZipFile::CreateFromDirectory, NOT Compress-Archive. Compress-Archive
# opens each staged file individually and races Windows Defender's
# real-time scan of freshly-written .ps1 files -- it can silently drop a
# locked file from the archive while still reporting success. One retry
# covers a transient AV/indexer lock; the post-zip manifest check below
# is the real safety net (a dropped file fails the build loudly).
Write-Host "Creating zip..." -ForegroundColor Cyan
if (Test-Path $OUTPUT_ZIP) { Remove-Item $OUTPUT_ZIP }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipOk = $false
for ($attempt = 1; $attempt -le 2 -and -not $zipOk; $attempt++) {
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $STAGE_DIR, $OUTPUT_ZIP,
            [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $zipOk = $true
    }
    catch [System.IO.IOException] {
        if (Test-Path $OUTPUT_ZIP) { Remove-Item $OUTPUT_ZIP -Force }
        if ($attempt -ge 2) { Write-Error "Zip creation failed (file lock): $($_.Exception.Message)"; Remove-Item $STAGE_DIR -Recurse -Force; exit 1 }
        Write-Host "  zip attempt $attempt hit a file lock; retrying..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
}

# Manifest check -- the zip MUST contain everything we staged. This is what
# turns a silent drop (the Compress-Archive failure mode) into a hard fail.
$expected = (Get-ChildItem $STAGE_DIR -Recurse -File |
    ForEach-Object { $_.FullName.Substring($STAGE_DIR.Length + 1).Replace('\','/') }) | Sort-Object
$archive  = [System.IO.Compression.ZipFile]::OpenRead($OUTPUT_ZIP)
$actual   = ($archive.Entries | ForEach-Object { $_.FullName.Replace('\','/') }) | Sort-Object
$archive.Dispose()
$dropped = $expected | Where-Object { $_ -notin $actual }
if ($dropped) {
    Write-Error ("Zip is missing staged files -- refusing to ship a broken package:`n  - " + ($dropped -join "`n  - "))
    Remove-Item $OUTPUT_ZIP -Force
    Remove-Item $STAGE_DIR -Recurse -Force
    exit 1
}
Write-Host "Zip manifest verified: $($actual.Count) entries, all staged files present." -ForegroundColor Green

Remove-Item $STAGE_DIR -Recurse -Force

$zipSize = [math]::Round((Get-Item $OUTPUT_ZIP).Length / 1MB, 1)
Write-Host "Package created: $OUTPUT_ZIP ($zipSize MB)" -ForegroundColor Green
