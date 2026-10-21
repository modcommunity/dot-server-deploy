<#
.SYNOPSIS
    The deployment wizard, on Windows: the server's settings, the firewall, start
    at boot, and an S3 publish.

.DESCRIPTION
    The Windows half of deploy.sh, and deliberately the smaller half.

    TLS IS NOT HERE. A browser can only reach a server over wss://, and in this
    project wss:// is nginx in front of the server with a certificate from Let's
    Encrypt or the development CA -- deploy/install-server-tls.sh,
    deploy/issue-letsencrypt.sh, deploy/install-game-origin.sh. Those are Linux
    deployment steps, and a Windows rendition of them would be a second nginx
    layout, a second certificate store and a second renewal story that nothing
    here tests. A Windows box serves desktop clients (ENet) directly; for browser
    players, put the proxy on a Linux machine (or WSL) and point it at this one:
        ./deploy.sh proxy --backend <this-box>:6064

    What it does here, natively:
        config      cfg\*.yml: name, game, slots, tickrate, password, port, transport
        firewall    Windows Firewall rules for the game port, TCP and UDP
        service     a Scheduled Task that runs server.ps1 at boot
        publish     the web build to S3, through deploy/publish-web-s3.sh when bash
                    (Git Bash, WSL) is installed
        list        what this checkout has: its config, rules and task

    On Linux and macOS (PowerShell 7) it hands everything to deploy.sh.

    UNTESTED ON WINDOWS, like setup.ps1 and server.ps1: it parses and its config
    writer is checked against the bash one, and nobody has run it on a Windows
    machine yet.

.PARAMETER Command
    config, firewall, service, publish, list, or nothing for a menu.

.PARAMETER Yes
    Take every default.

.PARAMETER DryRun
    Ask everything, print what would change, change nothing.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 config -Name "My Server" -Port 6070
    .\deploy.ps1 firewall -Yes
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = "",
    [switch] $Yes,
    [switch] $DryRun,
    [string] $Name = "",
    [string] $Game = "",
    [string] $Slots = "",
    [string] $Tick = "",
    [string] $Port = "",
    [string] $Transport = "",
    [string[]] $Set = @(),
    [string] $TaskName = "",
    [string] $Bucket = "",
    [string] $Region = "",
    [string] $Prefix = "",
    [string] $EnvFile = "",
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

# PowerShell 7 on Linux or macOS: deploy.sh is the real thing there, and has nginx,
# certbot and systemd to drive. $IsWindows does not exist in Windows PowerShell 5,
# where it reads as $null, which is why the test is -eq $false and not -not.
if ($IsWindows -eq $false) {
    $a = @()
    if ($Command) { $a += $Command }
    if ($Yes) { $a += '--yes' }
    if ($DryRun) { $a += '--dry-run' }
    $a += $Rest
    & bash (Join-Path $Root 'deploy.sh') @a
    exit $LASTEXITCODE
}

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor White }
function Ok($text)   { Write-Host "    ok   $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    !!   $text" -ForegroundColor Yellow }
function Note($text) { Write-Host "    $text" -ForegroundColor DarkGray }
function Die($text, $code = 1) {
    Write-Host ""; Write-Host "    $text" -ForegroundColor Red; Write-Host ""
    exit $code
}

# --- Questions -------------------------------------------------------------

function Ask([string]$q, [string]$given, [string]$default) {
    if ($given) { Write-Host "    $q $given (given)"; return $given }
    if ($Yes) { return $default }
    $a = Read-Host "    $q [$default]"
    if ($a) { return $a } else { return $default }
}

function Ask-YN([string]$q, [bool]$default) {
    if ($Yes) { return $default }
    $hint = if ($default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = Read-Host "    $q [$hint]"
        if (-not $a) { return $default }
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$') { return $false }
    }
}

function Ask-Number([string]$q, [string]$given, [string]$default, [int]$min = 0, [int]$max = [int]::MaxValue) {
    while ($true) {
        $a = Ask $q $given $default
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge $min -and $n -le $max) { return "$n" }
        if ($given -or $Yes) { Die "${q}: `"$a`" is not a number from $min to $max" 2 }
        Warn "a number from $min to $max"
    }
}

function Choose([string]$q, [string]$given, [string]$default, [string[][]]$options) {
    $keys = $options | ForEach-Object { $_[0] }
    if ($given) {
        if ($keys -contains $given) { Write-Host "    $q $given (given)"; return $given }
        Die "${q}: `"$given`" is not one of: $($keys -join ', ')" 2
    }
    if ($Yes) { return $default }
    Write-Host ""; Write-Host "    $q"
    for ($i = 0; $i -lt $options.Count; $i++) {
        $mark = if ($options[$i][0] -eq $default) { '*' } else { ' ' }
        Write-Host ("      {0,2} {1} {2,-12} {3}" -f ($i + 1), $mark, $options[$i][0], $options[$i][1])
    }
    while ($true) {
        $a = Read-Host "    [$default]"
        if (-not $a) { return $default }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $options[$n - 1][0] }
        if ($keys -contains $a) { return $a }
        Warn "pick a number from the list"
    }
}

# --- cfg\ --------------------------------------------------------------------
#
# The same reader and writer as deploy/lib.sh's cfg_get and cfg_set, line for line in
# what they accept: the first `key:` line, a double-quoted value read with \" and \\
# as DotYaml reads them, the comment after the value kept, a missing key appended.
# Two copies, because a Windows box has no bash to call; deploy.sh's are the ones a
# change goes into first.

function Get-CfgValue([string]$file, [string]$key) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if (-not $line.StartsWith("${key}:")) { continue }
        $v = $line.Substring($key.Length + 1).TrimStart()
        if ($v.StartsWith('"')) {
            $out = New-Object System.Text.StringBuilder
            for ($i = 1; $i -lt $v.Length; $i++) {
                $c = $v[$i]
                if ($c -eq '\' -and $i + 1 -lt $v.Length) { [void]$out.Append($v[$i + 1]); $i++; continue }
                if ($c -eq '"') { break }
                [void]$out.Append($c)
            }
            return $out.ToString()
        }
        $h = $v.IndexOf('#')
        if ($h -ge 0) { $v = $v.Substring(0, $h) }
        return $v.TrimEnd()
    }
    return $null
}

# Writes through the same file handle rather than replacing the file, for the reason
# cfg_set uses `cat >`: cfg\rcon.yml has a restricted ACL and a new file would not.
# No byte order mark: DotYaml would read one as part of the first key.
function Set-CfgValue([string]$file, [string]$key, [string]$yaml) {
    $lines = [System.Collections.Generic.List[string]]::new([System.IO.File]::ReadAllLines($file))
    $done = $false
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $line = $lines[$n]
        if (-not $line.StartsWith("${key}:")) { continue }
        $rest = $line.Substring($key.Length + 1)
        $comment = ''
        if ($rest.TrimStart().StartsWith('"')) {
            $i = $rest.IndexOf('"') + 1
            while ($i -lt $rest.Length) {
                if ($rest[$i] -eq '\') { $i += 2; continue }
                if ($rest[$i] -eq '"') { break }
                $i++
            }
            $tail = if ($i + 1 -lt $rest.Length) { $rest.Substring($i + 1) } else { '' }
            $h = $tail.IndexOf('#')
            if ($h -ge 0) { $comment = '  ' + $tail.Substring($h) }
        } else {
            $h = $rest.IndexOf('#')
            if ($h -ge 0) { $comment = '  ' + $rest.Substring($h) }
        }
        $lines[$n] = "${key}: $yaml$comment"
        $done = $true
        break
    }
    if (-not $done) { $lines.Add("${key}: $yaml") }
    $text = ($lines -join "`n") + "`n"
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
    $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::Truncate, [System.IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
}

function Yaml-Str([string]$v) { '"' + $v.Replace('\', '\\').Replace('"', '\"') + '"' }

function CfgV([string]$file, [string]$key, [string]$default) {
    $v = Get-CfgValue (Join-Path $Root "cfg\$file") $key
    if ($null -eq $v -and -not (Test-Path -LiteralPath (Join-Path $Root "cfg\$file"))) {
        $v = Get-CfgValue (Join-Path $Root "cfg.example\$file") $key
    }
    if ($v) { return $v } else { return $default }
}

# --- The plan ----------------------------------------------------------------
#
# deploy.sh's rule: every question first, then the list, one confirmation, then it
# runs. Each step is a description, a function's name and its arguments -- not a
# script block, because a block closed over with GetNewClosure runs in a module of
# its own, which cannot see this script's functions when it is run with -File.

$Plan = [System.Collections.Generic.List[object]]::new()
function Act([string]$desc, [string]$fn, [object[]]$fnArgs) {
    $Plan.Add([pscustomobject]@{ Desc = $desc; Fn = $fn; Args = $fnArgs })
}

function Set-Cfg([string]$file, [string]$key, [string]$yaml, [string]$shown) {
    $now = CfgV $file $key ''
    if ($now -eq $shown) { return }
    if ($key -match 'password|secret|token') {
        Act "cfg\${file}: $key -> $(if ($shown) { '(the one typed)' } else { 'cleared' })" 'Set-CfgValue' @((Join-Path $Root "cfg\$file"), $key, $yaml)
        return
    }
    Act "cfg\${file}: $key $(if ($now) { $now } else { 'unset' }) -> $shown" 'Set-CfgValue' @((Join-Path $Root "cfg\$file"), $key, $yaml)
}

function Run-Plan {
    if ($Plan.Count -eq 0) { Write-Host ""; Ok "nothing to change"; return }
    Write-Host ""; Write-Host "  This is the whole of it:"; Write-Host ""
    foreach ($s in $Plan) { Write-Host "    - $($s.Desc)" -ForegroundColor Green }
    if ($DryRun) { Write-Host ""; Write-Host "  -DryRun: nothing was done."; return }
    if (-not (Ask-YN "Go ahead?" $true)) { Write-Host "    nothing was done."; return }
    foreach ($s in $Plan) {
        Step $s.Desc
        $fa = $s.Args
        try { & $s.Fn @fa; Ok "done" }
        catch { Die "this step failed: $($_.Exception.Message)" 1 }
    }
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Commands ------------------------------------------------------------------

function Q-Config {
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'cfg\server.yml'))) {
        Die "this checkout has no cfg\ yet: run .\setup.bat first, which writes it (with an RCON password)." 1
    }
    Step "The server"
    $n = Ask "Server name, as the browser lists it" $Name (CfgV 'server.yml' 'sv_name' 'TMC Server')
    Set-Cfg 'server.yml' 'sv_name' (Yaml-Str $n) $n

    $opts = @(, @('default', 'whatever the server runs when nothing names a game'))
    foreach ($f in Get-ChildItem -Path (Join-Path $Root 'content') -Filter game.yml -Recurse -Depth 1 -ErrorAction SilentlyContinue) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text -notmatch '(?m)^kind:\s*pack') { continue }
        $title = if ($text -match '(?m)^name:\s*"?([^"\r\n]+)"?') { $Matches[1] } else { $f.Directory.Name }
        $opts += , @($f.Directory.Name, $title)
    }
    $cur = CfgV 'server.yml' 'sv_game' ''
    $g = Choose "Which game does it start with?" $Game $(if ($cur) { $cur } else { 'default' }) $opts
    if ($g -eq 'default') { $g = '' }
    Set-Cfg 'server.yml' 'sv_game' (Yaml-Str $g) $g

    $s = Ask-Number "Player slots" $Slots (CfgV 'server.yml' 'sv_maxplayers' '64') 1
    Set-Cfg 'server.yml' 'sv_maxplayers' $s $s
    $t = Ask-Number "Tick rate (Hz)" $Tick (CfgV 'server.yml' 'sv_tickrate' '60') 1
    Set-Cfg 'server.yml' 'sv_tickrate' $t $t

    if (-not $Yes) {
        $sec = Read-Host "    Join password [return keeps it, - clears it]" -AsSecureString
        $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if ($pw -eq '-') { Set-Cfg 'server.yml' 'sv_password' '""' '' }
        elseif ($pw) {
            Act "cfg\server.yml: sv_password -> (the one typed)" 'Set-CfgValue' @((Join-Path $Root 'cfg\server.yml'), 'sv_password', (Yaml-Str $pw))
        }
    }

    $p = Ask-Number "Game port (WebSocket and ENet; RCON is one above)" $Port (CfgV 'net.yml' 'net_port' '6064') 1 65535
    Set-Cfg 'net.yml' 'net_port' $p $p
    $tr = Choose "Which clients can connect directly?" $Transport (CfgV 'net.yml' 'net_transport' 'dual') @(
        @('dual', 'browsers (WebSocket) and desktop clients (ENet) on the one port'),
        @('websocket', 'browsers only'),
        @('enet', 'desktop clients only'))
    Set-Cfg 'net.yml' 'net_transport' $tr $tr
    if ($tr -ne 'enet') {
        Note "a browser needs wss://, which is nginx and a certificate: a Linux step (./deploy.sh proxy)"
    }

    foreach ($kv in $Set) {
        if ($kv -notmatch '^([^:]+):([^=]+)=(.*)$') { Die "-Set ${kv}: write it FILE:KEY=VALUE" 2 }
        $file = $Matches[1] -replace '^cfg[\\/]', ''; $key = $Matches[2]; $val = $Matches[3]
        if (-not (Test-Path -LiteralPath (Join-Path $Root "cfg\$file"))) { Die "-Set ${kv}: there is no cfg\$file" 2 }
        Set-Cfg $file $key $val ($val.Trim('"'))
    }
}

function Rule-Name([string]$proto, [string]$p) { "dot-server-deploy $p/$proto ($Root)" }

function Q-Firewall {
    Step "Windows Firewall"
    $p = CfgV 'net.yml' 'net_port' '6064'
    $tr = CfgV 'net.yml' 'net_transport' 'dual'
    if (-not (Test-Admin)) { Warn "adding a firewall rule needs an elevated prompt: run this as Administrator" }
    if (-not (Ask-YN "Allow the game port ($p) in?" $true)) { return }
    $protos = @('TCP')
    if ($tr -ne 'websocket') { $protos += 'UDP' }
    foreach ($proto in $protos) {
        $rn = Rule-Name $proto $p
        if (Get-NetFirewallRule -DisplayName $rn -ErrorAction SilentlyContinue) { Note "$rn is already there"; continue }
        Act "allow $p/$proto in" 'Add-FirewallRule' @($rn, $proto, $p)
    }
}

function Add-FirewallRule([string]$rn, [string]$proto, [string]$p) {
    New-NetFirewallRule -DisplayName $rn -Direction Inbound -Protocol $proto -LocalPort $p -Action Allow | Out-Null
}

# A Scheduled Task rather than a Windows service: a service needs a wrapper that
# speaks the service control protocol, and server.ps1 is a console program. A task
# at startup, as a named user, restarting on failure, is what a service would be.
function Q-Service {
    Step "Start at boot"
    $script = Join-Path $Root 'server.ps1'
    if (-not (Test-Path -LiteralPath $script)) { Die "no server.ps1 yet: run .\setup.bat first" 1 }
    if (-not (Test-Admin)) { Warn "registering a task that runs at startup needs an elevated prompt" }
    $tn = Ask "Task name" $TaskName 'dot-server'
    $user = Ask "Run it as" '' "$env:USERDOMAIN\$env:USERNAME"
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
        if (-not (Ask-YN "A task named $tn exists. Replace it?" $false)) { return }
    }
    Act "task ${tn}: server.ps1 at startup, as $user, restarting on failure" 'Register-ServerTask' @($tn, $user, $script)
}

function Register-ServerTask([string]$tn, [string]$user, [string]$script) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
    # The password is asked here, when the step runs, and goes straight to the task
    # scheduler: it is never a parameter and never in the plan.
    $cred = Get-Credential -UserName $user -Message "The password for $user, so the task can run with nobody signed in"
    Register-ScheduledTask -TaskName $tn -Action $action -Trigger $trigger -Settings $settings `
        -User $user -Password $cred.GetNetworkCredential().Password -Force | Out-Null
}

function Q-Publish {
    # Git for Windows' bash, never System32's: that one is WSL, which is handed a
    # C:\ path it cannot open. Under WSL, run ./deploy.sh publish from the WSL shell.
    $bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $bash) {
        $c = Get-Command bash -ErrorAction SilentlyContinue
        if ($c -and $c.Source -notlike "$env:SystemRoot\*") { $bash = $c.Source }
    }
    if (-not $bash) {
        Die "publishing signs its uploads in deploy/publish-web-s3.sh, which needs Git for Windows' bash (or run ./deploy.sh publish inside WSL)." 1
    }
    $a = @('publish')
    if ($Yes) { $a += '--yes' }
    if ($DryRun) { $a += '--dry-run' }
    if ($Bucket) { $a += @('--bucket', $Bucket) }
    if ($Region) { $a += @('--region', $Region) }
    if ($Prefix) { $a += @('--prefix', $Prefix) }
    if ($EnvFile) { $a += @('--env-file', $EnvFile) }
    & $bash (Join-Path $Root 'deploy.sh') @a
    exit $LASTEXITCODE
}

function Q-List {
    Step "This checkout"
    Write-Host "    $(CfgV 'server.yml' 'sv_name' '?'), port $(CfgV 'net.yml' 'net_port' '6064'), $(CfgV 'net.yml' 'net_transport' 'dual')"
    Get-NetFirewallRule -DisplayName "dot-server-deploy * ($Root)" -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "    firewall  $($_.DisplayName)" }
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.Actions | Where-Object { $_.Arguments -like "*$Root*server.ps1*" } } |
        ForEach-Object { Write-Host "    task      $($_.TaskName) ($($_.State))" }
}

function Linux-Only([string]$what) {
    Die "$what is nginx and a certificate, which this project does on Linux:
    ./deploy.sh $what   on the Linux box (or WSL) in front of this one.
    For a proxy to here: ./deploy.sh proxy --backend <this box's address>:$(CfgV 'net.yml' 'net_port' '6064')" 2
}

if (-not $Command) {
    $Command = Choose "What do you want to do?" '' 'config' @(
        @('config', "the server's settings (cfg\)"),
        @('firewall', 'allow the game port in'),
        @('service', 'start at boot'),
        @('publish', 'upload the web build to S3'),
        @('list', 'what this checkout has'),
        @('quit', ''))
}

switch ($Command) {
    'config'   { Q-Config }
    'firewall' { Q-Firewall }
    'service'  { Q-Service }
    'publish'  { Q-Publish }
    'list'     { Q-List; exit 0 }
    'quit'     { exit 0 }
    'new'      { Q-Config; Q-Firewall; Q-Service }
    { $_ -in 'cert', 'proxy', 'origin', 'modify' } { Linux-Only $Command }
    default    { Die "no such command: $Command (Get-Help .\deploy.ps1)" 2 }
}
Run-Plan
