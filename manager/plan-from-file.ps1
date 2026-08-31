# plan-from-file.ps1 - convert a document (e.g. a consult FINAL.md) into an executable plan.
# Direct MiniMax API - no opencode, exact token usage per run.
# Usage:  .\manager\plan-from-file.ps1 -File "path\to\FINAL.md" [-Model minimax/MiniMax-M3]
# Output: <same folder>\<name>.plan.md
param(
    [string]$File = "",
    [string]$Model = "minimax/MiniMax-M3"
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root "manager\engine.ps1")
Import-CicadaSecrets

if (-not $File) { $File = (Read-Host "Path to the document to convert (e.g. a consult FINAL.md)").Trim() }
if (-not $File) { Write-Host "No file given - aborting." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $File)) { Write-Host ("File not found: " + $File) -ForegroundColor Red; exit 1 }
$File = (Resolve-Path $File).Path
$doc = (Get-Content $File -Raw).Trim()
if (-not $doc) { Write-Host "File is empty - aborting." -ForegroundColor Red; exit 1 }

$outPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($File), ([System.IO.Path]::GetFileNameWithoutExtension($File) + ".plan.md"))

$sys = "You are a staff engineer converting a document into an executable plan. Output clean markdown only - no preamble, no conversation."
$prompt = @"
Convert the document below into an executable plan file with exactly this shape:

# (plan title, from the document)
## Context (2-3 sentences: what this is and why)
## Plan
Numbered tasks in dependency order. Every task states what to change or build, which files or areas it touches, and carries a line exactly like:
Prove: <a concrete validation command - a test, a curl, a build, a file check>
## Verification
How to prove the whole plan is genuinely done (the final gate).

Rules: every task must be independently verifiable; no task without a Prove command; tasks must be small enough to execute and verify in isolation; if the document already contains a build plan or executable plan section, refine it into this shape rather than reinventing it; never invent scope the document does not contain.

THE DOCUMENT:
$doc
"@

$body = @{
    model = ($Model -replace "^minimax/", "")
    messages = @(
        @{ role = "system"; content = $sys },
        @{ role = "user"; content = $prompt }
    )
    temperature = 0.2
    max_tokens = 4000
} | ConvertTo-Json -Depth 10

Write-Host ("plan-from-file: " + $File) -ForegroundColor Cyan
Write-Host ("model: " + $Model) -ForegroundColor DarkGray

$resp = $null
try {
Show-ReplayCommand -ParamNames @("File","Model","Yes")
    $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json" } -Body $body -TimeoutSec 300
} catch {
    Write-Host ("  (call failed: " + $_.Exception.Message + " - retrying once)") -ForegroundColor Yellow
    $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json" } -Body $body -TimeoutSec 300
}

$plan = [string]$resp.choices[0].message.content
$plan = [regex]::Replace($plan, "(?s)<think>.*?</think>", "").Trim()
if (-not $plan) { Write-Host "the API returned no plan text" -ForegroundColor Red; exit 1 }

# --- shape gate: the plan must match the contract (numbered tasks, Prove per task) ---
$plan = $plan -replace '\*\*Prove\*\*:', 'Prove:'   # normalise the bold variant into the parseable form
$taskLines = [regex]::Matches($plan, '(?m)^\s*\d+\.')
$proveCount = [regex]::Matches($plan, 'Prove:').Count
if ($taskLines.Count -lt 2 -or $proveCount -lt $taskLines.Count) {
    Write-Warning ("shape gate: " + $taskLines.Count + " numbered tasks, " + $proveCount + " Prove gates - off-contract; one corrective retry")
    $fixPrompt = $prompt + "`n`nCONTRACT VIOLATION: your previous output did not follow the required shape. Rewrite it as a FLAT numbered list under ## Plan: every task is one numbered line ending with '| Prove: <command>'. No ### headers, no bold markers, no prose paragraphs between tasks."
    $body.messages[1].content = $fixPrompt
    $body = $body | ConvertTo-Json -Depth 10
    $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json" } -Body $body -TimeoutSec 300
    $retry = [string]$resp.choices[0].message.content
    $retry = [regex]::Replace($retry, "(?s)<think>.*?</think>", "").Trim()
    $retry = $retry -replace '\*\*Prove\*\*:', 'Prove:'
    if ($retry) { $plan = $retry }
    $taskLines = [regex]::Matches($plan, '(?m)^\s*\d+\.')
    $proveCount = [regex]::Matches($plan, 'Prove:').Count
    if ($taskLines.Count -lt 2 -or $proveCount -lt $taskLines.Count) {
        Write-Warning ("shape gate: still off-contract after retry (" + $taskLines.Count + " tasks / " + $proveCount + " proves) - saving anyway; review before feeding to Execute plan")
    }
}

$plan | Set-Content $outPath -Encoding utf8
Write-Host $plan
Write-Host ""
if ($resp.usage) { Write-Host ("(tokens: " + $resp.usage.prompt_tokens + " in / " + $resp.usage.completion_tokens + " out)") -ForegroundColor DarkGray }
Write-Host ("Plan written: " + $outPath) -ForegroundColor Green
Write-Host "Feed it to Execute plan when you are ready - every task carries its own Prove gate." -ForegroundColor DarkGray
