param(
    [string]$Project,
    [string]$Question,
    [string]$Model = "minimax/MiniMax-M3",
    [switch]$Yes
)

. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

if (-not $Project) { $Project = (Read-Host "Project directory").Trim().Trim('"').Trim([char]39) }
if (-not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path

if (-not $Question) {
    $Question = (Read-Host "Question (text, or path to a file containing it)").Trim().Trim('"').Trim([char]39)
}
if (-not $Question) { Write-Error "No question given."; exit 1 }

$candidate = $Question
if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $Project $candidate }
if (Test-Path $candidate -PathType Leaf) {
    $Question = (Get-Content $candidate -Raw).Trim()
    Write-Host ("question loaded from file: " + $candidate) -ForegroundColor DarkGray
}

$flat = ($Question -replace '\s+', ' ')
if ($flat.Length -gt 90) { $flat = $flat.Substring(0, 90) + "..." }
Write-Host ""
Write-Host ("targeted inspect: " + $Project) -ForegroundColor Cyan
Write-Host ("question: " + $flat) -ForegroundColor Cyan
Write-Host ""

$prompt = @"
You are answering ONE specific question about a codebase. Do NOT survey the whole project and do NOT produce a general state report - inspect only the files needed to answer this question precisely, citing file paths (and line numbers where useful) as evidence.

Project: $Project

Question:
$Question

Report in exactly this shape:
VERDICT: <YES | NO | PARTIAL>
EVIDENCE:
- <file:line - what you found>
GAPS:
- <what would need to change, or "none">
"@

$r = Invoke-AgentWithFallback -CallArgs @{ Project=$Project; Prompt=$prompt; Model=$Model; Agent="plan"; Title="inspect-target" } -FallbackModels @(Get-CicadaFallbackFor ([string]$Model)) -Seat "inspect-target"

if (-not $r -or -not $r.Text) { Write-Error "no response from the model"; exit 1 }
Write-Host $r.Text
Write-Host ""
Send-CicadaTelegram ("CICADA [inspect-target] " + (Split-Path -Leaf $Project) + " | " + $flat)
exit 0
