param([string]$Name, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Words)
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir = Join-Path $Root "state"
New-Item -ItemType Directory -Force $dir | Out-Null
$msg = ($Words -join " ").Trim()
if (-not $msg) { $msg = (Read-Host "Steering note").Trim() }
if (-not $msg) { Write-Host "Empty note - nothing sent."; exit 0 }
$line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $msg
$file = "steer.txt"
if ($Name) { $file = "steer-" + $Name.ToLower() + ".txt" }
$line | Set-Content (Join-Path $dir $file) -Encoding utf8
$target = "the next checkpoint (any run)"
if ($Name) { $target = "agent '" + $Name + "' specifically" }
Write-Host ("Steering queued for " + $target + ": " + $line) -ForegroundColor Green
