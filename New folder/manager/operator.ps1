param(
    [string]$Project,
    [string]$Goal,
    [int]$MaxRuns = 3,
    [int]$InspectMaxAgeHours = 48
)

. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

if (-not $Project) { $Project = (Read-Host "Project directory").Trim() }
if (-not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path
if (-not $Goal) { $Goal = (Read-Host "Goal (rough is fine - the operator sharpens it through inspect/plan)").Trim() }

$root = Split-Path $PSScriptRoot
$inspectScript = Join-Path $PSScriptRoot "inspect.ps1"
$planScript    = Join-Path $PSScriptRoot "plan.ps1"
$orchScript    = Join-Path $PSScriptRoot "orchestrator.ps1"
$inspectPath   = Join-Path $Project "INSPECT.md"
$planPath      = Join-Path $Project "PLAN.md"
$leaf          = Split-Path -Leaf $Project

Send-CicadaTelegram ("CICADA [operator] starting | " + $leaf + " | goal: " + $Goal)

# --- 1. inspection freshness (acts as you: stale analysis = bad plans) ---
$needInspect = -not (Test-Path $inspectPath)
if (-not $needInspect -and ((Get-Item $inspectPath).LastWriteTime -lt (Get-Date).AddHours(-$InspectMaxAgeHours))) { $needInspect = $true }
if ($needInspect) {
    Write-Host "[operator] inspection missing or stale - running inspect" -ForegroundColor DarkGray
    & $inspectScript -Project $Project -Yes
}

# --- 2. the plan layer (replan if missing or older than the inspection) ---
$needPlan = -not (Test-Path $planPath)
if (-not $needPlan -and (Test-Path $inspectPath) -and ((Get-Item $planPath).LastWriteTime -lt (Get-Item $inspectPath).LastWriteTime)) { $needPlan = $true }
if ($needPlan) {
    Write-Host "[operator] generating PLAN.md" -ForegroundColor DarkGray
    & $planScript -Project $Project -Yes
}

# --- 3. the execute-readout-replan loop (your judgment, automated) ---
$runNo = 0
$done = $false
while (-not $done -and $runNo -lt $MaxRuns) {
    $runNo++
    Write-Host ("[operator] run " + $runNo + " of " + $MaxRuns) -ForegroundColor Cyan
    Send-CicadaTelegram ("CICADA [operator] run " + $runNo + "/" + $MaxRuns + " | " + $leaf)
    & $orchScript -Project $Project -PlanFile $planPath
    $code = $LASTEXITCODE
    if ($code -eq 0) { $done = $true; break }

    $digest = Get-ChildItem (Join-Path $root "state\runs\run_*-digest.md") | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $digestLine = if ($digest) { $digest.Name } else { "no digest" }
    Write-Host ("[operator] run ended exit " + $code + " - " + $digestLine) -ForegroundColor Yellow
    Send-CicadaTelegram ("CICADA [operator] run " + $runNo + " ended (exit " + $code + ") | " + $leaf + " | " + $digestLine)

    if ($runNo -lt $MaxRuns) {
        Write-Host "[operator] replanning around the blocker in smaller deliverables" -ForegroundColor DarkGray
        & $planScript -Project $Project -Yes -Focus "The previous unsupervised run blocked partway through this plan. Re-plan the REMAINING work only, in smaller independently-provable deliverables, and work around whatever blocked it."
    }
}

$verdict = if ($done) { "GOAL COMPLETE" } else { "STOPPED after " + $runNo + " runs - needs you" }
Write-Host ("[operator] " + $verdict) -ForegroundColor $(if ($done) { "Green" } else { "Yellow" })
Send-CicadaTelegram ("CICADA [operator] " + $verdict + " | " + $leaf + " | goal: " + $Goal)
