# Update Archiso boot entries on an existing USB stick.
#
# Usage:
#   .\tools\set_usb_archisolabel_windows.ps1 -UsbDrive X: -Label AMICACHY_202605

param(
    [Parameter(Mandatory = $true)]
    [string]$UsbDrive,

    [string]$Label = ""
)

$ErrorActionPreference = "Stop"

if ($UsbDrive.Length -eq 1) {
    $UsbDrive = "$UsbDrive`:"
}
$UsbRoot = $UsbDrive.TrimEnd("\") + "\"

if (!(Test-Path $UsbRoot)) {
    throw "USB drive not found: $UsbRoot"
}

if ([string]::IsNullOrWhiteSpace($Label)) {
    $letter = $UsbDrive.TrimEnd(":","\")
    $volume = Get-Volume -DriveLetter $letter
    $Label = $volume.FileSystemLabel
}

if ([string]::IsNullOrWhiteSpace($Label)) {
    throw "Could not detect a label. Pass it explicitly with -Label."
}

$entries = Join-Path $UsbRoot "loader\entries"
if (!(Test-Path $entries)) {
    throw "Boot entries not found: $entries"
}

attrib -R "$entries\*" /S /D

Get-ChildItem $entries -Filter "*.conf" | ForEach-Object {
    $text = Get-Content $_.FullName -Raw
    if ($text -match "archisolabel=") {
        $text = $text -replace "archisolabel=\S+", "archisolabel=$Label"
    } else {
        $text = $text -replace "(options\s+\S+)", "`$1 archisolabel=$Label"
    }
    Set-Content -Path $_.FullName -Value $text -NoNewline
    Write-Host "Updated $($_.Name) -> archisolabel=$Label"
}

Write-Host ""
Write-Host "Done. USB boot entries now use archisolabel=$Label" -ForegroundColor Green
