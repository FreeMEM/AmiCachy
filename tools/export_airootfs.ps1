#!/usr/bin/env pwsh
# Export airootfs from AmiCachy project for USB replacement

param(
    [string]$OutputPath = ".",
    [switch]$Compress
)

$ErrorActionPreference = "Stop"

Write-Host "=== AmiCachy airootfs Export ===" -ForegroundColor Green
Write-Host ""

# Paths
$ProjectDir = Split-Path -Parent $PSScriptRoot
$AirootfsDir = Join-Path $ProjectDir "archiso\airootfs"
$OutputDir = if ($OutputPath -eq ".") { $ProjectDir } else { $OutputPath }

Write-Host "Source: $AirootfsDir"
Write-Host "Output: $OutputDir"
Write-Host ""

# Verify source exists
if (-not (Test-Path $AirootfsDir)) {
    throw "ERROR: airootfs directory not found at $AirootfsDir"
}

# Create output directory if needed
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Export airootfs
$TargetPath = Join-Path $OutputDir "airootfs"
Write-Host "Copying airootfs to $TargetPath..."

if (Test-Path $TargetPath) {
    Write-Host "Removing existing airootfs..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $TargetPath
}

# Copy with progress
Robocopy $AirootfsDir $TargetPath /E /MT:8 /R:2 /W:5 | Out-Null

if ($LASTEXITCODE -ge 8) {
    throw "ERROR: Robocopy failed with exit code $LASTEXITCODE"
}

Write-Host "✓ airootfs copied successfully" -ForegroundColor Green

# Verify WiFi files are present
$RegDb = Join-Path $TargetPath "usr\lib\firmware\regulatory.db"
$IwTool = Join-Path $TargetPath "usr\bin\iw"

Write-Host ""
Write-Host "Verifying WiFi components..." -ForegroundColor Cyan

if (Test-Path $RegDb) {
    Write-Host "✓ regulatory.db found" -ForegroundColor Green
} else {
    Write-Host "✗ regulatory.db MISSING" -ForegroundColor Red
}

if (Test-Path $IwTool) {
    Write-Host "✓ iw tool found" -ForegroundColor Green
} else {
    Write-Host "✗ iw tool MISSING" -ForegroundColor Red
}

# Compress if requested
if ($Compress) {
    Write-Host ""
    Write-Host "Compressing airootfs..." -ForegroundColor Cyan
    $CompressedPath = Join-Path $OutputDir "airootfs.zip"

    if (Test-Path $CompressedPath) {
        Remove-Item -Force $CompressedPath
    }

    Compress-Archive -Path $TargetPath -DestinationPath $CompressedPath -Force
    Write-Host "✓ Compressed to $CompressedPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Export Complete ===" -ForegroundColor Green
Write-Host "airootfs ready for USB replacement at: $TargetPath"
