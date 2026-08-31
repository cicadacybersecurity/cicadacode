param(
    [string]$Project,
    [int]$Workers = 0,
    [string]$Model = "",
    [string[]]$Tasks,
    [switch]$Yes
)
# OpenClaw squad: the parallel console, but every worker is a baked-in
# Linux + OpenClaw expert carrying openclaw.md as its skillset.
$ErrorActionPreference = "Stop"
$skill = Join-Path $PSScriptRoot "openclaw.md"
if (-not (Test-Path $skill)) { Write-Error "openclaw.md missing - re-run install-openclaw-squad.ps1"; exit 1 }

if (-not $Project) { $Project = (Read-Host "Project directory").Trim() }
if (-not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path

if ($Workers -lt 1) { $Workers = [int](Read-Host "How many OpenClaw expert workers (e.g. 2)") }
if ($Workers -lt 1) { $Workers = 1 }

$preamble = "You are a senior Linux systems developer and OpenClaw platform specialist working in this project - you do not just operate software for OpenClaw, you DEVELOP it: agent-native by design, Linux-native by default, every feature built so an autonomous agent can install, run, inspect, and recover it without a human. Your baked-in skillset (openclaw.md, attached below) is your convention book - follow it exactly: Linux-native tooling, agent-operable steps (no interactive prompts, no GUI assumptions), idempotent commands, every claim gated by a runnable check. TASK: "

$taskList = @()
if ($Tasks) { $taskList = @($Tasks) }
while ($taskList.Count -lt $Workers) {
    $taskList += (Read-Host ("Worker " + ($taskList.Count + 1) + " task"))
}
$wrapped = @()
foreach ($t in $taskList) { if ($t) { $wrapped += ($preamble + $t) } else { $wrapped += $t } }

$console = Join-Path $PSScriptRoot "console.ps1"
if (-not (Test-Path $console)) { Write-Error "console.ps1 not found next to this script"; exit 1 }
Show-ReplayCommand -ParamNames @("Project","Workers","Model","Tasks","Yes")
$callArgs = @{ Project = $Project; Workers = $Workers; Tasks = $wrapped; TaskFile = $skill; Yes = $true }
if ($Model) { $callArgs.Model = $Model }
& $console @callArgs
exit $LASTEXITCODE
