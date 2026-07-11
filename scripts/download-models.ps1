# download-models.ps1
# Download all ML models for OmniTranslator.
# Run from the repository root after setup-tools.ps1.
#
# Usage:
#   cd omnitranslator
#   powershell -ExecutionPolicy Bypass -File scripts\download-models.ps1

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $PSScriptRoot
$ModelsDir = "$env:APPDATA\omnitranslator\models"

Write-Host "=== OmniTranslator — Download Models ===" -ForegroundColor Cyan
Write-Host "Target: $ModelsDir"
Write-Host ""

$models = @(
    @{ Id = "whisper-small-q5_1"; Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin"; Size = "190 MB" },
    @{ Id = "whisper-base-q5_1"; Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin"; Size = "60 MB" },
    @{ Id = "spleeter-2stems-fp16"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems-fp16.tar.bz2"; Size = "40 MB" },
    @{ Id = "piper-pt-br"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-faber-medium.tar.bz2"; Size = "65 MB" },
    @{ Id = "piper-es"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-sharvard-medium.tar.bz2"; Size = "65 MB" },
    @{ Id = "piper-en"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2"; Size = "65 MB" },
    @{ Id = "piper-de-thorsten"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-thorsten-medium.tar.bz2"; Size = "68 MB" },
    @{ Id = "piper-fr-siwis"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-fr_FR-siwis-medium.tar.bz2"; Size = "68 MB" },
    @{ Id = "piper-pl-gosia"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pl_PL-gosia-medium.tar.bz2"; Size = "68 MB" },
    @{ Id = "piper-cs-jirka"; Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-cs_CZ-jirka-medium.tar.bz2"; Size = "68 MB" }
)

foreach ($m in $models) {
    $destDir = "$ModelsDir\$($m.Id)"
    $destFile = if ($m.Id -like "whisper-*") { "$destDir\$($m.Id).bin" } else { "$destDir\model.tar.bz2" }

    if (Test-Path $destDir) {
        Write-Host "  [$($m.Id)] already exists, skipping" -ForegroundColor Gray
        continue
    }

    Write-Host "  [$($m.Id)] downloading ($($m.Size))..." -ForegroundColor Yellow
    $null = New-Item -ItemType Directory -Force $destDir

    try {
        Invoke-WebRequest -Uri $m.Url -OutFile "$destDir\temp" -UseBasicParsing
        if ($m.Id -like "whisper-*") {
            Move-Item "$destDir\temp" "$destDir\$($m.Id).bin" -Force
        } else {
            # tar.bz2 extraction
            Move-Item "$destDir\temp" "$destDir\model.tar.bz2" -Force
            tar -xjf "$destDir\model.tar.bz2" -C $destDir
            # Move contents from subfolder to root
            $subdirs = Get-ChildItem -Directory $destDir
            foreach ($sub in $subdirs) {
                if ($sub.Name -ne "." -and $sub.Name -ne "..") {
                    Get-ChildItem $sub.FullName | Move-Item -Destination $destDir -Force
                    Remove-Item $sub.FullName -Recurse -Force
                }
            }
            Remove-Item "$destDir\model.tar.bz2" -Force
        }
        Write-Host "  [$($m.Id)] done" -ForegroundColor Green
    } catch {
        Write-Host "  [$($m.Id)] FAILED: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Model download complete!" -ForegroundColor Cyan
Write-Host "NOTE: Translation models (en-pt-tiny etc.) will be downloaded automatically" -ForegroundColor Yellow
Write-Host "      by translateLocally when you first run a translation." -ForegroundColor Yellow
