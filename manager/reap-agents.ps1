# reap-agents.ps1 - kill orphaned opencode worker processes
# Usage:
#   .\manager\reap-agents.ps1           kill opencode processes NOT registered as live workers
#   .\manager\reap-agents.ps1 -All      kill every opencode process (nuclear option)
#   .\manager\reap-agents.ps1 -WhatIf   show what would die without killing
param(
    [switch]$All,
    [switch]$WhatIf
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$workersFile = Join-Path $Root "state\workers.json"

$livePorts = @{}
if (Test-Path $workersFile) {
    try {
        $ws = (Get-Content $workersFile -Raw | ConvertFrom-Json).workers
        foreach ($p in $ws.PSObject.Properties) {
            if ($p.Value.port) { $livePorts[[int]$p.Value.port] = $true }
        }
    } catch {}
}

$procs = @(Get-Process | Where-Object Name -match "opencode")
if ($procs.Count -eq 0) { Write-Host "no opencode processes running - nothing to reap" -ForegroundColor DarkGray; exit 0 }

$killed = 0
foreach ($p in $procs) {
    $keep = $false
    if (-not $All) {
        try {
            $conns = Get-NetTCPConnection -State Listen -OwningProcess $p.Id -ErrorAction SilentlyContinue
            foreach ($c in $conns) { if ($livePorts.ContainsKey([int]$c.LocalPort)) { $keep = $true } }
        } catch {}
    }
    if ($keep) {
        Write-Host ("keep   pid " + $p.Id + " (live worker, started " + $p.StartTime + ")") -ForegroundColor Green
    } else {
        $killed++
        if ($WhatIf) {
            Write-Host ("WOULD reap pid " + $p.Id + " (started " + $p.StartTime + ")") -ForegroundColor DarkYellow
        } else {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-Host ("reaped pid " + $p.Id + " (started " + $p.StartTime + ")") -ForegroundColor DarkYellow
        }
    }
}
Write-Host ""
if ($WhatIf) {
    Write-Host ("dry run: " + $killed + " would be reaped, " + ($procs.Count - $killed) + " kept") -ForegroundColor Cyan
} else {
    Write-Host ("done - " + $killed + " reaped, " + ($procs.Count - $killed) + " kept (registered live workers)") -ForegroundColor Green
}
