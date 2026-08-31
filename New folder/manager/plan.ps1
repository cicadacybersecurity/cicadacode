param(
    [string]$Project,
    [string]$Focus,
    [string]$Model = "minimax/MiniMax-M3",
    [switch]$Yes
)

. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

if (-not $Project) { $Project = (Read-Host "Project directory (e.g. C:\Users\David\my-project)").Trim() }
if (-not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path

$inspectPath = Join-Path $Project "INSPECT.md"
$hasInspect = Test-Path $inspectPath

$Focus = Resolve-CicadaText $Focus

$focusBlock = ""
if ($Focus) {
$focusBlock = @"

The plan has a stated focus: $Focus
Weight the deliverables toward it and omit work that does not serve it.
"@
}

$sourceLine = if ($hasInspect) { "An inspection report exists at INSPECT.md - read it first, then verify its claims against the actual files (the report may be stale)." } else { "No inspection report exists - inspect the project yourself first: list the directory tree, read the entry points, configs, tests, docs and manifests." }
$sourceName = if ($hasInspect) { "INSPECT.md" } else { "fresh inspection" }
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm"

$prompt = @"
You are the planning layer of an autonomous coding system: you turn a project's current state into an executable plan of small, independently provable deliverables.

Project directory: $Project
$sourceLine

IMPORTANT: never read, list, glob, or enumerate generated or vendored directories - treat them as absent: node_modules, .git, dist, build, bin, obj, out, vendor, __pycache__, .next, .turbo, coverage, packages. They contain nothing relevant and would consume the entire budget.

GRANULARITY IS A HARD CONTRACT:
- One deliverable per numbered item. Never merge multiple deliverables into one item.
- Each item must be independently buildable and provable by a builder agent in at most 15 build steps.
- Order by impact and dependency: foundations first.

VALIDATION IS A HARD CONTRACT:
- Every item's Validation is ONE runnable command whose EXIT CODE proves the work.
- Prefer exit-code checks that test behavior: npx tsc --noEmit, npx vitest run, npm test, python3 -m py_compile <file>. Never validate a fix by the presence of a string that also exists in the broken state - presence is not proof.
- If you must use findstr: write plain quotes, never backslash-escaped (/C: matches literally). For absence checks invert correctly, e.g. powershell -Command "if (Test-Path <path>) { exit 1 } else { exit 0 }".
$focusBlock
Write the plan in EXACTLY this structure:

# Plan: <one-line project summary>

Generated: $stamp | Model: $Model | Source: $sourceName

## Context
<2-3 sentences: current state, and why these deliverables in this order>

## Deliverables

### 1. <short title>
- **Files:** <exact comma-separated paths>
- **Change:** <1-2 sentences>
- **Validation:** ``<exact command>``
- **Risk:** low | high   (high = deletions, cross-cutting changes, anything irreversible)
- **Est. steps:** <n>

### 2. <next item, same shape> (and so on)

No preamble, no closing remarks - only the markdown above.
"@

if (-not $Yes) { $Model = Select-CicadaModel -Seat "Plan writer" -Current $Model -Recommend "minimax/MiniMax-M3" }
Write-Host ("Planning " + $Project + " (" + $Model + ", source: " + $sourceName + ")...") -ForegroundColor DarkGray

$callArgs = @{ Project=$Project; Prompt=$prompt; Model=$Model; Agent="plan"; Title="plan" }
$r = Invoke-AgentWithFallback -CallArgs $callArgs -FallbackModels @(Get-CicadaFallbackFor ([string]$callArgs.Model)) -Seat "plan"
if ($r.ExitCode -ne 0 -or -not $r.Text) { Write-Error ("planning failed: " + $r.ErrorName + " " + $r.ErrorMessage + " log=" + $r.LogPath); exit 1 }

$plan = $r.Text.Trim()
$heading = $plan.IndexOf("# Plan:")
if ($heading -gt 0) { $plan = $plan.Substring($heading).Trim() }

$outPath = Join-Path $Project "PLAN.md"
$plan | Set-Content $outPath -Encoding utf8
$plan | Set-Clipboard

$itemCount = [regex]::Matches($plan, '(?m)^### \d+\.').Count

Write-Host ""
Write-Host $plan
Write-Host ""
Write-Host ("Saved to " + $outPath + " (" + $itemCount + " deliverables) and copied to the clipboard") -ForegroundColor DarkGray
Send-CicadaTelegram ("CICADA plan ready | project: " + (Split-Path -Leaf $Project) + " | " + $itemCount + " deliverables | PLAN.md saved + on clipboard")
# --- the chain: plan -> execution ---
$orchScript = Join-Path $PSScriptRoot "orchestrator.ps1"
if ((-not $Yes) -and (Test-Path $orchScript)) {
    $ex = Show-CicadaMenu -Title "Plan saved - next step?" -Options @("Execute this plan now (unsupervised run)", "Save only - I will run it later") -Default 0
    if ($ex -eq 0) {
        $execObjective = 'execute the plan in "' + $outPath + '" - each numbered deliverable in PLAN.md is one task with its own validation'
        & $orchScript -Project $Project -Objective $execObjective -PlanFile $outPath -PlanModel $Model
        exit $LASTEXITCODE
    }
}



