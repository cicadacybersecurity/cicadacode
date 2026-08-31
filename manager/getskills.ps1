param(
    [string]$Source,
    [switch]$Yes
)

. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

$skillFileName = "SKILL" + ".m" + "d"
$Root = Split-Path -Parent $PSScriptRoot
$skillsDir = Join-Path $Root "skills"
$cacheRoot = Join-Path $Root "state\skill-market"
New-Item -ItemType Directory -Force $cacheRoot | Out-Null
New-Item -ItemType Directory -Force $skillsDir | Out-Null

$sources = @(
    [pscustomobject]@{ Label = "Anthropic official skills catalog"; Repo = "anthropics/skills" },
    [pscustomobject]@{ Label = "Community marketplace (beshkenadze)"; Repo = "beshkenadze/claude-skills-marketplace" }
)

# --- pick source repo ---
$repo = $null
if ($Source) {
    $repo = $Source -replace '^https?://github\.com/', '' -replace '\.git$', '' -replace '/$', ''
} else {
    Write-Host ""
    Write-Host "Skill sources:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $sources.Count; $i++) { Write-Host ("  [" + ($i + 1) + "] " + $sources[$i].Label + " (github.com/" + $sources[$i].Repo + ")") }
    Write-Host "  [C] Custom repo (owner/name)" -ForegroundColor DarkGray
    $pick = (Read-Host "Source").Trim()
    if ($pick -match '^[Cc]$') { $repo = (Read-Host "owner/repo").Trim() }
    else {
        $n = 0
        if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $sources.Count) { $repo = $sources[$n - 1].Repo } else { Write-Host "Aborted."; exit 0 }
    }
}
if (-not $repo) { Write-Error "no source repo"; exit 1 }

# --- fetch or update the cached clone ---
$safeName = $repo -replace '/', '-'
$dest = Join-Path $cacheRoot $safeName
if (Test-Path (Join-Path $dest ".git")) {
    Write-Host ("Updating cached copy of " + $repo + "...") -ForegroundColor DarkGray
    & git -C $dest pull --quiet --ff-only 2>$null
} else {
    Write-Host ("Downloading github.com/" + $repo + " (shallow clone)...") -ForegroundColor Cyan
    & git clone --depth 1 --quiet ("https://github.com/" + $repo + ".git") $dest
    if ($LASTEXITCODE -ne 0) { Write-Error ("git clone failed for " + $repo + " - check the repo name and your network"); exit 1 }
}

# --- enumerate skill folders (any depth, skip .git), read frontmatter ---
$found = @()
$files = Get-ChildItem $dest -Recurse -Filter $skillFileName -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($f in $files) {
    $text = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    $name = Split-Path -Leaf (Split-Path -Parent $f.FullName)
    $desc = ""
    if ($text -match '(?s)\A---\s*\r?\n(.+?)\r?\n---') {
        $mn = [regex]::Match($Matches[1], '(?im)^\s*name:\s*(.+?)\s*$')
        $md2 = [regex]::Match($Matches[1], '(?im)^\s*description:\s*(.+?)\s*$')
        if ($mn.Success) { $name = $mn.Groups[1].Value.Trim().Trim('"').Trim([char]39) }
        if ($md2.Success) { $desc = $md2.Groups[1].Value.Trim().Trim('"').Trim([char]39) }
    }
    $found += [pscustomobject]@{ Name = $name; Description = $desc; Path = (Split-Path -Parent $f.FullName); Chars = $text.Length }
}
if ($found.Count -eq 0) { Write-Error ("no skills (folders containing " + $skillFileName + ") found in " + $repo); exit 1 }
$found = @($found | Sort-Object Name)

Write-Host ""
Write-Host ($found.Count.ToString() + " skills available in " + $repo + ":") -ForegroundColor Cyan
for ($i = 0; $i -lt $found.Count; $i++) {
    $s = $found[$i]
    $line = "  [{0}] {1} ({2} chars)" -f ($i + 1), $s.Name, $s.Chars
    if ($s.Description) { $line += " - " + $s.Description }
    if ($line.Length -gt 150) { $line = $line.Substring(0, 147) + "..." }
    Write-Host $line
}
Write-Host "  Enter numbers (e.g. 1,3), 'all', or Enter to cancel" -ForegroundColor DarkGray
$sel = (Read-Host "Install").Trim()
if (-not $sel) { Write-Host "Aborted."; exit 0 }
if ($sel -eq 'all') { $picked = $found } else {
    $picked = @()
    foreach ($part in ($sel -split '[,\s]+')) {
        $n = 0
        if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $found.Count) { $picked += $found[$n - 1] }
    }
}
if ($picked.Count -eq 0) { Write-Host "Nothing selected."; exit 0 }

# --- install into skills\ ---
$installed = @()
foreach ($s in $picked) {
    $target = Join-Path $skillsDir $s.Name
    if (Test-Path $target) {
        if (-not $Yes) {
            $ow = (Read-Host ($s.Name + " already installed - overwrite? (y/N)")).Trim()
            if ($ow -notmatch '^[Yy]') { Write-Host ("  skipped: " + $s.Name) -ForegroundColor DarkGray; continue }
        }
        Remove-Item $target -Recurse -Force
    }
    Copy-Item $s.Path $target -Recurse
    $installed += $s.Name
    Write-Host ("  installed: " + $s.Name) -ForegroundColor Green
}

Write-Host ""
Write-Host ($installed.Count.ToString() + " skill(s) installed to " + $skillsDir + " - they appear in the startup skills menu next run") -ForegroundColor Green
Write-Host "Tip: the startup menu shows char counts - run debulk mode on any that feel heavy." -ForegroundColor DarkGray
if ($installed.Count -gt 0) { Send-CicadaTelegram ("CICADA [getskills] installed " + $installed.Count + " skill(s) from " + $repo + ": " + ($installed -join ', ')) }
