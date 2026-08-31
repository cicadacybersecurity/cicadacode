param(
    [string]$Skill,
    [string]$Model = "minimax/MiniMax-M3",
    [switch]$Yes
)

. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

$mdExt = ".m" + "d"
$skillsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\skills"))

# --- navigable folder picker: browse the skills tree, select a skill file ---
function Select-CicadaSkillPath {
    param([string]$StartDir)
    if (-not (Test-Path $StartDir -PathType Container)) { return $null }
    $current = $StartDir
    while ($true) {
        $files = @(Get-ChildItem $current -Filter *.md -File | Sort-Object Name)
        $dirs  = @(Get-ChildItem $current -Directory | Sort-Object Name)
        Write-Host ""
        Write-Host ("Browse: " + $current) -ForegroundColor Cyan
        $idx = 1
        $map = @()
        foreach ($d in $dirs) {
            Write-Host ("  [{0}] [DIR] {1}\" -f $idx, $d.Name)
            $map += [pscustomobject]@{ Type = 'dir'; Target = $d.FullName }
            $idx++
        }
        foreach ($f in $files) {
            $chars = (Get-Item $f.FullName).Length
            Write-Host ("  [{0}] {1} ({2} chars)" -f $idx, $f.Name, $chars)
            $map += [pscustomobject]@{ Type = 'file'; Target = $f.FullName }
            $idx++
        }
        if ($current -ne $StartDir) { Write-Host "  [0] Up a level" -ForegroundColor DarkGray }
        else { Write-Host "  [0] Cancel" -ForegroundColor DarkGray }
        $pick = (Read-Host "Select (number)").Trim()
        $n = 0
        if (-not [int]::TryParse($pick, [ref]$n)) { continue }
        if ($n -eq 0) {
            if ($current -eq $StartDir) { return $null }
            $parent = Split-Path -Parent $current
            if ($parent -and $parent.Length -ge $StartDir.Length) { $current = $parent } else { return $null }
            continue
        }
        if ($n -lt 1 -or $n -gt $map.Count) { continue }
        $sel = $map[$n - 1]
        if ($sel.Type -eq 'dir') { $current = $sel.Target; continue }
        return $sel.Target
    }
}

# --- resolve skill: explicit arg, otherwise browse the skills folder ---
$path = $null
if ($Skill) {
    if (Test-Path $Skill -PathType Leaf) { $path = (Resolve-Path $Skill).Path }
    elseif (Test-Path $Skill -PathType Container) { $p = Join-Path $Skill ("SKILL" + $mdExt); if (Test-Path $p) { $path = (Resolve-Path $p).Path } }
    elseif (Test-Path (Join-Path $skillsRoot $Skill) -PathType Container) { $p = Join-Path $skillsRoot (Join-Path $Skill ("SKILL" + $mdExt)); if (Test-Path $p) { $path = $p } }
    elseif (Test-Path (Join-Path $skillsRoot ($Skill + $mdExt))) { $path = Join-Path $skillsRoot ($Skill + $mdExt) }
    if (-not $path) { Write-Error "skill not found: $Skill (looked at literal path, folder skill file, and $skillsRoot)"; exit 1 }
} else {
    $path = Select-CicadaSkillPath -StartDir $skillsRoot
    if (-not $path) { Write-Host "Aborted."; exit 0 }
    Write-Host ("Selected: " + $path) -ForegroundColor DarkGray
}

$raw = Get-Content $path -Raw
if (-not $raw) { Write-Error "skill file is empty: $path"; exit 1 }
$origLen = $raw.Length

# --- mojibake normalization (verified table) ---
$mojiFixes = @(
    @(@(0x00D4,0x00C7,0x00F6), 0x2014),
    @(@(0x00D4,0x00C7,0x00F4), 0x2013),
    @(@(0x00D4,0x00EB,0x00F1), 0x2264),
    @(@(0x00D4,0x00EB,0x00EA), 0x2248),
    @(@(0x00D4,0x00E5,0x00C6), 0x2192),
    @(@(0x00D4,0x00FB,0x00B8), 0x25B8),
    @(@(0x251C,0x00F9),        0x00D7)
)
foreach ($f in $mojiFixes) {
    $bad = -join ($f[0] | ForEach-Object { [string][char]$_ })
    $raw = $raw.Replace($bad, [string][char]($f[1]))
}

# --- preserve YAML frontmatter verbatim; capture description for identity terms ---
$front = ""
$body = $raw
$skillDesc = ""
if ($raw -match '(?s)\A(---\s*\r?\n.+?\r?\n---\s*\r?\n?)(.*)$') {
    $front = $Matches[1]; $body = $Matches[2]
    $dm = [regex]::Match($front, '(?im)^\s*description:\s*(.+?)\s*$')
    if ($dm.Success) { $skillDesc = $dm.Groups[1].Value.Trim().Trim('"').Trim([char]39) }
}

# --- NEW: folder inventory + file references (folder-aware debulking) ---
$skillFolder = Split-Path -Parent $path
$isFolderSkill = ($skillFolder -ne $skillsRoot)
$folderInventory = @()
$fileRefs = @()
if ($isFolderSkill) {
    foreach ($f in (Get-ChildItem $skillFolder -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq ("SKILL" + $mdExt) -or $f.FullName -match '\\\.git\\') { continue }
        $folderInventory += $f.FullName.Substring($skillFolder.Length).TrimStart('\','/')
    }
    foreach ($d in (Get-ChildItem $skillFolder -Recurse -Directory -ErrorAction SilentlyContinue)) {
        if ($d.FullName -match '\\\.git') { continue }
        $folderInventory += ($d.FullName.Substring($skillFolder.Length).TrimStart('\','/') + '\')
    }
    $folderInventory = @($folderInventory | Sort-Object)
}
# extract file references from the original body (backtick paths, bare extensions, dir refs)
$refSet = @{}
foreach ($m in [regex]::Matches($body, '`([^`]+)`')) {
    $p = $m.Groups[1].Value.Trim()
    if ($p -match '[/\\]' -or $p -match '\.\w{1,5}$') { $refSet[$p] = $true }
}
foreach ($m in [regex]::Matches($body, '\b[\w./\\-]+\.(?:pdf|py|json|png|jpg|jpeg|svg|css|js|html|md|txt|xml|yaml|yml|toml|sh|ps1)\b')) {
    $refSet[$m.Value] = $true
}
foreach ($m in [regex]::Matches($body, '\b[\w-]+/')) { $refSet[$m.Value] = $true }
$fileRefs = @($refSet.Keys | Sort-Object)
if ($folderInventory.Count -gt 0) { Write-Host ("Folder-aware: " + $folderInventory.Count + " supporting file(s) in " + (Split-Path -Leaf $skillFolder) + " - read-only, never modified") -ForegroundColor DarkGray }
if ($fileRefs.Count -gt 0) { Write-Host ("Reference guard: " + $fileRefs.Count + " file reference(s) tracked: " + ($fileRefs -join ', ')) -ForegroundColor DarkGray }

# --- mask fenced code blocks as CODE-N (byte-exact passthrough) ---
$script:codeMap = [ordered]@{}
$script:codeIdx = 0
$masked = [regex]::Replace($body, '(?s)```.*?```', {
    param($m)
    $script:codeIdx++
    $key = "CODE-$($script:codeIdx)"
    $script:codeMap[$key] = $m.Value
    return $key
})

# --- mask long inline code spans (>=40 chars, single-line) as FRAG-N ---
$script:fragMap = [ordered]@{}
$script:fragIdx = 0
$masked = [regex]::Replace($masked, '`([^`\r\n]{40,})`', {
    param($m)
    $script:fragIdx++
    $key = "FRAG-$($script:fragIdx)"
    $script:fragMap[$key] = $m.Groups[1].Value
    return $key
})
Write-Host ("Debulking " + (Split-Path -Leaf $path) + ": " + $origLen + " chars | masked " + $script:codeMap.Count + " code block(s) + " + $script:fragMap.Count + " fragment(s)") -ForegroundColor DarkGray

# --- NEW: critical-term extraction (deterministic, for quality gating) ---
$stopWords = @('the','a','an','and','or','of','to','in','on','for','with','from','by','as','at','is','are','be','was','were','this','that','it','its','these','those','not','no','but','if','then','than','so','such','more','most','all','any','each','every','your','you','we','our','their','there','here','can','could','should','would','may','might','must','do','does','did','done','have','has','had','will','shall','about','into','over','under','out','up','down','between','through','during','before','after','above','below','again','further','once','also','only','own','same','other','new','old','great','good','bad','well','very','just','too','much','many','being','been','both','few','nor','s','don','now','get','got','use','used','using','make','made','like','want','way','thing','things','one','two','set','put','take','going','go','come','came','look','see','know','think','say','said','help','need','try','often','actually','careful','around','always','best','bring','build','building','consider','control','copy','default','defaults','deliberate','directions','end','even','everyone','example','feel','first','give','given','hand','hard','important','keep','keeps','left','less','little','long','lot','mean','means','mind','move','name','never','next','nice','number','order','part','people','place','point','possible','problem','rather','really','right','room','seem','seems','simple','simply','something','sometimes','sort','start','still','stuff','sure','taken','tell','tend','though','time','together','turn','usually','went','whole','work','works','write','written','yes','yet')
function Get-CicadaCriticalTerms {
    param([string]$Body, [string]$Description)
    $counts = @{}
    foreach ($m in [regex]::Matches($Body, '[A-Za-z][A-Za-z0-9_-]{2,}')) {
        $w = $m.Value.ToLower()
        if ($stopWords -contains $w) { continue }
        if ($counts.ContainsKey($w)) { $counts[$w]++ } else { $counts[$w] = 1 }
    }
    $terms = @()
    foreach ($w in $counts.Keys) { if ($counts[$w] -ge 2) { $terms += $w } }
    foreach ($m in [regex]::Matches($Description, '[A-Za-z][A-Za-z0-9_-]{2,}')) {
        $w = $m.Value.ToLower()
        if ($stopWords -contains $w) { continue }
        if ($terms -notcontains $w) { $terms += $w }
    }
    return $terms
}
function Test-CicadaTermCoverage {
    param([string]$Clean, [string[]]$Terms)
    $lost = @($Terms | Where-Object { $Clean.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
    $cov = if ($Terms.Count -gt 0) { [math]::Round(100 * ($Terms.Count - $lost.Count) / $Terms.Count) } else { 100 }
    return [pscustomobject]@{ Coverage = $cov; Lost = $lost; Total = $Terms.Count }
}
$criticalTerms = @(Get-CicadaCriticalTerms -Body $masked -Description $skillDesc)
Write-Host ("Quality gate: " + $criticalTerms.Count + " critical terms tracked") -ForegroundColor DarkGray

# --- build the folder/reference context block for the prompt ---
$folderCtx = ""
if ($folderInventory.Count -gt 0 -or $fileRefs.Count -gt 0) {
    $sb = [System.Text.StringBuilder]::new()
    if ($folderInventory.Count -gt 0) {
        [void]$sb.AppendLine("The skill folder contains these supporting files. They are READ-ONLY reference material - never modify, create, or delete them, and never tell the user to:")
        foreach ($i in $folderInventory) { [void]$sb.AppendLine("- " + $i) }
    }
    if ($fileRefs.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("SKILL.md references these files/paths. Preserve every reference EXACTLY in your output - never drop, rename, or reword them:")
        foreach ($r in $fileRefs) { [void]$sb.AppendLine("- " + $r) }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("You are ONLY editing SKILL.md. No other file in the skill folder may be altered.")
    $folderCtx = $sb.ToString()
}

$prompt = @"
You are the skill debulker: you compress an agent skill/playbook into its leanest possible form while preserving every operative instruction.

HARD RULES:
- Preserve every rule, instruction, checklist item, file path, identifier, command and constraint. Losing an operative instruction is a failure.
- Remove everything else: preamble, motivation, rationale, repetition, adjectives, hedging, examples that add no rule, filler transitions.
- CODE-N tokens are verbatim fenced code blocks and FRAG-N tokens are verbatim code fragments: keep each EXACTLY ONCE at the position where its content belongs. Never modify, renumber, drop, repeat or invent tokens.
- Keep markdown structure (headings, bullets). Keep exactly one top-level heading.
- No commentary before or after the skill. Output the compressed skill body only.
- Aim for under 50 percent of the input length. Every surviving word must change how the agent behaves.

$folderCtx
The skill to debulk:

$masked
"@

if (-not $Yes) { $Model = Select-CicadaModel -Seat "Debulker" -Current $Model -Recommend "minimax/MiniMax-M3" }

# --- run loop: retry on corruption, self-cert failure, under-compression, low term coverage, OR lost file references ---
$clean = $null
$attempt = 0
$maxAttempts = 3
$bestClean = $null
$bestScore = -1
$lastCoverage = 0
$lastLost = @()
$lastRefLost = @()
while ($attempt -lt $maxAttempts) {
    $attempt++
    $usePrompt = $prompt
    if ($attempt -gt 1) {
        $nudge = "`n`nIMPORTANT: your previous attempt was rejected. "
        if ($lastLost.Count -gt 0) { $nudge += "These important terms MUST appear in your output: " + ($lastLost -join ', ') + ". " }
        if ($lastRefLost.Count -gt 0) { $nudge += "These file references MUST appear in your output exactly: " + ($lastRefLost -join ', ') + ". " }
        $nudge += "Compress MUCH harder on the prose while keeping every operative instruction and every CODE-N/FRAG-N token exactly once."
        $usePrompt = $prompt + $nudge
        Write-Warning ("attempt " + ($attempt - 1) + " rejected (coverage " + $lastCoverage + "%) - retrying with nudge")
    }
    Write-Host ("Calling " + $Model + " (attempt " + $attempt + ")...") -ForegroundColor DarkGray
    $callArgs = @{ Project=(Split-Path -Parent $path); Prompt=$usePrompt; Model=$Model; Agent="plan"; Title="debulk-skill" }
    $r = Invoke-AgentWithFallback -CallArgs $callArgs -FallbackModels @(Get-CicadaFallbackFor ([string]$callArgs.Model)) -Seat "debunker"
    if ($r.ExitCode -ne 0 -or -not $r.Text) { Write-Error ("debulk failed: " + $r.ErrorName + " " + $r.ErrorMessage + " log=" + $r.LogPath); exit 1 }

    $clean = $r.Text.Trim()

    # normalize transit mojibake in model output
    foreach ($f in $mojiFixes) {
        $bad = -join ($f[0] | ForEach-Object { [string][char]$_ })
        $clean = $clean.Replace($bad, [string][char]($f[1]))
    }

    # splice CODE blocks then FRAG fragments back (missing = corrupt)
    $missing = @()
    foreach ($k in $script:codeMap.Keys) {
        $pat = '`?' + $k + '(?![0-9])`?'
        $occ = [regex]::Matches($clean, $pat).Count
        if ($occ -ge 1) {
            $block = $script:codeMap[$k]
            if ($occ -gt 1) { Write-Warning ($k + " echoed x" + $occ + " - keeping first, deleting echoes") }
            $clean = ([regex]$pat).Replace($clean, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }.GetNewClosure(), 1)
            $clean = [regex]::Replace($clean, '\s*`?' + $k + '(?![0-9])`?', '')
        } else {
            $block = $script:codeMap[$k]
            $pos = $masked.IndexOf($k)
            $ctx = ''
            if ($pos -gt 60) { $ctx = $masked.Substring($pos - 60, 60) } elseif ($pos -ge 0) { $ctx = $masked.Substring(0, $pos) }
            $ctxWords = @([regex]::Matches($ctx, '[A-Za-z][A-Za-z0-9_-]{3,}') | ForEach-Object { $_.Value })
            $bestLine = $null
            $bestHits = 0
            foreach ($ln in ([regex]::Split($clean, '\r?\n'))) {
                $hits = 0
                foreach ($w in $ctxWords) { if ($ln.IndexOf($w, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits++ } }
                if ($hits -gt $bestHits) { $bestHits = $hits; $bestLine = $ln }
            }
            if ($bestLine -and $bestHits -ge 2) {
                $clean = ([regex]([regex]::Escape($bestLine))).Replace($clean, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value + "`r`n`r`n" + $block }.GetNewClosure(), 1)
                Write-Warning ($k + " dropped by model - reattached after best-matching line")
            } else {
                $clean = $clean.TrimEnd() + "`r`n`r`nRecovered code block " + $k + " (model omitted it; original placement unknown):`r`n`r`n" + $block
                Write-Warning ($k + " dropped by model - recovered in appendix")
            }
        }
    }
    foreach ($k in $script:fragMap.Keys) {
        $pat = '`?' + $k + '(?![0-9])`?'
        $occ = [regex]::Matches($clean, $pat).Count
        if ($occ -ge 1) {
            $frag = $script:fragMap[$k]
            if ($occ -gt 1) { Write-Warning ($k + " echoed x" + $occ + " - keeping first, deleting echoes") }
            $clean = ([regex]$pat).Replace($clean, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '`' + $frag + '`' }.GetNewClosure(), 1)
            $clean = [regex]::Replace($clean, '\s*`?' + $k + '(?![0-9])`?', '')
        } else {
            $frag = $script:fragMap[$k]
            $pos = $masked.IndexOf($k)
            $ctx = ''
            if ($pos -gt 60) { $ctx = $masked.Substring($pos - 60, 60) } elseif ($pos -ge 0) { $ctx = $masked.Substring(0, $pos) }
            $ctxWords = @([regex]::Matches($ctx, '[A-Za-z][A-Za-z0-9_-]{3,}') | ForEach-Object { $_.Value })
            $bestLine = $null
            $bestHits = 0
            foreach ($ln in ([regex]::Split($clean, '\r?\n'))) {
                $hits = 0
                foreach ($w in $ctxWords) { if ($ln.IndexOf($w, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits++ } }
                if ($hits -gt $bestHits) { $bestHits = $hits; $bestLine = $ln }
            }
            if ($bestLine -and $bestHits -ge 2) {
                $clean = ([regex]([regex]::Escape($bestLine))).Replace($clean, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value + ' `' + $frag + '`' }.GetNewClosure(), 1)
                Write-Warning ($k + " dropped by model - reattached inline after best-matching line")
            } else {
                $clean = $clean.TrimEnd() + "`r`n`r`nRecovered fragment " + $k + " (model omitted it; original placement unknown):`r`n`r`n" + ('`' + $frag + '`')
                Write-Warning ($k + " dropped by model - recovered in appendix")
            }
        }
    }
    $leftover = [regex]::Matches($clean, '(CODE|FRAG)-\d+').Count
    if ($missing.Count -gt 0 -or $leftover -gt 0) {
        Write-Warning ("attempt " + $attempt + " corrupt: missing=" + ($missing -join ',') + " leftover=" + $leftover)
        $lastCoverage = 0; $lastLost = @(); $lastRefLost = @()
        if ($attempt -lt $maxAttempts) { continue }
        Write-Error "output still corrupt after retries - original skill untouched"; exit 1
    }

    # dedupe token echoes
    $clean = [regex]::Replace($clean, '(`[^`]{20,}`)\s*\(\1\)', '$1')
    $clean = [regex]::Replace($clean, '(`[^`]{20,}`)\s+\1', '$1')
    $clean = [regex]::Replace($clean, '(?s)(```.*?```)\s*\1', '$1')

    # self-certification: every masked item appears exactly once
    $badCounts = @()
    foreach ($k in $script:codeMap.Keys) {
        $o = [regex]::Matches($clean, [regex]::Escape($script:codeMap[$k])).Count
        if ($o -ne 1) { $badCounts += ($k + " x" + $o) }
    }
    foreach ($k in $script:fragMap.Keys) {
        $o = [regex]::Matches($clean, [regex]::Escape('`' + $script:fragMap[$k] + '`')).Count
        if ($o -ne 1) { $badCounts += ($k + " x" + $o) }
    }
    if ($badCounts.Count -gt 0) {
        Write-Warning ("attempt " + $attempt + " failed self-certification: " + ($badCounts -join ', '))
        $lastCoverage = 0; $lastLost = @(); $lastRefLost = @()
        if ($attempt -lt $maxAttempts) { continue }
        Write-Error "self-certification failed after retries - original skill untouched"; exit 1
    }

    # sanity: shorter than input, not suspiciously tiny
    $maxLen = [math]::Floor($body.Length * 0.97)
    if ($clean.Length -gt $maxLen -or $clean.Length -lt 100) {
        Write-Warning ("attempt " + $attempt + " produced " + $clean.Length + " chars from " + $body.Length + " - outside sane bounds")
        $lastCoverage = 0; $lastLost = @(); $lastRefLost = @()
        if ($attempt -lt $maxAttempts) { continue }
        Write-Error "no acceptable compression after retries - original skill untouched"; exit 1
    }

    # --- NEW: reference-survival gate (folder-aware) ---
    $lastRefLost = @($fileRefs | Where-Object { $clean.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
    if ($lastRefLost.Count -gt 0) {
        Write-Warning ("attempt " + $attempt + " dropped " + $lastRefLost.Count + " file reference(s): " + ($lastRefLost -join ', '))
        if ($attempt -lt $maxAttempts) { continue }
        Write-Warning ("file references still missing after retries: " + ($lastRefLost -join ', '))
    }

    # --- quality gate: term coverage ---
    $cov = Test-CicadaTermCoverage -Clean $clean -Terms $criticalTerms
    $lastCoverage = $cov.Coverage
    $lastLost = $cov.Lost
    if ($lastRefLost.Count -eq 0 -and ($cov.Coverage -gt $bestScore -or ($cov.Coverage -eq $bestScore -and $bestClean -and $clean.Length -lt $bestClean.Length))) { $bestScore = $cov.Coverage; $bestClean = $clean }
    Write-Host ("  coverage: " + $cov.Coverage + "% (" + ($cov.Total - $cov.Lost.Count) + "/" + $cov.Total + " critical terms)") -ForegroundColor $(if ($cov.Coverage -ge 90) { "Green" } else { "DarkYellow" })
    if ($cov.Coverage -ge 90 -and $lastRefLost.Count -eq 0) { break }
    if ($attempt -ge $maxAttempts) {
        Write-Warning ("coverage " + $cov.Coverage + "% after " + $attempt + " attempts - keeping best effort. Lost: " + ($cov.Lost -join ', '))
        break
    }
}
if ($bestClean) { $clean = $bestClean }
Write-Host ("SELF-CERTIFIED: " + $script:codeMap.Count + " code blocks + " + $script:fragMap.Count + " fragments each exactly once, byte-exact") -ForegroundColor Green

# bullet parity: cheap signal for instruction loss on rule-list skills
$srcBullets = [regex]::Matches($masked, '(?m)^\s*[-*]\s').Count
$outBullets = [regex]::Matches($clean, '(?m)^\s*[-*]\s').Count
if ($srcBullets -ge 4 -and $outBullets -lt [math]::Ceiling($srcBullets / 2)) {
    Write-Warning "bullet count dropped $srcBullets -> $outBullets - possible instruction loss, review before relying on this skill"
}

# --- write: backup original FIRST, then replace the skill in place (frontmatter restored verbatim) ---
$final = $front + $clean.Trim() + "`n"
$backup = $path + ".predebulk.bak"
Copy-Item $path $backup -Force
Set-Content $path $final -Encoding utf8

$pct = [math]::Round(100 * (1 - ($final.Length / [math]::Max(1, $origLen))))
$tokensSaved = [math]::Round(($origLen - $final.Length) / 4)
Write-Host ("Debulked " + (Split-Path -Leaf $path) + ": " + $origLen + " -> " + $final.Length + " chars (" + $pct + "% smaller, attempt " + $attempt + ")") -ForegroundColor Green
Write-Host ("~" + $tokensSaved + " tokens saved per agent call, ~" + ($tokensSaved * 60) + " across a 60-step build. Backup: " + $backup) -ForegroundColor DarkGray
$covFinal = Test-CicadaTermCoverage -Clean $clean -Terms $criticalTerms
$refFinal = @($fileRefs | Where-Object { $clean.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
Send-CicadaTelegram ("CICADA [debunker] " + (Split-Path -Leaf $path) + ": " + $origLen + " -> " + $final.Length + " chars (" + $pct + "%) | coverage " + $covFinal.Coverage + "% | refSurv " + ($fileRefs.Count - $refFinal.Count) + "/" + $fileRefs.Count + " | self-certified | backup saved")




