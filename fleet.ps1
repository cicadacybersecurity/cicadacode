#Requires -Version 5.1
<#
fleet.ps1 - bring the whole fleet up with one command.

  .\fleet.ps1                 one titled console window per project in fleet.json
                              + the overseer window (auto-detects the fleet)
  .\fleet.ps1 -ConsolesOnly   just the project consoles
  .\fleet.ps1 -OverseerOnly -ExpectWorkers 4
                              just the overseer - adopts the consoles you
                              started by hand yourself (no fleet.json needed)

First run creates fleet.json - edit your projects (+ optional opening task per
project), then run it again. A worker becomes visible to the overseer once its
first task is sent: set "task" in fleet.json, or type the task in the console
window after it opens (the overseer keeps looking for a while, and /detect in
Telegram adopts late arrivals).
#>
[CmdletBinding()]
param(
    [switch]$ConsolesOnly,
    [switch]$OverseerOnly,
    [int]$ExpectWorkers = 0,
    [int]$OverseerWaitSec = 180
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$consolePs1  = Join-Path $Root "manager\console.ps1"
$overseerPs1 = Join-Path $Root "manager\overseer.ps1"
if (-not (Test-Path $consolePs1) -or -not (Test-Path $overseerPs1)) {
    Write-Error "run me from the CICADA root (the folder containing agent.ps1)"
    exit 1
}

$cfgPath = Join-Path $Root "fleet.json"
$fleet = @()
if (-not $OverseerOnly -and -not (Test-Path $cfgPath)) {
    @"
[
  { "name": "contentgen", "project": "C:\\Users\\David\\contentgen", "task": "" },
  { "name": "facebook",   "project": "C:\\Users\\David\\facebook",   "task": "" },
  { "name": "instagram",  "project": "C:\\Users\\David\\instagram-hashtag-research-tool", "task": "" },
  { "name": "fourth",     "project": "C:\\path\\to\\fourth-project", "task": "" }
]
"@ | Set-Content $cfgPath -Encoding utf8
    Write-Host "created fleet.json - edit your 4 projects (+ optional opening task each), then re-run .\fleet.ps1" -ForegroundColor Yellow
    exit 0
}

if (-not $OverseerOnly) {
    $fleet = @(Get-Content $cfgPath -Raw | ConvertFrom-Json)
    if ($fleet.Count -eq 0) { Write-Error "fleet.json has no projects"; exit 1 }
}

# which projects already have a live worker session?
function Get-LiveWorkerProjects {
    $dirs = @()
    for ($port = 4311; $port -le 4320; $port++) {
        try {
            $sessions = Invoke-RestMethod -Method Get -Uri ("http://127.0.0.1:" + $port + "/session") -TimeoutSec 2
            foreach ($s in @($sessions)) {
                if ([string]$s.title -match '^worker-\d+$' -and $s.directory) { $dirs += ([string]$s.directory).TrimEnd('\') }
            }
        } catch {}
    }
    return $dirs
}

function Start-FleetConsole([string]$name, [string]$project, [string]$task) {
    $body = "& '" + $consolePs1 + "' -Project '" + ($project -replace "'","''") + "' -Workers 1"
    if ($task) { $body += " -Tasks @('" + ($task -replace "'","''") + "') -Yes" }
    $cmd = "`$host.UI.RawUI.WindowTitle = 'CICADA: " + ($name -replace "'","''") + "'; Set-Location -LiteralPath '" + $Root + "'; " + $body
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell -ArgumentList @("-NoExit", "-EncodedCommand", $enc) -WorkingDirectory $Root
}

$launched = 0
$skipped  = 0
if (-not $OverseerOnly) {
    $live = @(Get-LiveWorkerProjects)
    foreach ($p in $fleet) {
        $name = [string]$p.name
        $proj = [string]$p.project
        $task = [string]$p.task
        if (-not $proj) { continue }
        if (-not (Test-Path $proj -PathType Container)) {
            Write-Host ("  skip " + $name + ": project path not found - " + $proj) -ForegroundColor Yellow
            continue
        }
        $projFull = (Resolve-Path $proj).Path.TrimEnd('\')
        if ($live -contains $projFull) {
            Write-Host ("  skip " + $name + ": already has a live worker") -ForegroundColor DarkGray
            $skipped++
            continue
        }
        Start-FleetConsole $name $projFull $task
        Write-Host ("  launched console: " + $name + "  (" + $projFull + ")" + $(if ($task) { "  - opening task sent" } else { "  - type the first task in its window" })) -ForegroundColor Green
        $launched++
        Start-Sleep -Milliseconds 700   # stagger so the port grab never races
    }
}

if (-not $ConsolesOnly) {
    # launcher fix v1.1: the old CIM/WMI process query could hang for minutes
    # on this machine (the recurring WMI fault) and stall the launcher itself.
    # The overseer heartbeats manager\overseer.lock every poll - a FRESH lock
    # with a live PID means running. A wedged overseer holds a STALE lock: we
    # launch a new one and overseer v4.6+ kills the wedge at startup by window
    # title. Zero WMI on this path now.
    $ovRunning = $false
    try {
        $lockPath = Join-Path $Root "manager\overseer.lock"
        if (Test-Path $lockPath) {
            $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
            $lockAge = (New-TimeSpan -Start ([datetime]::Parse([string]$lock.stamp)) -End (Get-Date)).TotalSeconds
            $op = Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue
            if ($op -and $lockAge -lt 30) { $ovRunning = $true }
        }
    } catch {}
    if ($ovRunning) {
        Write-Host "  overseer already running - leaving it alone" -ForegroundColor DarkGray
    } else {
        $expect = if ($ExpectWorkers -gt 0) { $ExpectWorkers } else { $launched + $skipped }
        $obody = "& '" + $overseerPs1 + "' -AutoDetect -ExpectWorkers " + $expect + " -AutoDetectTimeoutSec " + $OverseerWaitSec
        Start-Process powershell -ArgumentList @("-NoExit", "-Command", $obody) -WorkingDirectory $Root
        Write-Host ("  launched overseer (auto-detect, expecting " + $expect + " worker(s))") -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Telegram cheat sheet:" -ForegroundColor Cyan
Write-Host "  roster arrives by itself (auto-detect)  -  or type /detect"
Write-Host "  /status   /doing Alpha   /interrupt Alpha <note>"
Write-Host "  'Alpha: <text>' steers one worker   -   'yes' sends its suggestion"
