#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
Build and package a local Windows x64 release, with app-local MSVC runtime.
.EXAMPLE
powershell -NoProfile -File .\scripts\build_windows_portable.ps1
.EXAMPLE
.\scripts\build_windows_portable.ps1 -SkipBuild -VisualCppRuntimeDirectory 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Redist\MSVC\14.44.35211\x64\Microsoft.VC143.CRT'
.NOTES
Does not publish, install software, sign binaries, or package source projects.
Dot-sourcing defines helpers without running the Windows entry point.
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$ReleaseDirectory,
    [string]$OutputDirectory,
    [string]$VisualCppRuntimeDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-EcadFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -eq 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Required file is empty or a link: $Path"
    }
}

function Assert-EcadX64Binary {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-EcadFile $Path
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Not a Windows PE binary: $Path"
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 24)) {
            throw "Invalid PE header: $Path"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "Expected a Windows x64 binary: $Path"
        }
    } finally {
        $reader.Dispose()
    }
}

function Get-EcadTreeFiles {
    # Reject links before descending, so packaging cannot follow an external tree.
    param([Parameter(Mandatory = $true)][string]$Directory)
    $root = Get-Item -LiteralPath $Directory -Force
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected an ordinary directory, not a link: $Directory"
    }
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($root.FullName)
    while ($queue.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $queue.Dequeue() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Links are not allowed in a release bundle: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
            else { $item }
        }
    }
}

function Assert-EcadRuntimeDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $item = Get-Item -LiteralPath $Directory -Force
    if (-not $item.PSIsContainer -or $item.Name -notmatch '^Microsoft\.VC[0-9]+\.CRT$' -or
        $item.Parent.Name -ne 'x64' -or $item.FullName -notmatch '[/\\]Redist[/\\]MSVC[/\\]') {
        throw 'Use the x64\Microsoft.VC*.CRT folder from an installed Visual Studio VC\Redist\MSVC directory.'
    }
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        Assert-EcadX64Binary (Join-Path $Directory $name)
    }
    foreach ($dll in Get-ChildItem -LiteralPath $Directory -Filter '*.dll' -File -Force) {
        Assert-EcadX64Binary $dll.FullName
    }
}

function Find-EcadRuntimeDirectory {
    param([string]$ExplicitDirectory)
    if ($ExplicitDirectory) {
        Assert-EcadRuntimeDirectory $ExplicitDirectory
        return (Get-Item -LiteralPath $ExplicitDirectory).FullName
    }
    $redistRoots = @()
    if ($env:VCToolsRedistDir) { $redistRoots += $env:VCToolsRedistDir }
    if ($env:VCINSTALLDIR) { $redistRoots += Join-Path $env:VCINSTALLDIR 'Redist\MSVC' }
    $vswhere = $null
    if (${env:ProgramFiles(x86)}) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if ($vswhere -and (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        $installations = @(& $vswhere -all -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
        if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery (vswhere) failed.' }
        foreach ($installation in $installations) {
            if ($installation.Trim()) { $redistRoots += Join-Path $installation.Trim() 'VC\Redist\MSVC' }
        }
    }
    $candidates = @()
    foreach ($root in ($redistRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        # VCToolsRedistDir points at one version; VC\Redist\MSVC contains versions.
        $versionDirectories = @((Get-Item -LiteralPath $root)) + @(Get-ChildItem -LiteralPath $root -Directory)
        foreach ($versionDirectory in $versionDirectories) {
            $x64 = Join-Path $versionDirectory.FullName 'x64'
            if (-not (Test-Path -LiteralPath $x64 -PathType Container)) { continue }
            foreach ($crt in Get-ChildItem -LiteralPath $x64 -Directory -Filter 'Microsoft.VC*.CRT') {
                $dll = Join-Path $crt.FullName 'msvcp140.dll'
                if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { continue }
                $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
                $candidates += [PSCustomObject]@{
                    Path = $crt.FullName
                    Version = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
                }
            }
        }
    }
    foreach ($candidate in ($candidates | Sort-Object Version -Descending)) {
        try {
            Assert-EcadRuntimeDirectory $candidate.Path
            return $candidate.Path
        } catch {
            Write-Verbose "Skipping incomplete MSVC runtime at $($candidate.Path): $_"
        }
    }
    throw 'A complete x64 MSVC runtime was not found. Install the Visual Studio Desktop development with C++ workload, or pass -VisualCppRuntimeDirectory. No ZIP was created.'
}

function Get-EcadProjectVersion {
    param([Parameter(Mandatory = $true)][string]$ProjectDirectory)
    $pubspec = Get-Content -LiteralPath (Join-Path $ProjectDirectory 'pubspec.yaml') -Raw
    $match = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)\s*(?:#.*)?$')
    if (-not $match.Success) { throw 'pubspec.yaml must contain a plain semantic version.' }
    return $match.Groups[1].Value
}

function Get-EcadSourceProvenance {
    param([Parameter(Mandatory = $true)][string]$ProjectDirectory)
    if ($env:GITHUB_SHA -match '^[0-9a-fA-F]{40}$' -and
        $env:GITHUB_REPOSITORY -match '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' -and
        $env:GITHUB_SERVER_URL -eq 'https://github.com') {
        return "Source commit: $($env:GITHUB_SHA)`r`nSource: $($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/tree/$($env:GITHUB_SHA)"
    }
    $source = 'Source: local project sources; obtain the corresponding source from the author.'
    if (Test-Path -LiteralPath (Join-Path $ProjectDirectory '.git')) {
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($git) {
            try {
                $commit = & $git.Source -C $ProjectDirectory rev-parse --verify HEAD 2>$null
                if ($LASTEXITCODE -eq 0 -and $commit -match '^[0-9a-fA-F]{40}$') {
                    $source += "`r`nLocal base commit: $commit (may include additional local changes)."
                }
            } catch { Write-Verbose 'No local Git commit is available for provenance.' }
        }
    }
    return $source
}

function New-EcadWindowsPortablePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory
    )
    $version = Get-EcadProjectVersion $ProjectDirectory
    $archiveName = "open-ecad-windows-native-$version-x64"
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    $zipPath = Join-Path $output "$archiveName.zip"
    $hashPath = "$zipPath.sha256"
    if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $hashPath)) {
        throw "An output already exists: $zipPath (or its SHA256 file). Use another -OutputDirectory; existing artifacts are not overwritten."
    }

    $release = Get-Item -LiteralPath $ReleaseDirectory -Force
    if (-not $release.PSIsContainer -or ($release.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The release directory must be an ordinary directory.'
    }
    $releasePrefix = $release.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($output -eq $release.FullName -or $output.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputDirectory must be outside ReleaseDirectory so the bundle cannot include its own staging files.'
    }
    # Allow only runtime files at the top level; ignore known compiler byproducts.
    # New output layouts fail visibly instead of quietly omitting plugin assets.
    foreach ($item in Get-ChildItem -LiteralPath $release.FullName -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Release contains a link: $($item.Name)" }
        if ($item.PSIsContainer) {
            if ($item.Name -ne 'data') { throw "Unexpected release directory: $($item.Name). Review the packaging layout first." }
        } elseif ($item.Name -ne 'open_ecad.exe' -and $item.Extension -notin @('.dll', '.pdb', '.lib', '.exp', '.ilk')) {
            throw "Unexpected release file: $($item.Name). Only application runtime files can be packaged."
        }
    }
    $exe = Join-Path $release.FullName 'open_ecad.exe'
    Assert-EcadX64Binary $exe
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $exeInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
        if ($exeInfo.IsDebug -or $exeInfo.ProductVersion -ne $version) {
            throw "EXE version '$($exeInfo.ProductVersion)' does not match pubspec '$version', or this is a debug EXE. Build a new release."
        }
    }
    foreach ($name in @('flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')) {
        Assert-EcadFile (Join-Path $release.FullName $name)
    }
    $pluginFile = Join-Path $ProjectDirectory 'windows/flutter/generated_plugins.cmake'
    $pluginText = Get-Content -LiteralPath $pluginFile -Raw
    $pluginList = [regex]::Match($pluginText, '(?s)list\(APPEND FLUTTER_PLUGIN_LIST\s*(.*?)\)')
    if (-not $pluginList.Success) { throw 'Cannot verify Windows plugin list; run flutter build windows --release first.' }
    foreach ($plugin in ($pluginList.Groups[1].Value -split '\s+' | Where-Object { $_ })) {
        if ($plugin -notmatch '^[a-zA-Z0-9_]+$') { throw "Unexpected generated plugin entry: $plugin" }
        Assert-EcadFile (Join-Path $release.FullName "${plugin}_plugin.dll")
    }
    $assetDirectory = Join-Path $release.FullName 'data/flutter_assets'
    if (-not ((Test-Path -LiteralPath (Join-Path $assetDirectory 'NOTICES.Z') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $assetDirectory 'NOTICES') -PathType Leaf))) {
        throw 'Flutter package license asset (NOTICES.Z or NOTICES) is missing.'
    }
    foreach ($noticeName in @('NOTICES.Z', 'NOTICES')) {
        $noticePath = Join-Path $assetDirectory $noticeName
        if (Test-Path -LiteralPath $noticePath -PathType Leaf) { Assert-EcadFile $noticePath }
    }
    $dataFiles = @(Get-EcadTreeFiles (Join-Path $release.FullName 'data'))
    foreach ($file in $dataFiles) {
        if ($file.Extension -in @('.pdf', '.oecad', '.dart', '.py', '.ps1', '.bat', '.cmd', '.sh', '.pem', '.key') -or $file.Name -eq '.env') {
            throw "Unexpected document, source or private asset in data: $($file.Name). Review assets before packaging."
        }
        if ($file.Extension -eq '.dll') { Assert-EcadX64Binary $file.FullName }
    }
    Assert-EcadRuntimeDirectory $RuntimeDirectory
    foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'assets/fonts/LICENSE.txt')) {
        Assert-EcadFile (Join-Path $ProjectDirectory $name)
    }
    [void][IO.Directory]::CreateDirectory($output)
    $staging = Join-Path $output ('.open-ecad-native-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    $hashPublished = $false
    $zipPublished = $false
    try {
        $bundle = Join-Path $staging $archiveName
        [void][IO.Directory]::CreateDirectory($bundle)
        Copy-Item -LiteralPath $exe -Destination $bundle
        foreach ($dll in Get-ChildItem -LiteralPath $release.FullName -Filter '*.dll' -File -Force) {
            Assert-EcadX64Binary $dll.FullName
            Copy-Item -LiteralPath $dll.FullName -Destination $bundle
        }
        Copy-Item -LiteralPath (Join-Path $release.FullName 'data') -Destination $bundle -Recurse
        foreach ($dll in Get-ChildItem -LiteralPath $RuntimeDirectory -Filter '*.dll' -File -Force) {
            # The installed, selected redist is authoritative if a prior build
            # already copied a runtime DLL into its release output.
            Copy-Item -LiteralPath $dll.FullName -Destination $bundle -Force
        }
        foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) {
            Copy-Item -LiteralPath (Join-Path $ProjectDirectory $name) -Destination $bundle
        }
        $licenses = Join-Path $bundle 'licenses'
        [void][IO.Directory]::CreateDirectory($licenses)
        Copy-Item -LiteralPath (Join-Path $ProjectDirectory 'assets/fonts/LICENSE.txt') -Destination (Join-Path $licenses 'NotoSans-LICENSE.txt')
        $utf8 = [Text.UTF8Encoding]::new($true)
        $sourceProvenance = Get-EcadSourceProvenance $ProjectDirectory
        $reviewerText = @"
Open ECAD $version - zkušební nativní verze pro Windows x64

1. Rozbalte celý ZIP do vlastní složky. Zachovejte EXE, všechny DLL a složku data pohromadě.
2. Spusťte open_ecad.exe z rozbalené složky. Instalace ani administrátorská práva nejsou potřeba.
3. V nabídce Soubor zvolte Otevřít ukázkový projekt. Zkuste upravit přístroj, propojit vodič, vrátit změnu a exportovat PDF/SVG.
4. Ctrl+S uloží .oecad; Ctrl+O jej znovu otevře. Vlastní práci ukládejte do samostatných souborů.
5. Poznamenejte si verzi Windows, škálování obrazovky, kroky k případné chybě a očekávané chování.

Balík obsahuje knihovny Flutteru a Microsoft C++ přímo vedle aplikace. Flutter, Visual Studio ani Python se pro běžnou práci neinstalují.
Import PDF vyžaduje zvlášť připravený místní převodník s Pythonem/PyMuPDF; tento ZIP jej neobsahuje. Export PDF funguje bez něj. Již převedený .oecad lze otevřít přímo.
Aplikace ukládá nastavení a malou pracovní kopii do uživatelského profilu Windows. Přenosná je aplikace; nastavení se mezi počítači nepřenáší automaticky.
Jde o nepodepsaný prototyp. Případnou zprávu Windows při spuštění předejte autorovi spolu s názvem a SHA256 balíku.

Licence aplikace: GPL-3.0-or-later (LICENSE). Další licence: THIRD_PARTY_NOTICES.md, licenses a data/flutter_assets/NOTICES[.Z].
$sourceProvenance
"@
        [IO.File]::WriteAllText((Join-Path $bundle 'CTETE-NEJDRIV.txt'), $reviewerText, $utf8)
        $runtimeInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $RuntimeDirectory 'msvcp140.dll'))
        $runtimeNames = (Get-ChildItem -LiteralPath $RuntimeDirectory -Filter '*.dll' -File | Select-Object -ExpandProperty Name | Sort-Object) -join ', '
        $runtimeNotice = @"
Microsoft Visual C++ runtime (x64), version $($runtimeInfo.FileVersion)
Copyright Microsoft Corporation. These binaries retain Microsoft's license;
they are not covered by the application's GPL license.
Copied from the installed Visual Studio redistributable CRT directory.
Files: $runtimeNames
Redistribution terms and file lists:
https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files
Application-local deployment:
https://learn.microsoft.com/en-us/cpp/windows/walkthrough-deploying-a-visual-cpp-application-to-an-application-local-folder
Runtime updates require a new application bundle with updated runtime files.
"@
        [IO.File]::WriteAllText((Join-Path $licenses 'Microsoft-Visual-Cpp-runtime.txt'), $runtimeNotice, $utf8)
        $packageInfo = "Open ECAD $version`r`nTarget: Windows x64 release`r`nPackaged UTC: $([DateTime]::UtcNow.ToString('o'))`r`n$sourceProvenance`r`nPackaging validates file layout and x64 PE headers; it does not test application startup.`r`n"
        [IO.File]::WriteAllText((Join-Path $bundle 'PACKAGE-INFO.txt'), $packageInfo, $utf8)

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $temporaryZip = Join-Path $staging "$archiveName.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $temporaryZip, [IO.Compression.CompressionLevel]::Optimal, $true)
        $archive = [IO.Compression.ZipFile]::OpenRead($temporaryZip)
        try {
            $files = @(Get-EcadTreeFiles $bundle)
            $entries = @($archive.Entries | Where-Object { $_.Name })
            if ($entries.Count -ne $files.Count) { throw 'ZIP verification failed: file count differs.' }
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($bundle.Length + 1).Replace('\', '/')
                $entryName = "$archiveName/$relative"
                $entry = $archive.GetEntry($entryName)
                if ($null -eq $entry -or $entry.Length -ne $file.Length) { throw "ZIP verification failed: $entryName" }
            }
        } finally { $archive.Dispose() }
        $digest = (Get-FileHash -LiteralPath $temporaryZip -Algorithm SHA256).Hash.ToLowerInvariant()
        $temporaryHash = Join-Path $staging "$archiveName.zip.sha256"
        [IO.File]::WriteAllText($temporaryHash, "$digest  $archiveName.zip`r`n", [Text.Encoding]::ASCII)
        # Publish the ZIP last. File.Move never replaces an existing artifact.
        [IO.File]::Move($temporaryHash, $hashPath)
        $hashPublished = $true
        [IO.File]::Move($temporaryZip, $zipPath)
        $zipPublished = $true
        Write-Host "Created: $zipPath"
        Write-Host "SHA256:  $digest"
        return $zipPath
    } finally {
        if ($hashPublished -and -not $zipPublished) { Remove-Item -LiteralPath $hashPath -Force }
        # Only this invocation's unique staging directory is ever removed.
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script builds/packages native Windows binaries on Windows only. Linux checks cannot produce a tested Windows release.'
}
$hostArchitecture = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $hostArchitecture = $env:PROCESSOR_ARCHITEW6432 }
if ($hostArchitecture -ne 'AMD64') { throw 'This packaging script requires an x64 Windows host (AMD64/Intel 64).' }
if ($ReleaseDirectory -and -not $SkipBuild) { throw '-ReleaseDirectory is only valid with -SkipBuild.' }
$project = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $project 'artifacts' }
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $project 'build/windows/x64/runner/Release' }
$runtime = Find-EcadRuntimeDirectory $VisualCppRuntimeDirectory
if (-not $SkipBuild) {
    $flutterName = 'flutter.bat'
    if ($env:ECAD_FLUTTER_BIN) { $flutterName = $env:ECAD_FLUTTER_BIN }
    $flutter = Get-Command $flutterName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $flutter) { throw 'Flutter was not found. Install Flutter 3.47.7 and add its bin directory to PATH, or set ECAD_FLUTTER_BIN.' }
    Push-Location -LiteralPath $project
    try {
        & $flutter.Source --no-version-check --suppress-analytics pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed; no package was created.' }
        & $flutter.Source --no-version-check --suppress-analytics build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed; no package was created.' }
    } finally { Pop-Location }
}
New-EcadWindowsPortablePackage -ProjectDirectory $project -ReleaseDirectory $ReleaseDirectory -OutputDirectory $OutputDirectory -RuntimeDirectory $runtime
