$ErrorActionPreference = "Stop"
$ag = "C:\Users\David\minimax-agents\agent.ps1"
$src = Get-Content $ag -Raw
if ($src -match '"getskills"') { Write-Host "agent.ps1: getskills already wired" -ForegroundColor DarkGray; exit 0 }
if ($src -notmatch '"debulk"') { Write-Error "agent.ps1 is missing its debulk wiring - unexpected state"; exit 1 }

$src = $src.Replace('[ValidateSet("parallel","unsupervised","idea","inspect","pi","plan","tokeniser","debulk")]', '[ValidateSet("parallel","unsupervised","idea","inspect","pi","plan","tokeniser","debulk","getskills")]')
$src = $src.Replace('"Debulk skill (shrink a skill playbook)", "Quit")', '"Debulk skill (shrink a skill playbook)", "Get skills (browse + install from marketplaces)", "Quit")')
$src = $src.Replace('elseif ($mi -eq 7) { $Mode = "debulk" }', 'elseif ($mi -eq 7) { $Mode = "debulk" }' + "`r`n" + '    elseif ($mi -eq 8) { $Mode = "getskills" }')
$src = $src.Replace('$Mode -ne "pi" -and $Mode -ne "debulk"', '$Mode -ne "pi" -and $Mode -ne "debulk" -and $Mode -ne "getskills"')

$dispatch = @(
'if ($Mode -eq "getskills") {'
'    $gsScript = Join-Path $Root "manager\getskills.ps1"'
'    if (Test-Path $gsScript) { & $gsScript -Yes:$Yes; exit $LASTEXITCODE }'
'    Write-Host "getskills.ps1 not found in manager\." -ForegroundColor Red'
'    exit 1'
'}'
'') -join "`r`n"
$src = $src.Replace('if ($Mode -eq "debulk") {', $dispatch + "`r`n" + 'if ($Mode -eq "debulk") {')

$count = ([regex]::Matches($src, 'getskills')).Count
if ($count -lt 7) { Write-Error ("self-check failed: expected 7+ getskills insertions, found " + $count + " - agent.ps1 NOT written"); exit 1 }
Set-Content $ag $src -Encoding utf8
$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($ag, [ref]$null, [ref]$e)
if ($e.Count) { $e | ForEach-Object Message; Write-Host "PARSE FAILED" -ForegroundColor Red; exit 1 }
Write-Host "parse OK - agent.ps1 now has getskills mode" -ForegroundColor Green

