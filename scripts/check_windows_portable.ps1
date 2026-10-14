#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Smoke check the actual ZIP, not the developer's build directory.
[CmdletBinding()]
param([string]$ArchiveDirectory = 'dist')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This startup check requires Windows.'
}
$archives = @(Get-ChildItem -LiteralPath $ArchiveDirectory -Filter '*.zip' -File)
if ($archives.Count -ne 1) { throw 'Expected exactly one portable ZIP.' }
$archive = $archives[0]
$expectedHash = ((Get-Content -LiteralPath ($archive.FullName + '.sha256') -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'Portable ZIP checksum does not match.'
}
$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ('open-ecad-smoke-' + [guid]::NewGuid().ToString('N'))
$process = $null
$previousLocalAppData = $env:LOCALAPPDATA
$previousAppData = $env:APPDATA
try {
    New-Item -ItemType Directory -Path $smokeRoot | Out-Null
    Expand-Archive -LiteralPath $archive.FullName -DestinationPath $smokeRoot
    $executables = @(Get-ChildItem -LiteralPath $smokeRoot -Recurse -File -Filter 'open_ecad.exe')
    if ($executables.Count -ne 1) { throw 'Expected exactly one Open ECAD executable.' }
    $exe = $executables[0]
    $env:LOCALAPPDATA = Join-Path $smokeRoot 'profile-local'
    $env:APPDATA = Join-Path $smokeRoot 'profile-roaming'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA, $env:APPDATA | Out-Null
    $process = Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Open ECAD exited during startup: $($process.ExitCode)." }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and $process.MainWindowTitle -eq 'Open ECAD') { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero -or $process.MainWindowTitle -ne 'Open ECAD') {
        throw 'Open ECAD did not show its main window within 45 seconds.'
    }
    Start-Sleep -Seconds 5
    $process.Refresh()
    if ($process.HasExited -or -not $process.Responding) { throw 'Open ECAD failed the startup responsiveness check.' }
    Write-Host "Portable startup passed: $($process.MainWindowTitle), extracted from $($archive.Name)."
} finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
            [void]$process.WaitForExit(10000)
        }
        $process.Dispose()
    }
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:APPDATA = $previousAppData
    if (Test-Path -LiteralPath $smokeRoot) { Remove-Item -LiteralPath $smokeRoot -Recurse -Force }
}
