<#
.SYNOPSIS
    Unpack the native library of every locked addon that has one (dot-sim): the Windows
    twin of tools/fetch-natives.sh.

.DESCRIPTION
    Not a second copy of the fetcher. The download, the SHA256SUMS.natives check, the stamp
    and the keep-a-local-build rule are dot-bootstrap's Fetch-Natives; this lifts that
    function (and the helpers it needs) out of bootstrap.ps1 at run time, by parsing it,
    and supplies only what is specific to here: the pin comes from addons.lock instead of
    a game's .gitignore, and the place is the repository addons\<addon> links into.
    bootstrap.ps1 is looked for in $env:DOT_BOOTSTRAP, beside this checkout and in
    addons\.repos\; with none, it is cloned shallow into addons\.repos\ (unless -NoClone).

    Never run for export-web: a .gdextension in a web build stops every script.
    $env:DOT_NATIVES = 'none' skips everything; a platform with no zip warns and the
    GDScript twins run.

.EXAMPLE
    .\tools\fetch-natives.ps1
    .\tools\fetch-natives.ps1 -Platform windows-x86_64
#>
[CmdletBinding()]
param(
    [string[]] $Platform = @(),
    [switch] $NoClone
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$NativeRepos = @('dot-sim')          # addons that publish a platform zip
if ($env:DOT_NATIVES -eq 'none') { exit 0 }
if ($env:TMC_NO_CLONE) { $NoClone = $true }

$boot = $null
foreach ($c in @($env:DOT_BOOTSTRAP, (Join-Path $Root '..\dot-bootstrap'), (Join-Path $Root 'addons\.repos\dot-bootstrap'))) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'bootstrap.ps1'))) { $boot = Join-Path $c 'bootstrap.ps1'; break }
}
if (-not $boot -and -not $NoClone -and (Test-Path -LiteralPath (Join-Path $Root 'addons')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $repos = Join-Path $Root 'addons\.repos'
    New-Item -ItemType Directory -Force -Path $repos | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $repos '.gdignore'))) { New-Item -ItemType File -Path (Join-Path $repos '.gdignore') | Out-Null }
    $gitBase = if ($env:TMC_GIT_BASE) { $env:TMC_GIT_BASE } else { 'https://github.com/modcommunity' }
    & git clone --quiet --depth 1 "$gitBase/dot-bootstrap.git" (Join-Path $repos 'dot-bootstrap') 2>$null
    if ($LASTEXITCODE -eq 0) { $boot = Join-Path $repos 'dot-bootstrap\bootstrap.ps1' }
}
if (-not $boot) {
    Write-Host "    !!   dot-sim: native motor=off (dot-bootstrap's bootstrap.ps1 not found; GDScript runs, slower)" -ForegroundColor Yellow
    exit 0
}

# Lift the functions, do not run the script.
$wanted = @('Get-NativePlatform', 'Test-NativeBuiltHere', 'Fetch-Natives')
$ast = [System.Management.Automation.Language.Parser]::ParseFile($boot, [ref]$null, [ref]$null)
$found = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $a.Name }, $true))
if ($found.Count -ne $wanted.Count) {
    Write-Host "    !!   $boot has no Fetch-Natives (GDScript runs)" -ForegroundColor Yellow
    exit 0
}
foreach ($f in $found) { . ([scriptblock]::Create($f.Extent.Text)) }
$hostPlatform = Get-NativePlatform

# What Fetch-Natives expects of its caller.
$script:RC = 0
$script:CurPlat = $hostPlatform
$script:CurRepo = ''
$script:CurAddon = ''
$script:RepoDir = ''
$projectsDir = ''
function Say  ($proj, $msg, $color = 'DarkGray') { Write-Host "    --   $msg" -ForegroundColor $color }
function Ok   ($proj, $msg) { Write-Host "    ok   $msg" -ForegroundColor Green }
function Warn ($proj, $msg) { Write-Host "    !!   $msg" -ForegroundColor Yellow }
function Err  ($proj, $msg) { Write-Host "    !!   $msg" -ForegroundColor Red; $script:RC = 1 }
function Get-OnDisk ($repo) { return (Split-Path -Leaf $script:RepoDir) }
function Get-NativePlatform { return $script:CurPlat }
# The pin comes from addons.lock; the place is the repository addons\<addon> links into.
function Get-NativesFor ($proj) {
    $lock = Join-Path $Root 'addons.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return }
    foreach ($line in Get-Content -LiteralPath $lock) {
        $f = $line -split "`t"
        if ($f.Count -ge 2 -and $f[0] -eq $script:CurRepo -and $f[1]) {
            [pscustomobject]@{ Repo = $f[0]; Tag = $f[1]; Addon = $script:CurAddon; LibDir = 'bin' }
        }
    }
}

if ($Platform.Count -eq 0) { $Platform = @($hostPlatform) }
foreach ($repo in $NativeRepos) {
    $addon = $repo -replace '-', '_'
    if (-not (Test-Path -LiteralPath (Join-Path $Root "addons\$addon"))) { continue }
    # setup.ps1 links addons\<addon> to ..\<repo>\addons\<addon>; a -Vendor tree holds a copy.
    $sibling = Join-Path $Root "..\$repo"
    $repoDir = if (Test-Path -LiteralPath (Join-Path $sibling "addons\$addon")) { (Resolve-Path -LiteralPath $sibling).Path } else { $Root }
    $script:CurRepo = $repo; $script:CurAddon = $addon; $script:RepoDir = $repoDir
    $projectsDir = Split-Path -Parent $repoDir
    $lib = Join-Path $repoDir "addons\$addon\bin"
    $stamp = Join-Path $lib '.natives'

    # dot-bootstrap keeps ONE stamp ("<tag> <platform>") per library folder, so fetching
    # macos-arm64 and then macos-x86_64 made each undo the other's stamp and download
    # both every run. Here each platform keeps its own (.natives-<platform>) and is
    # swapped into .natives around the call; the twin of fetch-natives.sh.
    foreach ($p in $Platform) {
        $script:CurPlat = $p
        $per = Join-Path $lib ".natives-$p"
        if (Test-Path -LiteralPath $per) { Copy-Item -Force -LiteralPath $per -Destination $stamp }
        Fetch-Natives $Root
        if ((Test-Path -LiteralPath $stamp) -and ((Get-Content -LiteralPath $stamp -Raw).Trim() -split ' ')[1] -eq $p) {
            Copy-Item -Force -LiteralPath $stamp -Destination $per
        }
    }
    $ext = Join-Path $repoDir "addons\$addon\$addon.gdextension"
    $hostLib = Join-Path $lib $Platform[0]
    if ((Test-Path -LiteralPath $ext) -and (Test-Path -LiteralPath $hostLib) -and (Get-ChildItem -LiteralPath $hostLib -ErrorAction SilentlyContinue)) {
        Write-Host "    ok   $repo`: native motor=on ($($Platform -join ' '))" -ForegroundColor Green
    } else {
        Write-Host "    !!   $repo`: native motor=off (no library for $($Platform -join ' '); GDScript runs, slower)" -ForegroundColor Yellow
    }
}
exit $script:RC
