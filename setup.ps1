<#
.SYNOPSIS
    One command to go from a clone to a server you can start, on Windows.

.DESCRIPTION
    The Windows half of setup.sh. It does the same six things and one of them
    differently, which is the reason this is a separate script rather than a
    wrapper:

    ADDON LINKS ARE DIRECTORY JUNCTIONS, NOT SYMLINKS. A symlink on Windows
    needs Developer Mode or an elevated prompt; a junction needs neither, and
    Godot follows one transparently because the filesystem resolves it before
    Godot ever sees it.

    The failure this avoids does not look like a link problem. If Git checks a
    symlink out as a regular file -- which is what it does when core.symlinks is
    false -- then addons\dot_core is a ~30 byte text file containing a path.
    Godot loads it, finds no scripts, and every class_name the addon defines
    fails to resolve. A GDScript file that merely MENTIONS an unknown class_name
    fails to parse and takes every script referencing it down too, so the
    symptom is dozens of unrelated parse errors in files you did not touch.

.PARAMETER Godot
    Path to a Godot 4.7+ executable. Searched for on PATH when not given, and
    downloaded -- pinned and checksummed -- when the machine has none.

.PARAMETER NoDownload
    Never fetch a runtime. Fail instead, the way this script used to.

.PARAMETER Vendor
    Copy the addons instead of linking them. What a release tarball needs, and
    what a junction cannot survive: a junction stores an ABSOLUTE target, so it
    breaks the moment the tree moves.

.PARAMETER NoImport
    Skip Godot's import pass. Only safe on a re-run that added no new class_name.

.PARAMETER Check
    After setting up, boot the server once and shut it down.

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -Godot C:\Godot\Godot_v4.4.1-stable_win64.exe -Check
#>

[CmdletBinding()]
param(
    [string] $Godot = "",
    [switch] $NoDownload,
    [switch] $Vendor,
    [switch] $NoImport,
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor White }
function Ok($text)   { Write-Host "    ok   $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    !!   $text" -ForegroundColor Yellow }
function Die($text, $code = 1) {
    Write-Host ""; Write-Host "    $text" -ForegroundColor Red; Write-Host ""
    exit $code
}

# --- 1. The runtime --------------------------------------------------------

Step "Godot runtime"

# The pin, and the digests that prove it. Same version as tools/fetch-godot.sh --
# this is the Windows half of that script, not a second policy. Digests are from the
# release's own SHA512-SUMS.txt, read by a person and checked in here; they are NOT
# fetched from beside the binary, because a checksum served by whoever served the zip
# is checked by whoever would have had to tamper with both.
#
#   curl -fsSL https://github.com/godotengine/godot/releases/download/4.7.2-stable/SHA512-SUMS.txt
$GodotVersion = '4.7.2-stable'
$GodotAssets = @{
    'X64'   = @{ Asset = "Godot_v${GodotVersion}_win64.exe.zip";         Exe = "Godot_v${GodotVersion}_win64_console.exe";         Sha512 = '83decd58fdf67b9d657958a1ae6bf1929c20785315a81effe245874cdc57acb709bf868e00778a96984338c1b29dafdb453c6847747694621c6ecf5da2259993' }
    'Arm64' = @{ Asset = "Godot_v${GodotVersion}_windows_arm64.exe.zip"; Exe = "Godot_v${GodotVersion}_windows_arm64_console.exe"; Sha512 = '683f8dd9fb087db79dfbbc52d5b2209df98218a4fef0d10d8478ec2230ae8db6032a36929677479b9f9c5a6aa0c51ee359d7e57eb5abbcb6cef4998526dec5a6' }
}

# The CONSOLE exe, not the plain one. The plain Windows build detaches from the
# console it was started from, so a headless server started by this launcher prints
# nothing anywhere -- and a server with no log is a server nobody can operate. The
# console exe is a 200 KB shim that needs the big one beside it, which is why the
# unpack below keeps both.

$GodotCache = Join-Path $(if ($env:TMC_GODOT_CACHE) { $env:TMC_GODOT_CACHE } else { Join-Path $env:LOCALAPPDATA 'tmc\godot' }) $GodotVersion

function Test-GodotVersion($path) {
    if (-not $path) { return $null }
    $v = (& $path --version 2>$null | Select-Object -First 1)
    if ($v -match '^(4\.(?:[7-9]|\d\d)|5)\.') { return $v }
    return $null
}

function Get-PinnedGodot {
    # PROCESSOR_ARCHITECTURE rather than RuntimeInformation: it is there in Windows
    # PowerShell 5.1 on a machine with no newer .NET, which is most of them.
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'Arm64' } else { 'X64' }
    $pin  = $GodotAssets[$arch]
    $url  = "https://github.com/godotengine/godot/releases/download/$GodotVersion/$($pin.Asset)"

    New-Item -ItemType Directory -Force -Path $GodotCache | Out-Null
    $zip = Join-Path $GodotCache $pin.Asset

    Write-Host "    downloading $($pin.Asset)" -ForegroundColor DarkGray
    try {
        # Invoke-WebRequest's progress bar makes a 120 MB download several times
        # slower in Windows PowerShell. It is restored in the finally.
        $prev = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
        Die @"
could not download $url

    $($_.Exception.Message)

    No network, or a proxy in the way. Download it by hand and point at it:
        .\setup.ps1 -Godot C:\path\to\godot.exe
"@ 3
    } finally { $ProgressPreference = $prev }

    # Verified BEFORE anything is unpacked, let alone run. A zip is parsed by a
    # library, and a file that is not the one we pinned does not get to be parsed.
    $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA512).Hash.ToLower()
    if ($got -ne $pin.Sha512) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Die @"
CHECKSUM MISMATCH on $($pin.Asset) -- the file has been deleted.

    expected  $($pin.Sha512)
    got       $got

    A corrupted download, or a file that is not the one this script is pinned to.
    Re-run once; if it happens again, do NOT work around it. Install Godot
    yourself from a source you trust and pass it with -Godot.
"@ 4
    }
    Write-Host "    sha512 verified" -ForegroundColor DarkGray

    Expand-Archive -LiteralPath $zip -DestinationPath $GodotCache -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $target = Join-Path $GodotCache $pin.Exe
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Die "the archive did not contain $($pin.Exe): the pin and the release layout disagree." 4
    }
    return $target
}

$exe = $null

if ($Godot) {
    # An explicit -Godot is not a suggestion: a wrong one that quietly became a
    # download would be this script ignoring the argument it was handed.
    if (Test-Path -LiteralPath $Godot -PathType Leaf) { $exe = (Resolve-Path $Godot).Path }
    else {
        $found = Get-Command $Godot -ErrorAction SilentlyContinue
        if ($found) { $exe = $found.Source } else { Die "no runtime at $Godot" 3 }
    }
    $version = Test-GodotVersion $exe
    if (-not $version) {
        Die "Godot 4.7 or newer is required; $exe is $(& $exe --version 2>&1 | Select-Object -First 1)" 3
    }
} else {
    # The cache first, then PATH: the downloaded one is the version this project is
    # pinned to, and if the machine's own is fine it was found on the first run and
    # nothing was ever downloaded.
    $candidates = @()
    foreach ($arch in $GodotAssets.Keys) { $candidates += (Join-Path $GodotCache $GodotAssets[$arch].Exe) }
    $candidates += @('godot', 'godot4', 'Godot')

    $tooOld = $null
    foreach ($candidate in $candidates) {
        $resolved = $null
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $resolved = (Resolve-Path $candidate).Path }
        else {
            $found = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($found) { $resolved = $found.Source }
        }
        if (-not $resolved) { continue }
        $version = Test-GodotVersion $resolved
        if ($version) { $exe = $resolved; break }
        $tooOld = "$resolved ($(& $resolved --version 2>&1 | Select-Object -First 1))"
    }

    if (-not $exe) {
        if ($NoDownload) {
            Die @"
No Godot 4.7+ runtime found$(if ($tooOld) { " ($tooOld is too old)" }), and -NoDownload was given.

    Install Godot 4.7 or newer and put it on PATH, or:
        .\setup.ps1 -Godot C:\path\to\godot.exe
"@ 3
        }
        if ($tooOld) { Warn "$tooOld is too old" }
        Warn "no Godot 4.7 or newer on this machine; fetching the pinned $GodotVersion"
        $exe = Get-PinnedGodot
        $version = Test-GodotVersion $exe
        if (-not $version) { Die "the fetched runtime does not report a usable version" 3 }
    }
}

Ok "$exe ($version)"

# --- 2. The addons ---------------------------------------------------------

$addons = @('dot_core','dot_net','dot_server','dot_server_query','dot_server_security','dot_2d','dot_ui','dot_auth',
            'dot_cloud','dot_user','dot_user_avatar','dot_platform',
            'dot_loadout','dot_match')

Step "dot-* addons"
New-Item -ItemType Directory -Force -Path 'addons' | Out-Null

$missing = @()
foreach ($name in $addons) {
    $repo   = $name -replace '_', '-'
    $source = Join-Path $Root "..\$repo\addons\$name"
    $link   = Join-Path $Root "addons\$name"

    if (Test-Path -LiteralPath $source -PathType Container) {
        # Remove whatever is there first. A stale junction, or -- the case that
        # actually bites -- a plain text file Git left behind in place of a
        # symlink. Directory.Delete on a link deletes the link, not the target;
        # Remove-Item -Recurse on a directory link is ambiguous across
        # PowerShell versions and has been known to delete through it.
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType) { [System.IO.Directory]::Delete($item.FullName, $false) }
            else { Remove-Item -LiteralPath $link -Recurse -Force }
        }

        if ($Vendor) {
            Copy-Item -LiteralPath (Resolve-Path $source).Path -Destination $link -Recurse -Force
        } else {
            New-Item -ItemType Junction -Path $link -Target (Resolve-Path $source).Path -ErrorAction SilentlyContinue | Out-Null
            if (-not (Test-Path -LiteralPath $link)) { $missing += $repo }
        }
    }
    elseif (-not (Test-Path -LiteralPath $link -PathType Container)) {
        $missing += $repo
    }
}

if ($missing.Count -gt 0) {
    Die @"
These addon repositories are not beside this one:

    $($missing -join ', ')

Each dot-* project is a separate repository and there is no way to clone the
tree at once. Clone them as siblings of this directory, or vendor their
addons\<name> folders into .\addons\.
"@ 4
}
Ok "$($addons.Count) addons $(if ($Vendor) { 'copied' } else { 'linked' })"

# --- 3. The lobby ----------------------------------------------------------

Step "the lobby"

$room = Join-Path $Root '..\dot-a-room'

if (Test-Path -LiteralPath (Join-Path $room 'game') -PathType Container) {
    # Copied, not linked. It is compiled into this build -- content\lobby\game.yml
    # says why -- and the paths line up because the layout matches dot-a-room's.
    Remove-Item -LiteralPath 'game','scenes' -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $room 'game') -Destination 'game' -Recurse -Force
    New-Item -ItemType Directory -Force -Path 'scenes' | Out-Null
    Copy-Item -Path (Join-Path $room 'scenes\*.tscn') -Destination 'scenes' -Force
    Get-ChildItem -Path 'game','scenes' -Filter '*.uid' -Recurse | Remove-Item -Force
    Ok "copied from $room"
}
elseif (Test-Path -LiteralPath (Join-Path $Root 'game') -PathType Container) {
    Ok "already present"
}
else {
    Die "dot-a-room is not beside this repository and no lobby is vendored." 4
}

# --- 4. Import -------------------------------------------------------------

if (-not $NoImport) {
    Step "importing"
    # Re-run after ANY script with a new class_name is added. Without it the
    # identifier does not resolve, the scene fails to load, and the process HANGS
    # rather than exiting, because nothing ever reaches get_tree().quit().
    & $exe --headless --path $Root --import 2>&1 | Out-Null
    Ok "class_name globals registered"
}

# --- 5. Configuration ------------------------------------------------------

Step "configuration"
foreach ($dir in 'cfg','cfg\content','content\global','data') {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$newConfig = -not (Test-Path -LiteralPath 'cfg\server.yml')

function Write-IfMissing($path, $text) {
    if (Test-Path -LiteralPath $path) { return }
    # UTF8 without a BOM. A BOM at the top of a YAML file is three bytes before
    # the first key, and every parser that does not strip it reads the first key
    # name with an invisible character in it -- including this one.
    [System.IO.File]::WriteAllText(
        (Join-Path $Root $path), $text, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "    +    $path" -ForegroundColor Green
}

# The same defaults setup.sh writes. Kept as one string per file rather than
# generated from a shared source, because the shared source would be a third
# format and two scripts that agree by construction is not worth inventing one.
Write-IfMissing 'cfg\server.yml' @"
# General server settings.
#
# Anything dot-server exposes as a console variable can go here too, under its
# own name -- this file is compiled to a .cfg and handed to dot-server's console,
# which is the parser and the validator. data\from_yaml.cfg is what it became;
# read that when a setting appears not to work.

sv_name: "TMC Test Server"
sv_maxplayers: 64
sv_password: ""
sv_tickrate: 60
sv_game: ""
sv_tags: [lobby, tmc]
"@

Write-IfMissing 'cfg\net.yml' @"
# Network & Bind

net_bind_ip: "0.0.0.0"
net_port: 6064

# Uses Bind IP if not set. Only needed if the server is behind NAT. Nothing binds
# to it -- it is what the join address is printed from.
net_public_ip: ""

# Performance
net_max_bps: 1000000
net_max_pps: 60
net_max_update_rate: 66
"@

Write-IfMissing 'cfg\auth.yml' @"
# Authentication.
#
# Absent or disabled, everybody arrives as a guest and the server works.
#
# WORTH KNOWING: DotAdminManager refuses permissions to any unauthenticated
# session -- a guest uid is a random per-device string, so granting anything to
# one grants it to anyone. Until this is wired up, cfg\permissions.yml has no
# effect and the local console is the only administrator.

enabled: false

backend:
  type: "rest"
  url: "http://localhost:8000"
  timeout: 30
  retries: 3
  verify:
    type: "jwt"
    public_key_file: "cfg/issuer.pub.pem"
"@

Write-IfMissing 'cfg\groups.yml' @"
# Permission groups.
#
# dot-server's model is FLAGS, not roles. This file is the translation: a group
# is a name for a set of flags. is_root is every flag there is, present and
# future.

groups:
  owner:
    is_root: true
    immunity: 100
  admin:
    immunity: 80
    permissions: [kick, ban, mute, warn, announce, change]
  moderator:
    immunity: 50
    permissions: [kick, mute, warn, announce]
"@

Write-IfMissing 'cfg\permissions.yml' @"
# Who is in which group. The key is matched against a player's account uid,
# username and display name, case-insensitively.
#
# See cfg\auth.yml: without authentication this file does nothing.

users:
  gamemann:
    group: owner
"@

$newRcon = $false
if (-not (Test-Path -LiteralPath 'cfg\rcon.yml')) {
    $bytes = New-Object byte[] 18
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $rcon = [Convert]::ToBase64String($bytes) -replace '[/+=]', ''

    Write-IfMissing 'cfg\rcon.yml' @"
# Remote console.
#
# An EMPTY password means the RCON listener does not open at all, which is the
# right setting for a server nobody administers remotely. There is no
# configuration that produces an unauthenticated remote console.
#
# This password was generated once and printed once. Do NOT put it in a command
# line or an environment variable: both are readable by any other process on the
# machine and both end up in pasted bug reports.

rcon_password: "$rcon"
rcon_port: 0
rcon_allowed: []
rcon_websocket: false
"@
    $newRcon = $true
}

if (-not $newConfig) { Ok "cfg\ already exists and was not touched" }

# --- 6. server.ps1 / server.cmd -------------------------------------------
#
# [b]server.cmd used to be the whole Windows launcher, and it was nine lines.[/b] It
# understood `check`, `config` and `games` and handed everything else to Godot unread
# -- so --port, --bind, --name, --max-players, --game, --config, --content, --data,
# --godot, --dry-run, the `--` passthrough, the runtime version check, the refusal of
# a secret on the command line and every meaningful exit code existed on one of the two
# platforms this project supports. The documentation described a launcher Windows did
# not have.
#
# So the real thing is `server.ps1`, generated from tools/server.ps1.in exactly the way
# ./server is generated from tools/server.in, and server.cmd stays as a shim: it is
# what `docker`, a scheduled task and every existing note say to run, and a file that
# stops existing is a worse upgrade than a file that forwards.

Step "server"

$ps1Template = Join-Path $Root 'tools/server.ps1.in'
if (-not (Test-Path -LiteralPath $ps1Template)) { Die "tools/server.ps1.in is missing" 1 }

$ps1 = [System.IO.File]::ReadAllText($ps1Template).Replace('@GODOT@', $exe)
[System.IO.File]::WriteAllText((Join-Path $Root 'server.ps1'), $ps1,
    (New-Object System.Text.UTF8Encoding $false))
Ok "server.ps1 written, using $exe"

# -ExecutionPolicy Bypass, and it is not a hole: the policy is a guard against a script
# arriving from somewhere the user did not intend, and this one was written two lines
# ago by the script being run. Without it, a default Windows install refuses to run
# server.ps1 at all and the shim's whole purpose -- that the documented command works --
# fails on the machine it exists for.
$shim = @"
@echo off
rem GENERATED by setup.ps1. Re-run it to regenerate.
rem
rem A shim. server.ps1 beside it is the launcher; this exists so that `server.cmd`,
rem which is what the older notes and any scheduled task say, keeps working.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
"@
[System.IO.File]::WriteAllText((Join-Path $Root 'server.cmd'), $shim,
    (New-Object System.Text.UTF8Encoding $false))
Ok "server.cmd written, forwarding to server.ps1"

if ($newRcon) {
    Write-Host ""
    Write-Host "  RCON password (printed once, it is in cfg\rcon.yml):" -ForegroundColor White
    Write-Host "      $rcon"
}

if ($Check) {
    Step "checking"
    & (Join-Path $Root 'server.ps1') check
    if ($LASTEXITCODE -ne 0) { Die "the server did not come up. Run .\server.ps1 check --verbose" 1 }
    Ok "the server boots, loads the lobby, and shuts down"
}

Write-Host ""
Write-Host "  Ready." -ForegroundColor White
Write-Host ""
Write-Host "    .\server.ps1             start it"
Write-Host "    .\server.ps1 check       boot once and exit, for CI"
Write-Host "    .\server.ps1 config      what your YAML became"
Write-Host "    .\server.ps1 --help      every option"
Write-Host ""
Write-Host "    server.cmd               the same thing, for cmd.exe and older notes"
Write-Host ""
Write-Host "    docker compose up -d     the same thing in a container"
Write-Host ""
