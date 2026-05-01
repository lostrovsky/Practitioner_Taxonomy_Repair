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
Write-Host "Creating zip..." -ForegroundColor Cyan
if (Test-Path $OUTPUT_ZIP) { Remove-Item $OUTPUT_ZIP }
Compress-Archive -Path "$STAGE_DIR\*" -DestinationPath $OUTPUT_ZIP

Remove-Item $STAGE_DIR -Recurse -Force

$zipSize = [math]::Round((Get-Item $OUTPUT_ZIP).Length / 1MB, 1)
Write-Host "Package created: $OUTPUT_ZIP ($zipSize MB)" -ForegroundColor Green
