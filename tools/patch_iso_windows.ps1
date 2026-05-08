# AmiCachy - Patch an existing ISO using Docker Desktop on Windows.
#
# This avoids a full archiso rebuild. It extracts the generated ISO, patches the
# squashfs filesystem, installs only missing automount packages if needed, and
# re-emits a patched ISO under out/.

param(
    [string]$InputIso = "",
    [string]$OutputIso = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

function Get-ProjectRelativePath {
    param([string]$Path)

    $projectFull = [System.IO.Path]::GetFullPath($ProjectDir).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $projectFull + [System.IO.Path]::DirectorySeparatorChar

    if ($pathFull -ieq $projectFull) {
        return ""
    }
    if (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must be inside the project directory: $Path"
    }

    return $pathFull.Substring($prefix.Length)
}

function Convert-ToContainerPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $resolved = Resolve-Path $Path
    $relative = Get-ProjectRelativePath $resolved.Path

    return "/work/" + ($relative -replace "\\", "/")
}

$patchArgs = @()
$containerInput = Convert-ToContainerPath $InputIso
$containerOutput = ""

if ($containerInput) {
    $patchArgs += "--input=$containerInput"
}

if ($OutputIso) {
    if ([System.IO.Path]::IsPathRooted($OutputIso)) {
        $fullOutput = [System.IO.Path]::GetFullPath($OutputIso)
    } else {
        $fullOutput = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $OutputIso))
    }
    $relativeOutput = Get-ProjectRelativePath $fullOutput
    $containerOutput = "/work/" + ($relativeOutput -replace "\\", "/")
    $patchArgs += "--output=$containerOutput"
}

Write-Host ":: Patching AmiCachy ISO in Docker container..." -ForegroundColor Cyan
Write-Host "   Project: $ProjectDir" -ForegroundColor Gray
if ($InputIso) { Write-Host "   Input:   $InputIso" -ForegroundColor Gray }
if ($OutputIso) { Write-Host "   Output:  $OutputIso" -ForegroundColor Gray }

docker run --rm `
    --privileged `
    -v "${ProjectDir}:/work" `
    -w /work `
    cachyos/cachyos:latest `
    bash -lc @"
        set -e
        echo ":: Installing patch tools..."
        pacman -Sy --noconfirm xorriso squashfs-tools pacman > /dev/null
        cp /work/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist /etc/pacman.d/
        if [ -f /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist ]; then
            cp /work/archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist /etc/pacman.d/
        fi
        bash /work/tools/patch_iso.sh $($patchArgs -join ' ')
"@

if ($LASTEXITCODE -ne 0) {
    throw "ISO patch failed."
}

Write-Host ":: Done. Patched ISO should be in out/." -ForegroundColor Green
Get-ChildItem "${ProjectDir}\out\*.iso" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 3 Name, @{N="Size_MB";E={[math]::Round($_.Length/1MB)}}, LastWriteTime |
    Format-Table
