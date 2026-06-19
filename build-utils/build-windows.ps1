# Build Flutter Windows app
# Usage: .\build-utils\build-windows.ps1 [-EnvFile .env]

param(
    [string]$EnvFile = ".env"
)

Write-Host "Building Flutter Windows app..." -ForegroundColor Green

# Verificar que estamos en el directorio correcto
$projectRoot = Split-Path -Parent $PSScriptRoot

# Resolve plugin symlinks - replace them with real directory copies
# to avoid CMake extraction errors through symlinks (e.g. fvp mdk-sdk).
$symlinksDir = "$projectRoot\windows\flutter\ephemeral\.plugin_symlinks"
if (Test-Path $symlinksDir) {
    Write-Host "Resolving plugin symlinks..." -ForegroundColor Yellow
    Get-ChildItem $symlinksDir -Directory | Where-Object { $_.LinkType -ne $null } | ForEach-Object {
        $target = $_.Target
        if ($target -and (Test-Path $target)) {
            Write-Host "  Resolving $($_.Name) -> $target" -ForegroundColor Gray
            Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            Copy-Item -Recurse $target $_.FullName -Force
        }
    }
}

# Limpiar build anterior si existe
if (Test-Path "$projectRoot\build\windows\x64\runner\Release") {
    Write-Host "Cleaning previous build..." -ForegroundColor Yellow
    Remove-Item -Path "$projectRoot\build\windows\x64\runner\Release" -Recurse -Force -ErrorAction SilentlyContinue
}

# Build release
Write-Host "Building Windows release..." -ForegroundColor Cyan
Set-Location $projectRoot
$envArg = ""
if (Test-Path "$projectRoot\$EnvFile") {
    Write-Host "Loading environment from $EnvFile..." -ForegroundColor Cyan
    $envArg = "--dart-define-from-file=$EnvFile"
} else {
    Write-Host "Env file not found: $EnvFile" -ForegroundColor Yellow
}

flutter build windows --release $envArg

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error during build" -ForegroundColor Red
    exit 1
}

# Obtener versión del pubspec.yaml
$version = (Select-String -Path "$projectRoot\pubspec.yaml" -Pattern "^version:\s*(.+)" | ForEach-Object { $_.Matches.Groups[1].Value }).Trim()

# Crear directorio de salida
Write-Host "Creating output directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path "$projectRoot\release" -Force | Out-Null

# Crear bundle
Write-Host "Creating bundle..." -ForegroundColor Cyan
$bundleDir = "$projectRoot\build\windows\x64\runner\Release"
$outputZip = "$projectRoot\release\neostation-windows-x64-$version.zip"

# Copiar sqlite3.dll desde native_assets (generado por el build)
$sqliteNative = "$projectRoot\build\native_assets\windows\sqlite3.dll"
if (Test-Path $sqliteNative) {
    Write-Host "Copying sqlite3.dll from native_assets..." -ForegroundColor Cyan
    Copy-Item -Path $sqliteNative -Destination "$bundleDir\" -Force
} else {
    Write-Host "Warning: sqlite3.dll not found in native_assets" -ForegroundColor Yellow
}

# Comprimir bundle
Write-Host "🗜️ Compressing bundle..." -ForegroundColor Cyan
Compress-Archive -Path "$bundleDir\*" -DestinationPath $outputZip -Force

if (Test-Path $outputZip) {
    Write-Host ""
    Write-Host "Build completado!" -ForegroundColor Green
    Write-Host "Resultado en: release\" -ForegroundColor Cyan
    Get-ChildItem -Path "$projectRoot\release" -Filter "*.zip" | Format-Table Name, @{Name="Size (MB)";Expression={[math]::Round($_.Length/1MB, 2)}}, LastWriteTime
} else {
    Write-Host "Error al crear el archivo ZIP" -ForegroundColor Red
    exit 1
}
