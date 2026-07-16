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
# Extensivel: destino difere por tipo. .so vai pra jniLibs/<abi>/ (auto-
# empacotado pelo Android Gradle Plugin, sem mudanca de build.gradle.kts).
# .aar vai pra app/libs/ (referenciado explicitamente por
# `implementation(files("libs/..."))` em app/build.gradle.kts -- e o caso do
# FFmpegKitNext (AT-3/F2, revisao de 2026-07-16): AAR nao e auto-empacotado
# como .so solto, precisa da declaracao de dependencia).
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File tool/android/fetch_native_libs.ps1
#
# ASCII-only (mesmo motivo do tool/verify.ps1): PowerShell 5.1 misreads
# UTF-8 sem BOM com acentos.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-VerifiedFile {
    param($Name, $Url, $Sha256, $DestFile, $DestDir)
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

    Write-Host "Baixando $Name de $Url ..."
    Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing

    $actual = (Get-FileHash -Path $DestFile -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256) {
        Remove-Item $DestFile -Force
        Write-Error "${Name}: SHA-256 nao bate. esperado=$Sha256 obtido=$actual"
        exit 1
    }
    Write-Host "OK: $Name verificado (sha256=$actual) em $DestFile"
}

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
    Get-VerifiedFile -Name $lib.Name -Url $lib.Url -Sha256 $lib.Sha256 -DestFile $destFile -DestDir $destDir
}

$aars = @(
    @{
        Name = 'ffmpeg-kit-next.aar'
        # Publicado por .github/workflows/build-ffmpeg-kit-next.yml (Release
        # permanente na propria tag, F1 da revisao de 2026-07-16 -- mesmo
        # padrao do build-slimt.yml). Atualizar os dois campos abaixo juntos
        # quando rodar um novo build (nova tag at3-ffmpeg-build-N).
        Url = 'https://github.com/luistiagos/ominitranslator/releases/download/at3-ffmpeg-build-7/ffmpeg-kit.aar'
        Sha256 = '0f2f65c8a2ef1306337aa120880766910dc008ab7363e8a637b3e42d57131055'
    }
)

foreach ($aar in $aars) {
    $destDir = Join-Path $repo "app\android\app\libs"
    $destFile = Join-Path $destDir $aar.Name
    Get-VerifiedFile -Name $aar.Name -Url $aar.Url -Sha256 $aar.Sha256 -DestFile $destFile -DestDir $destDir
}
