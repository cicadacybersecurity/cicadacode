param([string]$Model = "minimax/MiniMax-M2.7")
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root "manager\engine.ps1")
Import-CicadaSecrets

$ws = Join-Path $Root "pi-agent"
if (-not (Test-Path $ws)) { New-Item -ItemType Directory -Force -Path $ws | Out-Null }

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

This worker operates a Raspberry Pi over SSH. It has NO direct access to the Pi's filesystem - everything happens by running remote commands through the local shell.

## Connection
- Host: $piHost   User: $piUser
- Run anything on the Pi with:  $sshPrefix "<remote command>"
- Copy files TO the Pi:    scp -i "$piKey" <localfile> $piUser@${piHost}:<remote-path>
- Copy files FROM the Pi:  scp -i "$piKey" $piUser@${piHost}:<remote-path> <localfile>

## Rules
- Verify before modifying: inspect remotely first, then change.
- Never run destructive commands (rm -rf, mkfs, dd, shutdown, reboot, service stops) unless the user's current prompt explicitly asked for exactly that.
- Prefer idempotent commands; report what each command returned, honestly.
- If a command fails, show the error and propose the fix - do not retry blindly more than once.
- For long-running remote work use nohup ... & and poll - do not hold sessions open.
"@
$piMd | Set-Content (Join-Path $ws "PI.md") -Encoding utf8

$seedTask = "You are the Pi operator. Read PI.md in this project for connection details and rules. Verify the connection now with a single remote command chain: hostname; uptime; df -h /; free -m. Report the results honestly, then stop and await instructions."

& (Join-Path $Root "manager\console.ps1") -Project $ws -Workers 1 -Tasks @($seedTask) -Model $Model -Agent "pi" -Yes
exit $LASTEXITCODE

