param(
    [string]$Project,
    [string]$PlanFile,
    [string]$Model = "minimax/MiniMax-M3",
    [switch]$Yes
)

. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets
$ErrorActionPreference = "Continue"  # native stderr (git warnings etc.) must never terminate this script - mirrors orchestrator.ps1

if (-not $Project) { $Project = (Read-Host "Project directory").Trim().Trim('"').Trim([char]39) }
if (-not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path

if (-not $PlanFile) {
    $defaultPlan = Join-Path $Project "PLAN.md"
    $inp = (Read-Host "Plan file [$defaultPlan]").Trim().Trim('"').Trim([char]39)
    if ($inp) { $PlanFile = $inp } else { $PlanFile = $defaultPlan }
}
if (-not [System.IO.Path]::IsPathRooted($PlanFile)) { $PlanFile = Join-Path $Project $PlanFile }
if (-not (Test-Path $PlanFile -PathType Leaf)) { Write-Error "Plan file not found: $PlanFile"; exit 1 }

$doc = Get-Content $PlanFile -Raw

function Invoke-Check([string]$Command) {
    $job = Start-Job -ScriptBlock {
        param($dir, $cmd)
        Set-Location $dir
        $code = $null
        $out = ""
        try {
            if ($cmd -match '&&' -or $cmd -match '\S\s+&\s+\S' -or $cmd -match '>nul') {
                $out = cmd /c $cmd 2>&1 | Out-String
                $code = $LASTEXITCODE
            } else {
                $out = Invoke-Expression $cmd 2>&1 | Out-String
                $code = $LASTEXITCODE
            }
        } catch { $out = $_.Exception.Message; $code = -1 }
        if ($null -eq $code) { $code = 0 }
        return @{ code = $code; output = $out }
    } -ArgumentList $Project, $Command
    $done = Wait-Job $job -Timeout 120
    if ($done) {
        $r = Receive-Job $job
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        if ($null -eq $r) { return @{ code = -1; output = "check job returned nothing" } }
        return $r
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return @{ code = -1; output = "check timed out after 120s" }
}

# --- parse: contract format (### N. + Files/Change/Validation) OR flat tokenprompt format (N. ... | Files: ... | Prove: ...) ---
$items = @()
$format = ""
$firstItemIdx = -1

$blocks = [regex]::Matches($doc, '(?ms)^### (\d+)\.\s+(.+?)\r?\n(.*?)(?=^### \d+\.|\z)')
if ($blocks.Count -gt 0) {
    $format = "contract"
    $firstItemIdx = $blocks[0].Index
    foreach ($blk in $blocks) {
        $bn = [int]$blk.Groups[1].Value
        $btitle = $blk.Groups[2].Value.Trim()
        $bbody = $blk.Groups[3].Value
        $bfiles = @()
        $fm = [regex]::Match($bbody, '(?m)^-\s+\*\*Files:\*\*\s+(.+?)\s*$')
        if ($fm.Success) { $bfiles = @($fm.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $bvalidate = ""
        $vm = [regex]::Match($bbody, '(?m)^-\s+\*\*Validation:\*\*\s+(.+?)\s*$')
        if ($vm.Success) { $bvalidate = $vm.Groups[1].Value.Trim().Trim([char]96).Trim() }
        $items += [pscustomobject]@{ n=$bn; title=$btitle; files=$bfiles; validate=$bvalidate; body=$bbody; line="" }
    }
} else {
    $delivIdx = $doc.IndexOf("## Deliverables")
    $searchFrom = 0
    if ($delivIdx -ge 0) { $searchFrom = $delivIdx }
    $flatMatches = [regex]::Matches($doc.Substring($searchFrom), '(?m)^(\d+)\.\s+(.+?)\s*$')
    if ($flatMatches.Count -eq 0) { Write-Error "No plan items found in $PlanFile - supports contract plans (### N. with - **Validation:**) and tokenprompt files (N. ... | Prove: ...)"; exit 1 }
    $format = "flat"
    $firstItemIdx = $searchFrom + $flatMatches[0].Index
    foreach ($lm in $flatMatches) {
        $bn = [int]$lm.Groups[1].Value
        $line = $lm.Groups[2].Value.Trim()
        $bfiles = @()
        $fm = [regex]::Match($line, '\|\s*Files:\s*([^|]+)')
        if ($fm.Success) { $bfiles = @(($fm.Groups[1].Value -replace [char]96, '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $bvalidate = ""
        $vm = [regex]::Match($line, '\|\s*Prove:\s*`([^`]+)`')
        if ($vm.Success) { $bvalidate = $vm.Groups[1].Value }
        $btitle = ($line -split '\|', 2)[0].Trim()
        $items += [pscustomobject]@{ n=$bn; title=$btitle; files=$bfiles; validate=$bvalidate; body=""; line=$line }
    }
}

Write-Host ""
Write-Host ("inspect-update: " + $items.Count + " plan items in " + (Split-Path -Leaf $PlanFile) + " (" + $format + " format) - checking each against the code") -ForegroundColor Cyan
Write-Host ""

$doneNums = @()
$doneTitles = @()
$remaining = @()
$needModel = @()

foreach ($it in $items) {
    if ($it.validate) {
        $cmds = @($it.validate)
        if (Get-Command Split-CicadaGateCommand -ErrorAction SilentlyContinue) { $split = @(Split-CicadaGateCommand $it.validate); if ($split.Count -gt $cmds.Count) { $cmds = $split } }
        if (Get-Command Normalize-CicadaGateCommands -ErrorAction SilentlyContinue) { $cmds = @(Normalize-CicadaGateCommands $cmds) }
        $pass = $true
        $failInfo = ""
        foreach ($c in $cmds) {
            $res = Invoke-Check $c
            if ($res.code -ne 0) { $pass = $false; $tail = $res.output; if ($tail -and $tail.Length -gt 160) { $tail = $tail.Substring($tail.Length - 160) }; $failInfo = "exit " + $res.code + " (" + ($tail -replace '\s+',' ').Trim() + ")"; break }
        }
        if ($pass) {
            Write-Host ("  [done]      " + $it.n + ". " + $it.title) -ForegroundColor Green
            $doneNums += $it.n; $doneTitles += $it.title
        } else {
            Write-Host ("  [remaining] " + $it.n + ". " + $it.title + "  - gate: " + $failInfo) -ForegroundColor DarkYellow
            $remaining += $it
        }
    } else {
        $needModel += $it
    }
}

if ($needModel.Count -gt 0) {
    Write-Host ""
    Write-Host ($needModel.Count.ToString() + " item(s) have no mechanical validation - asking the model to verify against the code...") -ForegroundColor DarkGray
    $listText = ($needModel | ForEach-Object { "- Item " + $_.n + ": " + $_.title + " | Files: " + ($_.files -join ', ') }) -join "`n"
    $q = "You are verifying which planned deliverables are already complete in a codebase. Project: " + $Project + "`nInspect the actual files. For EACH item below, answer with exactly one line:`nITEM <n>: DONE - <evidence>`nor`nITEM <n>: NOT DONE - <what is missing>`nBe strict: DONE only if the change is actually present in the code on disk.`n`nItems:`n" + $listText
    $r = Invoke-AgentWithFallback -CallArgs @{ Project=$Project; Prompt=$q; Model=$Model; Agent="plan"; Title="inspect-update" } -FallbackModels @(Get-CicadaFallbackFor ([string]$Model)) -Seat "inspect-update"
    $modelDone = @{}
    if ($r -and $r.Text) {
        foreach ($m in [regex]::Matches($r.Text, '(?im)^\s*ITEM\s+(\d+)\s*:\s*(DONE|NOT DONE)\b')) {
            $modelDone[[int]$m.Groups[1].Value] = ($m.Groups[2].Value -eq 'DONE')
        }
    }
    foreach ($it in $needModel) {
        if ($modelDone.ContainsKey($it.n) -and $modelDone[$it.n]) {
            Write-Host ("  [done]      " + $it.n + ". " + $it.title + "  - model-verified") -ForegroundColor Green
            $doneNums += $it.n; $doneTitles += $it.title
        } else {
            Write-Host ("  [remaining] " + $it.n + ". " + $it.title + "  - model: not done / no verdict") -ForegroundColor DarkYellow
            $remaining += $it
        }
    }
}

Write-Host ""
Write-Host ($doneNums.Count.ToString() + " complete, " + $remaining.Count.ToString() + " remaining") -ForegroundColor Cyan

if ($doneNums.Count -eq 0) { Write-Host "Nothing is complete - plan file left unchanged." -ForegroundColor DarkGray; exit 0 }

# --- rewrite the plan: header preserved, completed items removed, remaining renumbered ---
$header = $doc.Substring(0, $firstItemIdx).TrimEnd()
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$note = "<!-- inspect-update " + $stamp + ": removed " + $doneNums.Count + " completed item(s): " + ($doneTitles -join '; ') + " -->"

if ($format -eq "contract") {
    $outParts = @($header, $note, "", "## Remaining deliverables")
    $newN = 0
    foreach ($it in ($remaining | Sort-Object n)) {
        $newN++
        $outParts += ("### " + $newN + ". " + $it.title)
        $outParts += $it.body.TrimEnd()
        $outParts += ""
    }
} else {
    $outParts = @($header, $note, "")
    $newN = 0
    foreach ($it in ($remaining | Sort-Object n)) {
        $newN++
        $outParts += ($newN.ToString() + ". " + $it.line)
    }
}
$newDoc = ($outParts -join "`r`n").TrimEnd() + "`r`n"

$backup = $PlanFile + ".preinspect.bak"
Copy-Item $PlanFile $backup -Force
Set-Content $PlanFile $newDoc -Encoding utf8

$committed = $false
& git -C $Project rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    & git -C $Project add -- $PlanFile 2>&1 | Out-Null
    & git -C $Project commit -m ("cicada: inspect-update trimmed plan (" + $doneNums.Count + " done, " + $remaining.Count + " remaining)") --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $committed = $true }
}

Write-Host ""
Write-Host ("Plan updated: " + $PlanFile + " (" + $remaining.Count + " remaining items, renumbered)") -ForegroundColor Green
Write-Host ("Backup: " + $backup + $(if ($committed) { " | git committed" } else { "" })) -ForegroundColor DarkGray
Send-CicadaTelegram ("CICADA [inspect-update] " + (Split-Path -Leaf $Project) + " | " + $doneNums.Count + " done, " + $remaining.Count + " remaining | plan trimmed + backup saved")



