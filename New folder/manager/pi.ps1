param([string]$Model = "minimax/MiniMax-M2.7", [string]$SkillFile = "")
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root "manager\engine.ps1")
Import-CicadaSecrets
Show-ReplayCommand -ParamNames @("Project","Model","SkillFile","Workers","Yes")

$ws = Join-Path $Root "pi-agent"
if (-not (Test-Path $ws)) { New-Item -ItemType Directory -Force -Path $ws | Out-Null }

# ---------- optional skill/playbook file (e.g. an OpenClaw setup guide) ----------
if (-not $SkillFile) {
    $SkillFile = (Read-Host "Skill file for the Pi worker (path to a .md playbook, or Enter to skip)").Trim()
}
$skillName = ""
if ($SkillFile) {
    if (Test-Path $SkillFile) {
        $skillName = "SKILL.md"
        Copy-Item $SkillFile (Join-Path $ws $skillName) -Force
        Write-Host ("skill file loaded: " + $SkillFile + " -> pi-agent\SKILL.md") -ForegroundColor Green
    } else {
        Write-Host ("skill file not found: " + $SkillFile + " - continuing without it") -ForegroundColor Yellow
    }
}

$s = Get-Content $script:SecretsPath -Raw | ConvertFrom-Json
$piHost = [string]$s.PI_HOST
$piUser = [string]$s.PI_USER
$piKey  = [string]$s.PI_KEY
if (-not $piHost -or -not $piUser) {
    Write-Host "Pi connection not configured. Add PI_HOST and PI_USER (and optionally PI_KEY) to manager\secrets.json, then run the one-time key setup." -ForegroundColor Yellow
    exit 1
}
if (-not $piKey) { $piKey = Join-Path $env:USERPROFILE ".ssh\pi_key" }
$sshPrefix = "ssh -i `"$piKey`" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $piUser@$piHost"

$piMd = @"
# Pi operator cheatsheet

YOUR DEFAULT CONTEXT IS THE PI. Every command you run should be a Pi command through the wrappers below. You only touch the local Windows machine when a task explicitly says local, or to move files.

## The wrappers (in this project - use these, never raw ssh/scp prefixes)
- Run a command on the Pi:        .\onpi.ps1 "<remote command>"
- Run a local script ON the Pi:   .\runpi.ps1 .\script.sh        (copies it over and executes it there)
- Copy Windows -> Pi:             .\pushpi.ps1 .\file-or-folder [remote-path]   (default ~)
- Copy Pi -> Windows:             .\pullpi.ps1 <remote-path> [local-path]

## Connection (already baked into the wrappers - you never type it)
- Host: $piHost   User: $piUser

## Rules
- Default to the Pi. If you catch yourself preparing a local command for Pi work, stop and wrap it instead.
- Plain user space: no sudo, no system-level changes, unless the user's current prompt explicitly asks for exactly that.
- Verify before modifying: inspect remotely first (ls, cat, systemctl --user status), then change.
- Never destructive (rm -rf, mkfs, dd, shutdown, reboot, service stops) unless the prompt explicitly asked for exactly that.
- Prefer idempotent commands; report what each command returned, honestly.
- If a command fails, show the error and propose the fix - one blind retry maximum.
- Long remote work: nohup ... & and poll - never hold sessions open.
- You ARE the worker: no delegation layer exists and no task tool is available - never attempt to invoke one. If a step is beyond your permissions, output the exact commands for the human, mark it a blocker, and keep going with anything you CAN do yourself.
"@
$piMd | Set-Content (Join-Path $ws "PI.md") -Encoding utf8

# ---------- Pi-native wrappers: the worker lives on the Pi by default ----------
$onpi = @"
param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Cmd)
`$c = `$Cmd -join " "
& ssh -i "$piKey" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $piUser@$piHost `$c
exit `$LASTEXITCODE
"@
$onpi | Set-Content (Join-Path $ws "onpi.ps1") -Encoding utf8

$runpi = @"
param([string]`$Script)
if (-not (Test-Path `$Script)) { Write-Error "script not found: `$Script"; exit 1 }
`$tmp = "/tmp/pi-run-" + (Split-Path -Leaf `$Script)
& scp -i "$piKey" `$Script "$piUser@`${piHost}:`$tmp"
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
& ssh -i "$piKey" $piUser@$piHost "bash `$tmp"
exit `$LASTEXITCODE
"@
$runpi | Set-Content (Join-Path $ws "runpi.ps1") -Encoding utf8

$pushpi = @"
param([string]`$Local, [string]`$Remote = "~")
if (-not (Test-Path `$Local)) { Write-Error "local path not found: `$Local"; exit 1 }
& scp -i "$piKey" -r `$Local "$piUser@`${piHost}:`$Remote"
exit `$LASTEXITCODE
"@
$pushpi | Set-Content (Join-Path $ws "pushpi.ps1") -Encoding utf8

$pullpi = @"
param([string]`$Remote, [string]`$Local = ".")
& scp -i "$piKey" -r "$piUser@`${piHost}:`$Remote" `$Local
exit `$LASTEXITCODE
"@
$pullpi | Set-Content (Join-Path $ws "pullpi.ps1") -Encoding utf8

$seedTask = "You are the Pi operator. Read PI.md in this project for connection details and rules."
if ($skillName) { $seedTask += " Also read SKILL.md in this project - it is your playbook for this session; follow it for the work ahead." }
$seedTask += " Verify the connection now with: .\onpi.ps1 `"hostname; uptime; df -h /; free -m`". Report the results honestly, then stop and await instructions."

& (Join-Path $Root "manager\console.ps1") -Project $ws -Workers 1 -Tasks @($seedTask) -Model $Model -Agent "pi" -Yes
exit $LASTEXITCODE


