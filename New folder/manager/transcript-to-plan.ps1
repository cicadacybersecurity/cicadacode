param(
    [string]$Transcript,
    [string]$Project,
    [string]$Model = "minimax/MiniMax-M3",
    [switch]$NoTokenise,
    [switch]$Yes
)
# transcript-to-plan.ps1 - consult transcript -> phased, worker-ready plan.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

if (-not $Transcript) { $Transcript = (Read-Host "Path to the consult transcript (transcript.md)").Trim() }
$Transcript = $Transcript.Trim().Trim('"').Trim([char]39).Trim()
if (-not (Test-Path $Transcript)) { Write-Error "transcript not found: $Transcript"; exit 1 }
$source = (Get-Content $Transcript -Raw).Trim()
if (-not $source) { Write-Error "transcript is empty: $Transcript"; exit 1 }

if (-not $Project) { $Project = (Read-Host "Project directory (the plan file is saved here)").Trim() }
if (-not $Project) { Write-Error "no project directory given"; exit 1 }
if (-not (Test-Path $Project -PathType Container)) { New-Item -ItemType Directory -Force -Path $Project | Out-Null }
$Project = (Resolve-Path $Project).Path

Show-ReplayCommand -ParamNames @("Transcript","Project","Model","NoTokenise","Yes")

$sys = @"
You are a staff engineer who converts two-AI consult transcripts into executable phased plans for coding agents. The input is a conversation transcript: two seats debating a piece of work. Your job is to extract what they DECIDED and emit the plan - never the debate.

HARD RULES:
- Output decisions, not discussion. Where the seats disagreed, the position they converged on LAST is the decision. Where they never settled, put the open question in the relevant phase as its own task.
- Structure the output as phases: "## Phase 1: <short name>", "## Phase 2: ..." in dependency order. Each phase is a self-contained unit a single coding agent can execute in one session WITHOUT reading the transcript - include the file paths, decisions, and constraints it needs inside the phase.
- Inside each phase, numbered tasks. Task numbers NEVER reset across phases (phase 2 continues the numbering). Each task line ends with: "| Files: <paths> | Prove: <one runnable command whose exit code 0 proves the task>".
- Keep phases few and fat: 2-6 phases, each a meaningful chunk. Never a phase per task.
- Begin with a one-line title and a two-sentence context block. No commentary on the conversation, no "the models decided", no process narration - the plan is the deliverable.

Output EXACTLY this structure:
# <plan title>
## Context
<two sentences>
## Phase 1: <name>
1. <task> | Files: <paths> | Prove: <command>
2. ...
## Phase 2: <name>
3. ...
## Verification
<how to prove the whole thing is done>
"@

$prompt = "Convert this consult transcript into a phased plan for coding agents. Transcript:`n`n" + $source

$m = $Model -replace "^minimax/", ""
$plan = $null
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $usePrompt = $prompt
    if ($attempt -eq 2) {
        $usePrompt = $prompt + "`n`nCONTRACT VIOLATION: your previous output had no phase structure. Rewrite it with ## Phase N: <name> headers, continuous task numbering, and a Prove command per task."
        Write-Warning "attempt 1 produced no phases - one corrective retry"
    }
    $body = @{
        model = $m
        messages = @(
            @{ role = "system"; content = $sys },
            @{ role = "user"; content = $usePrompt }
        )
        temperature = 0.3
        max_tokens = 16000
    } | ConvertTo-Json -Depth 10
    Write-Host ("converting transcript (" + $source.Length + " chars) -> phased plan (" + $m + ", attempt " + $attempt + ")...") -ForegroundColor DarkGray
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 600
    } catch {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host ("API error body: " + $_.ErrorDetails.Message) -ForegroundColor DarkYellow }
        throw
    }
    $plan = [string]$resp.choices[0].message.content
    $plan = [regex]::Replace($plan, "(?s)<think>.*?</think>", "").Trim()
    if ($resp.usage) { Write-Host ("  (tokens: " + $resp.usage.prompt_tokens + " in / " + $resp.usage.completion_tokens + " out)") -ForegroundColor DarkGray }
    if (-not $plan) { throw "direct API returned no text" }
    $phaseCount = [regex]::Matches($plan, '(?im)^##\s+Phase\s+\d+').Count
    if ($phaseCount -ge 1) { break }
    if ($attempt -eq 2) { Write-Warning "still no phase structure after retry - saving best effort; review before handing to workers" }
}

$base = (Get-Item $Transcript).BaseName -replace '[^A-Za-z0-9._-]', ''
$outPath = Join-Path $Project ($base + ".phases.plan.md")
$plan | Set-Content $outPath -Encoding utf8
$plan | Set-Clipboard
Write-Host ""
Write-Host ("phased plan saved: " + $outPath + " (" + $phaseCount + " phase(s), " + [regex]::Matches($plan, '(?m)^\s*\d+\.').Count + " tasks) - also on the clipboard") -ForegroundColor Green

if (-not $NoTokenise) {
    $tk = Join-Path $PSScriptRoot "tokeniser.ps1"
    if (Test-Path $tk) {
        Write-Host ""
        Write-Host "chaining through the tokeniser (worker-lean version)..." -ForegroundColor DarkGray
        & $tk -Project $Project -PromptFile $outPath -Model $Model -Yes
    } else {
        Write-Host "tokeniser.ps1 not found - skipped (the plan file is ready to use as-is)" -ForegroundColor DarkYellow
    }
}
