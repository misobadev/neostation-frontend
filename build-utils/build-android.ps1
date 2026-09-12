# Build Flutter Android APK
# Usage: .\build-utils\build-android.ps1 [-EnvFile .env]

param(
    [string]$EnvFile = ".env"
)

Write-Host "Building Flutter Android APK..." -ForegroundColor Green

# Verify we are in the correct directory
$projectRoot = Split-Path -Parent $PSScriptRoot

# Build release APK
Write-Host "Building Android release..." -ForegroundColor Cyan
Set-Location $projectRoot
$envArg = ""
if (Test-Path "$projectRoot\$EnvFile") {
    Write-Host "Loading environment from $EnvFile..." -ForegroundColor Cyan
    $envArg = "--dart-define-from-file=$EnvFile"
} else {
    Write-Host "Env file not found: $EnvFile" -ForegroundColor Yellow
}

# One APK per ABI instead of a universal one: no target device is x86_64, and
# armeabi-v7a is kept for 32-bit Android TV boxes. Both flags are needed:
# --target-platform only drops the engine and AOT libs, while --split-per-abi
# sets abiFilters, which is what drops the plugin natives Gradle packages for
# every ABI.
#
# Removing --split-per-abi later is not free: Flutter rewrites versionCode to
# abi*1000+build (127 ships as 1127/2127), so a universal build after this one
# must jump the pubspec build number above the highest shipped code, or Android
# refuses the install as a downgrade.
flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm $envArg

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error during build" -ForegroundColor Red
    exit 1
}

# Get version from pubspec.yaml
$version = (Select-String -Path "$projectRoot\pubspec.yaml" -Pattern "^version:\s*(.+)" | ForEach-Object { $_.Matches.Groups[1].Value }).Trim()

# Create output directory
Write-Host "Creating output directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path "$projectRoot\release" -Force | Out-Null

# Copy and rename the APKs
Write-Host "Copying APKs to release..." -ForegroundColor Cyan
# Both must publish: UpdateService picks the one matching the ABI the running
# app was installed for.
$apkDir = "$projectRoot\build\app\outputs\flutter-apk"
$missing = $false

foreach ($abi in @("arm64-v8a", "armeabi-v7a")) {
    $sourceApk = "$apkDir\app-$abi-release.apk"
    $destApk = "$projectRoot\release\neostation-android-$abi-$version.apk"

    if (Test-Path $sourceApk) {
        Copy-Item -Path $sourceApk -Destination $destApk -Force
    } else {
        Write-Host "No $abi release APK found in: $apkDir" -ForegroundColor Red
        $missing = $true
    }
}

if ($missing) {
    if (Test-Path $apkDir) {
        Get-ChildItem -Path $apkDir | Select-Object -ExpandProperty Name
    } else {
        Write-Host "  (directory does not exist)"
    }
    exit 1
}

Write-Host ""
Write-Host "Build completado!" -ForegroundColor Green
Write-Host "Resultado en: release\" -ForegroundColor Cyan
Get-ChildItem -Path "$projectRoot\release" -Filter "*.apk" | Format-Table Name, @{Name="Size (MB)";Expression={[math]::Round($_.Length/1MB, 2)}}, LastWriteTime
