# setup-tools.ps1
# Download all external binaries for OmniTranslator into tools/win/
# Run from the repository root.
#
# Usage:
#   cd omnitranslator
#   powershell -ExecutionPolicy Bypass -File scripts\setup-tools.ps1

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $PSScriptRoot
$ToolsDir = "$RootDir\tools\win"
$null = New-Item -ItemType Directory -Force "$ToolsDir\sherpa"
$null = New-Item -ItemType Directory -Force "$ToolsDir\translateLocally"

Write-Host "=== OmniTranslator - Setup Tools ===" -ForegroundColor Cyan
Write-Host "Target: $ToolsDir"
Write-Host ""

# 1. FFmpeg (LGPL build from BtbN)
Write-Host "[1/4] Downloading FFmpeg..." -ForegroundColor Yellow
$ffmpegZip = "$env:TEMP\ffmpeg.zip"
Invoke-WebRequest -Uri "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-lgpl.zip" -OutFile $ffmpegZip
tar -xf $ffmpegZip -C "$env:TEMP"
Copy-Item "$env:TEMP\ffmpeg-master-latest-win64-lgpl\bin\ffmpeg.exe" "$ToolsDir\"
Copy-Item "$env:TEMP\ffmpeg-master-latest-win64-lgpl\bin\ffprobe.exe" "$ToolsDir\"
Remove-Item $ffmpegZip
Remove-Item "$env:TEMP\ffmpeg-master-latest-win64-lgpl" -Recurse -Force
Write-Host "  ffmpeg.exe + ffprobe.exe copied"
Write-Host ""

# 2. whisper.cpp
Write-Host "[2/4] Downloading whisper-cli..." -ForegroundColor Yellow
$whisperZip = "$env:TEMP\whisper.zip"
Invoke-WebRequest -Uri "https://github.com/ggml-org/whisper.cpp/releases/latest/download/whisper-bin-x64.zip" -OutFile $whisperZip
Expand-Archive $whisperZip -DestinationPath "$env:TEMP\whisper-bin" -Force
Get-ChildItem "$env:TEMP\whisper-bin\*" -File | Copy-Item -Destination "$ToolsDir\"
Remove-Item $whisperZip
Remove-Item "$env:TEMP\whisper-bin" -Recurse -Force
Write-Host "  whisper-cli.exe + DLLs copied"
Write-Host ""

# 3. translateLocally
Write-Host "[3/4] Downloading translateLocally..." -ForegroundColor Yellow
Write-Host "  Please download manually from: https://github.com/XapaJIaMnu/translateLocally/releases" -ForegroundColor Magenta
Write-Host "  Extract the entire folder into: $ToolsDir\translateLocally\" -ForegroundColor Magenta
Write-Host "  The .exe needs Qt DLLs from the same folder"
Write-Host ""

# 4. sherpa-onnx (source separation)
Write-Host "[4/4] Downloading sherpa-onnx..." -ForegroundColor Yellow
$apiUrl = "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest"
$release = Invoke-RestMethod -Uri $apiUrl
$tag = $release.tag_name
Write-Host "  Latest tag: $tag"

$assetName = "sherpa-onnx-$tag-win-x64-shared.tar.bz2"
$asset = $release.assets | Where-Object { $_.name -eq $assetName }
if ($null -eq $asset) {
    Write-Host "  Could not find $assetName in the release assets." -ForegroundColor Red
    Write-Host "  Available assets:" -ForegroundColor Yellow
    $release.assets | ForEach-Object { Write-Host "    - $($_.name)" }
    exit 1
}

$sherpaTbz = "$env:TEMP\sherpa.tar.bz2"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $sherpaTbz
tar -xjf $sherpaTbz -C "$env:TEMP"
$extractedDir = "$env:TEMP\sherpa-onnx-$tag-win-x64-shared"
Copy-Item "$extractedDir\bin\sherpa-onnx-offline-source-separation.exe" "$ToolsDir\sherpa\"
Get-ChildItem "$extractedDir\bin\*.dll" | Copy-Item -Destination "$ToolsDir\sherpa\"
Remove-Item $sherpaTbz
Remove-Item $extractedDir -Recurse -Force
Write-Host "  sherpa-onnx copied"
Write-Host ""

# Validation
Write-Host "=== Validation ===" -ForegroundColor Cyan
& "$ToolsDir\ffmpeg.exe" -version | Select-Object -First 1
& "$ToolsDir\whisper-cli.exe" --help | Select-Object -First 1
Write-Host ""
Write-Host "Setup complete!" -ForegroundColor Green
Write-Host "NOTE: translateLocally was NOT downloaded automatically." -ForegroundColor Yellow
Write-Host "      Download it manually from the link above." -ForegroundColor Yellow
