param(
    [string]$Project,
    [string]$Idea,
    [string]$ExpandModel = "minimax/MiniMax-M3",
    [double]$MaxCost = 0,
    [int64]$MaxTokens = 0,
    [switch]$NoGit,
    [switch]$Yes
)

. (Join-Path $PSScriptRoot "engine.ps1")
Repair-CicadaStaleRuns
Import-CicadaSecrets

if (-not $Project) { $Project = (Read-Host "Project directory (e.g. C:\Users\David\my-project)").Trim() }
if (-not (Test-Path $Project -PathType Container)) { New-Item -ItemType Directory -Force -Path $Project | Out-Null }
$Project = (Resolve-Path $Project).Path
if (-not $Idea) { $Idea = (Read-Host "The idea (rough is fine - or a path to a file)").Trim() }
if (-not $Idea) { Write-Error "No idea given."; exit 1 }
$Idea = Resolve-CicadaText $Idea

if (-not $Yes) { $ExpandModel = Select-CicadaModel -Seat "Expander" -Current $ExpandModel -Recommend "minimax/MiniMax-M3" }
Write-Host "Expanding idea into a full objective..." -ForegroundColor DarkGray

$prompt = @"
You are a senior engineer converting a rough idea into a precise, buildable objective for an autonomous coding system.

Project directory: $Project
Rough idea: $Idea

Write the expanded objective now: 2-4 plain sentences naming concrete deliverables (exact file names), the exact behavior each must have, and important constraints. Environment: Windows PowerShell 5.1, no network access, no credentials, no user available to answer questions. Prefer simple, mechanically verifiable outcomes over clever ones. Cap the objective at three concrete deliverables; if the idea implies more, pick the three highest-impact ones. Then, on a final line by itself, write:
ACCEPTANCE: <one PowerShell command, runnable from the project root, that exits 0 only if the work is done correctly>

No preamble, no markdown fences, no commentary - just the objective sentences and the ACCEPTANCE line.
"@

$callArgs = @{ Project=$Project; Prompt=$prompt; Model=$ExpandModel; Agent="plan"; Title="idea-expand" }
$r = Invoke-AgentWithFallback -CallArgs $callArgs -FallbackModels @(Get-CicadaFallbackFor ([string]$callArgs.Model)) -Seat "idea"
if ($r.ExitCode -ne 0 -or -not $r.Text) { Write-Error ("expansion call failed: " + $r.ErrorName + " " + $r.ErrorMessage + " log=" + $r.LogPath); exit 1 }

$expanded = $r.Text.Trim()
Write-Host ""
Write-Host "===== EXPANDED OBJECTIVE =====" -ForegroundColor Cyan
Write-Host $expanded
Write-Host ""

if (-not $Yes) {
    Send-CicadaTelegram ("CICADA idea expansion ready | project: " + (Split-Path -Leaf $Project) + " | awaiting Run/Cancel")
$goi = Show-CicadaMenu -Title "Run the unsupervised loop on this?" -Options @("Run it","Cancel") -Default 0
    if ($goi -ne 0) { Write-Host "Not running - tweak the idea and retry."; exit 0 }
}

$orchArgs = @{ Project=$Project; Objective=$expanded; MaxCost=$MaxCost; MaxTokens=$MaxTokens; ModeLabel="idea" }
if ($NoGit) { $orchArgs.NoGit = $true }
& (Join-Path $PSScriptRoot "orchestrator.ps1") @orchArgs
exit $LASTEXITCODE










