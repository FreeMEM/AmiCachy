# AmiCachy - Export a copy-to-USB Archiso tree from an existing ISO.
#
# Output:
#   out/amicachy-airoot-usb/
#
# Copy the contents of that directory to a FAT32/exFAT USB stick labelled
# AMICACHYUSB. This is not an ISO; it is the file tree the firmware boots.

param(
    [string]$InputIso = "",
    [string]$OutputDir = "",
    [string]$UsbLabel = "AMICACHYUSB",
    [switch]$InstallRsync
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$OutDir = Join-Path $ProjectDir "out"

if ([string]::IsNullOrWhiteSpace($InputIso)) {
    $InputIso = Get-ChildItem (Join-Path $OutDir "amicachy-*.iso") |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $OutDir "amicachy-airoot-usb"
}

$InputIso = (Resolve-Path $InputIso).Path
if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
} else {
    $OutputDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $OutputDir))
}

if ($UsbLabel.Length -gt 11) {
    throw "UsbLabel must be 11 characters or fewer for FAT/exFAT labels."
}

Write-Host ":: Exporting AmiCachy USB tree" -ForegroundColor Cyan
Write-Host "   ISO:    $InputIso" -ForegroundColor Gray
Write-Host "   Output: $OutputDir" -ForegroundColor Gray
Write-Host "   Label:  $UsbLabel" -ForegroundColor Gray

if (Test-Path $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$diskImage = $null
try {
    Write-Host ":: Mounting ISO..." -ForegroundColor Cyan
    $diskImage = Mount-DiskImage -ImagePath $InputIso -PassThru
    Start-Sleep -Seconds 1
    $volume = $diskImage | Get-Volume
    if (-not $volume.DriveLetter) {
        throw "Could not find mounted ISO drive letter."
    }
    $source = "$($volume.DriveLetter):\"

    Write-Host ":: Copying ISO file tree..." -ForegroundColor Cyan
    robocopy $source $OutputDir /E /NFL /NDL /NJH /NJS /NP | Out-Host
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed with exit code $LASTEXITCODE."
    }
    attrib -R "$OutputDir\*" /S /D
} finally {
    if ($diskImage) {
        Write-Host ":: Dismounting ISO..." -ForegroundColor Cyan
        Dismount-DiskImage -ImagePath $InputIso | Out-Null
    }
}

Write-Host ":: Setting USB label in boot entries..." -ForegroundColor Cyan
$entryDir = Join-Path $OutputDir "loader\entries"
if (Test-Path $entryDir) {
    Get-ChildItem $entryDir -Filter "*.conf" | ForEach-Object {
        $text = Get-Content $_.FullName -Raw
        $text = $text -replace 'archisolabel=\S+', "archisolabel=$UsbLabel"
        Set-Content -Path $_.FullName -Value $text -NoNewline
    }
}

if (!(Get-Command wsl -ErrorAction SilentlyContinue)) {
    throw "WSL is required to patch airootfs.sfs. Install WSL or rebuild the ISO instead."
}

$patchScript = Join-Path $ProjectDir "tools\patch_airootfs.sh"
$wslPatchScript = (& wsl wslpath -a ($patchScript -replace "\\", "/")).Trim()
$wslOutputDir = (& wsl wslpath -a ($OutputDir -replace "\\", "/")).Trim()

Write-Host ":: Patching airootfs.sfs with the AmiCachy offline installer..." -ForegroundColor Cyan
wsl -u root bash "$wslPatchScript" "$wslOutputDir"
if ($LASTEXITCODE -ne 0) {
    throw "airootfs patch failed."
}

if ($InstallRsync) {
    if (!(Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is required for -InstallRsync, but docker was not found in PATH."
    }
    $projectPrefix = $ProjectDir.TrimEnd("\") + "\"
    if (!$OutputDir.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "OutputDir must be inside the project directory when using -InstallRsync."
    }
    $relativeOutput = $OutputDir.Substring($projectPrefix.Length)
    $containerOutputDir = "/work/" + ($relativeOutput -replace "\\", "/")

    Write-Host ":: Injecting rsync into airootfs.sfs via Docker..." -ForegroundColor Cyan
    docker run --rm `
        --privileged `
        -v "${ProjectDir}:/work" `
        -w /work `
        cachyos/cachyos:latest `
        bash -lc "set -euo pipefail; pacman -Sy --noconfirm squashfs-tools pacman >/dev/null; bash /work/tools/inject_airoot_package.sh '$containerOutputDir' rsync"
    if ($LASTEXITCODE -ne 0) {
        throw "rsync injection failed."
    }
}

$readme = @"
AmiCachy USB tree
=================

Copy everything in this folder to the root of a USB stick.

Important:
- Format the USB stick as FAT32 or exFAT.
- Set the USB volume label to: $UsbLabel
- Keep the directory layout exactly as-is:
  EFI/
  loader/
  arch/

This tree boots the patched AmiCachy live environment and launches the
AmiCachy offline installer instead of Calamares.
"@
Set-Content -Path (Join-Path $OutputDir "COPY_TO_USB.txt") -Value $readme -NoNewline

Write-Host ""
Write-Host ":: Done. Copy this directory's contents to the USB root:" -ForegroundColor Green
Write-Host "   $OutputDir" -ForegroundColor Green
Write-Host "   USB label must be: $UsbLabel" -ForegroundColor Yellow
