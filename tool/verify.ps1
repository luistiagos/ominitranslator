# Local project gate (decision D-d: no CI).
#
# Runs what a CI would: analyze + tests for the engine and the app, and fails
# if the engine test count regresses. Usage:
#   powershell -ExecutionPolicy Bypass -File tool/verify.ps1
#
# ASCII-only on purpose: Windows PowerShell 5.1 misreads a UTF-8-no-BOM script
# with accented characters. Flutter lives at C:\tools\flutter (off PATH here).

# 'Continue', not 'Stop': with 2>&1 on a native exe, PS 5.1 wraps each stderr
# line as a NativeCommandError. Under 'Stop' that throws; we want the text.
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$dart = 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe'
$flutter = 'C:\tools\flutter\bin\flutter.bat'

# Engine test floor: the gate fails below this. Raise it as tests are added,
# to lock coverage against regressions.
$minEngineTests = 368

$failures = @()

function Section($name) { Write-Host "`n=== $name ===" -ForegroundColor Cyan }

# --- engine: analyze -------------------------------------------------------
Section 'engine - dart analyze'
Push-Location "$repo\packages\dubbing_engine"
$analyze = & $dart analyze 2>&1
$problems = $analyze | Select-String -Pattern ' error | warning '
if ($problems) {
  $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  $failures += 'engine analyze has error/warning'
} else {
  Write-Host '  ok - no error/warning' -ForegroundColor Green
}
Pop-Location

# --- engine: tests ---------------------------------------------------------
Section 'engine - dart test'
Push-Location "$repo\packages\dubbing_engine"
$testOut = & $dart test 2>&1
$passLine = $testOut | Select-String -Pattern '\+(\d+): All tests passed' | Select-Object -Last 1
if (-not $passLine) {
  $testOut | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }
  $failures += 'engine: tests failed'
} else {
  $count = [int]($passLine.Matches[0].Groups[1].Value)
  if ($count -lt $minEngineTests) {
    Write-Host "  REGRESSION: $count tests (floor: $minEngineTests)" -ForegroundColor Red
    $failures += "engine: $count tests below floor $minEngineTests"
  } else {
    Write-Host "  ok - $count tests passed (floor: $minEngineTests)" -ForegroundColor Green
  }
}
Pop-Location

# --- app: analyze (error/warning only; the 3 known info lints are ignored) --
Section 'app - flutter analyze'
Push-Location "$repo\app"
$appAnalyze = & $flutter analyze 2>&1
$appProblems = $appAnalyze | Select-String -Pattern ' error | warning '
if ($appProblems) {
  $appProblems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  $failures += 'app analyze has error/warning'
} else {
  Write-Host '  ok - no error/warning (pre-existing info lints ignored)' -ForegroundColor Green
}
Pop-Location

# --- app: tests ------------------------------------------------------------
Section 'app - flutter test'
Push-Location "$repo\app"
$appTest = & $flutter test 2>&1
if ($appTest | Select-String -Pattern 'All tests passed') {
  Write-Host '  ok' -ForegroundColor Green
} else {
  $appTest | Select-Object -Last 6 | ForEach-Object { Write-Host "  $_" }
  $failures += 'app: tests failed'
}
Pop-Location

# --- verdict ---------------------------------------------------------------
Section 'result'
if ($failures.Count -eq 0) {
  Write-Host 'VERIFY OK' -ForegroundColor Green
  exit 0
} else {
  $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
  exit 1
}
