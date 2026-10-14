# SPDX-License-Identifier: GPL-3.0-or-later
# Windows desktop launcher. Extra arguments are forwarded to `flutter run`.
# Example: .\scripts\run.ps1 --release
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ecadProjectDir = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $ecadProjectDir
$ecadFlutterCommand = $null

if ($env:ECAD_FLUTTER_BIN) {
    $ecadFlutterCommand = Get-Command $env:ECAD_FLUTTER_BIN -ErrorAction SilentlyContinue
} else {
    $ecadFlutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $ecadFlutterCommand) {
        $ecadCandidates = @(
            (Join-Path $ecadProjectDir '.fvm\flutter_sdk\bin\flutter.bat'),
            (Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'),
            (Join-Path $env:USERPROFILE 'development\flutter\bin\flutter.bat'),
            'C:\src\flutter\bin\flutter.bat',
            'C:\flutter\bin\flutter.bat'
        )
        foreach ($ecadCandidate in $ecadCandidates) {
            if (Test-Path -LiteralPath $ecadCandidate -PathType Leaf) {
                $ecadFlutterCommand = Get-Command $ecadCandidate
                break
            }
        }
    }
}

if (-not $ecadFlutterCommand) {
    throw 'Flutter was not found. Install Flutter 3.47.7, add flutter\bin to PATH, or set ECAD_FLUTTER_BIN.'
}

& $ecadFlutterCommand.Source --no-version-check --suppress-analytics run -d windows @args
exit $LASTEXITCODE
