# ============================================================================
# CICADA agent.ps1 - single-terminal entry point / mode select.
#   .\agent.ps1                                                 interactive menu
#   .\agent.ps1 -Mode unsupervised -Project <dir> -Objective "<goal>" -Yes
#   .\agent.ps1 -Mode parallel -Project <dir> -Workers 2
# ============================================================================
[CmdletBinding()]
param(
    [ValidateSet("parallel","unsupervised","idea","inspect","pi","plan")]
    [string]$Mode,
    [string]$Project,
    [string]$Objective,
    [int]$Workers = 0,
    [string[]]$Tasks = @(),
    [string]$PlanModel = "minimax/MiniMax-M3",
    [string]$ReviewModel = "minimax/MiniMax-M3",
    [string]$BuilderModel = "minimax/MiniMax-M2.7",
    [double]$MaxCost = 0,
    [int64]$MaxTokens = 1000000,
    [switch]$NoGit,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "manager\engine.ps1")
Import-CicadaSecrets

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " CICADA Agent System" -ForegroundColor Cyan
if (-not $Mode) { Show-CicadaCheatsheet }
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Mode) {
$mi = Show-CicadaMenu -Title "Select mode" -Options @("Parallel / Interactive (worker fleet)", "Unsupervised (autonomous loop)", "Idea (rough sentence -> product)", "Inspect (state of a project + what is next)", "SSH / Pi operator (one worker on your Raspberry Pi)", "Plan (inspection -> actionable PLAN.md)", "Quit")
if ($mi -eq 0) { $Mode = "parallel" }
elseif ($mi -eq 1) { $Mode = "unsupervised" }
elseif ($mi -eq 2) { $Mode = "idea" }
elseif ($mi -eq 3) { $Mode = "inspect" }
elseif ($mi -eq 4) { $Mode = "pi" }
elseif ($mi -eq 5) { $Mode = "plan" }
else { exit 0 }
}

if (-not $Project -and $Mode -ne "pi") { $Project = (Read-Host "Project (e.g. C:\Users\David\my-project)").Trim() }
if ($Mode -ne "pi" -and -not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
if ($Project) { $Project = (Resolve-Path $Project).Path }

# ---------------- unsupervised: run in THIS terminal ----------------
if ($Mode -eq "unsupervised") {
    if (-not $Objective) { $Objective = Read-CicadaPrompt -Label "Objective" -Example "add a -Since filter to report.ps1 and extend its tests" -Project $Project -ExpandModel $PlanModel; if ($Objective -eq "__CANCEL__") { Write-Host "Aborted."; exit 0 } }
if ($Objective) { $Objective = Resolve-CicadaText $Objective }
    if (-not $Objective) { Write-Host "Objective is required." -ForegroundColor Red; exit 1 }

    if (-not $Yes) {
$PlanModel = Select-CicadaModel -Seat "Planner" -Current $PlanModel -Recommend "minimax/MiniMax-M3"
$ReviewModel = Select-CicadaModel -Seat "Reviewer" -Current $ReviewModel -Recommend "minimax/MiniMax-M3"
$BuilderModel = Select-CicadaModel -Seat "Builder" -Current $BuilderModel -Recommend "minimax/MiniMax-M2.7"


Write-Host ""
Write-Host "  Project:            $Project"
Write-Host "  Objective:          $Objective"
Write-Host "  Planner/reviewer:   $PlanModel"
Write-Host "  Builder:            $BuilderModel"
$goi = Show-CicadaMenu -Title "Start autonomous run?" -Options @("Start","Cancel") -Default 0
if ($goi -ne 0) { Write-Host "Aborted."; exit 0 }
}

Write-Host ""
Write-Host "Starting unsupervised run in this terminal." -ForegroundColor Green
Write-Host "Progress streams below. Ctrl+C stops; the journal survives for resume." -ForegroundColor DarkGray
Write-Host ""
$orch = Join-Path $Root "manager\orchestrator.ps1"
# Every new unsupervised run is planned before builders can start.
$planScript = Join-Path $Root "manager\plan.ps1"
$planPath = Join-Path $Project "PLAN.md"

if (-not (Test-Path $planScript)) {
    Write-Error "plan.ps1 not found in manager\. Cannot safely start an unsupervised run without PLAN.md."
    exit 1
}

Write-Host "Preparing an actionable PLAN.md before execution..." -ForegroundColor Cyan
& $planScript -Project $Project -Focus $Objective -Model $PlanModel -Yes
$planCode = $LASTEXITCODE

if ($planCode -ne 0) {
    Write-Error "Plan generation failed (exit $planCode). No builders were started."
    exit $planCode
}
if (-not (Test-Path $planPath)) {
    Write-Error "Plan generation reported success but PLAN.md was not created. No builders were started."
    exit 1
}

Write-Host "Starting unsupervised execution from PLAN.md..." -ForegroundColor Green
& $orch -Project $Project -Objective $Objective -PlanFile $planPath -PlanModel $PlanModel -ReviewModel $ReviewModel -BuilderModel $BuilderModel -MaxCost $MaxCost -MaxTokens $MaxTokens -NoGit:$NoGit
$code = $LASTEXITCODE
Write-Host ""
Write-Host "Run ended (exit $code). Status: .\dashboard.ps1 -Once | Resume: .\manager\orchestrator.ps1 -Project <dir> -RunId <id>" -ForegroundColor DarkGray
exit $code
}
# ---------------- pi: one SSH operator worker ----------------
if ($Mode -eq "pi") {
$piScript = Join-Path $Root "manager\pi.ps1"
if (Test-Path $piScript) { & $piScript; exit $LASTEXITCODE }
Write-Host "pi.ps1 not found in manager\." -ForegroundColor Red
exit 1
}
# ---------------- inspect: standalone read-only report ----------------
# ---------------- plan: inspection -> actionable PLAN.md ----------------
if ($Mode -eq "plan") {
    $planScript = Join-Path $Root "manager\plan.ps1"
    if (Test-Path $planScript) { & $planScript -Project $Project; exit $LASTEXITCODE }
    Write-Host "plan.ps1 not found in manager\." -ForegroundColor Red
    exit 1
}
if ($Mode -eq "inspect") {
$inspectScript = Join-Path $Root "manager\inspect.ps1"
if (Test-Path $inspectScript) { & $inspectScript -Project $Project; exit $LASTEXITCODE }
Write-Host "inspect.ps1 not found in manager\." -ForegroundColor Red
exit 1
}
# ---------------- idea: expand then run ----------------
if ($Mode -eq "idea") {
$ideaScript = Join-Path $Root "manager\idea.ps1"
if (Test-Path $ideaScript) { & $ideaScript -Project $Project -MaxCost $MaxCost -MaxTokens $MaxTokens -NoGit:$NoGit; exit $LASTEXITCODE }
Write-Host "idea.ps1 not found in manager\." -ForegroundColor Red
exit 1
}
# ---------------- parallel: one-terminal console ----------------
if ($Mode -eq "parallel") {
    $console = Join-Path $Root "manager\console.ps1"
    if (Test-Path $console) {
        & $console -Project $Project -Workers $Workers -Tasks $Tasks -Yes:$Yes
        exit $LASTEXITCODE
    }
    Write-Host "Parallel console is built next - manager\console.ps1 not present yet." -ForegroundColor Yellow
    exit 0
}























