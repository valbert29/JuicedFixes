# JuicedFixes: MSBuild Release|x86 via VsDevCmd (use VS Code task "JuicedFixes: Release x86").
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Set-Location $repoRoot

function Test-HasMsbuildAndMsvc([string] $Root) {
    if (-not $Root) { return $false }
    $dev = Join-Path $Root 'Common7\Tools\VsDevCmd.bat'
    $msb = Join-Path $Root 'MSBuild\Current\Bin\MSBuild.exe'
    if (-not (Test-Path $dev) -or -not (Test-Path $msb)) { return $false }
    $msvcBase = Join-Path $Root 'VC\Tools\MSVC'
    if (-not (Test-Path $msvcBase)) { return $false }
    $verDir = Get-ChildItem $msvcBase -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.Name } -Descending | Select-Object -First 1
    if (-not $verDir) { return $false }
    $cl1 = Join-Path $verDir.FullName 'bin\Hostx64\x86\cl.exe'
    $cl2 = Join-Path $verDir.FullName 'bin\Hostx86\x86\cl.exe'
    return (Test-Path $cl1) -or (Test-Path $cl2)
}

function Get-PlatformToolset([string] $Root) {
    # Важно: имя каталога MSBuild\Microsoft\VC\v180 — это НЕ значение PlatformToolset.
    # Реальные toolset лежат в ...\VC\v*\Platforms\Win32\PlatformToolsets\v143|v145|...
    $bestName = $null
    $bestNum = -1
    $vcRoots = Join-Path $Root 'MSBuild\Microsoft\VC'
    if (-not (Test-Path $vcRoots)) { return $null }
    Get-ChildItem $vcRoots -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pts = Join-Path $_.FullName 'Platforms\Win32\PlatformToolsets'
        if (-not (Test-Path $pts)) { return }
        Get-ChildItem $pts -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^v(\d+)$') {
                $n = [int]$Matches[1]
                $props = Join-Path $_.FullName 'Toolset.props'
                if (-not (Test-Path $props)) { return }
                if ($n -gt $bestNum) {
                    $bestNum = $n
                    $bestName = $_.Name
                }
            }
        }
    }
    return $bestName
}

function Find-VisualStudioRoot {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }

    # 1) Typical full VS / Build Tools with C++ workload (strict component IDs).
    $candidates = @(
        @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.MSBuild', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'),
        @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Workload.NativeDesktop', '-property', 'installationPath'),
        @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Workload.VCTools', '-property', 'installationPath'),
        @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.MSBuild', '-property', 'installationPath')
    )
    foreach ($args in $candidates) {
        $p = & $vswhere @args 2>$null
        if ($p -and (Test-HasMsbuildAndMsvc $p)) { return $p.Trim() }
    }

    # 2) Prefer newest install that has MSBuild + MSVC (by VsDevCmd.bat timestamp).
    $allPaths = @(
        & $vswhere -all -products * -property installationPath 2>$null |
        Where-Object { $_ } |
        ForEach-Object { $_.Trim() } |
        Select-Object -Unique
    )
    $ranked = @(
        foreach ($p in $allPaths) {
            if (-not (Test-HasMsbuildAndMsvc $p)) { continue }
            $dev = Join-Path $p 'Common7\Tools\VsDevCmd.bat'
            $t = (Get-Item $dev -ErrorAction SilentlyContinue).LastWriteTimeUtc
            [PSCustomObject]@{ Path = $p; Time = $t }
        }
    )
    $best = $ranked | Sort-Object Time -Descending | Select-Object -First 1
    if ($best) { return $best.Path }

    # 3) Default disk paths (when Installer exists but vswhere returns nothing useful).
    $roots = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\18\BuildTools",
        "${env:ProgramFiles}\Microsoft Visual Studio\18\Enterprise",
        "${env:ProgramFiles}\Microsoft Visual Studio\18\Professional",
        "${env:ProgramFiles}\Microsoft Visual Studio\18\Community",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools",
        "${env:ProgramFiles}\Microsoft Visual Studio\2019\Enterprise",
        "${env:ProgramFiles}\Microsoft Visual Studio\2019\Professional",
        "${env:ProgramFiles}\Microsoft Visual Studio\2019\Community",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools"
    )
    foreach ($p in $roots) {
        if (Test-HasMsbuildAndMsvc $p) { return $p }
    }

    return $null
}

$inst = Find-VisualStudioRoot
if (-not $inst) {
    Write-Host 'No usable Visual Studio / Build Tools found (need MSBuild + MSVC with x86 cl.exe).'
    Write-Host ''
    Write-Host 'Fix: open "Visual Studio Installer" -> Modify your VS or Build Tools ->'
    Write-Host '  enable workload "Desktop development with C++" (or MSVC v143 + Windows SDK), then Install.'
    Write-Host 'Download Build Tools: https://visualstudio.microsoft.com/visual-cpp-build-tools/'
    Write-Host 'In VS Code you can run task: "Open MSVC Build Tools download page".'
    exit 1
}

$devCmd = Join-Path $inst 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $devCmd)) {
    Write-Host "VsDevCmd.bat not found: $devCmd"
    exit 1
}

Write-Host "Using Visual Studio at: $inst"

$toolset = Get-PlatformToolset $inst
if (-not $toolset) {
    Write-Host 'No Win32 PlatformToolset found ( ...\MSBuild\Microsoft\VC\v*\Platforms\Win32\PlatformToolsets\v* ).'
    Write-Host 'Install workload "Desktop development with C++" (MSVC + Windows SDK).'
    exit 1
}
Write-Host "PlatformToolset (from PlatformToolsets): $toolset"

if (-not (Test-Path "$repoRoot\3rdparty\injector\include\injector\injector.hpp")) {
    Write-Host 'Git submodules missing. Run: git submodule update --init --recursive'
    exit 1
}

$msbArgs = @(
    'JuicedFixes.sln',
    '/p:Configuration=Release',
    '/p:Platform=x86',
    "/p:PlatformToolset=$toolset",
    '/m',
    '/v:m'
)

$cmdLine = "call `"$devCmd`" -arch=x86 -host_arch=amd64 && cd /d `"$repoRoot`" && msbuild " + ($msbArgs -join ' ')
$code = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmdLine) -Wait -PassThru -NoNewWindow
exit $code.ExitCode
