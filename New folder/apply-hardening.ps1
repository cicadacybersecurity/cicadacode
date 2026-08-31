#Requires -Version 5.1
<#
apply-hardening.ps1 - CICADA brittleness fixes. v2
Run from the CICADA directory root (the folder containing agent.ps1):

    powershell -ExecutionPolicy Bypass -File .\apply-hardening.ps1

What it does:
  1. git baseline: inits a repo (if needed), extends .gitignore (state/, backups),
     sets a local identity if none, and commits a pre-hardening snapshot so every
     change is reversible.
  2. manager\engine.ps1: opencode version drift detection + an event-schema
     sentinel - warn loudly instead of silently mis-accounting tokens/cost when
     an opencode update changes the JSON event format.
  3. manager\orchestrator.ps1: safety denylist for validation gate commands -
     gates run via Invoke-Expression with your privileges, so validation must
     be read-only and local.
  4. manager\orchestrator.ps1: self-modification guard - refuse to run the fleet
     against the CICADA install itself unless -AllowSelfModify is passed.

Every patch is anchored to exact text and must match exactly once; if your files
differ from the reviewed version, nothing is written. Idempotent: already-applied
patches are skipped.

Rollback:  git checkout -- manager      (or: git restore manager)

v2: git section runs under ErrorActionPreference=Continue - in PS 5.1, harmless
    git stderr warnings (e.g. "LF will be replaced by CRLF") become terminating
    NativeCommandErrors under -Stop. .gitignore check is now exact-line based so
    "state/" is added even when "state/logs/" already exists.
#>
[CmdletBinding()]
param([switch]$SkipGit)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path (Join-Path $root "manager\engine.ps1")) -or
    -not (Test-Path (Join-Path $root "manager\orchestrator.ps1"))) {
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

# ---------------- git baseline ----------------
# NOTE: native git calls run under ErrorActionPreference=Continue. Under -Stop,
# ANY git stderr output (including harmless CRLF warnings) throws NativeCommandError.

$script:GitBaselineOk = $false

if (-not $SkipGit) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Host "git not found - skipping baseline snapshot. Patches still apply, but install git for rollback safety." -ForegroundColor Yellow
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
            # .gitignore: add entries by exact line match (substring matching would
            # wrongly treat existing "state/logs/" as covering "state/").
            $giPath = Join-Path $root ".gitignore"
            $giText = ""
            $giLines = @()
            if (Test-Path $giPath) {
                $giText = [System.IO.File]::ReadAllText($giPath)
                $giLines = @($giText -split "`r?`n")
            }
            $want = @("state/", "*.bak", "*.bak2", "*.backup", "*.pre-*", "*.before-*", "*.corrupt-*")
            $missing = @()
            foreach ($w in $want) {
                $found = $false
                foreach ($line in $giLines) { if ($line.Trim() -eq $w) { $found = $true; break } }
                if (-not $found) { $missing += $w }
            }
            if ($missing.Count -gt 0) {
                $prefix = ""
                if ($giText.Length -gt 0 -and -not $giText.EndsWith("`n")) { $prefix = "`r`n" }
                [System.IO.File]::AppendAllText($giPath, $prefix + ($missing -join "`r`n") + "`r`n")
                Write-Host ("git: .gitignore += " + ($missing -join ", ")) -ForegroundColor Green
            }
            & git add -A 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host ("git: add failed (exit " + $LASTEXITCODE + ") - patches will still apply, but there is no rollback snapshot") -ForegroundColor Yellow
            } else {
                $porc = & git status --porcelain 2>$null | Out-String
                if ($porc.Trim()) {
                    & git commit --quiet -m "baseline: pre-hardening snapshot" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $script:GitBaselineOk = $true
                        Write-Host "git: baseline committed (rollback: git checkout -- manager)" -ForegroundColor Green
                    } else {
                        Write-Host ("git: commit failed (exit " + $LASTEXITCODE + ") - patches will still apply, but there is no rollback snapshot") -ForegroundColor Yellow
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

$p1Text = "`r`n`r`n" + @'
# --- hardening: opencode version drift detection -----------------------------
# This harness parses opencode's JSON event stream (step_finish, tokens, cost).
# If an opencode update changes that schema, accounting breaks silently. Record
# the version on first run and warn loudly whenever it changes underneath us.
$script:OpenCodeVersionFile = Join-Path $script:StateDir "opencode-version.txt"
$script:OpenCodeDriftChecked = $false

function Test-CicadaOpenCodeDrift {
    if ($script:OpenCodeDriftChecked) { return }
    $script:OpenCodeDriftChecked = $true
    try {
        $exe = Resolve-OpenCodeExe
        $v = (& $exe --version 2>&1 | Out-String).Trim()
        if (-not $v) { return }
        if (Test-Path $script:OpenCodeVersionFile) {
            $pinned = (Get-Content $script:OpenCodeVersionFile -Raw).Trim()
            if ($pinned -and $pinned -ne $v) {
                Write-Host ("WARNING: opencode version changed (" + $pinned + " -> " + $v + "). If runs misbehave or token/cost totals read zero, the event schema may have changed. Verify a run works, then delete state\opencode-version.txt to accept the new version.") -ForegroundColor Yellow
            }
        } else {
            if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
            $v | Set-Content $script:OpenCodeVersionFile -Encoding utf8
        }
    } catch { }
}
'@

$p3Text = @'
    # hardening: schema sentinel - if opencode produced assistant text but no
    # step_finish event, the event stream changed; say so instead of silently
    # recording zero tokens/cost forever.
    if ($exit -eq 0 -and $textParts.Count -gt 0 -and $null -eq $tokens) {
        Write-Host "WARNING: opencode returned text but no step_finish/token event. The event schema may have changed - token/cost accounting is unreliable until engine.ps1 is updated to match." -ForegroundColor Yellow
    }

'@

$p5Text = "`r`n" + @'
# hardening: never run the fleet against the CICADA installation itself without
# an explicit opt-in - self-patching runs have corrupted manager scripts before.
$CicadaRoot = Split-Path -Parent $PSScriptRoot
if ($Project -eq $CicadaRoot -and -not $AllowSelfModify) {
    Write-Error "Project is the CICADA installation itself. Self-patching has corrupted manager scripts before (see the *.corrupt / *.pre-* backups). Snapshot with git, then re-run with -AllowSelfModify to override."
    exit 1
}
'@

$p6aText = @'
# hardening: gate commands come from planner/builder output and run via
# Invoke-Expression on the host with your privileges. Validation must be
# read-only and local: deny mutation, network, and system verbs at command
# boundaries (start of string, or right after a pipe/semicolon/ampersand),
# plus any output redirect that would write a file.
function Test-CicadaGateSafe([string]$Command) {
    $c = $Command.ToLower()
    $b = '(^|[|;&]\s*)\s*'
    $checks = @(
        # mutation / system / network / code-execution verbs at a command boundary
        ($b + '(remove-item|del|erase|rmdir|rd|format-volume|mkfs|dd|shutdown|restart-computer|stop-computer|stop-process|taskkill|kill|set-content|out-file|add-content|clear-content|tee-object|tee|new-item|mkdir|md|copy-item|copy|xcopy|robocopy|move-item|move|rename-item|ren|invoke-webrequest|invoke-restmethod|curl|wget|start-bitstransfer|ssh|scp|ftp|reg|takeown|icacls|attrib|cipher|invoke-expression|iex|start-process|msiexec|choco|winget|pip3?)(?=[\s.]|$)'),
        # package-manager / vcs / service / dotnet mutations
        ($b + '(npm|yarn|pnpm)\s+(install|uninstall|remove|publish|add|ci|i)(?=[\s]|$)'),
        ($b + 'git\s+(push|reset|clean|commit|checkout|rebase|merge|rm)(?=[\s]|$)'),
        ($b + 'net\s+(user|localgroup|share|start|stop)(?=[\s]|$)'),
        ($b + 'dotnet\s+(add|remove|publish|nuget)(?=[\s]|$)'),
        # output redirect that writes a file (2>&1 stays allowed)
        '(?<![\d>&])>\s*[~\.\w\\]'
    )
    foreach ($re in $checks) {
        $m = [regex]::Match($c, $re)
        if ($m.Success) { return $m.Value.Trim() }
    }
    return $null
}


'@

$p6bText = @'
    $denyHit = Test-CicadaGateSafe $Command
    if ($denyHit) {
        return @{ code = -1; output = ("gate blocked by safety denylist (matched '" + $denyHit + "'); validation commands must be read-only and local - re-run the check without mutation, network, or system verbs") }
    }
'@

$patches = @(
    @{ File = "manager\engine.ps1"; Name = "engine: opencode drift detection"
       Pattern = 'throw "opencode was not found on PATH\."\r?\n\}'
       Mode = "After"; Marker = "OpenCodeVersionFile"; Text = $p1Text },

    @{ File = "manager\engine.ps1"; Name = "engine: drift check call in Invoke-Agent"
       Pattern = 'Import-CicadaSecrets\r?\n    \$exe = Resolve-OpenCodeExe'
       Mode = "After"; Marker = "Test-CicadaOpenCodeDrift  # hardening"
       Text = "`r`n    Test-CicadaOpenCodeDrift  # hardening: warn if opencode updated underneath us" },

    @{ File = "manager\engine.ps1"; Name = "engine: event schema sentinel"
       Pattern = '    \$raw  = \(\$textParts -join ""\)'
       Mode = "Before"; Marker = "schema sentinel"; Text = $p3Text },

    @{ File = "manager\orchestrator.ps1"; Name = "orchestrator: -AllowSelfModify param"
       Pattern = '    \[string\]\$RunId(?=\r?\n\))'
       Mode = "After"; Marker = '[switch]$AllowSelfModify'
       Text = ",`r`n    [switch]`$AllowSelfModify" },

    @{ File = "manager\orchestrator.ps1"; Name = "orchestrator: self-modification guard"
       Pattern = '\$Project = \(Resolve-Path \$Project\)\.Path\r?\n'
       Mode = "After"; Marker = "never run the fleet against the CICADA installation"; Text = $p5Text },

    @{ File = "manager\orchestrator.ps1"; Name = "orchestrator: gate safety function"
       Pattern = '# ---------- deterministic validation gate \(no model\) ----------'
       Mode = "Before"; Marker = "Test-CicadaGateSafe"; Text = $p6aText },

    @{ File = "manager\orchestrator.ps1"; Name = "orchestrator: denylist wired into Invoke-Validation"
       Pattern = 'function Invoke-Validation\(\[string\]\$Command\) \{\r?\n    if \(-not \$Command\) \{ return \$null \}\r?\n'
       Mode = "After"; Marker = '$denyHit = Test-CicadaGateSafe'; Text = $p6bText }
)

# ---------------- apply (in memory; write only if everything verifies) ----------------

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
    $ev = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) if ($Mode -eq "After") { $m.Value + $Text } else { $Text + $m.Value } }
    $texts[$f] = [regex]::Replace($texts[$f], $p.Pattern, $ev)
    $applied += $p.Name
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "PATCH ABORTED - no files were modified:" -ForegroundColor Red
    foreach ($x in $failures) { Write-Host ("  " + $x) -ForegroundColor Red }
    exit 1
}

# syntax check before writing
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
Write-Host "Hardening complete." -ForegroundColor Green
Write-Host "  engine.ps1       - opencode version drift detection + event schema sentinel"
Write-Host "  orchestrator.ps1 - validation gate denylist (read-only/local commands only)"
Write-Host "  orchestrator.ps1 - self-modification guard (-AllowSelfModify overrides)"
Write-Host ""
if ($script:GitBaselineOk) {
    Write-Host "Review the changes:  git diff manager"
    Write-Host "Rollback anytime:    git checkout -- manager" -ForegroundColor DarkGray
}
