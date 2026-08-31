# manager\skills.ps1 - CICADA skills layer (v3: recursive Claude-skill detection)
# Auto-detects plain .md files at the root AND Claude-style skills (folders containing SKILL.md
# with YAML frontmatter) at ANY depth under <repo>\skills; operator multi-selects at startup;
# selected skill content is injected into every Invoke-Agent call (all modes).

$script:SkillsDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\skills"))
if (-not $global:CicadaActiveSkills) { $global:CicadaActiveSkills = @() }

function Get-CicadaSkills {
    if (-not (Test-Path $script:SkillsDir -PathType Container)) { return @() }
    $entries = @()
    # loose .md files at the root of the skills folder
    foreach ($f in (Get-ChildItem $script:SkillsDir -Filter *.md -File)) {
        $entries += [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($f.Name); Path = $f.FullName }
    }
    # Claude-style skills: any folder at any depth containing SKILL.md
    foreach ($sk in (Get-ChildItem $script:SkillsDir -Recurse -Filter "SKILL.md" -File -ErrorAction SilentlyContinue)) {
        $folder = Split-Path -Parent $sk.FullName
        $rel = $folder.Substring($script:SkillsDir.Length).TrimStart('\','/')
        if (-not $rel) { $rel = Split-Path -Leaf $folder }
        $entries += [pscustomobject]@{ Name = $rel; Path = $sk.FullName }
    }
    $skills = @()
    foreach ($e in ($entries | Sort-Object Name)) {
        $text = Get-Content $e.Path -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        $title = $null; $desc = $null
        # Claude-style YAML frontmatter: name / description
        if ($text -match '(?s)\A---\s*\r?\n(.+?)\r?\n---') {
            $fm = $Matches[1]
            $mn = [regex]::Match($fm, '(?im)^\s*name:\s*(.+?)\s*$')
            $md = [regex]::Match($fm, '(?im)^\s*description:\s*(.+?)\s*$')
            if ($mn.Success) { $title = $mn.Groups[1].Value.Trim().Trim('"').Trim([char]39) }
            if ($md.Success) { $desc = $md.Groups[1].Value.Trim().Trim('"').Trim([char]39) }
        }
        if (-not $title) {
            foreach ($line in ($text -split "`r?`n")) {
                $t = $line.Trim()
                if (-not $t -or $t -eq '---') { continue }
                if (-not $title -and $t -match '^#{1,3}\s+(.+)$') { $title = $Matches[1].Trim(); continue }
                if (-not $desc -and $t -notmatch '^#' -and $t -notmatch '^\w[\w-]*:') { $desc = $t }
                if ($title -and $desc) { break }
            }
        }
        if (-not $title) { $title = $e.Name }
        $skills += [pscustomobject]@{ Name = $e.Name; Title = $title; Description = $desc; Path = $e.Path; Chars = $text.Length }
    }
    return $skills
}

function Set-CicadaSkillsByName {
    param([string]$Spec)
    $skills = @(Get-CicadaSkills)
    if ($Spec -eq 'all') { $global:CicadaActiveSkills = $skills }
    elseif ($Spec -eq 'none' -or -not $Spec) { $global:CicadaActiveSkills = @() }
    else {
        $names = @($Spec -split ',' | ForEach-Object { $_.Trim().ToLower() })
        $global:CicadaActiveSkills = @($skills | Where-Object { $names -contains $_.Name.ToLower() })
    }
    $env:CICADA_SKILLS = (($global:CicadaActiveSkills | ForEach-Object Name) -join ',')
}

function Select-CicadaSkills {
    if ($env:CICADA_SKILLS) { Set-CicadaSkillsByName $env:CICADA_SKILLS; Write-Host ("Skills (from CICADA_SKILLS): " + $(if ($global:CicadaActiveSkills.Count) { ($global:CicadaActiveSkills | ForEach-Object Title) -join ', ' } else { 'none' })) -ForegroundColor DarkGray; return }
    $skills = @(Get-CicadaSkills)
    if ($skills.Count -eq 0) { Write-Host "No skills in $($script:SkillsDir) - drop any .md file (or a Claude skill folder) there and it appears here" -ForegroundColor DarkGray; return }
    Write-Host ""
    Write-Host "Available skills (auto-detected from $($script:SkillsDir)):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $skills.Count; $i++) {
        $s = $skills[$i]
        $line = "  [{0}] {1} ({2} chars)" -f ($i + 1), $s.Title, $s.Chars
        if ($s.Description -and $s.Description -ne $s.Title) { $line += " - " + $s.Description }
        if ($line.Length -gt 150) { $line = $line.Substring(0, 147) + "..." }
        Write-Host $line
    }
    Write-Host "  Enter numbers (e.g. 1,3), 'all', or press Enter for none" -ForegroundColor DarkGray
    $sel = (Read-Host "Skills").Trim()
    if (-not $sel) { $global:CicadaActiveSkills = @(); $env:CICADA_SKILLS = ''; return }
    if ($sel -eq 'all') { Set-CicadaSkillsByName 'all' }
    else {
        $picked = @()
        foreach ($part in ($sel -split '[,\s]+')) {
            $n = 0
            if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $skills.Count) { $picked += $skills[$n - 1] }
        }
        $global:CicadaActiveSkills = $picked
        $env:CICADA_SKILLS = (($picked | ForEach-Object Name) -join ',')
    }
    if ($global:CicadaActiveSkills.Count -gt 0) {
        $total = ($global:CicadaActiveSkills | Measure-Object -Property Chars -Sum).Sum
        Write-Host ("Skills active: " + (($global:CicadaActiveSkills | ForEach-Object Title) -join ', ') + " (" + $total + " chars injected into every agent call)") -ForegroundColor Green
        if ($total -gt 8000) { Write-Warning "skill payload is $total chars - large skill context burns tokens on every call; consider trimming" }
    }
}

function Get-CicadaSkillContext {
    if (-not $global:CicadaActiveSkills -or $global:CicadaActiveSkills.Count -eq 0) { return "" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("ACTIVE SKILLS - operator-authored playbooks. Follow them whenever they apply to the task at hand:")
    foreach ($s in $global:CicadaActiveSkills) {
        $body = Get-Content $s.Path -Raw -ErrorAction SilentlyContinue
        if ($body) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("=== SKILL: " + $s.Title + " ===")
            [void]$sb.AppendLine($body.Trim())
            [void]$sb.AppendLine("=== END SKILL ===")
        }
    }
    return $sb.ToString()
}

# --- wrap Invoke-Agent so every mode inherits skills with zero per-mode plumbing ---
if (Get-Command Invoke-Agent -ErrorAction SilentlyContinue) {
    $existing = (Get-Command Invoke-Agent).ScriptBlock.ToString()
    if ($existing -notmatch 'Invoke-Agent-CicadaBase') {
        Copy-Item function:\Invoke-Agent function:\Invoke-Agent-CicadaBase -Force
        function Invoke-Agent {
            $ctx = Get-CicadaSkillContext
            if ($ctx) {
                if ($PSBoundParameters.ContainsKey('Prompt')) {
                    $p = [string]$PSBoundParameters['Prompt']
                    if ($p -and -not $p.Contains('ACTIVE SKILLS')) { $PSBoundParameters['Prompt'] = $p + $ctx }
                }
                if ($PSBoundParameters.ContainsKey('CallArgs')) {
                    $ca = $PSBoundParameters['CallArgs']
                    if ($ca -is [System.Collections.IDictionary] -and $ca.Contains('Prompt')) {
                        $p = [string]$ca['Prompt']
                        if ($p -and -not $p.Contains('ACTIVE SKILLS')) { $ca['Prompt'] = $p + $ctx }
                    }
                }
            }
            Invoke-Agent-CicadaBase @PSBoundParameters @args
        }
    }
}

# env-driven activation for non-interactive / child-process runs
if ($env:CICADA_SKILLS -and $global:CicadaActiveSkills.Count -eq 0) { Set-CicadaSkillsByName $env:CICADA_SKILLS }
