# ============================================================================
# CICADA engine.ps1 - core primitives: agent invocation + run journals.
# Dot-source before use:  . .\manager\engine.ps1
# No side effects on load.
# ============================================================================

$script:EngineRoot  = Split-Path -Parent $PSScriptRoot
$script:ConfigPath  = Join-Path $script:EngineRoot "minimax-opencode.json"
$script:SecretsPath = Join-Path $script:EngineRoot "manager\secrets.json"
$script:StateDir    = Join-Path $script:EngineRoot "state"
$script:RunDir      = Join-Path $script:StateDir "runs"
$script:LogDir      = Join-Path $script:StateDir "logs"

function Import-CicadaSecrets {
    if (Test-Path $script:SecretsPath) {
        $s = Get-Content $script:SecretsPath -Raw | ConvertFrom-Json
        foreach ($p in $s.PSObject.Properties) {
            $v = [string]$p.Value
            if ($v -and $v -notmatch "^PASTE-") {
                # fleet fix: secrets.json is AUTHORITATIVE. The old guard only set
                # a var if the process lacked one, so a stale MINIMAX_API_KEY
                # inherited from the launching shell silently beat the file -
                # after a key rotation every API call 401'd while the file tested
                # fine. Always overwrite Process scope.
                [Environment]::SetEnvironmentVariable($p.Name, $v, "Process")
            }
        }
    }
}

function Resolve-OpenCodeExe {
    # Prefer the real binary over the npm .cmd shim: cmd.exe mangles prompts
    # containing quotes or shell metacharacters (the shim forwards %* raw).
    $exe = Join-Path $env:APPDATA "npm\node_modules\opencode-ai\bin\opencode.exe"
    if (Test-Path $exe) { return $exe }
    $cmd = Get-Command "opencode.cmd" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command "opencode" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "opencode was not found on PATH."
}

# --- hardening: opencode version drift detection -----------------------------
# This harness parses opencode's JSON event stream (step_finish, tokens, cost).
# If an opencode update changes that schema, accounting breaks silently. Record
# the version on first run and warn loudly whenever it changes underneath us.
$script:OpenCodeVersionFile = Join-Path $script:StateDir "opencode-version.txt"
$script:OpenCodeDriftChecked = $false

function Test-CicadaOpenCodeDrift {
    if ($script:OpenCodeDriftChecked) { return }
    $script:OpenCodeDriftChecked = $true
    try {
        $exe = Resolve-OpenCodeExe
        $v = (& $exe --version 2>&1 | Out-String).Trim()
        if (-not $v) { return }
        if (Test-Path $script:OpenCodeVersionFile) {
            $pinned = (Get-Content $script:OpenCodeVersionFile -Raw).Trim()
            if ($pinned -and $pinned -ne $v) {
                Write-Host ("WARNING: opencode version changed (" + $pinned + " -> " + $v + "). If runs misbehave or token/cost totals read zero, the event schema may have changed. Verify a run works, then delete state\opencode-version.txt to accept the new version.") -ForegroundColor Yellow
            }
        } else {
            if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
            $v | Set-Content $script:OpenCodeVersionFile -Encoding utf8
        }
    } catch { }
}

function Invoke-Agent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Project,
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Model,
        [string]$Agent,
        [string]$SessionId,
        [switch]$Continue,
        [switch]$Fork,
        [switch]$Auto,
        [string]$Title,
        [string]$LogPath
    )

    if (-not (Test-Path $Project -PathType Container)) { throw "Project directory not found: $Project" }
    $Project = (Resolve-Path $Project).Path
    Import-CicadaSecrets
    $exe = Resolve-OpenCodeExe
    Test-CicadaOpenCodeDrift  # hardening: warn if opencode updated underneath us

    if (-not $LogPath) {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
        $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
        $name  = if ($Title) { ($Title -replace "[^\w\-]", "-") } else { "run" }
        $LogPath = Join-Path $script:LogDir "$stamp-$name.jsonl"
    }

    # Flatten multi-line prompts: native .cmd shims cannot carry embedded newlines.
    $flatPrompt = ($Prompt -replace "\r\n?", "`n") -replace "`n", " "
    # Escape embedded quotes for PS 5.1 native argument passing
    $flatPrompt = $flatPrompt -replace '"', '\"'
    $ocArgs = @("run", $flatPrompt, "--pure", "--format", "json", "--dir", $Project)
    if ($Model)     { $ocArgs += @("-m", $Model) }
    if ($Agent)     { $ocArgs += @("--agent", $Agent) }
    if ($SessionId) { $ocArgs += @("--session", $SessionId) }
    elseif ($Continue) { $ocArgs += "--continue" }
    if ($Fork)      { $ocArgs += "--fork" }
    if ($Auto)      { $ocArgs += "--auto" }
    if ($Title)     { $ocArgs += @("--title", $Title) }

    $textParts = New-Object System.Collections.Generic.List[string]
    $sessionIdOut = $null; $tokens = $null; $cost = $null
    $reason = $null; $errName = $null; $errMsg = $null; $exit = $null

    $oldCfg = $env:OPENCODE_CONFIG
    $env:OPENCODE_CONFIG = $script:ConfigPath
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $exe @ocArgs 2>&1 | Tee-Object -FilePath $LogPath | ForEach-Object {
            $ev = $null
            try { $ev = $_.ToString() | ConvertFrom-Json -ErrorAction Stop } catch { return }
            if ($ev.sessionID) { $sessionIdOut = $ev.sessionID }
            switch ($ev.type) {
                "text"        { if ($ev.part.text) { $textParts.Add([string]$ev.part.text) } }
                "step_finish" { $tokens = $ev.part.tokens.total; $cost = $ev.part.cost; $reason = $ev.part.reason }
                "error"       { $errName = $ev.error.name; $errMsg = [string]$ev.error.data.message }
            }
        }
        $exit = $LASTEXITCODE
    }
    finally {
        $env:OPENCODE_CONFIG = $oldCfg
        $ErrorActionPreference = $oldEAP
    }

    # hardening: schema sentinel - if opencode produced assistant text but no
    # step_finish event, the event stream changed; say so instead of silently
    # recording zero tokens/cost forever.
    if ($exit -eq 0 -and $textParts.Count -gt 0 -and $null -eq $tokens) {
        Write-Host "WARNING: opencode returned text but no step_finish/token event. The event schema may have changed - token/cost accounting is unreliable until engine.ps1 is updated to match." -ForegroundColor Yellow
    }
    $raw  = ($textParts -join "")
    $text = [regex]::Replace($raw, "(?s)<think>.*?</think>", "").Trim()

    [PSCustomObject][ordered]@{
        SessionId    = $sessionIdOut
        Text         = $text
        RawText      = $raw
        Tokens       = $tokens
        Cost         = $cost
        FinishReason = $reason
        ExitCode     = $exit
        ErrorName    = $errName
        ErrorMessage = $errMsg
        LogPath      = $LogPath
        Project      = $Project
        Model        = $Model
        Agent        = $Agent
        Timestamp    = [DateTime]::UtcNow.ToString("o")
    }
}

function New-CicadaRun {
    param(
        [Parameter(Mandatory=$true)][string]$Mode,
        [Parameter(Mandatory=$true)][string]$Project,
        [string]$Objective = ""
    )
    $id = "run_" + [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + ([guid]::NewGuid().ToString("n").Substring(0,6))
    $run = [PSCustomObject][ordered]@{
        id        = $id
        mode      = $Mode
        project   = $Project
        objective = $Objective
        status    = "running"
        created   = [DateTime]::UtcNow.ToString("o")
        updated   = [DateTime]::UtcNow.ToString("o")
        tasks     = @()
        events    = @()
    }
    Save-CicadaRun -Run $run
    return $run
}

function Save-CicadaRun {
    param([Parameter(Mandatory=$true)]$Run)
    if (-not (Test-Path $script:RunDir)) { New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null }
    $Run.updated = [DateTime]::UtcNow.ToString("o")
    $path = Join-Path $script:RunDir ($Run.id + ".json")
    $tmp  = $path + ".tmp"
    ($Run | ConvertTo-Json -Depth 12) | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $path -Force
}

function Get-CicadaRun {
    param([string]$Id, [switch]$Latest)
    if ($Latest) {
        $f = Get-ChildItem (Join-Path $script:RunDir "*.json") -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $f) { return $null }
        return (Get-Content $f.FullName -Raw | ConvertFrom-Json)
    }
    if (-not $Id) { throw "Get-CicadaRun: pass -Id or -Latest." }
    $path = Join-Path $script:RunDir ($Id + ".json")
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Add-CicadaEvent {
    param(
        [Parameter(Mandatory=$true)]$Run,
        [Parameter(Mandatory=$true)][string]$Type,
        $Data = $null
    )
    $Run.events += [PSCustomObject][ordered]@{ t = [DateTime]::UtcNow.ToString("o"); type = $Type; data = $Data }
    Save-CicadaRun -Run $Run
}



function Repair-CicadaStaleRuns {
    param([int]$StaleMinutes = 45)
    $files = Get-ChildItem (Join-Path $script:RunDir "*.json") -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $run = $null
        try { $run = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($run.status -ne "running") { continue }
        $updated = $null
        try { $updated = [DateTime]::Parse($run.updated).ToUniversalTime() } catch { continue }
        if (([DateTime]::UtcNow - $updated).TotalMinutes -lt $StaleMinutes) { continue }
        $run.status = "interrupted"
        Add-CicadaEvent -Run $run -Type "interrupted" -Data "no journal update for $StaleMinutes+ minutes; assumed stopped"
    }
}

function Show-CicadaCheatsheet {
$text = @"
Quick reference
---------------
ONE-TIME SETUP
  secrets:   manager\secrets.json = { "MINIMAX_API_KEY": "..." }   (jobs auto-hydrate from it)
  manual:    `$env:OPENCODE_CONFIG = (Resolve-Path .\minimax-opencode.json).Path   (for hand-run opencode)

UNSUPERVISED (plan -> build -> gate -> commit -> digest)
  .\agent.ps1 -Mode unsupervised -Project <dir> -Yes -Objective '...'
  flags:   -MaxTokens 2000000   -MaxCost 0.25   -NoGit
  models:  -PlanModel minimax/MiniMax-M3  -ReviewModel minimax/MiniMax-M3  -BuilderModel minimax/MiniMax-M2.7  (defaults: plan/review/inspect M3, build M2.7)
  resume:  .\manager\orchestrator.ps1 -Project <dir> -RunId <id>   (adds -MaxTaskRetries 2 etc.)

PARALLEL (interactive fleet, max 3 workers - slot 4 reserved)
  .\agent.ps1 -Mode parallel     (guided)   or:
  .\manager\console.ps1 -Project <dir> -Workers 2 -Tasks @('..','..') -Models @('m3','m2.7') -Yes
  console: /status  /tail <n>  /attach <n>  /abort <n>  /stop <n>  /quit    (m3 / m2.7 aliases work here)

OBSERVE
  .\dashboard.ps1 -Once          journals + digests: state\runs\
  run ledger: C:\Users\David\cicada-run-report\report.ps1 -RunsDir state\runs
"@
Write-Host $text
}

function Show-CicadaMenu {
    param(
        [string]$Title = "Select",
        [string[]]$Options,
        [int]$Default = 0
    )
    if (-not $Options -or $Options.Count -eq 0) { return -1 }
    $sel = [Math]::Max(0, [Math]::Min($Default, $Options.Count - 1))
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    $menuLines = $Options.Count + 1
    $width = ($Options | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum + 5
    $first = $true
    while ($true) {
        if (-not $first) { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $menuLines)) }
        $first = $false
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $line = if ($i -eq $sel) { "  > " + $Options[$i] } else { "    " + $Options[$i] }
            $line = $line.PadRight($width)
            # never wrap: the cursor math below assumes exactly one console line per option
            $maxMenuWidth = $Host.UI.RawUI.WindowSize.Width - 1
            if ($line.Length -gt $maxMenuWidth) { $line = $line.Substring(0, [Math]::Max(10, $maxMenuWidth - 3)) + "..." }
            if ($i -eq $sel) { Write-Host $line -ForegroundColor Black -BackgroundColor Gray }
            else { Write-Host $line -ForegroundColor Gray -BackgroundColor Black }
        }
        Write-Host "  (up/down to move, Enter to select)" -ForegroundColor DarkGray
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if ($key.VirtualKeyCode -eq 38) { $sel = ($sel - 1 + $Options.Count) % $Options.Count }
        elseif ($key.VirtualKeyCode -eq 40) { $sel = ($sel + 1) % $Options.Count }
        elseif ($key.VirtualKeyCode -eq 13) { return $sel }
    }
}



function Expand-CicadaPrompt {
    param([string]$Project, [string]$Raw, [string]$Model = "minimax/MiniMax-M3")
    $prompt = @"
You are a senior engineer converting a rough instruction into a precise, executable prompt for an autonomous coding agent.

Project directory: $Project
Rough instruction: $Raw

Write the expanded prompt now: 2-4 plain sentences naming concrete deliverables (exact file names), exact behavior, and constraints. Environment: Windows PowerShell 5.1, no network access, no credentials, no user available to answer questions. Prefer simple, mechanically verifiable outcomes. Cap the objective at three concrete deliverables; if the instruction implies more, pick the three highest-impact ones. If this will run as a single autonomous task, end with a final line by itself:
ACCEPTANCE: <one PowerShell command, runnable from the project root, that exits 0 only if the work is done correctly>

No preamble, no markdown fences, no commentary.
"@
    $callArgs = @{ Project=$Project; Prompt=$prompt; Model=$Model; Agent="plan"; Title="prompt-expand" }
    $r = Invoke-Agent @callArgs
    if ($r.ExitCode -ne 0 -or -not $r.Text) { Write-Host ("expansion failed: " + $r.ErrorName + " " + $r.ErrorMessage + " - using your original text") -ForegroundColor Yellow; return $null }
    return $r.Text.Trim()
}

function Read-CicadaPrompt {
    param([string]$Label, [string]$Example, [string]$Project, [string]$ExpandModel = "minimax/MiniMax-M3")
    $promptLabel = $Label
    if ($Example) { $promptLabel = $Label + " (e.g. " + $Example + ")" }
    $raw = (Read-Host $promptLabel).Trim()
    $raw = Resolve-CicadaText $raw
    if (-not $raw) { return "" }
    $choice = Show-CicadaMenu -Title "Prompt style" -Options @("Use as-is", "Expand with M3 first (rough idea -> full spec)", "Re-type") -Default 0
    if ($choice -eq 2) { return (Read-CicadaPrompt -Label $Label -Example $Example -Project $Project -ExpandModel $ExpandModel) }
    if ($choice -eq 1) {
        $expanded = Expand-CicadaPrompt -Project $Project -Raw $raw -Model $ExpandModel
        if (-not $expanded) { return $raw }
        Write-Host ""
        Write-Host "===== EXPANDED PROMPT =====" -ForegroundColor Cyan
        Write-Host $expanded
        $use = Show-CicadaMenu -Title "Which prompt should the run use?" -Options @("Use expanded", "Use my original", "Cancel") -Default 0
        if ($use -eq 0) { return $expanded }
        if ($use -eq 1) { return $raw }
        return "__CANCEL__"
    }
    return $raw
}



function Resolve-CicadaText {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if (-not $Value) { return $Value }
    $trim = $Value.Trim().Trim('"').Trim("'")
    if (($trim -match '^[A-Za-z]:[\\/]' -or $trim -match '^\.[\\/]' -or $trim -match '^~[\\/]' -or $trim -match '^\\\\') -and (Test-Path $trim -PathType Leaf)) {
        $text = (Get-Content $trim -Raw).Trim()
        Write-Host ("  [prompt loaded from file: " + $trim + " - " + $text.Length + " chars]") -ForegroundColor DarkGray
        return $text
    }
    return $Value
}


function Split-CicadaGateCommand {
    param([string]$Cmd)
    $hits = @()
    $inS = $false; $inD = $false
    for ($i = 0; $i -lt $Cmd.Length; $i++) {
        $ch = $Cmd[$i]
        if ($inS) { if ($ch -eq [char]39) { $inS = $false }; continue }
        if ($inD) { if ($ch -eq [char]34) { $inD = $false }; continue }
        if ($ch -eq [char]39) { $inS = $true; continue }
        if ($ch -eq [char]34) { $inD = $true; continue }
        if (-not [regex]::Match($Cmd.Substring($i), '^(findstr|type|powershell|pwsh|node|npm|npx|yarn|pnpm|python|pytest|dotnet|go|cargo|git)(?=[\s\.]|$)').Success) { continue }
        if ($i -eq 0) { $hits += $i; continue }
        $j = $i - 1
        if (-not [char]::IsWhiteSpace($Cmd[$j])) { continue }
        while ($j -ge 0 -and [char]::IsWhiteSpace($Cmd[$j])) { $j-- }
        if ($j -ge 0 -and $Cmd[$j] -ne '|') { $hits += $i }
    }
    if ($hits.Count -gt 0 -and $hits[0] -ne 0) { return @($Cmd) }
    if ($hits.Count -le 1) { return @($Cmd) }
    $segs = @()
    for ($k = 0; $k -lt $hits.Count; $k++) {
        $s = $hits[$k]; $e = $Cmd.Length
        if ($k + 1 -lt $hits.Count) { $e = $hits[$k + 1] }
        $segs += $Cmd.Substring($s, $e - $s).Trim()
    }
    return $segs
}


function Send-CicadaTelegram {
    param([string]$Message)
    try {
        $secretsPath = $script:SecretsPath
        if (-not (Test-Path $secretsPath)) { return }
        $s = Get-Content $secretsPath -Raw | ConvertFrom-Json
        $token = [string]$s.TELEGRAM_BOT_TOKEN
        $chatId = [string]$s.TELEGRAM_CHAT_ID
        if (-not $token -or -not $chatId) { return }
        $uri = "https://api.telegram.org/bot" + $token + "/sendMessage"
        $body = @{ chat_id = $chatId; text = $Message } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType "application/json" -TimeoutSec 15 | Out-Null
    } catch { }
}



function Select-CicadaModel {
    param([string]$Seat, [string]$Current, [string]$Recommend = "minimax/MiniMax-M3")
    $optM3 = "MiniMax-M3"
    $optM27 = "MiniMax-M2.7"
    if ($Recommend -match "M3") { $optM3 += " (recommended)" } else { $optM27 += " (recommended)" }
    $opts = @($optM3, $optM27, "custom (type a model id)")
    $def = 0
    if ($Current -match "M2\.7") { $def = 1 }
    $mi = Show-CicadaMenu -Title ($Seat + " model  [current: " + $Current + "]") -Options $opts -Default $def
    if ($mi -eq 0) { return "minimax/MiniMax-M3" }
    if ($mi -eq 1) { return "minimax/MiniMax-M2.7" }
    $custom = (Read-Host "Custom model id (e.g. minimax/MiniMax-M3-highspeed)").Trim()
    if ($custom) { return $custom }
    return $Current
}


function Get-WorkerCurrentAction {
    param([string]$LogPath)
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $null }
    $tail = Get-Content $LogPath -Tail 15
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        try { $ev = $tail[$i] | ConvertFrom-Json } catch { continue }
        if ($ev.type -eq "tool_use" -and $ev.part.tool) {
            $tool = [string]$ev.part.tool
            $detail = ""
            if ($ev.part.input -and $ev.part.input.command) { $detail = [string]$ev.part.input.command }
            elseif ($ev.part.input -and $ev.part.input.filePath) { $detail = [string]$ev.part.input.filePath }
            elseif ($ev.part.state -and $ev.part.state.input -and $ev.part.state.input.command) { $detail = [string]$ev.part.state.input.command }
            if ($detail.Length -gt 70) { $detail = $detail.Substring(0, 70) + "..." }
            if ($detail) { return ($tool + ": " + $detail) }
            return $tool
        }
    }
    return $null
}

function Normalize-CicadaGateCommands {
    param([array]$Cmds)
    $out = @()
    foreach ($g in $Cmds) {
        if ($g -match '^\s*findstr\s' -and $g.Contains('\"')) {
            $g = $g -replace '\\"', '"'
            $m = [regex]::Match($g, '^(?<head>\s*findstr\s+/C:)"(?<body>.*)"(?<tail>\s+.+)$')
            if ($m.Success) { $g = $m.Groups['head'].Value + "'" + $m.Groups['body'].Value + "'" + $m.Groups['tail'].Value }
        }
        if ($g -match '^\s*python\s+-c\s') {
            # restore quote chars stripped by prompt compression: width=\\880\\' -> width="880"'
            $g = [regex]::Replace($g, '=(\\+)([\w\-.]+)(\\+)('')', '="$2"')
        }
        $out += $g
    }
    return $out
}

# ---------- port #1: provider fallback chain (from the Python orchestrator) ----------

function Test-CicadaProviderFailure {
    # The Python escalation policy, faithfully: ANY provider-class failure advances
    # the chain. Task-level problems come back exit 0 with text - those never walk.
    param($Result)
    if ($null -eq $Result) { return $true }
    if ($Result.ExitCode -ne 0) { return $true }
    if ([string]::IsNullOrWhiteSpace($Result.Text)) { return $true }
    return $false
}

function Get-CicadaFallbackFor {
    # Default chain: each tier falls back to the other.
    param([string]$Model)
    if ($Model -match "M3") { return @("minimax/MiniMax-M2.7") }
    if ($Model -match "M2\.7") { return @("minimax/MiniMax-M3") }
    return @("minimax/MiniMax-M3", "minimax/MiniMax-M2.7")
}

function Invoke-AgentWithFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$CallArgs,
        [string[]]$FallbackModels = @(),
        [string]$Seat = ""
    )
    $primary = [string]$CallArgs.Model
    $r = Invoke-Agent @CallArgs
    if (-not (Test-CicadaProviderFailure $r)) { return $r }

    $fbIdx = 0
    while ($fbIdx -lt $FallbackModels.Count) {
        $next = $FallbackModels[$fbIdx]
        $fbIdx++
        if (-not $next -or $next -eq $primary) { continue }
        Write-Host ("  [fallback]" + $(if ($Seat) { " " + $Seat } else { "" }) + " provider failure on " + $primary + " -> retrying on " + $next + " (fresh session)") -ForegroundColor Yellow
        $retryArgs = @{} + $CallArgs
        $retryArgs.Model = $next
        $retryArgs.SessionId = $null
        $retryArgs.Remove("LogPath")
        $retryArgs.Remove("Continue")
        $retryArgs.Title = ([string]$CallArgs.Title) + "-fb" + $fbIdx
        $r2 = Invoke-Agent @retryArgs
        if (-not (Test-CicadaProviderFailure $r2)) {
            $r2 | Add-Member -NotePropertyName FallbackFrom -NotePropertyValue $primary -Force
            return $r2
        }
        $r = $r2
    }
    return $r
}


# --- skills layer (auto-detect + Invoke-Agent wrapping; see manager\skills.ps1) ---
. (Join-Path $PSScriptRoot "skills.ps1")

# --- operator steering: mid-run guidance the unsupervised loop picks up at checkpoints ---
$script:SteerFile = Join-Path (Split-Path -Parent $PSScriptRoot) "state\steer.txt"
function Get-CicadaSteering {
    if (-not (Test-Path $script:SteerFile)) { return $null }
    $note = Get-Content $script:SteerFile -Raw -ErrorAction SilentlyContinue
    if (-not $note -or -not $note.Trim()) { return $null }
    return $note.Trim()
}
function Clear-CicadaSteering {
    if (Test-Path $script:SteerFile) { Remove-Item $script:SteerFile -Force -ErrorAction SilentlyContinue }
}

# --- operator interrupt: non-blocking /interrupt capture for the unsupervised loop ---
function Read-CicadaInterrupt {
    try {
        if (-not [Console]::KeyAvailable) { return $null }
    } catch { return $null }
    $buf = ""
    try {
        while ([Console]::KeyAvailable) {
            $ki = [Console]::ReadKey($true)
            if ($ki.Key -eq [System.ConsoleKey]::Enter) { break }
            $buf += $ki.KeyChar
        }
    } catch { return $null }
    $buf = $buf.Trim()
    if (-not $buf) { return $null }
    if ($buf -match '^/(i|interrupt)\b\s*(.*)$') {
        $note = $Matches[2].Trim()
        if (-not $note) {
            Write-Host ""
            Write-Host "[INTERRUPT] loop pauses at this checkpoint - your note goes to the planner, not the builder" -ForegroundColor Yellow
            $note = (Read-Host "Tell the planner").Trim()
        }
        if ($note) { return $note }
    }
    return $null
}

# --- agent names + named steering ---
$script:CicadaNamePool = @("Echo","Falcon","Zephyr","Onyx","Sable","Rook","Vega","Nimbus","Quill","Aster","Birch","Cinder","Drift","Ember","Flint","Halo","Iris","Juno","Kestrel","Lumen")
$script:CicadaRunName = $null
function Set-CicadaRunName([string]$RunId) {
    $h = 0
    foreach ($c in ([string]$RunId).ToCharArray()) { $h = ($h + [int]$c) % 97 }
    $script:CicadaRunName = $script:CicadaNamePool[$h % $script:CicadaNamePool.Count]
    return $script:CicadaRunName
}
function Get-CicadaSteeringFor([string]$Name) {
    $dir = Split-Path -Parent $script:SteerFile
    if ($Name) {
        $named = Join-Path $dir ("steer-" + $Name.ToLower() + ".txt")
        if (Test-Path $named) {
            $n = Get-Content $named -Raw -ErrorAction SilentlyContinue
            if ($n -and $n.Trim()) { Remove-Item $named -Force -ErrorAction SilentlyContinue; return $n.Trim() }
        }
    }
    if (Test-Path $script:SteerFile) {
        $n = Get-Content $script:SteerFile -Raw -ErrorAction SilentlyContinue
        if ($n -and $n.Trim()) { Remove-Item $script:SteerFile -Force -ErrorAction SilentlyContinue; return $n.Trim() }
    }
    return $null
}

# ---------- replay command: print the exact CLI that reproduces this run ----------
function Show-ReplayCommand([string[]]$ParamNames) {
    $scriptPath = $null
    $psc = Get-Variable PSCommandPath -Scope 1 -ErrorAction SilentlyContinue
    if ($psc -and $psc.Value) { $scriptPath = $psc.Value }
    if (-not $scriptPath) { $scriptPath = (Get-Variable MyInvocation -Scope 1).Value.MyCommand.Path }
    $bp = $null
    $bpv = Get-Variable PSBoundParameters -Scope 1 -ErrorAction SilentlyContinue
    if ($bpv) { $bp = $bpv.Value }
    $parts = @('& "' + $scriptPath + '"')
    foreach ($name in $ParamNames) {
        $val = $null; $has = $false
        if ($bp -and $bp.ContainsKey($name)) { $val = $bp[$name]; $has = $true }
        else {
            $v = Get-Variable -Name $name -Scope 1 -ErrorAction SilentlyContinue
            if ($v -and $null -ne $v.Value -and "" -ne $v.Value) { $val = $v.Value; $has = $true }
        }
        if (-not $has) { continue }
        if ($val -is [System.Management.Automation.SwitchParameter]) { if ($val.IsPresent) { $parts += ("-" + $name) }; continue }
        if ($val -is [bool]) { if ($val) { $parts += ("-" + $name) }; continue }
        if ($val -is [array]) {
            if ($val.Count -eq 0) { continue }
            $parts += ("-" + $name + " " + (($val | ForEach-Object { '"' + ([string]$_) + '"' }) -join ','))
            continue
        }
        $parts += ("-" + $name + ' "' + ([string]$val) + '"')
    }
    $cmd = $parts -join ' '
    Write-Host ""
    Write-Host "replay this exact run anytime (copied to clipboard):" -ForegroundColor DarkGray
    Write-Host ("  " + $cmd) -ForegroundColor DarkGray
    try { $cmd | Set-Clipboard } catch {}
}
