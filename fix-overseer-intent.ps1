#Requires -Version 5.1
<#
fix-overseer-intent.ps1  v2 - ONE job, no patch layers, no interior anchors.

Replaces two whole functions in manager\overseer.ps1 (found by their boundary
lines, so drift INSIDE the functions cannot break this):

1. Invoke-IntentDecode - the free-form message decoder. "ask alpha whats next
   to implement" was decoded as 'doing' (answered from history) instead of
   'steer' (delivered to the worker). New prompt: steer is the default for
   anything the worker itself could act on or answer; 'doing' shrinks to a
   pure is-it-busy check.

2. Get-WorkerDoing - the "Last word:" tail leaked raw <think>...</think>
   reasoning. Now stripped before sending.

Run from the CICADA root:
    powershell -ExecutionPolicy Bypass -File .\fix-overseer-intent.ps1

Safe to re-run (each function swap detects its own marker and skips).
Syntax-checks the whole file before writing; aborts cleanly on any surprise.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$file = Join-Path $root "manager\overseer.ps1"
if (-not (Test-Path $file)) { Write-Error "manager\overseer.ps1 not found - run me from the CICADA root (folder with agent.ps1)."; exit 1 }

# ---- the two replacement functions ----

$newIntentDecode = @'
function Invoke-IntentDecode([string]$text, [string]$rosterNames) {
    # intent fix v2.1: steer is the default for worker-bound messages
    $sys = "You are the command decoder for a worker-fleet overseer bot. The operator types free-form messages about workers identified by callsigns. Decode into a JSON object with exactly these keys: action (one of: interrupt, steer, query, doing, status, fleet, detect, none), target (the worker callsign mentioned, or empty string), text (the message to deliver, or empty string). Rules: steer = the message is FOR the worker to act on - an instruction, a task, or a question the worker itself should answer in its next turn (examples: ask alpha whats next to implement, tell bravo to run the tests, get charlie to fix the gate, alpha do phase 7). Put the operator's actual instruction in text, phrased as a message to the worker, minus the leading callsign/ask/tell phrasing. doing = ONLY a live state check (is X busy right now, what is X mid-way through) - never a question the worker should answer. query = the operator wants YOU to answer from the worker's session history WITHOUT messaging it (what did X finish, why did X fail). Golden rule: if the words could be typed into the worker's own console for it to act on, choose steer; when in doubt between steer and anything else, choose steer. interrupt = only when the operator explicitly wants to abort the worker's current in-flight turn. status/fleet = whole-fleet overview. detect = rescan for workers. none = not about the fleet at all. Live workers: " + $rosterNames + ". Reply with ONLY the JSON object - no markdown fences, no commentary."
    $body = @{ model = ($Model -replace "^minimax/", ""); messages = @(@{ role = "system"; content = $sys }, @{ role = "user"; content = $text }); temperature = 0; max_tokens = 200 } | ConvertTo-Json -Depth 10
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
        $t = [string]$resp.choices[0].message.content
        $t = [regex]::Replace($t, "(?s)<think>.*?</think>", "").Trim()
        $t = $t -replace '(?s)^```(json)?', '' -replace '```\s*$', ''
        $t = $t.Trim()
        if ($resp.usage) { Write-Host ("  (decode: " + $resp.usage.prompt_tokens + " in / " + $resp.usage.completion_tokens + " out)") -ForegroundColor DarkGray }
        return ($t | ConvertFrom-Json)
    } catch {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host ("  decode API error: " + $_.ErrorDetails.Message) -ForegroundColor DarkYellow }
        return $null
    }
}
'@

$newWorkerDoing = @'
function Get-WorkerDoing($wk) {
    # intent fix v2.1: strip think tags from the tail
    $msgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 15
    $lastAny = $null; $lastAssistant = $null
    foreach ($mm in @($msgs)) {
        $role = [string]$mm.info.role
        if ($role) { $lastAny = $mm }
        if ($role -eq "assistant") { $lastAssistant = $mm }
    }
    $busy = ($lastAny -and [string]$lastAny.info.role -eq "user")
    $tail = ""
    if ($lastAssistant) {
        $parts = @($lastAssistant.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
        $tail = [regex]::Replace(($parts -join " "), "(?s)<think>.*?</think>", "")
        $tail = ($tail -replace "\s+", " ").Trim()
        if ($tail.Length -gt 500) { $tail = $tail.Substring(0, 500) + "..." }
    }
    return @{ busy = $busy; tail = $tail }
}
'@

# ---- read, preserving BOM ----
$bytes = [System.IO.File]::ReadAllBytes($file)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$enc = New-Object System.Text.UTF8Encoding($false, $false)
if ($bom) { $text = $enc.GetString($bytes, 3, $bytes.Length - 3) } else { $text = $enc.GetString($bytes, 0, $bytes.Length) }

# ---- line-based function swap: boundaries only, interior never read ----
function Swap-CicadaFunction([string[]]$lines, [string]$fnName, [string[]]$newBody) {
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ("^\s*function\s+" + [regex]::Escape($fnName) + "\b")) { $start = $i; break }
    }
    if ($start -lt 0) { return @{ ok = $false; err = ("function " + $fnName + " not found") } }
    $end = -1
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "}") { $end = $i; break }   # first brace alone at column 0 = function end
    }
    if ($end -lt 0) { return @{ ok = $false; err = ("found start of " + $fnName + " but not its closing brace") } }
    $head = @(); $tail = @()
    if ($start -gt 0) { $head = @($lines[0..($start - 1)]) }
    if ($end -lt $lines.Count - 1) { $tail = @($lines[($end + 1)..($lines.Count - 1)]) }
    return @{ ok = $true; lines = (@($head) + @($newBody) + @($tail)); start = $start; end = $end }
}

$swaps = @(
    @{ Name = "Invoke-IntentDecode"; Body = ($newIntentDecode -split "`r?`n"); Label = "intent decoder: steer is the default for worker-bound messages" },
    @{ Name = "Get-WorkerDoing";      Body = ($newWorkerDoing -split "`r?`n"); Label = "doing tail: think tags stripped" }
)

$work = $text
$didWork = @(); $already = @(); $problems = @()

foreach ($sw in $swaps) {
    # already applied? (marker lives inside the new function body)
    $fnPat = "(?s)^\s*function\s+" + [regex]::Escape($sw.Name) + "\b.*?\n}"
    $m = [regex]::Match($work, "(?m)^\s*function\s+" + [regex]::Escape($sw.Name) + "\b")
    if (-not $m.Success) { $problems += ($sw.Label + ": function " + $sw.Name + " not found - NOT writing anything"); continue }
    # find current body text to check the marker
    $cur = $work.Substring($m.Index)
    $curLines = $cur -split "`r?`n"
    $braceIdx = -1
    for ($i = 1; $i -lt $curLines.Count; $i++) { if ($curLines[$i] -eq "}") { $braceIdx = $i; break } }
    if ($braceIdx -gt 0) {
        $bodyText = ($curLines[0..$braceIdx] -join "`n")
        if ($bodyText.Contains("intent fix v2.1")) { $already += $sw.Label; continue }
    }

    $lines = $work -split "`r?`n"
    $r = Swap-CicadaFunction $lines $sw.Name $sw.Body
    if (-not $r.ok) { $problems += ($sw.Label + ": " + $r.err + " - NOT writing anything"); continue }
    $work = ($r.lines -join "`r`n")
    $didWork += ($sw.Label + " (lines " + ($r.start + 1) + "-" + ($r.end + 1) + ")")
}

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "ABORTED - no files were modified:" -ForegroundColor Red
    foreach ($x in $problems) { Write-Host ("  " + $x) -ForegroundColor Red }
    exit 1
}

if ($didWork.Count -eq 0) {
    Write-Host "both fixes already present - nothing to do." -ForegroundColor DarkGray
    exit 0
}

# ---- syntax check the WHOLE file before writing ----
$errs = $null
[void][System.Management.Automation.PSParser]::Tokenize($work, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Error ("syntax check failed after replacement (" + $errs[0].Message + ") - nothing was written")
    exit 1
}

# ---- git snapshot so this is reversible (safe if git missing) ----
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git -and (Test-Path (Join-Path $root ".git"))) {
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Push-Location $root
    try {
        & git add -A 2>&1 | Out-Null
        & git commit --quiet -m "snapshot before fix-overseer-intent v2" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "git: snapshot committed (rollback: git checkout -- manager\overseer.ps1)" -ForegroundColor DarkGray }
    } finally { Pop-Location; $ErrorActionPreference = $oldEAP }
}

$wenc = New-Object System.Text.UTF8Encoding($bom, $false)
[System.IO.File]::WriteAllText($file, $work, $wenc)

Write-Host ""
foreach ($s in $already) { Write-Host ("  skip (already applied): " + $s) -ForegroundColor DarkGray }
foreach ($d in $didWork) { Write-Host ("  fixed: " + $d) -ForegroundColor Green }
Write-Host ""
Write-Host "Done. Now: close the overseer window, start it again ( .\fleet.ps1 -OverseerOnly -ExpectWorkers 3 )." -ForegroundColor Cyan
Write-Host "Then in Telegram:  'ask alpha whats next to implement' DELIVERS it to Alpha." -ForegroundColor Cyan
Write-Host "(The deterministic form always works too:  Alpha: implement the next phase )" -ForegroundColor DarkGray
