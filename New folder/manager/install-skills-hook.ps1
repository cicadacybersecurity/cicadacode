$root = "C:\Users\David\minimax-agents"
$ag = Join-Path $root "agent.ps1"
$agSrc = Get-Content $ag -Raw
if ($agSrc -match 'Select-CicadaSkills') {
    Write-Host "agent.ps1: already wired" -ForegroundColor DarkGray
} else {
    $lines = $agSrc -split "`r?`n"
    $idx = -1
    # prefer a real dot-source line for engine.ps1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\.\s+.*engine\.ps1') { $idx = $i; break }
    }
    # fallback: any line mentioning engine.ps1 at all
    if ($idx -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'engine\.ps1') { $idx = $i; break }
        }
    }
    if ($idx -lt 0) { Write-Error "agent.ps1 never references engine.ps1 - paste the top 20 lines into the chat"; exit 1 }
    $hook = 'if (-not (Get-Command Select-CicadaSkills -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "manager\skills.ps1") }; if (Get-Command Select-CicadaSkills -ErrorAction SilentlyContinue) { Select-CicadaSkills }'
    $new = @()
    $new += $lines[0..$idx]
    $new += $hook
    if ($idx + 1 -lt $lines.Count) { $new += $lines[($idx + 1)..($lines.Count - 1)] }
    Set-Content $ag ($new -join "`r`n") -Encoding utf8
    Write-Host ("agent.ps1: skills selection hooked after line " + ($idx + 1) + " -> " + $lines[$idx].Trim()) -ForegroundColor Green
}
Get-ChildItem (Join-Path $root "skills") -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'http|\[|\]' } | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($ag, [ref]$null, [ref]$e)
if ($e.Count) { $e | ForEach-Object Message; Write-Host "PARSE FAILED: agent.ps1" -ForegroundColor Red } else { Write-Host "parse OK: agent.ps1" -ForegroundColor Green }
