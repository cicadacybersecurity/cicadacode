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

# --- sub-mode: unprompted (report the state) or prompted (inspect with a purpose) ---
if (-not $Focus -and -not $Yes) {
    $smi = Show-CicadaMenu -Title "Inspect mode" -Options @("Unprompted (inspect and report the current state)", "Prompted (inspect with a stated purpose)") -Default 0
    if ($smi -eq 1) { $Focus = (Read-Host "Purpose - type text or a path to a .md/.txt file").Trim().Trim('"').Trim([char]39).Trim() }
}

$Focus = Resolve-CicadaText $Focus

$purposeBlock = ""
if ($Focus) {
    $purposeBlock = @"

The inspection has a stated purpose: $Focus
Answer it directly in a fourth section:
## Against the purpose
<the direct answer, grounded in the files you read>
"@
}

$prompt = @"
You are a senior engineer producing a precise state-of-the-project report for a codebase you have never seen.

Project directory: $Project

Inspect the project thoroughly before writing: list the directory tree, read the key files (entry points, configs, tests, docs, manifests), and determine what is complete vs stubbed vs missing. Ground every claim in a file you actually read.

IMPORTANT: never read, list, glob, or enumerate generated or vendored directories - treat them as absent: node_modules, .git, dist, build, bin, obj, out, vendor, __pycache__, .next, .turbo, coverage, packages. They contain nothing relevant and would consume the entire inspection.

Then write the report in EXACTLY this structure:

# Project Inspection: <one-line what-this-is>

## What it is
<2-4 sentences: purpose, stack, shape>

## Current state
<the exact truth: file inventory with a one-line purpose each, what works, what is stubbed/broken/missing, test state, anything noteworthy. Cite file names.>

## What should be next
<prioritized concrete next steps, highest impact first - each one a specific, buildable task naming the files involved. Be opinionated.>
$purposeBlock

No preamble. Ground everything in files you read.
"@

if (-not $Yes) { $Model = Select-CicadaModel -Seat "Inspector" -Current $Model -Recommend "minimax/MiniMax-M3" }
Write-Host ("Inspecting " + $Project + " (" + $Model + ", read-only" + $(if ($Focus) { ", prompted" } else { ", unprompted" }) + ")...") -ForegroundColor DarkGray

$callArgs = @{ Project=$Project; Prompt=$prompt; Model=$Model; Agent="inspect"; Title="inspect" }
$r = Invoke-AgentWithFallback -CallArgs $callArgs -FallbackModels @(Get-CicadaFallbackFor ([string]$callArgs.Model)) -Seat "inspect"
if ($r.ExitCode -ne 0 -or -not $r.Text) { Write-Error ("inspection failed: " + $r.ErrorName + " " + $r.ErrorMessage + " log=" + $r.LogPath); exit 1 }

$report = $r.Text.Trim()
$outPath = Join-Path $Project "INSPECT.md"
$report | Set-Content $outPath -Encoding utf8
$report | Set-Clipboard

Write-Host ""
Write-Host $report
Write-Host ""
Write-Host ("Saved to " + $outPath + " and copied to the clipboard - Ctrl+V it anywhere") -ForegroundColor DarkGray
Send-CicadaTelegram ("CICADA inspect ready | project: " + (Split-Path -Leaf $Project) + $(if ($Focus) { " | prompted: " + $Focus } else { " | unprompted" }) + " | report on clipboard + INSPECT.md")
# --- the next layer: inspection -> actionable plan ---
$planScript = Join-Path $PSScriptRoot "plan.ps1"
if ((-not $Yes) -and (Test-Path $planScript)) {
    $pl = Show-CicadaMenu -Title "Inspection saved - next step?" -Options @("Turn it into an actionable plan (PLAN.md)", "Done for now") -Default 0
    if ($pl -eq 0) { & $planScript -Project $Project; exit $LASTEXITCODE }
}






