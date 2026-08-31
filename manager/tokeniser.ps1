param(
    [string]$Project,
    [string]$PromptFile,
    [string]$Model = "minimax/MiniMax-M3",
    [switch]$Yes
)

. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

if (-not $Project) { $Project = (Read-Host "Project directory").Trim() }
if (-not (Test-Path $Project -PathType Container)) { Write-Error "Project directory does not exist: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path

if (-not $PromptFile) { $PromptFile = (Read-Host "Path to the big idea / prompt file").Trim() }
$PromptFile = $PromptFile.Trim().Trim('"').Trim([char]39).Trim()
if (($PromptFile -match '^[A-Za-z]:\\' -or $PromptFile -match '\.(md|txt)$') -and -not (Test-Path $PromptFile)) { Write-Error "prompt file not found: $PromptFile - pass a real file path or paste the idea text directly"; exit 1 }
$rawIdea = Resolve-CicadaText $PromptFile
if (-not $rawIdea) { Write-Error "no input - pass -PromptFile <path to the idea file>"; exit 1 }
Show-ReplayCommand -ParamNames @("Project","PromptFile","Model","Yes")

# --- STAGE 0a: mojibake normalization (verified sequences, codepoint-literal so the table itself cannot corrupt) ---
$mojiFixes = @(
    @(@(0x00D4,0x00C7,0x00F6), 0x2014),  # em dash
    @(@(0x00D4,0x00C7,0x00F4), 0x2013),  # en dash
    @(@(0x00D4,0x00EB,0x00F1), 0x2264),  # less-than-or-equal
    @(@(0x00D4,0x00EB,0x00EA), 0x2248),  # almost-equal
    @(@(0x00D4,0x00E5,0x00C6), 0x2192),  # right arrow
    @(@(0x00D4,0x00FB,0x00B8), 0x25B8),  # small right triangle
    @(@(0x251C,0x00F9),        0x00D7)   # multiplication sign
)
$mojiCount = 0
foreach ($f in $mojiFixes) {
    $bad = -join ($f[0] | ForEach-Object { [string][char]$_ })
    $good = [string][char]($f[1])
    $hits = [regex]::Matches($rawIdea, [regex]::Escape($bad)).Count
    if ($hits -gt 0) { $rawIdea = $rawIdea.Replace($bad, $good); $mojiCount += $hits }
}
if ($mojiCount -gt 0) { Write-Host ("Normalized " + $mojiCount + " mojibake character(s)") -ForegroundColor DarkGray }

# --- STAGE 0b: deterministic pre-clean ---
$pre = [regex]::Replace($rawIdea, '(?s)<!--.*?-->', '')
$pre = [regex]::Replace($pre, '[ \t]+\r?\n', "`n")
$pre = [regex]::Replace($pre, '(\r?\n){3,}', "`n`n")

# --- STAGE 1a: mask Validation/Prove commands (numbered per deliverable for reattach) ---
$script:proveMap = [ordered]@{}
$script:proveIdx = 0
$masked = [regex]::Replace($pre, '(?im)^\s*-\s*\*\*(Validation|Prove):\*\*\s*`([^`]+)`\s*$', {
    param($m)
    $script:proveIdx++
    $key = "PROVE-$($script:proveIdx)"
    $script:proveMap[$key] = $m.Groups[2].Value
    return ("- **" + $m.Groups[1].Value + ":** " + $key)
})

# --- STAGE 1b: mask long inline code spans (>=40 chars, single-line) as FRAG-N ---
# --- STAGE 1a-ii: mask inline Prove commands (plan-file shape: Prove: `cmd` anywhere in a line) ---
$masked = [regex]::Replace($masked, '(?im)Prove: *`([^`]+)`', {
param($m)
$script:proveIdx++
$key = "PROVE-$($script:proveIdx)"
$script:proveMap[$key] = $m.Groups[1].Value
return ("Prove: " + $key)
})

$script:fragMap = [ordered]@{}
$script:fragIdx = 0
$masked = [regex]::Replace($masked, '`([^`\r\n]+)`', {
    param($m)
    if ($m.Groups[1].Value.Length -lt 40) { return $m.Value }
    $script:fragIdx++
    $key = "FRAG-$($script:fragIdx)"
    $script:fragMap[$key] = $m.Groups[1].Value
    return $key
})
Write-Host ("Masked " + $script:proveMap.Count + " prove command(s) + " + $script:fragMap.Count + " code fragment(s) - model sees " + $masked.Length + " of " + $rawIdea.Length + " chars") -ForegroundColor DarkGray

$prompt = @"
You are the tokeniser: you compress elaborate instructions into a minimal, lossless execution prompt for an autonomous coding system.

HARD RULES:
- Preserve every functional requirement, constraint, file name, identifier and acceptance criterion. Losing a requirement is a failure.
- Remove everything that does not change what gets built: preamble, motivation, repetition, adjectives, politeness, examples that add no constraint, context the code already shows.
- Rewrite as a flat numbered list of deliverables. One deliverable per line; never bundle multiple deliverables into one line. Each deliverable must be independently provable by a builder agent in at most 15 steps.
- Each line format: <imperative deliverable> | Files: <exact comma-separated paths> | Prove: <one runnable command whose exit code 0 proves the work>.
- The source contains placeholder tokens. PROVE-N tokens are pre-written validation commands: copy each EXACTLY as written into the matching deliverable's Prove field. FRAG-N tokens are verbatim code fragments: keep each token at the position where its content belongs in your output line.
- CRITICAL: every placeholder token must appear EXACTLY ONCE in your entire output. Never repeat, echo, quote, or parenthesise a token. One token, one position.
- If a source deliverable has no PROVE-N token, write a new Prove command yourself.
- No commentary before or after the list.

Output EXACTLY this structure:

# Tokenised Prompt
Compression: <input chars> -> <output chars>

## Deliverables
1. ...
2. ...

FLUFF RULE: strip every word that does not change what gets built - motivation, backstory, marketing language, politeness, hedging, repeated emphasis. If removing a word changes nothing about the resulting code, the word goes.
QUALITY RULE: code, commands, file names, identifiers, and acceptance criteria are byte-sacred - they survive verbatim. Compress prose ruthlessly; never paraphrase code.
Never narrate your process. No "let me think", no deliberation, no self-commentary - the output is the document; anything else is a contract violation.

The elaborate idea to compress:

$masked
"@

$fragHome = @{}
foreach ($k in $script:fragMap.Keys) {
    $fragHome[$k] = 0
    $pos = $masked.IndexOf($k)
    if ($pos -ge 0) {
        $heads = [regex]::Matches($masked.Substring(0, $pos), '(?m)^### (\d+)\.')
        if ($heads.Count -gt 0) { $fragHome[$k] = [int]$heads[$heads.Count - 1].Groups[1].Value }
    }
}
if (-not $Yes) { $Model = Select-CicadaModel -Seat "Tokeniser" -Current $Model -Recommend "minimax/MiniMax-M3" }

# --- STAGE 2: run loop - one retry allowed for corruption or lazy compression ---
$clean = $null
$pct = 0
$attempt = 0
$reattached = @()
while ($attempt -lt 2) {
    $attempt++
    $usePrompt = $prompt
    if ($attempt -eq 2) {
        $usePrompt = $prompt + "`n`nIMPORTANT: your previous attempt was rejected (corruption or under-compression). Compress MUCH harder - cut every word that does not change what gets built - and place every PROVE-N and FRAG-N token exactly once."
        Write-Warning "attempt 1 rejected - retrying with harder-compression nudge"
    }
    Write-Host ("Tokenising " + $rawIdea.Length + " chars of idea (" + $Model + ", attempt " + $attempt + ")...") -ForegroundColor DarkGray
    # --- direct MiniMax API (no opencode harness; exact token usage per attempt) ---
    $tin = 0; $tout = 0
    $clean = $null
    $modelsToTry = @($Model) + @(Get-CicadaFallbackFor ([string]$Model))
    foreach ($tryModel in $modelsToTry) {
        if (-not $tryModel) { continue }
        $m = ([string]$tryModel) -replace "^minimax/", ""
        $body = @{
            model = $m
            messages = @(
                @{ role = "system"; content = "You are the tokeniser compression engine. Return exactly the requested structure - no preamble, no commentary. Reason briefly and internally; the deliverable is the document - spend at most a few hundred words of reasoning, then write it." },
                @{ role = "user"; content = $usePrompt }
            )
            temperature = 0.1
            max_tokens = 40000
        } | ConvertTo-Json -Depth 10
        try {
            $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json" } -Body $body -TimeoutSec 600
            $clean = [string]$resp.choices[0].message.content
            $clean = [regex]::Replace($clean, "(?s)<think>.*?</think>", "")   # reasoning stays out of the deliverable
            if ($resp.choices[0].finish_reason -eq "length") { Write-Warning "output hit the token cap - truncated mid-stream; content may be incomplete" }
            $reasonLen = 0
            if ($resp.choices[0].message.reasoning_content) { $reasonLen = ([string]$resp.choices[0].message.reasoning_content).Length }
            if ($reasonLen -gt 0) { Write-Host ("  (reasoning: " + $reasonLen + " chars, document: " + $clean.Length + " chars)") -ForegroundColor DarkGray }
            if ($resp.usage) { $tin = [int]$resp.usage.prompt_tokens; $tout = [int]$resp.usage.completion_tokens }
            if ($clean) {
                $via = if ([string]$tryModel -ne [string]$Model) { " | via fallback " + $tryModel } else { "" }
                Write-Host ("  (tokens: " + $tin + " in / " + $tout + " out" + $via + ")") -ForegroundColor DarkGray
                break
            }
        } catch {
            Write-Warning ("direct call failed on " + $tryModel + ": " + $_.Exception.Message)
        }
    }
    if (-not $clean) { Write-Error "tokenising failed on all models (direct API)"; exit 1 }
    $clean = $clean.Trim()

    # --- substance gate: the raw answer must contain the document, not process ---
    $delivCount = [regex]::Matches($clean, '(?m)^\s*\d+\.').Count
    if ($delivCount -lt 1) {
        if ($attempt -lt 2) {
            Write-Warning ("attempt " + $attempt + " produced no deliverables - the model answered with process, not the document; retrying")
            continue
        }
        Write-Error "output contained no deliverables after retry - not saving"; exit 1
    }

    # normalize mojibake in model output too - the CLI transit path reintroduces it
    foreach ($f in $mojiFixes) {
        $bad = -join ($f[0] | ForEach-Object { [string][char]$_ })
        $clean = $clean.Replace($bad, [string][char]($f[1]))
    }

    # quote-restore runs BEFORE splice so it only touches model-written text
    $clean = [regex]::Replace($clean, '=(\\+)([\w\-.]+)(\\+)('')', '="$2"')

    $heading = $clean.IndexOf("# Tokenised Prompt")
    if ($heading -gt 0) { $clean = $clean.Substring($heading).Trim() }
    $clean = [regex]::Replace($clean, '^# Tokenised Prompt[^\r\n]*', '# Tokenised Prompt')

    # splice FRAG fragments back
    $missingFrags = @()
    $reattachedFrags = @()
    foreach ($k in $script:fragMap.Keys) {
        $pat = '`?' + $k + '(?![0-9])`?'
        if ($clean -match $pat) {
            $frag = $script:fragMap[$k]
            $clean = [regex]::Replace($clean, $pat, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '`' + $frag + '`' }.GetNewClosure())
        } else {
            $fragDest = $fragHome[$k]
            $linePat = '(?m)^(' + $fragDest + '\..*$'
            if ($fragDest -gt 0 -and $clean -match $linePat) {
                $frag = $script:fragMap[$k]
                $clean = ([regex]$linePat).Replace($clean, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + ' `' + $frag + '`' }.GetNewClosure(), 1)
                $reattachedFrags += $k
            } else {
                $pos = $masked.IndexOf($k)
                $ctx = ''
                if ($pos -gt 40) { $ctx = $masked.Substring($pos - 40, 40) } elseif ($pos -ge 0) { $ctx = $masked.Substring(0, $pos) }
                $ctxWords = @([regex]::Matches($ctx, '[A-Za-z][A-Za-z0-9_-]{3,}') | ForEach-Object { $_.Value })
                $bestLine = $null
                $bestHits = 0
                foreach ($ln in ([regex]::Split($clean, '\r?\n'))) {
                    $hits = 0
                    foreach ($w in $ctxWords) { if ($ln.IndexOf($w, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits++ } }
                    if ($hits -gt $bestHits) { $bestHits = $hits; $bestLine = $ln }
                }
                if ($bestLine -and $bestHits -ge 2) {
                    $frag = $script:fragMap[$k]
                    $clean = ([regex]([regex]::Escape($bestLine))).Replace($clean, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value + ' `' + $frag + '`' }.GetNewClosure(), 1)
                    $reattachedFrags += ($k + '->context')
                } else {
                    $frag = $script:fragMap[$k]
                    $clean = $clean.TrimEnd() + "`r`n`r`nRecovered fragment #" + ($k -replace '\D','') + " (model omitted it; original placement unknown):`r`n`r`n" + '`' + $frag + '`'
                    $reattachedFrags += ($k + '->appendix')
                }
            }
        }
    }

    # splice PROVE commands back; auto-reattach dropped ones onto their numbered line
    $reattached = @()
    $lost = @()
    foreach ($k in $script:proveMap.Keys) {
        $n = $k -replace 'PROVE-',''
        $pat = '`?' + $k + '(?![0-9])`?'
        if ($clean -match $pat) {
            $cmd = $script:proveMap[$k]
            $clean = [regex]::Replace($clean, $pat, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '`' + $cmd + '`' }.GetNewClosure())
        } else {
            $linePat = '(?m)^(' + $n + '\..*)$'
            if ($clean -match $linePat) {
                $cmd = $script:proveMap[$k]
                $clean = [regex]::Replace($clean, $linePat, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + ' | Prove: `' + $cmd + '`' }.GetNewClosure(), 1)
                $reattached += $k
            } else { $lost += $k }
        }
    }
    if ($reattachedFrags.Count -gt 0) { Write-Warning ("model dropped " + $reattachedFrags.Count + " fragment(s) - auto-reattached onto source deliverable lines: " + ($reattachedFrags -join ', ')) }
$leftover = [regex]::Matches($clean, '(PROVE|FRAG)-\d+').Count

    # corruption assessment - retry once rather than die on a bad attempt
    $corrupt = ($missingFrags.Count -gt 0) -or ($lost.Count -gt 0) -or ($leftover -gt 0)
    if ($corrupt) {
        Write-Warning ("attempt " + $attempt + " corrupt: missingFrags=" + $missingFrags.Count + " lostProves=" + $lost.Count + " leftoverTokens=" + $leftover)
        if ($attempt -lt 2) { continue }
        Write-Error "output still corrupt after retry - not saving"; exit 1
    }

    # --- STAGE 3: dedupe token echoes ---
    $clean = [regex]::Replace($clean, '(`[^`]{20,}`)\s*\(\1\)', '$1')
    $clean = [regex]::Replace($clean, '\| Prove: (`[^`]+`)(?:\s*\| Prove: \1)+', '| Prove: $1')
    $clean = [regex]::Replace($clean, '(`[^`]{20,}`)\s+\1', '$1')

# --- exactly-once enforcer v2 (collision-aware): embedded occurrences belong to the longer command ---
function Get-FreeTokenCount([string]$text, [string]$needle) {
if (-not $needle) { return 0 }
$longer = @()
foreach ($kk in $script:fragMap.Keys) { $c = $script:fragMap[$kk]; if ($c.Length -gt $needle.Length -and $c.IndexOf($needle) -ge 0) { $longer += $c } }
foreach ($kk in $script:proveMap.Keys) { $c = $script:proveMap[$kk]; if ($c.Length -gt $needle.Length -and $c.IndexOf($needle) -ge 0) { $longer += $c } }
$free = 0; $pos = 0
while (($p = $text.IndexOf($needle, $pos)) -ge 0) {
$inside = $false
foreach ($lc in $longer) {
$lp = 0
while (($q = $text.IndexOf($lc, $lp)) -ge 0) {
if ($p -ge $q -and ($p + $needle.Length) -le ($q + $lc.Length)) { $inside = $true; break }
$lp = $q + 1
}
if ($inside) { break }
}
if (-not $inside) { $free++ }
$pos = $p + 1
}
return $free
}
foreach ($map in @($script:fragMap, $script:proveMap)) {
foreach ($k in $map.Keys) {
$content = $map[$k]
$longer = @()
foreach ($kk in $script:fragMap.Keys) { $c = $script:fragMap[$kk]; if ($c.Length -gt $content.Length -and $c.IndexOf($content) -ge 0) { $longer += $c } }
foreach ($kk in $script:proveMap.Keys) { $c = $script:proveMap[$kk]; if ($c.Length -gt $content.Length -and $c.IndexOf($content) -ge 0) { $longer += $c } }
$freePos = @(); $pos = 0
while (($p = $clean.IndexOf($content, $pos)) -ge 0) {
$inside = $false
foreach ($lc in $longer) {
$lp = 0
while (($q = $clean.IndexOf($lc, $lp)) -ge 0) {
if ($p -ge $q -and ($p + $content.Length) -le ($q + $lc.Length)) { $inside = $true; break }
$lp = $q + 1
}
if ($inside) { break }
}
if (-not $inside) { $freePos += $p }
$pos = $p + 1
}
if ($freePos.Count -gt 1) {
for ($j = $freePos.Count - 1; $j -ge 1; $j--) { $clean = $clean.Remove($freePos[$j], $content.Length) }
Write-Warning ("enforcer: " + $k + " had " + $freePos.Count + " free occurrences - kept first, cut the rest")
}
}
}

    # --- STAGE 3b: self-certification - every original command/fragment must appear EXACTLY ONCE ---
    $badCounts = @()
    foreach ($k in $script:proveMap.Keys) {
        $o = Get-FreeTokenCount $clean ($script:proveMap[$k])
        if ($o -ne 1) { $badCounts += ($k + " x" + $o) }
    }
    foreach ($k in $script:fragMap.Keys) {
        $o = Get-FreeTokenCount $clean ($script:fragMap[$k])
        if ($o -ne 1) { $badCounts += ($k + " x" + $o) }
    }
    if ($badCounts.Count -gt 0) {
        Write-Warning ("attempt " + $attempt + " failed self-certification: " + ($badCounts -join ', '))
        if ($attempt -lt 2) { continue }
        Write-Error "self-certification failed after retry - not saving"; exit 1
    }

    $pct = [math]::Round(100 * (1 - ($clean.Length / [math]::Max(1, $rawIdea.Length))))
if ($clean.Length -ge $rawIdea.Length) {
    if ($attempt -lt 2) {
        Write-Warning ("attempt " + $attempt + " GREW the prompt (" + $rawIdea.Length + " -> " + $clean.Length + " chars) - treating as a failed attempt, retrying")
        continue
    }
    Write-Warning ("output is larger than the source even after retry (" + $rawIdea.Length + " -> " + $clean.Length + ") - saving, but treat this tokenprompt as suspect")
}
    if ($pct -ge 20) { break }
    if ($attempt -lt 2) { Write-Warning ("attempt 1 compressed only " + $pct + "% - below 20% floor, retrying") } else { Write-Warning ("still only " + $pct + "% after retry - keeping best effort") }
}
if ($reattached.Count -gt 0) { Write-Warning ("model dropped " + $reattached.Count + " Prove placeholder(s) - auto-reattached byte-exact: " + ($reattached -join ', ')) }
Write-Host ("SELF-CERTIFIED: " + $script:proveMap.Count + " proves + " + $script:fragMap.Count + " frags each appear exactly once, byte-exact") -ForegroundColor Green

# --- STAGE 4: coverage verification (deliverable sections only - context preamble is droppable by design) ---
$srcItems = [regex]::Matches($masked, '(?m)^### \d+\.').Count
$outItems = [regex]::Matches($clean, '(?m)^\d+\.').Count
if ($srcItems -gt 0 -and $outItems -ne $srcItems) { Write-Warning "deliverable count mismatch: source $srcItems vs output $outItems - review before use" }
$delivStart = $masked.IndexOf("### 1.")
$idSource = if ($delivStart -ge 0) { $masked.Substring($delivStart) } else { $masked }
$ids = @{}
foreach ($m in [regex]::Matches($idSource, '[\w./-]+\.(?:html|css|js|ts|png|xml|txt|json|md)')) { $ids[$m.Value] = $true }
foreach ($m in [regex]::Matches($idSource, '(?:id|class)="([\w -]+)"')) { $ids[$m.Groups[1].Value] = $true }
foreach ($m in [regex]::Matches($idSource, '\bL\d+\b')) { $ids[$m.Value] = $true }
$idList = @($ids.Keys | Where-Object { $_ -notmatch 'PROVE|FRAG' })
$missingIds = @($idList | Where-Object { $clean.IndexOf($_) -lt 0 })
$coverage = if ($idList.Count -gt 0) { [math]::Round(100 * ($idList.Count - $missingIds.Count) / $idList.Count) } else { 100 }
Write-Host ("Identifier coverage (deliverables only): " + $coverage + "% (" + ($idList.Count - $missingIds.Count) + "/" + $idList.Count + ")") -ForegroundColor $(if ($coverage -ge 90) { "Green" } elseif ($coverage -ge 75) { "DarkYellow" } else { "Red" })
if ($missingIds.Count -gt 0) { Write-Host ("  missing: " + (($missingIds | Select-Object -First 10) -join ', ')) -ForegroundColor DarkYellow }

# --- STAGE 5: measured compression header ---
$measured = "Compression: $($rawIdea.Length) -> $($clean.Length) chars ($pct% reduction)"
if ($clean -match '(?im)^\s*Compression:.*$') {
    $clean = [regex]::Replace($clean, '(?im)^\s*Compression:.*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $measured })
} else {
    $clean = $clean -replace '(?m)^(# Tokenised Prompt.*)$', ("`$1`n" + $measured)
}

# --- loss report ---
$srcHeads = @([regex]::Matches($rawIdea, '(?m)^#{1,3}\s+[^\r\n]+') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
$dropped = @($srcHeads | Where-Object { $_ -notmatch 'Deliverables' -and $clean.IndexOf($_) -lt 0 })
if ($dropped.Count -gt 0) { Write-Host ("Dropped sections: " + ($dropped -join ' | ')) -ForegroundColor DarkYellow }

$outPath = Join-Path $Project "tokenprompt.md"
$clean | Set-Content $outPath -Encoding utf8
$clean | Set-Clipboard

Write-Host ""
Write-Host $clean
Write-Host ""
Write-Host ("Saved to " + $outPath + " (" + $rawIdea.Length + " -> " + $clean.Length + " chars, " + $pct + "% smaller, attempt " + $attempt + ") and copied to the clipboard") -ForegroundColor DarkGray
$tg = "CICADA [tokeniser] " + (Split-Path -Leaf $Project) + " | " + $rawIdea.Length + " -> " + $clean.Length + " chars (" + $pct + "%) | coverage " + $coverage + "% | self-certified " + $script:proveMap.Count + "p+" + $script:fragMap.Count + "f | attempt " + $attempt
if ($mojiCount -gt 0) { $tg += " | mojibake fixed " + $mojiCount }
if ($reattached.Count -gt 0) { $tg += " | reattached " + $reattached.Count }
if ($dropped.Count -gt 0) { $tg += " | dropped: " + ($dropped -join '; ') }
Send-CicadaTelegram $tg




