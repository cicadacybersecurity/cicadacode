# ============================================================================
# CICADA console.ps1 - one-terminal parallel worker console.
#   .\manager\console.ps1 -Project <dir>                     interactive setup
#   .\manager\console.ps1 -Project <dir> -Workers 2 -Tasks @("..","..") -Yes
#
# Session model: each console launch is a fresh fleet. A worker's session is
# captured from its own job log when the job finishes and kept in memory
# ($w.session). Old logs are forensics only - never used for resolution.
# ============================================================================
[CmdletBinding()]
param(
    [string]$Project,
    [ValidateRange(0,3)]
    [int]$Workers = 0,
    [string[]]$Tasks = @(),
    [string]$Model = "minimax/MiniMax-M2.7",
    [string]$Agent = "",
    [string[]]$Models = @(),
    [switch]$Yes
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root "manager\engine.ps1")
Repair-CicadaStaleRuns
Import-CicadaSecrets
$Tasks = @($Tasks | ForEach-Object { Resolve-CicadaText $_ })
$ConfigPath  = Join-Path $Root "minimax-opencode.json"
$WorkersFile = Join-Path $Root "state\workers.json"
$LogDir      = Join-Path $Root "state\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

$script:WorkerRegistry = @{}
$script:ConsolePrinted = $false
$script:Jobs           = @{}

if (-not $Project) { $Project = (Read-Host "Project").Trim() }
if (-not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path

# ---------- helpers ----------

function Resolve-ModelName([string]$m) {
switch -Regex ($m.Trim().ToLower()) {
"^m3$"      { return "minimax/MiniMax-M3" }
"^m2\.?7?$" { return "minimax/MiniMax-M2.7" }
default     { return $m }
}
}
function Get-FreePort([int]$start) {
    $p = $start
    while ($true) {
        try {
            $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
            $l.Start(); $l.Stop(); return $p
        } catch { $p++ }
    }
}

function Wait-WorkerUp([int]$port) {
    for ($i = 0; $i -lt 30; $i++) {
        try { $null = Invoke-RestMethod "http://127.0.0.1:$port/session" -TimeoutSec 2; return $true }
        catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function Save-WorkerRegistry {
    $obj = [ordered]@{ workers = [ordered]@{} }
    foreach ($id in ($script:WorkerRegistry.Keys | Sort-Object { [int]$_ })) {
        $w = $script:WorkerRegistry[$id]
        $obj.workers[$id] = [ordered]@{ title = $w.title; port = $w.port; pid = $w.pid; task = $w.task; session = $w.session; model = $w.model; agent = $w.agent; state = $w.state; log = $w.log; updated = $w.updated; project = $Project; started = $w.started }
    }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content $WorkersFile -Encoding utf8
}

function Send-WorkerMessage([string]$id, [string]$message) {
    $w = $script:WorkerRegistry[$id]
    if (-not $w) { Write-Host "  No worker $id." -ForegroundColor Red; return }
    Finalize-WorkerJob $id
    if ($script:Jobs.ContainsKey($id)) { $act = Get-WorkerCurrentAction $w.log; Write-Host ("  worker $id is busy" + $(if ($act) { " - currently: $act" } else { " - wait for it to finish" })) -ForegroundColor Yellow; return }

    $flat = ($message -replace "\r\n?", " ")
    $url  = "http://127.0.0.1:$($w.port)"
    $exe  = Resolve-OpenCodeExe
    $wm = $Model; if ($w.model) { $wm = $w.model }
    $wa = "build"; if ($w.agent) { $wa = $w.agent }
$args = @("run", $flat, "--attach", $url, "--dir", $Project, "--agent", $wa, "-m", $wm, "--pure", "--format", "json", "--title", $w.title)
    if ($w.session) { $args += @("--session", $w.session) }
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
    $log   = Join-Path $LogDir ("w" + $id + "-" + $stamp + ".jsonl")

    $job = Start-Job -ScriptBlock {
        param($exe, $a, $logPath, $cfg)
        $env:OPENCODE_CONFIG = $cfg
        & $exe @a 2>&1 | Out-File -FilePath $logPath -Encoding utf8
        return $LASTEXITCODE
    } -ArgumentList $exe, $args, $log, $ConfigPath
    $script:Jobs[$id] = @{ Job = $job; Log = $log }
$w.state = "busy"; $w.log = $log; $w.updated = [DateTime]::UtcNow.ToString("o"); Save-WorkerRegistry

    if ($w.session) { Write-Host ("  -> worker " + $id) -ForegroundColor DarkGray }
    else            { Write-Host ("  -> worker " + $id + " (new session)") -ForegroundColor DarkGray }
}

function Get-WorkerTail([string]$id) {
    $w = $script:WorkerRegistry[$id]
    if (-not $w) { Write-Host "  No worker $id." -ForegroundColor Red; return }
    if ($script:Jobs.ContainsKey($id)) { Write-Host "  (working...)" -ForegroundColor DarkGray; return }
    if (-not $w.session) { Write-Host "  (no session yet)" -ForegroundColor DarkGray; return }
    try { $msgs = Invoke-RestMethod ("http://127.0.0.1:" + $w.port + "/session/" + $w.session + "/message") -TimeoutSec 5 }
    catch { Write-Host ("  read failed: " + $_.Exception.Message) -ForegroundColor Red; return }
    $last = $msgs | Where-Object { $_.info.role -eq "assistant" } | Select-Object -Last 1
    if (-not $last) { Write-Host "  (no reply yet)" -ForegroundColor DarkGray; return }
    $text = (($last.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n")
    $text = [regex]::Replace($text, "(?s)<think>.*?</think>", "").Trim()
    $lines = $text -split "`n"
    if ($lines.Count -gt 40) { Write-Host ("  ... (" + ($lines.Count - 40) + " earlier lines omitted)") -ForegroundColor DarkGray; $lines = $lines[($lines.Count - 40)..($lines.Count - 1)] }
    foreach ($l in $lines) { Write-Host ("  " + $l) }
}

function Show-WorkerStatus {
    if ($script:WorkerRegistry.Count -eq 0) { Write-Host "  No workers." -ForegroundColor DarkGray; return }
    foreach ($id in ($script:WorkerRegistry.Keys | Sort-Object { [int]$_ })) {
        $w = $script:WorkerRegistry[$id]
        $alive = $false
        try { $null = Invoke-RestMethod ("http://127.0.0.1:" + $w.port + "/session") -TimeoutSec 1; $alive = $true } catch { }
        $entry = $script:Jobs[$id]
        $busy = ($entry -and $entry.Job.State -eq "Running")
        $cost = ""
        if ($alive -and $w.session) {
            try {
                $s = Invoke-RestMethod ("http://127.0.0.1:" + $w.port + "/session") -TimeoutSec 2
                $sess = $s | Where-Object { $_.id -eq $w.session } | Select-Object -First 1
                if ($sess -and $sess.cost) { $cost = "cost `$" + [math]::Round([double]$sess.cost, 4) }
            } catch { }
        }
        $state = ($(if ($alive) { "up" } else { "down" })) + "/" + ($(if ($busy) { "busy" } else { "idle" }))
        $col = if (-not $alive) { "Red" } elseif ($busy) { "Yellow" } else { "Green" }
        Write-Host ("  [" + $id + "] " + $w.title + "  port " + $w.port + "  " + $state + "  " + $cost) -ForegroundColor $col
        Write-Host ("       model: " + $(if ($w.model) { $w.model } else { $Model })) -ForegroundColor DarkGray
        if ($w.task) { Write-Host ("       task: " + $w.task) -ForegroundColor DarkGray }
    }
}

function Abort-WorkerTurn([string]$id) {
$w = $script:WorkerRegistry[$id]
if (-not $w) { Write-Host "  No worker $id." -ForegroundColor Red; return }
$entry = $script:Jobs[$id]
if (-not $entry) { Write-Host "  worker $id is idle - nothing to abort" -ForegroundColor DarkGray; return }
$sid = $w.session
if (-not $sid -and (Test-Path $entry.Log)) {
$m = Select-String -Path $entry.Log -Pattern '"sessionID":"(ses_[^"]+)"' | Select-Object -First 1
if ($m) { $sid = $m.Matches[0].Groups[1].Value }
}
if (-not $sid) { Write-Host "  worker $id - no session id yet; try again in a few seconds" -ForegroundColor Yellow; return }
try {
$r = Invoke-RestMethod -Method Post -Uri ("http://127.0.0.1:" + $w.port + "/session/" + $sid + "/abort") -TimeoutSec 5
Write-Host ("  abort sent to worker " + $id + " (session " + $sid + "); server returned: " + $r) -ForegroundColor Yellow
Write-Host "  turn cancelled server-side; the worker stays up and keeps its session" -ForegroundColor DarkGray
} catch { Write-Host ("  abort failed: " + $_.Exception.Message) -ForegroundColor Red }
}

function Stop-Worker([string]$id) {
    $w = $script:WorkerRegistry[$id]
    if (-not $w) { Write-Host "  No worker $id." -ForegroundColor Red; return }
    $entry = $script:Jobs[$id]
    if ($entry) { Stop-Job $entry.Job -ErrorAction SilentlyContinue; Remove-Job $entry.Job -Force -ErrorAction SilentlyContinue; $script:Jobs.Remove($id) }
    if ($w.pid) { Stop-Process -Id $w.pid -Force -ErrorAction SilentlyContinue }
    $script:WorkerRegistry.Remove($id)
    Save-WorkerRegistry
    Write-Host ("  worker " + $id + " stopped.") -ForegroundColor Yellow
}

function Finalize-WorkerJob([string]$id) {
    $entry = $script:Jobs[$id]
    if (-not $entry) { return }
    if ($entry.Job.State -eq "Running") { return }
    $code = Receive-Job $entry.Job -ErrorAction SilentlyContinue
    Remove-Job $entry.Job -Force -ErrorAction SilentlyContinue
    $script:Jobs.Remove($id)
    $sid = $null
    if (Test-Path $entry.Log) {
        $m = Select-String -Path $entry.Log -Pattern '"sessionID":"(ses_[^"]+)"' | Select-Object -First 1
        if ($m) { $sid = $m.Matches[0].Groups[1].Value }
    }
    $w = $script:WorkerRegistry[$id]
    if ($sid -and $w) { $w.session = $sid; Save-WorkerRegistry }
    Write-Host ""
    Write-Host ""
    Write-Host ("  --- worker " + $id + $(if ($w.agent) { " (" + $w.agent + ")" } else { "" }) + " " + ("-" * 40)) -ForegroundColor DarkCyan
    $agentLabel = "build"; if ($w.agent) { $agentLabel = $w.agent }
    Send-CicadaTelegram ("CICADA worker ready | agent: " + $agentLabel + " | project: " + (Split-Path -Leaf $Project) + " | worker " + $id + " exit " + $code + " | task: " + $w.title + " | reply waiting")
    $w.state = "idle"; $w.updated = [DateTime]::UtcNow.ToString("o"); Save-WorkerRegistry
    $script:ConsolePrinted = $true
    Get-WorkerTail $id
    Write-Host ("  " + ("-" * 46)) -ForegroundColor DarkCyan
}

function Sweep-Jobs {
    foreach ($id in @($script:Jobs.Keys)) { Finalize-WorkerJob $id }
}

function Show-Help {
    Write-Host ""
    Write-Host "  <n>> <message>   send a message to worker n      (e.g.  1> fix the auth bug)"
    Write-Host "  /status          worker table: up/down, busy/idle, cost"
    Write-Host "  /tail <n>        show worker n's latest reply"
    Write-Host "  /attach <n>      take over worker n's full TUI (exit TUI to return here)"
    Write-Host "  /abort <n>       cancel the current turn on worker n (worker survives; session kept)"
Write-Host "  /doing <n>       show the command worker n is currently running"
    Write-Host "  /stop <n>        stop worker n"
    Write-Host "  /quit            stop all workers and exit"
    Write-Host ""
}

# ---------- setup ----------
if ($Workers -le 0 -and -not $Yes) { $wi = Show-CicadaMenu -Title "How many workers? (slot 4 stays reserved)" -Options @("1","2","3") -Default 1; $Workers = $wi + 1 }
if ($Workers -le 0) { $Workers = 1 }
if ($Workers -gt 3) { Write-Host "capped at 3 workers (slot 4 reserved)" -ForegroundColor Yellow; $Workers = 3 }

$taskList = @()

$modelList = @()
for ($i = 1; $i -le $Workers; $i++) {
    $t = ""
    if ($i -le $Tasks.Count) { $t = [string]$Tasks[$i - 1] }
    elseif (-not $Yes) { $t = Read-CicadaPrompt -Label ("Agent " + $i + " task (empty = start idle)") -Project $Project; if ($t -eq "__CANCEL__") { $t = "" } }
    $taskList += $t
    $mdl = ""
    if ($i -le $Models.Count) { $mdl = [string]$Models[$i - 1] }
    elseif (-not $Yes) { $mi2 = Show-CicadaMenu -Title ("Agent " + $i + " model (fleet default: " + $Model + ")") -Options @("MiniMax-M2.7","MiniMax-M3") -Default $(if ($Model -match "M3") { 1 } else { 0 }); $mdl = @("m2.7","m3")[$mi2] }
    $modelList += $mdl
}

if (-not $Yes) {
    $fmi = Show-CicadaMenu -Title "Fleet default model" -Options @("MiniMax-M2.7","MiniMax-M3","custom (type full model id)") -Default $(if ($Model -match "M3") { 1 } else { 0 })
    if ($fmi -eq 0) { $Model = "minimax/MiniMax-M2.7" } elseif ($fmi -eq 1) { $Model = "minimax/MiniMax-M3" } else { $Model = (Read-Host "Full model id").Trim() }
    Write-Host ""
    Write-Host ("  Project: " + $Project)
    for ($i = 1; $i -le $Workers; $i++) { Write-Host ("  Agent " + $i + ": " + $(if ($taskList[$i-1]) { $taskList[$i-1] } else { "(idle)" })) }
    Write-Host ("  Model:   " + $Model)
    Write-Host ""
    $goi = Show-CicadaMenu -Title "Start workers?" -Options @("Start","Cancel") -Default 0
    if ($goi -ne 0) { Write-Host "Aborted."; exit 0 }
}

$Model = Resolve-ModelName $Model

# ---------- launch ----------

for ($i = 1; $i -le $Workers; $i++) {
    $id = [string]$i
    $port = Get-FreePort (4310 + $i)
    $title = "worker-" + $id
    $proc = Start-Process -FilePath (Resolve-OpenCodeExe) -ArgumentList @("serve", "--port", "$port", "--hostname", "127.0.0.1") -WorkingDirectory $Project -PassThru -WindowStyle Hidden
    if (Wait-WorkerUp $port) {
        $wmodel = $Model; if ($i -le $modelList.Count -and $modelList[$i-1]) { $wmodel = Resolve-ModelName $modelList[$i-1] }
        $script:WorkerRegistry[$id] = @{ title = $title; port = $port; pid = $proc.Id; task = $taskList[$i-1]; model = $wmodel; agent = $Agent; session = $null; state = "idle"; log = $null; updated = $null; started = [DateTime]::UtcNow.ToString("o") }
        Write-Host ("  worker " + $id + " up on port " + $port) -ForegroundColor Green
    } else {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Write-Host ("  worker " + $id + " FAILED to start on port " + $port) -ForegroundColor Red
    }
}
Save-WorkerRegistry

foreach ($id in @($script:WorkerRegistry.Keys | Sort-Object { [int]$_ })) {
    $t = $script:WorkerRegistry[$id].task
    if ($t) { Send-WorkerMessage $id $t }
}

Write-Host ""
Write-Host ("Parallel console ready - " + $script:WorkerRegistry.Count + " worker(s). Type /help for commands.") -ForegroundColor Cyan
Show-Help
Write-Host "Tip: .\dashboard.ps1 -Once in another terminal shows the same workers." -ForegroundColor DarkGray

# ---------- REPL ----------

try {
    while ($true) {
        Sweep-Jobs
        Write-Host "cicada: " -NoNewline -ForegroundColor DarkGray
        $line = ""
        while ($true) {
            Sweep-Jobs
            if ($script:ConsolePrinted) { Write-Host ("`r" + (" " * 60) + "`rcicada: " + $line) -NoNewline -ForegroundColor DarkGray; $script:ConsolePrinted = $false }
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) { Start-Sleep -Milliseconds 30; if ([Console]::KeyAvailable) { $line += " "; [Console]::Write(" "); continue }; Write-Host ""; break }
                if ($key.Key -eq [ConsoleKey]::Backspace) { if ($line.Length -gt 0) { $line = $line.Substring(0, $line.Length - 1); [Console]::Write("`b `b") }; continue }
                $ch = $key.KeyChar
                if ([int]$ch -ge 32) { $line += $ch; [Console]::Write($ch) }
            } else {
                Start-Sleep -Milliseconds 250
            }
        }
        $line = $line.Trim()
        if (-not $line) { continue }

        if ($line -match "^>\s*(\d+)\s+(.+)$") { $line = $Matches[1] + "> " + $Matches[2] }
        if ($line -match "^(\d+)\s*>\s*(.+)$") {
            Test-CicadaFileClaim $Matches[1] $Matches[2]
            Send-WorkerMessage $Matches[1] $Matches[2]
            continue
        }

        if ($line -match "^/(\w+)(?:\s+(\d+))?$") {
            $cmd = $Matches[1].ToLower()
            $n = $Matches[2]
            if ($cmd -eq "help") { Show-Help }
            elseif ($cmd -eq "doing") { if ($arg) { $act = Get-WorkerCurrentAction $script:WorkerRegistry[$arg].log; Write-Host ("  worker " + $arg + ": " + $(if ($act) { $act } else { "idle - nothing in flight" })) -ForegroundColor Cyan } else { Write-Host "  usage: /doing <n>" -ForegroundColor DarkGray } }
            elseif ($cmd -eq "status") { Show-WorkerStatus }
            elseif ($cmd -eq "tail") { if ($n) { Get-WorkerTail $n } else { Write-Host "usage: /tail <n>" } }
            elseif ($cmd -eq "attach") {
                if (-not $n) { Write-Host "usage: /attach <n>" }
                elseif (-not $script:WorkerRegistry[$n]) { Write-Host "  No worker $n." -ForegroundColor Red }
                else {
                    $w = $script:WorkerRegistry[$n]
                    Write-Host ("Attaching to worker " + $n + " - exit the opencode TUI to return here.") -ForegroundColor DarkGray
                    & (Resolve-OpenCodeExe) attach ("http://127.0.0.1:" + $w.port)
                    Write-Host "Back at console." -ForegroundColor DarkGray
                }
            }
            elseif ($cmd -eq "abort") { if ($n) { Abort-WorkerTurn $n } else { Write-Host "usage: /abort <n>" } }
            elseif ($cmd -eq "stop") { if ($n) { Stop-Worker $n } else { Write-Host "usage: /stop <n>" } }
            elseif ($cmd -eq "quit" -or $cmd -eq "exit") { break }
            else { Write-Host "Unknown command - /help" -ForegroundColor DarkGray }
            continue
        }

        if ($script:WorkerRegistry.Count -eq 1) { $only = ($script:WorkerRegistry.Keys | Select-Object -First 1); Send-WorkerMessage $only $line } else { Write-Host "Unrecognised input - send as <n> > <message> or type /help" -ForegroundColor DarkGray }
    }
}
finally {
    foreach ($id in @($script:WorkerRegistry.Keys)) { Stop-Worker $id }
    '{ "workers": {} }' | Set-Content $WorkersFile -Encoding utf8
    Write-Host "Console closed - all workers stopped." -ForegroundColor DarkGray
}




























# ---------- port #4: file claiming for parallel workers ----------
$script:FileClaims = @{}
function Test-CicadaFileClaim {
    param([string]$WorkerId, [string]$Message)
    $paths = @([regex]::Matches($Message, '(?:[A-Za-z]:\\[\w\.\-\\/]+|[\w\.\-]+(?:[/\\][\w\.\-]+)+\.\w{1,5})') | ForEach-Object { $_.Value.Trim() })
    if ($paths.Count -eq 0) { return }
    foreach ($k in @($script:FileClaims.Keys)) {
        $owner = $script:FileClaims[$k]
        $w = $script:WorkerRegistry[$owner]
        if (-not $w -or $w.state -ne "busy") { $script:FileClaims.Remove($k) }
    }
    foreach ($p in $paths) {
        $owner = $script:FileClaims[$p]
        if ($owner -and $owner -ne $WorkerId) {
            Write-Host ("  [file-claim] " + $p + " is owned by worker " + $owner + " - collision risk; hold this task or let the owner finish") -ForegroundColor Yellow
        } else {
            $script:FileClaims[$p] = $WorkerId
        }
    }
}

