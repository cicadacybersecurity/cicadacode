$ErrorActionPreference = "Stop"
$ag = "C:\Users\David\minimax-agents\agent.ps1"
$src = Get-Content $ag -Raw

if ($src -match 'skills: select playbooks for this run') { Write-Host "agent.ps1: skills selection already relocated" -ForegroundColor DarkGray; exit 0 }

$oldCall = 'if (Get-Command Select-CicadaSkills -ErrorAction SilentlyContinue) { Select-CicadaSkills }'
if (-not $src.Contains($oldCall)) { Write-Error "startup skills call not found - unexpected state"; exit 1 }
$src = $src.Replace($oldCall, "").Replace("if (-not (Get-Command Select-CicadaSkills -ErrorAction SilentlyContinue)) { . (Join-Path `$Root `"manager\skills.ps1`") }`r`n", "")

$anchor = 'if ($Project) { $Project = (Resolve-Path $Project).Path }'
if (-not $src.Contains($anchor)) { Write-Error "project-resolution anchor not found"; exit 1 }
$selBlock = @(
''
'# skills: select playbooks for this run once the mode is known (skipped for skill-management modes and -Yes automation)'
'if ($Mode -ne "getskills" -and $Mode -ne "debulk" -and -not $Yes) {'
'    if (Get-Command Select-CicadaSkills -ErrorAction SilentlyContinue) { Select-CicadaSkills }'
'}'
) -join "`r`n"
$src = $src.Replace($anchor, $anchor + "`r`n" + $selBlock)

$count = ([regex]::Matches($src, 'Select-CicadaSkills')).Count
if ($count -lt 2) { Write-Error ("self-check failed: expected 2+ Select-CicadaSkills references, found " + $count + " - agent.ps1 NOT written"); exit 1 }
Set-Content $ag $src -Encoding utf8
$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($ag, [ref]$null, [ref]$e)
if ($e.Count) { $e | ForEach-Object Message; Write-Host "PARSE FAILED" -ForegroundColor Red; exit 1 }
Write-Host "parse OK - skills selection moved into the mode flow" -ForegroundColor Green
