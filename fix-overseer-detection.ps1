#Requires -Version 5.1
<#
fix-overseer-detection.ps1 - ONE job, no history, no patch layers.

Replaces the Find-LiveWorkers function in manager\overseer.ps1 with the final
fleet version, then stops. Safe to re-run (it detects its own work and exits).

What the new function does:
  - a worker's identity is its SESSION, not its port: the same session listed
    on two ports (your Alpha/Bravo duplicate) is adopted ONCE, first port wins
  - zombie servers (console window closed, opencode server still listening) are
    tagged [zombie-server] in the roster but NEVER skipped - the old skip logic
    was eating live workers, which is why you got "no live workers detected"
  - sessions idle over -MaxSessionAgeHours (default 6h) are skipped as stale

Run from the CICADA root:
    powershell -ExecutionPolicy Bypass -File .\fix-overseer-detection.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$file = Join-Path $root "manager\overseer.ps1"
if (-not (Test-Path $file)) { Write-Error "manager\overseer.ps1 not found - run me from the CICADA root (folder with agent.ps1)."; exit 1 }

# ---- read, preserving BOM ----
$bytes = [System.IO.File]::ReadAllBytes($file)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$enc = New-Object System.Text.UTF8Encoding($false, $false)
if ($bom) { $text = $enc.GetString($bytes, 3, $bytes.Length - 3) } else { $text = $enc.GetString($bytes, 0, $bytes.Length) }

if ($text.Contains("fleet fix v2.1")) {
    Write-Host "already applied - Find-LiveWorkers is the final version. nothing to do." -ForegroundColor DarkGray
    exit 0
}

# ---- quick git snapshot so this is reversible (safe if git missing) ----
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git -and (Test-Path (Join-Path $root ".git"))) {
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Push-Location $root
    try {
        & git add -A 2>&1 | Out-Null
        & git commit --quiet -m "snapshot before fix-overseer-detection" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "git: snapshot committed (rollback: git checkout -- manager\overseer.ps1)" -ForegroundColor DarkGray }
    } finally { Pop-Location; $ErrorActionPreference = $oldEAP }
}

# ---- the replacement function ----
$newFnText = @'
function Find-LiveWorkers {
    # fleet fix v2.1: opencode stores sessions per PROJECT, so every serve
    # instance of one project lists the same sessions. A worker's identity is
    # its SESSION, not its port - the same session on two ports is one worker
    # (first port wins; callsigns follow ascending port order).
    # Orphaned serves (console window closed, server still listening) are tagged
    # [zombie-server] but NEVER skipped: opencode's process tree makes parentage
    # unreliable, and a missed live worker is worse than an adopted zombie.
    # Sessions idle over $MaxSessionAgeHours are skipped as stale.
    $found = @()

    $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalAddress -eq "127.0.0.1" -and
            $_.LocalPort -ge 4311 -and
            $_.LocalPort -le 4320
        } |
        Sort-Object LocalPort -Unique

    foreach ($conn in @($ports)) {
        $port = [int]$conn.LocalPort
        $url = "http://127.0.0.1:" + $port

        $orphanNote = ""
        $owningProc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$conn.OwningProcess) -ErrorAction SilentlyContinue
        if ($owningProc) {
            $parentProc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $owningProc.ParentProcessId) -ErrorAction SilentlyContinue
            if (-not $parentProc) { $orphanNote = " [zombie-server]" }
        }

        try {
            $sessions = Invoke-RestMethod `
                -Method Get `
                -Uri ($url + "/session") `
                -TimeoutSec 5

            $workerSessions = @(
                $sessions |
                Where-Object {
                    [string]$_.title -match '^worker-\d+$'
                } |
                Sort-Object { [long]$_.time.updated } -Descending
            )

            foreach ($sess in $workerSessions) {
                $ageHours = 999
                try {
                    $updMs = [long]$sess.time.updated
                    if ($updMs -lt 100000000000) { $updMs = $updMs * 1000 }
                    $ageHours = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds($updMs)).TotalHours
                } catch {}
                if ($ageHours -gt $MaxSessionAgeHours) {
                    Write-Host ("  detect: skipping stale session on port " + $port + " (idle " + [math]::Round($ageHours, 1) + "h - raise -MaxSessionAgeHours to adopt it)") -ForegroundColor DarkGray
                    continue
                }
                $found += @{
                    id = "pending"
                    name = ""
                    url = $url
                    session = [string]$sess.id
                    project = ([string]$sess.directory + $orphanNote)
                }
            }
        }
        catch {}
    }

    $seen = @{}
    $bySession = @()
    foreach ($fw in $found) {
        $sid = [string]$fw.session
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        $bySession += $fw
    }
    $seq = 0
    foreach ($fw in $bySession) {
        $seq++
        $fw.id = [string]$seq
        $fw.name = (Get-Callsign $fw.id)
    }
    return $bySession
}
'@

# ---- line-based surgical swap: find the function's boundary LINES, nothing
# about its interior matters, so drift inside the function cannot break this ----
$lines = $text -split "`r?`n"
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*function\s+Find-LiveWorkers\s*\{') { $start = $i; break }
}
if ($start -lt 0) { Write-Error "Find-LiveWorkers not found in $file - send me the file, it has drifted more than expected."; exit 1 }

$end = -1
for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -eq "}") { $end = $i; break }   # first brace alone on a line = function end
}
if ($end -lt 0) { Write-Error "found the start of Find-LiveWorkers but not its end - file looks truncated."; exit 1 }

$newLines = $newFnText -split "`r?`n"
$head = @()
$tail = @()
if ($start -gt 0) { $head = @($lines[0..($start - 1)]) }
if ($end -lt $lines.Count - 1) { $tail = @($lines[($end + 1)..($lines.Count - 1)]) }
$newText = (@($head) + @($newLines) + @($tail)) -join "`r`n"

# ---- syntax check the WHOLE file before writing anything ----
$errs = $null
[void][System.Management.Automation.PSParser]::Tokenize($newText, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Error ("syntax check failed after replacement (" + $errs[0].Message + ") - nothing was written")
    exit 1
}

$wenc = New-Object System.Text.UTF8Encoding($bom, $false)
[System.IO.File]::WriteAllText($file, $newText, $wenc)

Write-Host ""
Write-Host ("done - Find-LiveWorkers replaced (was lines " + ($start + 1) + "-" + ($end + 1) + ", now " + $newLines.Count + " lines)") -ForegroundColor Green
Write-Host "  - same session on two ports = ONE worker now"
Write-Host "  - zombie servers tagged [zombie-server] instead of hidden"
Write-Host "  - stale sessions (>6h idle) skipped"
Write-Host ""
Write-Host "Now: close the overseer window, start it again ( .\fleet.ps1 -OverseerOnly -ExpectWorkers 3 ), /detect." -ForegroundColor Cyan
