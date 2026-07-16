# Baixa as bibliotecas nativas construidas por CI (build-slimt.yml, P1 da
# revisao de pendencias de 2026-07-16) e coloca em
# app/android/app/src/main/jniLibs/<abi>/ -- path padrao do Android Gradle
# Plugin, empacotado automaticamente no APK sem qualquer mudanca em
# build.gradle.kts.
#
# Por que um script de fetch em vez de comitar o binario: .so nao entra no
# git (bloat de repo, historico permanente de binario). O hash pinado abaixo
# E a prova de proveniencia -- mesmo padrao do ModelCatalog.android()
# (model_manager.dart): sem ele, uma Release comprometida ou um MITM
# entregaria uma .so arbitraria pro APK sem ninguem perceber.
#
# Extensivel: quando a D3.3 empacotar o AAR do FFmpegKitNext (AT-3), ele
# entra como uma nova entrada em $nativeLibs, nao um script novo.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File tool/android/fetch_native_libs.ps1
#
# ASCII-only (mesmo motivo do tool/verify.ps1): PowerShell 5.1 misreads
# UTF-8 sem BOM com acentos.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$nativeLibs = @(
    @{
        Name = 'libslimt.so'
        # Publicado por .github/workflows/build-slimt.yml (Release
        # permanente na propria tag, nao o artifact expiravel do
        # upload-artifact). Atualizar os dois campos abaixo juntos quando
        # rodar um novo build-slimt (nova tag at-slimt-build-N).
        Url = 'https://github.com/luistiagos/ominitranslator/releases/download/at-slimt-build-4/libslimt.so'
        Sha256 = '4e2fd7229d7b7f456e1f5b7e2884965acdd7b6f67d8a777105f3bfa67a475f46'
        Abi = 'arm64-v8a'
    }
)

foreach ($lib in $nativeLibs) {
    $destDir = Join-Path $repo "app\android\app\src\main\jniLibs\$($lib.Abi)"
    $destFile = Join-Path $destDir $lib.Name
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    Write-Host "Baixando $($lib.Name) de $($lib.Url) ..."
    Invoke-WebRequest -Uri $lib.Url -OutFile $destFile -UseBasicParsing

    $actual = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $lib.Sha256) {
        Remove-Item $destFile -Force
        Write-Error "$($lib.Name): SHA-256 nao bate. esperado=$($lib.Sha256) obtido=$actual"
        exit 1
    }
    Write-Host "OK: $($lib.Name) verificado (sha256=$actual) em $destFile"
}
