# ============================================================================
# CICADA agent.ps1 - single-terminal entry point / mode select.
#   .\agent.ps1                                                 interactive menu
#   .\agent.ps1 -Mode unsupervised -Project <dir> -Objective "<goal>" -Yes
#   .\agent.ps1 -Mode parallel -Project <dir> -Workers 2
#   .\agent.ps1 -Mode debulk -Yes                               shrink a skill playbook
# ============================================================================
[CmdletBinding()]
param(
    [ValidateSet("parallel","unsupervised","idea","inspect","pi","plan","tokeniser","debulk","getskills","execute","consult", "overseer", "fleet")]
    [string]$Mode,
    [string]$Project,
    [string]$Objective,
    [string]$PlanFile,
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
if (-not (Get-Command Select-CicadaSkills -ErrorAction SilentlyContinue)) { . (Join-Path $Root "manager\skills.ps1") }

Import-CicadaSecrets

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " CICADA Agent System" -ForegroundColor Cyan
if (-not $Mode) { Show-CicadaCheatsheet }
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Mode) {
    $mi = Show-CicadaMenu -Title "Select mode" -Options @("Parallel / Interactive (worker fleet)", "Unsupervised (autonomous loop)", "Idea (rough sentence -> product)", "Inspect (state of a project + what is next)", "SSH / Pi operator (one worker on your Raspberry Pi)", "Plan (inspection -> actionable plan file)", "Tokeniser (big idea -> lean executable prompt)", "Debulk skill (shrink a skill playbook)", "Get skills (browse + install from marketplaces)", "Execute plan (run a plan file directly, no re-planning)", "Consult (two models level up an idea)","Overseer (telegram manager for the fleet)", "Fleet up (overseer auto-detect + Telegram control of running workers)", "Quit")
    if ($mi -eq 0) { $Mode = "parallel" }
    elseif ($mi -eq 1) { $Mode = "unsupervised" }
    elseif ($mi -eq 2) { $Mode = "idea" }
    elseif ($mi -eq 3) { $Mode = "inspect" }
    elseif ($mi -eq 4) { $Mode = "pi" }
    elseif ($mi -eq 5) { $Mode = "plan" }
    elseif ($mi -eq 6) { $Mode = "tokeniser" }
    elseif ($mi -eq 7) { $Mode = "debulk" }
    elseif ($mi -eq 8) { $Mode = "getskills" }
    elseif ($mi -eq 9) { $Mode = "execute" }
    elseif ($mi -eq 10) { $Mode = "consult" }
    elseif ($mi -eq 11) { $Mode = "overseer" }
    elseif ($mi -eq 12) { $Mode = "fleet" }
    else { exit 0 }
}

# ---------------- fleet: Telegram overseer for hand-started consoles ----------------
if ($Mode -eq "fleet") {
    $fleetScript = Join-Path $Root "fleet.ps1"
    if (-not (Test-Path $fleetScript)) { Write-Error "fleet.ps1 not found in the CICADA root - copy it there first."; exit 1 }
    $sub = Show-CicadaMenu -Title "Fleet launch" -Options @("Overseer only - detect the consoles I started myself", "Full launch - open consoles from fleet.json + overseer") -Default 0
    if ($sub -eq 0) {
        $expIn = (Read-Host "Workers to wait for before posting the roster [4]").Trim()
        $exp = 4
        $parsed = 0
        if ($expIn -and [int]::TryParse($expIn, [ref]$parsed)) { $exp = $parsed }
        & $fleetScript -OverseerOnly -ExpectWorkers $exp
        exit $LASTEXITCODE
    }
    & $fleetScript
    exit $LASTEXITCODE
}

if (-not $Project -and $Mode -ne "pi" -and $Mode -ne "debulk" -and $Mode -ne "getskills" -and $Mode -ne "overseer") { $Project = (Read-Host "Project (e.g. C:\Users\David\my-project)").Trim() }
if ($Mode -ne "pi" -and $Mode -ne "debulk" -and $Mode -ne "getskills" -and $Mode -ne "overseer" -and -not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
if ($Project) { $Project = (Resolve-Path $Project).Path }

# skills: select playbooks for this run once the mode is known (skipped for skill-management modes and -Yes automation)
if ($Mode -ne "getskills" -and $Mode -ne "debulk" -and -not $Yes) {
    if (Get-Command Select-CicadaSkills -ErrorAction SilentlyContinue) { Select-CicadaSkills }
}

# ---------------- unsupervised: run in THIS terminal ----------------
if ($Mode -eq "unsupervised") {
    if (-not $Objective) { $Objective = Read-CicadaPrompt -Label "Objective" -Example "add a -Since filter to report.ps1 and extend its tests" -Project $Project -ExpandModel $PlanModel; if ($Objective -eq "**CANCEL**") { Write-Host "Aborted."; exit 0 } }
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
    $planPath = Join-Path $Project ("PLAN" + ".md")

    if (-not (Test-Path $planScript)) {
        Write-Error "plan.ps1 not found in manager\. Cannot safely start an unsupervised run without a plan file."
        exit 1
    }

    Write-Host "Preparing an actionable plan file before execution..." -ForegroundColor Cyan
    & $planScript -Project $Project -Focus $Objective -Model $PlanModel -Yes
    $planCode = $LASTEXITCODE

    if ($planCode -ne 0) {
        Write-Error "Plan generation failed (exit $planCode). No builders were started."
        exit $planCode
    }
    if (-not (Test-Path $planPath)) {
        Write-Error "Plan generation reported success but the plan file was not created. No builders were started."
        exit 1
    }

    Write-Host "Starting unsupervised execution from the plan file..." -ForegroundColor Green
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

# ---------------- debulk: shrink a skill playbook ----------------
# ---------------- execute: run an existing plan file directly (no re-planning) ----------------
if ($Mode -eq "execute") {
    $orchScript = Join-Path $Root "manager\orchestrator.ps1"
    if (-not (Test-Path $orchScript)) { Write-Host "orchestrator.ps1 not found in manager\." -ForegroundColor Red; exit 1 }
    $planFile = $PlanFile
    if (-not $planFile) {
        $cand = @()
        $tp = Join-Path $Project "tokenprompt.md"
        $pl = Join-Path $Project "PLAN.md"
        if (Test-Path $tp) { $cand += $tp }
        if (Test-Path $pl) { $cand += $pl }
        $def = if ($cand.Count -gt 0) { $cand[0] } else { "" }
        $inp = (Read-Host "Plan file [$def]").Trim().Trim('"').Trim([char]39)
        if ($inp) { $planFile = $inp } else { $planFile = $def }
    }
    if (-not $planFile -or -not (Test-Path $planFile -PathType Leaf)) { Write-Error "Plan file not found: $planFile"; exit 1 }
    if (-not [System.IO.Path]::IsPathRooted($planFile)) { $planFile = Join-Path $Project $planFile }
    Write-Host "Executing plan directly (no re-planning): $planFile" -ForegroundColor Green
    & $orchScript -Project $Project -PlanFile $planFile -PlanModel $PlanModel -ReviewModel $ReviewModel -BuilderModel $BuilderModel -MaxCost $MaxCost -MaxTokens $MaxTokens -NoGit:$NoGit
    exit $LASTEXITCODE
}
if ($Mode -eq "getskills") {
    $gsScript = Join-Path $Root "manager\getskills.ps1"
    if (Test-Path $gsScript) { & $gsScript -Yes:$Yes; exit $LASTEXITCODE }
    Write-Host "getskills.ps1 not found in manager\." -ForegroundColor Red
    exit 1
}

if ($Mode -eq "debulk") {
    $dbScript = Join-Path $Root "manager\skill-debulker.ps1"
    if (Test-Path $dbScript) { & $dbScript -Model $PlanModel -Yes:$Yes; exit $LASTEXITCODE }
    Write-Host "skill-debulker.ps1 not found in manager\." -ForegroundColor Red
    exit 1
}

# ---------------- tokeniser: big idea -> lean executable prompt ----------------
if ($Mode -eq "tokeniser") {
    $tkScript = Join-Path $Root "manager\tokeniser.ps1"
    if (Test-Path $tkScript) { & $tkScript -Project $Project; exit $LASTEXITCODE }
    Write-Host "tokeniser.ps1 not found in manager\." -ForegroundColor Red
    exit 1
}

# ---------------- overseer: telegram manager for the worker fleet ----------------
if ($Mode -eq "overseer" -or "$Mode" -match "(?i)overseer") {
$ovScript = Join-Path $Root "manager\overseer.ps1"
if (Test-Path $ovScript) { & $ovScript -Project $Project; exit $LASTEXITCODE }
Write-Host "overseer.ps1 not found in manager\. Run install-overseer.ps1 first." -ForegroundColor Red
exit 1
}

# ---------------- plan: inspection -> actionable plan file ----------------
if ($Mode -eq "plan") {
    $pfi = Show-CicadaMenu -Title "Plan from?" -Options @("Inspection (survey a project)", "File (convert a document, e.g. a consult FINAL.md, into an executable plan)", "Transcript (consult transcript -> phased plan for workers)") -Default 0
    if ($pfi -eq 1) {
        $pff = Join-Path $PSScriptRoot "manager\plan-from-file.ps1"
        if (Test-Path $pff) { & $pff; exit $LASTEXITCODE }
        Write-Host "plan-from-file.ps1 not found in manager\." -ForegroundColor Red
        exit 1
    }
if ($pfi -eq 2 -or "$pfi" -match "Transcript") {
$t2p = Join-Path $PSScriptRoot "manager\transcript-to-plan.ps1"
if (Test-Path $t2p) { & $t2p -Project $Project; exit $LASTEXITCODE }
Write-Host "transcript-to-plan.ps1 not found in manager\" -ForegroundColor Red
exit 1
}
}
if ($Mode -eq "plan") {
    $planScript = Join-Path $Root "manager\plan.ps1"
    if (Test-Path $planScript) { & $planScript -Project $Project; exit $LASTEXITCODE }
    Write-Host "plan.ps1 not found in manager\." -ForegroundColor Red
    exit 1
}


# ---------------- consult: two models level up an idea ----------------
if ($Mode -eq "consult") {
    $consultScript = Join-Path $PSScriptRoot "manager\consult.ps1"
    if (Test-Path $consultScript) { & $consultScript -Project $Project; exit $LASTEXITCODE }
    Write-Host "consult.ps1 not found in manager\." -ForegroundColor Red
    exit 1
}
# ---------------- inspect: standalone read-only report ----------------
if ($Mode -eq "inspect") {
    $inspectScript = Join-Path $Root "manager\inspect.ps1"
    $updateScript = Join-Path $Root "manager\inspect-update.ps1"
    $ii = 0
    if (-not $Yes) { $ii = Show-CicadaMenu -Title "Inspect how?" -Options @("Classic (state of a project + what is next)", "Update plan (verify plan items against the code, trim completed)", "Targeted (answer one specific question about the project)") -Default 0 }
    if ($ii -eq 2) {
        $tScript = Join-Path $Root "manager\inspect-target.ps1"
        if (Test-Path $tScript) { & $tScript -Project $Project -Model $PlanModel; exit $LASTEXITCODE }
        Write-Host "inspect-target.ps1 not found in manager\." -ForegroundColor Red; exit 1
    }
    if ($ii -eq 0) {
        if (Test-Path $inspectScript) { & $inspectScript -Project $Project; exit $LASTEXITCODE }
        Write-Host "inspect.ps1 not found in manager\." -ForegroundColor Red
        exit 1
    }
    if (Test-Path $updateScript) { & $updateScript -Project $Project; exit $LASTEXITCODE }
    Write-Host "inspect-update.ps1 not found in manager\." -ForegroundColor Red
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






