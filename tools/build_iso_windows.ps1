# AmiCachy — Build ISO using Docker Desktop on Windows
#
# This script runs the Arch Linux ISO build process inside a CachyOS container.
# It uses a persistent volume for the pacman cache to speed up subsequent builds.
#
# Options:
#   -Fast      Use faster zstd compression (larger ISO, 3-5x faster build)
#   -Clean     Remove work/ directory before building (full rebuild)

param(
    [switch]$Fast,
    [switch]$Clean
)

$ProjectDir = (Get-Location).Path
$DockerImage = "cachyos/cachyos:latest"

Write-Host ":: AmiCachy Windows Build (Generic x86-64 mode)..." -ForegroundColor Cyan

# Check if Docker is running
if (!(Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Docker is not installed or not in PATH." -ForegroundColor Red
    exit 1
}

# Force generic pacman.conf (stripping v3 repositories for compatibility)
$originalPacmanConf = Join-Path $ProjectDir "archiso\pacman.conf"
$filteredPacmanConf = Join-Path $env:TEMP "amicachy-pacman-generic.conf"
Write-Host ":: Preparing generic pacman.conf (no v3 repos)..." -ForegroundColor Gray
$content = Get-Content $originalPacmanConf -Raw
$content = $content -replace '(?s)\[cachyos-v3\].*?Include = /etc/pacman\.d/cachyos-v3-mirrorlist\r?\nSigLevel = Never\r?\n', ''
$content = $content -replace '(?s)\[cachyos-core-v3\].*?Include = /etc/pacman\.d/cachyos-v3-mirrorlist\r?\nSigLevel = Never\r?\n', ''
$content = $content -replace '(?s)\[cachyos-extra-v3\].*?Include = /etc/pacman\.d/cachyos-v3-mirrorlist\r?\nSigLevel = Never\r?\n', ''
Set-Content -Path $filteredPacmanConf -Value $content -NoNewline

# Determine build flags
$buildFlags = ""
if ($Clean) { $buildFlags = " --clean" }

# Show options
if ($Fast) {
    Write-Host ":: FAST mode: using zstd compression (larger ISO, much faster build)" -ForegroundColor Yellow
} else {
    Write-Host ":: FULL mode: xz compression (smallest ISO, slower build)" -ForegroundColor Cyan
}
Write-Host ":: Docker image: $DockerImage" -ForegroundColor Cyan
Write-Host ""

Write-Host ":: Pulling latest base image..." -ForegroundColor Gray
docker pull $DockerImage

# Build the bash script to run inside Docker
# We write it to a temp file to avoid PowerShell escaping issues
$bashScript = Join-Path $env:TEMP "amicachy-build.sh"

$compOverride = ""
if ($Fast) {
    $compOverride = @'
echo ":: Overriding compression to zstd (fast mode)..."
sed -i "s/'-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M'/'-comp' 'zstd' '-Xcompression-level' '3'/" /work/archiso/profiledef.sh
'@
}

$scriptContent = @"
#!/bin/bash
set -euo pipefail
echo ":: Installing archiso..."
pacman -Sy --noconfirm archiso > /dev/null

echo ":: Initializing keyring..."
pacman-key --init
pacman-key --populate cachyos archlinux

echo ":: Setting up mirrorlists..."
cp /work/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist /etc/pacman.d/
if [ -f /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist ]; then
    cp /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/
fi

$compOverride

echo ":: Running build_iso.sh$buildFlags..."
bash /work/tools/build_iso.sh$buildFlags
"@

# Write with Unix line endings
$scriptContent = $scriptContent -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($bashScript, $scriptContent, [System.Text.UTF8Encoding]::new($false))

Write-Host ":: Starting build container..." -ForegroundColor Green
Write-Host "   (Cached packages will speed up subsequent builds)" -ForegroundColor Gray

docker run --rm --privileged `
    -v "${ProjectDir}:/work" `
    -v "${filteredPacmanConf}:/work/archiso/pacman.conf" `
    -v "${bashScript}:/tmp/build.sh" `
    -v "amicachy-pkg-cache:/var/cache/pacman/pkg" `
    -w /work `
    $DockerImage `
    bash /tmp/build.sh

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host ":: Done! ISO should be in the 'out' directory." -ForegroundColor Green
    Get-ChildItem "${ProjectDir}\out\*.iso" | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | Format-Table Name, @{N="Size_MB";E={[math]::Round($_.Length/1MB)}}, LastWriteTime
} else {
    Write-Host ""
    Write-Host ":: Error during build process (exit code: $LASTEXITCODE)." -ForegroundColor Red
}
