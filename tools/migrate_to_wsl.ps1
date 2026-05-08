# AmiCachy — Migrate project to WSL for 10x faster builds
#
# This script copies the current project to the native WSL filesystem.

$WslProjectDir = "/home/$($env:USERNAME.ToLower())/AmiCachy"
$WindowsPathToWsl = "\\wsl$\Ubuntu$($WslProjectDir -replace '/', '\')"

Write-Host ":: AmiCachy WSL Migration" -ForegroundColor Cyan
Write-Host ":: Destination: $WslProjectDir" -ForegroundColor Gray

# Create directory in WSL
Write-Host ":: Creating directory in WSL..."
wsl mkdir -p $WslProjectDir

# Copy files (excluding work/ and out/ to save time)
Write-Host ":: Copying files to WSL (this is much faster than the build)..."
Get-ChildItem -Exclude "work","out",".git" | ForEach-Object {
    $dest = Join-Path $WindowsPathToWsl $_.Name
    Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n:: Migration complete!" -ForegroundColor Green
Write-Host ":: TO BUILD THE ISO FAST:" -ForegroundColor White
Write-Host "1. Open your WSL terminal (Ubuntu)."
Write-Host "2. Run these commands:"
Write-Host "   cd $WslProjectDir"
Write-Host "   ./tools/build_iso_docker.sh --generic" -ForegroundColor Yellow
Write-Host "`nYour build should now take 10-15 minutes instead of 1 hour."
