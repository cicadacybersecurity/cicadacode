# ============================================================================
# CICADA dashboard.ps1 - read-only status surface for runs + workers.
#   .\dashboard.ps1         refresh loop (Ctrl+C to exit)
#   .\dashboard.ps1 -Once   render one frame and exit
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Once,
    [int]$RefreshSec = 3,
    [int]$RunCount = 4
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "manager\engine.ps1")
$WorkersFile = Join-Path $Root "state\workers.json"

function Truncate([string]$s, [int]$w) {
    if ($null -eq $s) { return "" }
    if ($s.Length -le $w) { return $s }
    return $s.Substring(0, [math]::Max(1, $w - 1)) + "~"
}

function Status-Color([string]$s) {
    switch ($s) {
        "done"     { "Green" }
        "complete" { "Green" }
        "blocked"  { "Red" }
        "failed"   { "Red" }
        "building" { "Yellow" }
        "review"   { "Yellow" }
        "retry"    { "Magenta" }
        default    { "Gray" }
    }
}

function Get-CicadaWorkers {
    if (-not (Test-Path $WorkersFile)) { return $null }
    try { return (Get-Content $WorkersFile -Raw | ConvertFrom-Json).workers } catch { return $null }
}

function Test-WorkerAlive([int]$port) {
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/session" -TimeoutSec 1
        return $true
    } catch { return $false }
}

function Show-Frame {
    Clear-Host
    Write-Host ""
    Write-Host "============================================" -ForegroundColor DarkRed
    Write-Host "              CICADA DASHBOARD" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor DarkRed
    Write-Host ("  " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor DarkGray
    Write-Host ""

    # ---------------- workers (parallel mode) ----------------
    Write-Host "Workers" -ForegroundColor Cyan
    Write-Host "-------" -ForegroundColor DarkGray
    $workers = Get-CicadaWorkers
    $props = @()
    if ($workers) { $props = @($workers.PSObject.Properties) }
    if ($props.Count -eq 0) {
        Write-Host "  No parallel workers registered." -ForegroundColor DarkGray
    } else {
        foreach ($p in $props) {
$w = $p.Value
$alive = Test-WorkerAlive ([int]$w.port)
$state = if ($alive) { "up" } else { "down" }
$col = if ($alive) { "Green" } else { "Red" }
$liveState = [string]$w.state
$age = ""
if ($w.updated) { try { $age = " " + [int]([DateTime]::UtcNow - [DateTime]::Parse($w.updated)).TotalMinutes + "m" } catch {} }
$stuck = ($alive -and $liveState -eq "busy" -and $w.log -and (Test-Path $w.log) -and (([DateTime]::UtcNow - (Get-Item $w.log).LastWriteTimeUtc).TotalMinutes -gt 5))
Write-Host ("  [{0}] {1}  port {2}  {3}" -f $p.Name, $w.title, $w.port, $state) -ForegroundColor $col
$agentName = "build"; if ($w.agent) { $agentName = $w.agent }
$modelName = "?"; if ($w.model) { $modelName = ($w.model -replace "minimax/","") }
$stateName = "idle"; if ($liveState) { $stateName = $liveState + $age }
$meta = "       " + $agentName + " | " + $modelName + " | " + $stateName
if ($stuck) { $meta += " | STUCK? (log quiet >5m)" }
Write-Host $meta -ForegroundColor $(if ($stuck) { "Red" } elseif ($liveState -eq "busy") { "Yellow" } else { "Gray" })
if ($w.project) { Write-Host ("       dir:  " + $w.project) -ForegroundColor DarkGray }
if ($w.task) { Write-Host ("       task: " + (Truncate $w.task 70)) -ForegroundColor Gray }
if ($w.log -and (Test-Path $w.log)) {
$snippet = ""
try { $tail = Get-Content $w.log -Tail 6; foreach ($line in $tail) { try { $ev = $line | ConvertFrom-Json; if ($ev.type -eq "text" -and $ev.part.text) { $t = ([regex]::Replace([string]$ev.part.text, "(?s)<think>.*?</think>", "")).Trim(); if ($t) { $snippet = $t } } elseif ($ev.type -eq "tool_use" -and $ev.part.tool) { $snippet = "[tool: " + $ev.part.tool + "]" } } catch {} } } catch {}
if ($snippet) { Write-Host ("       last: " + (Truncate ($snippet -replace "\s+"," ") 76)) -ForegroundColor DarkGray }
}
}
}
    Write-Host ""

    # ---------------- runs ----------------
    Write-Host "Runs" -ForegroundColor Cyan
    Write-Host "----" -ForegroundColor DarkGray
    $files = Get-ChildItem (Join-Path $Root "state\runs\*.json") -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First $RunCount
    if (-not $files) {
        Write-Host "  No runs yet." -ForegroundColor DarkGray
    } else {
        $latest = $true
        foreach ($f in $files) {
            $run = $null
            try { $run = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            $tasks = @($run.tasks)
            $done = @($tasks | Where-Object status -eq "done").Count
            $blocked = @($tasks | Where-Object status -eq "blocked").Count
            $cost = 0
            if ($run.totals -and $run.totals.cost) { $cost = [math]::Round([double]$run.totals.cost, 4) }
            $calls = 0
            if ($run.totals -and $run.totals.calls) { $calls = $run.totals.calls }
            $costStr = "`$$cost"
            Write-Host ("  {0}  {1,-12}  {2}" -f $run.id, $run.status, $run.mode) -ForegroundColor (Status-Color $run.status)
        if ($run.agentName) { Write-Host ("     agent: " + $run.agentName + "  (steer: press / then " + $run.agentName + " <message>)") -ForegroundColor Cyan }
if ($run.status -eq "running" -and $run.updated) { try { $runAge = [int]([DateTime]::UtcNow - [DateTime]::Parse($run.updated)).TotalMinutes; Write-Host ("     last event " + $runAge + " min ago" + $(if ($runAge -gt 10) { " - quiet, check it" } else { "" })) -ForegroundColor DarkYellow } catch {} }
            Write-Host ("     tasks {0}/{1} done, {2} blocked | calls {3} | cost {4}" -f $done, $tasks.Count, $blocked, $calls, $costStr) -ForegroundColor Gray

            if ($latest -and $tasks.Count -gt 0) {
                foreach ($t in $tasks) {
                    Write-Host ("     #{0} [{1,-8}] x{2} {3}" -f $t.n, $t.status, $t.attempts, (Truncate $t.title 58)) -ForegroundColor (Status-Color $t.status)
                    if ($t.verdict -and $t.status -ne "done") {
                        Write-Host ("          " + (Truncate $t.verdict 66)) -ForegroundColor DarkGray
                    }
                }
            }
            $latest = $false
        }
    }

    Write-Host ""
    Write-Host ("Ctrl+C to exit. Refresh: " + $RefreshSec + "s  |  press / to steer an agent") -ForegroundColor DarkGray
}

Repair-CicadaStaleRuns
Show-CicadaCheatsheet
if ($Once) { Show-Frame; Show-CicadaCheatsheet; exit 0 }
while ($true) {
    Show-Frame
    $waitUntil = (Get-Date).AddSeconds($RefreshSec)
    while ((Get-Date) -lt $waitUntil) {
        $pressed = $false
        try { $pressed = [Console]::KeyAvailable } catch { Start-Sleep -Milliseconds 500; continue }
        if ($pressed) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq '/') {
                Write-Host ""
                Write-Host "  Steer an agent: <Name> <message>   (names are the agent: labels in the Runs list)" -ForegroundColor Yellow
                $cmd = (Read-Host "  /interrupt").Trim()
                if ($cmd) {
                    $bits = $cmd -split '\s+', 2
                    if ($bits.Count -eq 2 -and $bits[1].Trim()) {
                        $target = $bits[0]
                        $note = $bits[1].Trim()
                        $file = "steer-" + $target.ToLower() + ".txt"
                        $line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $note
                        $line | Set-Content (Join-Path $Root ("state\" + $file)) -Encoding utf8
                        Write-Host ("  queued for " + $target + " - its loop picks it up within ~15s") -ForegroundColor Green
                    } else {
                        Write-Host "  need a name and a message - nothing sent" -ForegroundColor DarkGray
                    }
                    Start-Sleep -Seconds 2
                }
            }
        }
        Start-Sleep -Milliseconds 150
    }
}




