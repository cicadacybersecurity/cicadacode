$ErrorActionPreference = "Stop"
$p = "C:\Users\David\minimax-agents\manager\tokeniser.ps1"
$s = Get-Content $p -Raw
$a = '            } else { $missingFrags += $k }'
$hits = ([regex]::Matches($s, [regex]::Escape($a))).Count
if ($hits -ne 1) { Write-Error ("anchor expected once, found " + $hits); exit 1 }
$n = @(
'            } else {'
'                $pos = $masked.IndexOf($k)'
'                $ctx = '''''
'                if ($pos -gt 40) { $ctx = $masked.Substring($pos - 40, 40) } elseif ($pos -ge 0) { $ctx = $masked.Substring(0, $pos) }'
'                $ctxWords = @([regex]::Matches($ctx, ''[A-Za-z][A-Za-z0-9_-]{3,}'') | ForEach-Object { $_.Value })'
'                $bestLine = $null'
'                $bestHits = 0'
'                foreach ($ln in ([regex]::Split($clean, ''\r?\n''))) {'
'                    $hits = 0'
'                    foreach ($w in $ctxWords) { if ($ln.IndexOf($w, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits++ } }'
'                    if ($hits -gt $bestHits) { $bestHits = $hits; $bestLine = $ln }'
'                }'
'                if ($bestLine -and $bestHits -ge 2) {'
'                    $frag = $script:fragMap[$k]'
'                    $clean = ([regex]([regex]::Escape($bestLine))).Replace($clean, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value + '' `'' + $frag + ''`'' }.GetNewClosure(), 1)'
'                    $reattachedFrags += ($k + ''->context'')'
'                } else {'
'                    $frag = $script:fragMap[$k]'
'                    $clean = $clean.TrimEnd() + "`r`n`r`nRecovered fragment " + $k + " (model omitted it; original placement unknown):`r`n`r`n" + ''`'' + $frag + ''`'''
'                    $reattachedFrags += ($k + ''->appendix'')'
'                }'
'            }'
) -join "`r`n"
$s = $s.Replace($a, $n)
Set-Content $p $s -Encoding utf8
$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e)
if ($e.Count) { $e | ForEach-Object Message; Write-Host "PARSE FAILED" -ForegroundColor Red; exit 1 }
Write-Host "parse OK - tokeniser v4.2 (context + appendix frag recovery)" -ForegroundColor Green
