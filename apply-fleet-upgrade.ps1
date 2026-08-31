#Requires -Version 5.1
<#
apply-fleet-upgrade.ps1 - make the 4-console + overseer workflow one command.
Run once from the CICADA root (folder containing agent.ps1):

    powershell -ExecutionPolicy Bypass -File .\apply-fleet-upgrade.ps1

Fixes in manager\overseer.ps1:
  1. adoption bug: every console numbers its worker "worker-1" and the overseer
     deduped by worker id, so only ONE of your four workers was ever adopted.
     Now: one worker per port, renumbered in detection order (Alpha, Bravo...).
  2. /detect replay storm: the slash-command handler relayed a summary for EVERY
     historical assistant message instead of baselining. Now it primes quietly.
  3. adds -AutoDetect (-ExpectWorkers N, -AutoDetectTimeoutSec): the overseer
     waits for consoles to boot, adopts the fleet, baselines, posts the roster -
     you never type /detect by hand again.
  4. overseer window title: "CICADA overseer (Telegram)".
  5. summary format: worker replies arrive as plain-English CHANGED / NEXT /
     NEEDS YOU / SUGGESTION - the suggestion is a message you can send back
     verbatim (the existing 'yes' reply already does exactly that).

Fix in manager\console.ps1:
  5. each console window titles itself "CICADA console - <project>".

Same safety model as apply-hardening.ps1: git baseline first, exact anchors
verified once each, syntax check before writing, idempotent.
Rollback:  git checkout -- manager
#>
[CmdletBinding()]
param([switch]$SkipGit)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path (Join-Path $root "manager\overseer.ps1")) -or
    -not (Test-Path (Join-Path $root "manager\console.ps1"))) {
    Write-Error "Run me from the CICADA root (the folder containing agent.ps1)."
    exit 1
}

# ---------------- file IO (preserve UTF-8 BOM / no-BOM) ----------------

function Get-FileText([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($false, $false)
    if ($bom) { $text = $enc.GetString($bytes, 3, $bytes.Length - 3) }
    else      { $text = $enc.GetString($bytes, 0, $bytes.Length) }
    return @($text, $bom)
}

function Set-FileText([string]$path, [string]$text, [bool]$bom) {
    $enc = New-Object System.Text.UTF8Encoding($bom, $false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

# ---------------- git baseline (native git runs under Continue: PS 5.1 turns
# harmless git stderr warnings into NativeCommandError under -Stop) ------------

$script:GitBaselineOk = $false

if (-not $SkipGit) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Host "git not found - skipping baseline snapshot (rollback will be manual)." -ForegroundColor Yellow
    } else {
        Push-Location $root
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            if (-not (Test-Path (Join-Path $root ".git"))) {
                & git init 2>&1 | Out-Null
                Write-Host "git: initialized repository" -ForegroundColor Green
            }
            & git config user.email 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & git config user.email "cicada@localhost" 2>&1 | Out-Null
                & git config user.name "cicada" 2>&1 | Out-Null
                Write-Host "git: set local identity (cicada@localhost)" -ForegroundColor DarkGray
            }
            & git add -A 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host ("git: add failed (exit " + $LASTEXITCODE + ") - patches will still apply") -ForegroundColor Yellow
            } else {
                $porc = & git status --porcelain 2>$null | Out-String
                if ($porc.Trim()) {
                    & git commit --quiet -m "baseline: pre-fleet-upgrade snapshot" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $script:GitBaselineOk = $true
                        Write-Host "git: baseline committed (rollback: git checkout -- manager)" -ForegroundColor Green
                    } else {
                        Write-Host ("git: commit failed (exit " + $LASTEXITCODE + ") - patches will still apply") -ForegroundColor Yellow
                    }
                } else {
                    $script:GitBaselineOk = $true
                    Write-Host "git: working tree already clean - baseline exists" -ForegroundColor DarkGray
                }
            }
        } finally {
            $ErrorActionPreference = $oldEAP
            Pop-Location
        }
    }
}

# ---------------- patch definitions ----------------

$o2Text = @'
    # fleet fix: multiple consoles each number their worker "worker-1" - key by
    # port (one worker per port), then renumber in detection order so callsigns
    # Alpha, Bravo, Charlie... are unique across the whole fleet.
    $byPort = @($found | Sort-Object { [string]$_.url } -Unique)
    $byPort = @($byPort | Sort-Object { [int]([uri]([string]$_.url)).Port })
    $seq = 0
    foreach ($fw in $byPort) {
        $seq++
        $fw.id = [string]$seq
        $fw.name = (Get-Callsign $fw.id)
    }
    return $byPort
'@

$o3Text = @'
            # fleet fix: prime with the watch loop's hash format so adoption is
            # silent - only genuinely new replies relay from here on.
            foreach ($wk in @($workers)) {
                if (-not $wk.session) { continue }
                try {
                    $pMsgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 15
                    $pLast = $null
                    foreach ($pm in @($pMsgs)) { if ([string]$pm.info.role -eq "assistant") { $pLast = $pm } }
                    if ($pLast) {
                        $pParts = @($pLast.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
                        $pText = ($pParts -join "`n").Trim()
                        if ($pText) {
                            $pHashInput = $pText.Length.ToString() + ":" + $pText.Substring(0, [Math]::Min(64, $pText.Length))
                            $lastHash[$wk.id] = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pHashInput))
                        }
                    }
                } catch {}
            }
'@

$o4Text = @'
# fleet: optional startup auto-detect - wait for consoles to boot, adopt every
# live worker, baseline quietly (no history replay), post the roster to Telegram.
if ($AutoDetect) {
    $deadline = (Get-Date).AddSeconds($AutoDetectTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $detectedWorkers = Find-LiveWorkers
        $workers = @($detectedWorkers)
        if ($ExpectWorkers -gt 0 -and $workers.Count -ge $ExpectWorkers) { break }
        if ($ExpectWorkers -le 0 -and $workers.Count -gt 0) { break }
        Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
    }
    $lastHash = @{}
    foreach ($wk in @($workers)) {
        if (-not $wk.session) { continue }
        try {
            $pMsgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 15
            $pLast = $null
            foreach ($pm in @($pMsgs)) { if ([string]$pm.info.role -eq "assistant") { $pLast = $pm } }
            if ($pLast) {
                $pParts = @($pLast.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
                $pText = ($pParts -join "`n").Trim()
                if ($pText) {
                    $pHashInput = $pText.Length.ToString() + ":" + $pText.Substring(0, [Math]::Min(64, $pText.Length))
                    $lastHash[$wk.id] = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pHashInput))
                }
            }
        } catch {}
    }
    if ($workers.Count -eq 0) {
        Send-OverseerTelegram "auto-detect: no live workers found yet - a worker appears once its console sends its first task; /detect anytime to adopt later ones."
    } else {
        Send-OverseerTelegram ("auto-adopted " + $workers.Count + " worker(s) - watching:`n" + (Get-FleetRoster $workers))
    }
}


'@

$o5Text = @'
try { $host.UI.RawUI.WindowTitle = "CICADA overseer (Telegram)" } catch {}

'@

$o6Text = @'
$sys = "You rewrite a worker agent's latest reply for the operator's Telegram chat. Plain English, short labeled lines, no jargon, no markdown, no filler. The worker follows a plan broken into phases; its reply says what it did and what comes next. Output EXACTLY these lines, in this order, nothing else: CHANGED: one or two plain sentences - what the worker actually did, built, or fixed this round; name real files, commands, or results when the reply mentions them. NEXT: what is left to do - the next phase or remaining plan items; if the worker is blocked or waiting for direction, say what it is waiting for; if the plan is finished, say plan complete. NEEDS YOU: include this line ONLY when the worker is blocked, errored, or needs a decision - one plain sentence on exactly what is needed from the operator. SUGGESTION: the single most useful short message the operator could send back verbatim, e.g. implement phase 14, or run the tests, or fix the failing validation; write exactly none needed if there is nothing useful to send. Never invent facts, progress, or blockers. If the reply is only a question or acknowledgement, CHANGED says so, NEXT says what you can tell, SUGGESTION answers it or says none needed.";
'@

$c1Text = @'
try { $host.UI.RawUI.WindowTitle = "CICADA console - " + (Split-Path -Leaf $Project) } catch {}
'@

$patches = @(
    @{ File = "manager\overseer.ps1"; Name = "overseer: -AutoDetect params"
       Pattern = '    \[switch\]\$Yes(?=\r?\n\))'
       Mode = "After"; Marker = 'AutoDetectTimeoutSec'
       Text = ",`r`n    [switch]`$AutoDetect,`r`n    [int]`$ExpectWorkers = 0,`r`n    [int]`$AutoDetectTimeoutSec = 180" },

    @{ File = "manager\overseer.ps1"; Name = "overseer: adopt one worker per port, renumber by detection order"
       Pattern = '    return @\(\r?\n        \$found \|\r?\n        Sort-Object \{ \[int\]\$_\.id \} -Unique\r?\n    \)'
       Mode = "Replace"; Marker = 'fleet fix: multiple consoles'; Text = $o2Text },

    @{ File = "manager\overseer.ps1"; Name = "overseer: /detect baselines instead of replaying history"
       Pattern = '            # Baseline the current assistant response for every\r?\n            # adopted worker\. This prevents stale session output\r?\n            # from being immediately treated as a new reply\.\r?\n            \$lastHash = @\{\}\r?\n'
       Mode = "After"; Marker = 'fleet fix: prime with the watch loop'; Text = ("`r`n" + $o3Text) },

    @{ File = "manager\overseer.ps1"; Name = "overseer: window title"
       Pattern = 'Write-Host \("overseer live'
       Mode = "Before"; Marker = 'CICADA overseer (Telegram)'; Text = $o5Text },

    @{ File = "manager\overseer.ps1"; Name = "overseer: startup auto-detect"
       Pattern = '\$workers = @\(\)\r?\n\r?\n(?=while \(\$true\) \{)'
       Mode = "After"; Marker = 'fleet: optional startup auto-detect'; Text = $o4Text },

    @{ File = "manager\overseer.ps1"; Name = "overseer: plain-English summary format (CHANGED/NEXT/NEEDS YOU/SUGGESTION)"
       Pattern = '\$sys = "You are the concise operational briefing layer[^\r\n]*";'
       Mode = "Replace"; Marker = 'You rewrite a worker agent'; Text = $o6Text },

    @{ File = "manager\console.ps1"; Name = "console: window title per project"
       Pattern = '\$Project = \(Resolve-Path \$Project\)\.Path\r?\n'
       Mode = "After"; Marker = 'CICADA console - '; Text = $c1Text }
)

# ---------------- apply (in memory; write only if everything verifies) --------

$texts = @{}
$boms  = @{}
foreach ($f in ($patches.File | Select-Object -Unique)) {
    $p = Join-Path $root $f
    $r = Get-FileText $p
    $texts[$f] = $r[0]
    $boms[$f]  = [bool]$r[1]
}

$failures = @()
$applied  = @()
$skipped  = @()

foreach ($p in $patches) {
    $f = $p.File
    if ($texts[$f].Contains($p.Marker)) { $skipped += $p.Name; continue }
    $hits = [regex]::Matches($texts[$f], $p.Pattern).Count
    if ($hits -ne 1) {
        $failures += ($p.Name + ": anchor matched " + $hits + " time(s), expected exactly 1 - " + $f + " differs from the reviewed version; NOT writing anything")
        continue
    }
    $Mode = $p.Mode
    $Text = ($p.Text -replace "`r?`n", "`r`n")
    $ev = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) if ($Mode -eq "Replace") { $Text } elseif ($Mode -eq "After") { $m.Value + $Text } else { $Text + $m.Value } }
    $texts[$f] = [regex]::Replace($texts[$f], $p.Pattern, $ev)
    $applied += $p.Name
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "PATCH ABORTED - no files were modified:" -ForegroundColor Red
    foreach ($x in $failures) { Write-Host ("  " + $x) -ForegroundColor Red }
    exit 1
}

$syntaxBad = @()
foreach ($f in $texts.Keys) {
    $parseErrors = $null
    [void][System.Management.Automation.PSParser]::Tokenize($texts[$f], [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $syntaxBad += ($f + ": " + $parseErrors.Count + " parse error(s), first: " + $parseErrors[0].Message)
    }
}
if ($syntaxBad.Count -gt 0) {
    Write-Host "PATCH ABORTED - patched text failed PowerShell syntax check; no files were modified:" -ForegroundColor Red
    foreach ($x in $syntaxBad) { Write-Host ("  " + $x) -ForegroundColor Red }
    exit 1
}

foreach ($f in $texts.Keys) { Set-FileText (Join-Path $root $f) $texts[$f] $boms[$f] }

Write-Host ""
if ($skipped.Count -gt 0) { foreach ($s in $skipped) { Write-Host ("  skip (already applied): " + $s) -ForegroundColor DarkGray } }
foreach ($a in $applied) { Write-Host ("  patched: " + $a) -ForegroundColor Green }
Write-Host ""
Write-Host "Fleet upgrade complete." -ForegroundColor Green
Write-Host "  overseer.ps1 - adopts one worker per port (all 4 consoles visible), renumbers Alpha/Bravo/... in detection order"
Write-Host "  overseer.ps1 - /detect baselines quietly instead of replaying history"
Write-Host "  overseer.ps1 - -AutoDetect mode + window title"
Write-Host "  console.ps1  - window titled per project"
Write-Host ""
Write-Host "Next: .\fleet.ps1  (first run creates fleet.json - edit your 4 projects, run it again)" -ForegroundColor Cyan
Write-Host ""
if ($script:GitBaselineOk) {
    Write-Host "Review:   git diff manager"
    Write-Host "Rollback: git checkout -- manager" -ForegroundColor DarkGray
}
