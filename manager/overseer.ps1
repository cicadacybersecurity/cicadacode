param(
    [string]$Project,
    [string]$StateFile = "",
    [string]$Model = "minimax/MiniMax-M2.7",
    [int]$PollSeconds = 2,
    [switch]$Yes,
    [switch]$AutoDetect,
    [int]$ExpectWorkers = 0,
    [int]$AutoDetectTimeoutSec = 180,
    [double]$MaxSessionAgeHours = 12   # fleet fix v4.2: 12h window
)
# overseer.ps1 - the Telegram manager for the parallel worker fleet.
# v5: free-form messages are decoded by the cheap model into actions; v4's
# detection, callsigns, summary relay, and yes/custom routing.
# v4.6: update-backlog drop at startup, WMI-free twin sweep (window title),
# stale-heartbeat twin kill, guarded inline-menu JSON, send receipts in the
# console, comma-pinned suggestion buttons, first-sight baselining, tighter
# poll timeouts, broader listener detection.
# v4.7: Fleet status button replies visibly; /ak (or /kill Alpha, /killall)
# kills an agent's serve process by port ownership - no WMI.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

# fleet fix v4.3: self-logging - everything the overseer prints lands in
# manager\overseer.log, so debugging never needs console-hunting again.
try { Start-Transcript -Path (Join-Path $PSScriptRoot "overseer.log") -Append -Force | Out-Null } catch {}

# fleet fix v4.3: split-brain guard - if another overseer instance has a fresh
# heartbeat, kill it. A wedged twin consuming getUpdates is why commands can
# show read receipts yet never get replies. CIM-free: lock file + Get-Process.
$script:lockFile = Join-Path $PSScriptRoot "overseer.lock"
try {
    if (Test-Path $script:lockFile) {
        $lock = Get-Content $script:lockFile -Raw | ConvertFrom-Json
        $oldPid = [int]$lock.pid
        $lockAge = (New-TimeSpan -Start ([datetime]::Parse([string]$lock.stamp)) -End (Get-Date)).TotalSeconds
        $oldAlive = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        # fleet fix v4.6: a twin with a STALE heartbeat is wedged, not dead -
        # if its console title still says overseer it can wake and eat updates
        # at any moment, so kill it too.
        $twinByTitle = ($oldAlive -and [string]$oldAlive.MainWindowTitle -match 'CICADA overseer')
        if ($oldAlive -and $oldAlive.ProcessName -match '^(powershell|pwsh)$' -and $oldAlive.Id -ne $PID -and ($lockAge -lt 60 -or $twinByTitle)) {
            Write-Host ("another overseer instance (PID " + $oldPid + ", heartbeat " + [int]$lockAge + "s ago) is live - stopping it") -ForegroundColor Yellow
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
} catch {}
function Write-OverseerLock {
    try { (@{ pid = $PID; stamp = (Get-Date).ToString("o") } | ConvertTo-Json) | Set-Content $script:lockFile -Encoding UTF8 } catch {}
}
Write-OverseerLock

# fleet fix v4.4: sweep for pre-lock overseer processes (built before the lock
# existed - a wedged twin races the live overseer for every Telegram update,
# which is why commands show read receipts yet never get replies). CIM runs in
# a 10-second job so a hung WMI service cannot stall startup.
try {
    $pjob = Start-Job { Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Select-Object ProcessId, CommandLine }
    if (Wait-Job $pjob -Timeout 10) {
        foreach ($pr in @(Receive-Job $pjob)) {
            if ($pr.ProcessId -ne $PID -and [string]$pr.CommandLine -match 'overseer\.ps1') {
                Write-Host ("killing stale overseer process PID " + $pr.ProcessId) -ForegroundColor Yellow
                Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host "process scan timed out (WMI slow) - skipped" -ForegroundColor DarkYellow
    }
    Remove-Job $pjob -Force -ErrorAction SilentlyContinue
} catch {}

# fleet fix v4.6: WMI-free twin sweep. When WMI hangs (the recurring fault
# on this machine) the v4.4 CIM sweep above times out and is SKIPPED - and
# the pre-lock twin survives to keep racing this process for every Telegram
# update (the checkmark-but-silent pattern). Window titles need no WMI: any
# powershell console titled "CICADA overseer" that is not THIS process is a
# twin - kill on sight.
try {
    foreach ($tp in @(Get-Process powershell, pwsh -ErrorAction SilentlyContinue)) {
        if ($tp.Id -ne $PID -and [string]$tp.MainWindowTitle -match 'CICADA overseer') {
            Write-Host ("killing twin overseer console PID " + $tp.Id + " (window-title match, no WMI)") -ForegroundColor Yellow
            Stop-Process -Id $tp.Id -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}
$callsigns = @("Alpha","Bravo","Charlie","Delta","Echo","Foxtrot","Golf","Hotel","India","Juliet")
function Get-Callsign([string]$id) {
    $n = 0
    if ([int]::TryParse($id, [ref]$n) -and $n -ge 1 -and $n -le $callsigns.Count) { return $callsigns[$n - 1] }
    return ("Worker " + $id)
}

if (-not $Project) { $Project = $PSScriptRoot }   # no project needed - detection finds workers itself; this only hosts the state cache
if (-not (Test-Path $Project -PathType Container)) { New-Item -ItemType Directory -Force -Path $Project | Out-Null }
$Project = (Resolve-Path $Project).Path
if (-not $StateFile) { $StateFile = Join-Path $Project ".cicada-overseer.json" }

$s = Get-Content $script:SecretsPath -Raw | ConvertFrom-Json
$token = [string]$s.OVERSEER_BOT_TOKEN; if (-not $token) { $token = [string]$s.TELEGRAM_BOT_TOKEN }
$chatId = [string]$s.OVERSEER_CHAT_ID; if (-not $chatId) { $chatId = [string]$s.TELEGRAM_CHAT_ID }
if (-not $token -or -not $chatId) { Write-Error "no overseer bot configured - add OVERSEER_BOT_TOKEN and OVERSEER_CHAT_ID to manager\secrets.json"; exit 1 }

function Send-OverseerTelegram([string]$text) {
    # fleet fix v3.4: keyboards retired - plain sends; the operator drives
    # everything with shorthand commands (/<worker letter><action>).
    $body = @{ chat_id = $chatId; text = $text } | ConvertTo-Json
    try {
        [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/sendMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30)
        Write-Host ("  [" + (Get-Date -Format HH:mm:ss) + "] telegram: sent " + $text.Length + " chars") -ForegroundColor DarkGray   # fleet fix v4.6: proof of send - silence in Telegram now PROVES a twin ate it
    } catch { Write-Host ("  telegram send failed: " + $_.Exception.Message) -ForegroundColor DarkYellow }
}

# fleet fix v4.3: NEVER die silently. Any uncaught error anywhere gets logged
# (transcript) and reported to Telegram, then execution continues - a broken
# handler kills one reply, not the overseer.
trap {
    $em = $_.Exception.Message
    Write-Host ("overseer error (staying alive): " + $em) -ForegroundColor Red
    try { Send-OverseerTelegram ("overseer error (I stayed alive): " + $em) } catch {}
    continue
}

function Send-OverseerMenu([string]$text, $rows) {
    # fleet fix v3.2: force the button panel to auto-OPEN above the input box.
    # Telegram clients remember a collapsed keyboard; removing it and instantly
    # re-sending makes the client treat it as brand new and expand it. The
    # remove message self-deletes so the chat stays clean.
    $rmBody = @{ chat_id = $chatId; text = "..."; reply_markup = @{ remove_keyboard = $true } } | ConvertTo-Json -Depth 6
    try {
        $rm = Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/sendMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($rmBody)) -TimeoutSec 15
        if ($rm -and $rm.result -and $rm.result.message_id) {
            $dBody = @{ chat_id = $chatId; message_id = $rm.result.message_id } | ConvertTo-Json
            try { [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/deleteMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($dBody)) -TimeoutSec 15) } catch {}
        }
    } catch {}
    $body = @{ chat_id = $chatId; text = $text; reply_markup = @{ keyboard = @($rows); is_persistent = $true } } | ConvertTo-Json -Depth 10
    try {
        [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/sendMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30)
    } catch { Write-Host ("  telegram menu send failed: " + $_.Exception.Message) -ForegroundColor DarkYellow }
}
function Send-OverseerAnswerCallback([string]$callbackId) {
    try {
        $body = @{ callback_query_id = $callbackId } | ConvertTo-Json
        [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/answerCallbackQuery") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15)
    } catch {}
}
function Get-WorkerMenu($fleet) {
    $rows = New-Object System.Collections.ArrayList
    $row = New-Object System.Collections.ArrayList
    foreach ($w in @($fleet)) {
        if ($row.Count -ge 4) { [void]$rows.Add($row.ToArray()); $row = New-Object System.Collections.ArrayList }
        [void]$row.Add(@{ text = $w.name })
    }
    if ($row.Count -gt 0) { [void]$rows.Add($row.ToArray()) }
    [void]$rows.Add(@(@{ text = "Refresh" }, @{ text = "Status all" }, @{ text = "Hide" }))
    return $rows
}
function Get-WorkerCommandMenu([string]$id, [string]$name) {
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add(@(@{ text = ("Message " + $name) }))
    [void]$rows.Add(@(@{ text = ("Next " + $name) }))
    [void]$rows.Add(@(@{ text = ("Status " + $name) }))
    [void]$rows.Add(@(@{ text = ("Interrupt " + $name) }))
    [void]$rows.Add(@(@{ text = "Back" }, @{ text = "Hide" }))
    return $rows
}
function Send-OverseerKeyboardRemove([string]$text) {
    # fleet fix v3.6: Telegram requires a message to clear a client keyboard -
    # so the removal message deletes itself instantly; zero visible chatter
    $body = @{ chat_id = $chatId; text = $text; reply_markup = @{ remove_keyboard = $true } } | ConvertTo-Json -Depth 6
    try {
        $r = Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/sendMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30
        if ($r -and $r.result -and $r.result.message_id) {
            $dBody = @{ chat_id = $chatId; message_id = $r.result.message_id } | ConvertTo-Json
            try { [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/deleteMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($dBody)) -TimeoutSec 15) } catch {}
        }
    } catch {}
}
function Remove-OverseerPinnedMenu {
    # fleet fix v3.1: the pinned top menu is retired (operator prefers the
    # bottom keyboard) - unpin any leftover fleet-menu message at startup.
    try {
        $c = Invoke-RestMethod -Method Get -Uri ("https://api.telegram.org/bot" + $token + "/getChat?chat_id=" + $chatId) -TimeoutSec 15
        $pm = $c.result.pinned_message
        if ($pm -and ([string]$pm.text -match '^fleet menu' -or [string]$pm.text -match ' - pick an action:$')) {
            $pBody = @{ chat_id = $chatId; message_id = $pm.message_id } | ConvertTo-Json
            [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/unpinChatMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($pBody)) -TimeoutSec 15)
        }
    } catch {}
}
function Send-OverseerInlineMenu([string]$text, $rows) {
    # fleet fix v4.5: PS 5.1's ConvertTo-Json collapses single-element nested
    # arrays (a one-button row), which Telegram rejects with 400 "expected an
    # Array of InlineKeyboardButton" - silently eating the roster + button.
    # Build the keyboard JSON by hand so the structure can never collapse, and
    # fall back to a plain message so bad markup can never lose the text.
    $rowsJson = @()
    foreach ($row in @($rows)) {
        $btns = @()
        foreach ($b in @($row)) {
            # fleet fix v4.6: skip null/empty buttons - Telegram rejects empty
            # text or callback_data with the same 400 that ate the roster.
            if (-not $b) { continue }
            $bt = [string]$b.text
            $bd = [string]$b.callback_data
            if (-not $bt -or -not $bd) { continue }
            $btns += ('{"text":' + ($bt | ConvertTo-Json) + ',"callback_data":' + ($bd | ConvertTo-Json) + '}')
        }
        # fleet fix v4.6: never emit an empty row - Telegram 400s on [].
        if ($btns.Count -gt 0) { $rowsJson += ("[" + ($btns -join ",") + "]") }
    }
    # fleet fix v4.6: if every button was invalid, the text still goes out plain.
    if ($rowsJson.Count -eq 0) { Send-OverseerTelegram $text; return }
    $cid = [string]$chatId
    if ($cid -match '^-?\d+$') { $cidJson = $cid } else { $cidJson = ($cid | ConvertTo-Json) }
    $body = '{"chat_id":' + $cidJson + ',"text":' + ([string]$text | ConvertTo-Json) + ',"reply_markup":{"inline_keyboard":[' + ($rowsJson -join ",") + ']}}'
    try {
        [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/sendMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30)
        Write-Host ("  [" + (Get-Date -Format HH:mm:ss) + "] telegram: inline menu sent (" + $rowsJson.Count + " button row(s))") -ForegroundColor DarkGray   # fleet fix v4.6: proof of send
    } catch {
        Write-Host ("  telegram inline menu failed: " + $_.Exception.Message + " / " + [string]$_.ErrorDetails.Message) -ForegroundColor DarkYellow
        Write-Host ("  rejected body was: " + $body) -ForegroundColor DarkGray   # fleet fix v4.6: the exact payload lands in overseer.log
        Send-OverseerTelegram $text   # fleet fix v4.5: never lose the message to bad markup
    }
}
function Get-WorkerInlineMenu($fleet) {
    # fleet fix v3.3: the floating bar - worker row (up to 4 wide) + utilities
    $rows = New-Object System.Collections.ArrayList
    $row = New-Object System.Collections.ArrayList
    foreach ($w in @($fleet)) {
        if ($row.Count -ge 4) { [void]$rows.Add($row.ToArray()); $row = New-Object System.Collections.ArrayList }
        [void]$row.Add(@{ text = $w.name; callback_data = ("w:" + $w.id) })
    }
    if ($row.Count -gt 0) { [void]$rows.Add($row.ToArray()) }
    [void]$rows.Add(@(@{ text = "Refresh"; callback_data = "menu:detect" }, @{ text = "Status all"; callback_data = "menu:status" }))
    return $rows
}
function Get-WorkerInlineCommandMenu([string]$id, [string]$name) {
    # fleet fix v3.3: vertical option stack per worker
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add(@(@{ text = ("Message " + $name); callback_data = ("msg:" + $id) }))
    [void]$rows.Add(@(@{ text = ("Next " + $name); callback_data = ("next:" + $id) }))
    [void]$rows.Add(@(@{ text = ("Status " + $name); callback_data = ("doing:" + $id) }))
    [void]$rows.Add(@(@{ text = ("Interrupt " + $name); callback_data = ("int:" + $id) }))
    [void]$rows.Add(@(@{ text = "Back"; callback_data = "menu:main" }))
    return $rows
}
function Update-FleetDashboard($fleet, [switch]$Force) {
    # fleet fix v4.1: the pinned live status board. Crash-proof (a failure here
    # can never kill the main loop), throttle-bypassable with -Force, reposts in
    # the SAME call when the pinned copy is gone, and tells the console what it
    # did so the board is never silently absent again.
    try {
        if (@($fleet).Count -eq 0) { return }
        if (-not $Force -and $script:dashLastUpdate -and ((Get-Date) - $script:dashLastUpdate).TotalSeconds -lt 3) { return }

        $lines = @()
        foreach ($w in @($fleet)) {
            $d = $null
            try { $d = Get-WorkerDoing $w -TimeoutSec 6 } catch {}   # fleet fix v4.6: a hung worker must not stall the board
            if ($d) {
                $state = if ($d.busy) { "busy" } else { "idle" }
                $for = ""
                if ($d.sinceMs -and [long]$d.sinceMs -gt 0) {
                    try {
                        $ms = [long]$d.sinceMs
                        if ($ms -lt 100000000000) { $ms = $ms * 1000 }
                        $span = [DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds($ms)
                        if ($span.TotalHours -ge 1) { $for = (" " + [int]$span.TotalHours + "h " + $span.Minutes + "m") }
                        elseif ($span.TotalMinutes -ge 1) { $for = (" " + [int]$span.TotalMinutes + "m") }
                        else { $for = (" " + [Math]::Max(0, [int]$span.TotalSeconds) + "s") }
                    } catch {}
                }
                $lines += ($w.name + " - " + $state + $for)
            } else {
                $lines += ($w.name + " - unreachable")
            }
        }
        $text = "fleet status (live):`n" + ($lines -join "`n") + "`nupdated " + (Get-Date -Format HH:mm:ss)
        if (-not $Force -and $text -eq $script:dashLastText) { return }
        $script:dashLastUpdate = Get-Date

        if (-not $script:dashMsgId) {
            try {
                $c = Invoke-RestMethod -Method Get -Uri ("https://api.telegram.org/bot" + $token + "/getChat?chat_id=" + $chatId) -TimeoutSec 15
                $pm = $c.result.pinned_message
                if ($pm -and [string]$pm.text -match '^fleet status') { $script:dashMsgId = [long]$pm.message_id }
            } catch {}
        }

        if ($script:dashMsgId) {
            $eBody = @{ chat_id = $chatId; message_id = $script:dashMsgId; text = $text } | ConvertTo-Json -Depth 6
            try {
                [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/editMessageText") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($eBody)) -TimeoutSec 15)
                $script:dashLastText = $text
                return
            } catch {
                $em = ""; if ($_.ErrorDetails) { $em = [string]$_.ErrorDetails.Message }
                if ($em -match 'not modified') { $script:dashLastText = $text; return }
                if ($em -match 'message to edit not found|message_id_invalid|chat not found|message to pin') {
                    $script:dashMsgId = $null   # genuinely gone - fall through and repost now
                } else {
                    Write-Host ("  dashboard edit skipped (transient): " + $em) -ForegroundColor DarkYellow
                    return   # transient - next cycle retries the edit
                }
            }
        }

        $sBody = @{ chat_id = $chatId; text = $text } | ConvertTo-Json -Depth 6
        $r = Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/sendMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($sBody)) -TimeoutSec 15
        if ($r -and $r.result -and $r.result.message_id) {
            $script:dashMsgId = [long]$r.result.message_id
            $script:dashLastText = $text
            $pBody = @{ chat_id = $chatId; message_id = $script:dashMsgId; disable_notification = $true } | ConvertTo-Json
            try { [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/pinChatMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($pBody)) -TimeoutSec 15) } catch {}
            Write-Host ("  dashboard posted + pinned (msg " + $script:dashMsgId + ")") -ForegroundColor DarkGray
        }
    } catch {
        Write-Host ("  dashboard update failed: " + $_.Exception.Message) -ForegroundColor DarkYellow
    }
}
function Get-OverseerUpdates([long]$offset) {
    try {
        $r = Invoke-RestMethod -Method Get -Uri ("https://api.telegram.org/bot" + $token + "/getUpdates?timeout=0&offset=" + $offset) -TimeoutSec 15
        return $r.result
    } catch { return @() }
}
function Invoke-OverseerSummary([string]$workerText, [string]$who) {
    $sys = "You rewrite a worker agent's latest reply for the operator's Telegram chat. Plain English, short labeled lines, no jargon, no markdown, no filler. The worker follows a plan broken into phases; its reply says what it did and what comes next. Output EXACTLY these lines, in this order, nothing else: CHANGED: one or two plain sentences - what the worker actually did, built, or fixed this round; name real files, commands, or results when the reply mentions them. NEXT: what is left to do - the next phase or remaining plan items; if the worker is blocked or waiting for direction, say what it is waiting for; if the plan is finished, say plan complete. NEEDS YOU: include this line ONLY when the worker is blocked, errored, or needs a decision - one plain sentence on exactly what is needed from the operator. SUGGESTION: the single most useful short message the operator could send back verbatim, e.g. implement phase 14, or run the tests, or fix the failing validation; write exactly none needed if there is nothing useful to send. Never invent facts, progress, or blockers. If the reply is only a question or acknowledgement, CHANGED says so, NEXT says what you can tell, SUGGESTION answers it or says none needed.";
    # fleet fix v3.6: hard cap - huge replies were failing the summary call
    if ($workerText.Length -gt 12000) { $workerText = $workerText.Substring(0, 12000) + "`n[...trimmed]" }
    $body = @{ model = ($Model -replace "^minimax/", ""); messages = @(@{ role = "system"; content = $sys }, @{ role = "user"; content = $workerText }); temperature = 0.2; max_tokens = 400 } | ConvertTo-Json -Depth 10
    $script:LastSummaryError = ""
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
        # fleet fix v3.7: MiniMax can answer HTTP 200 with an error envelope -
        # read base_resp so the real reason is never invisible
        if ($resp.base_resp -and [int]$resp.base_resp.status_code -ne 0) {
            $script:LastSummaryError = ("api code " + $resp.base_resp.status_code + " " + [string]$resp.base_resp.status_msg)
            Write-Host ("  summary rejected: " + $script:LastSummaryError) -ForegroundColor DarkYellow
            return $null
        }
        $t = [string]$resp.choices[0].message.content
        $t = [regex]::Replace($t, "(?s)<think>.*?</think>", "").Trim()
        if (-not $t) { $script:LastSummaryError = "empty answer from api" }
        if ($resp.usage) { Write-Host ("  (summary: " + $resp.usage.prompt_tokens + " in / " + $resp.usage.completion_tokens + " out)") -ForegroundColor DarkGray }
        return $t
    } catch {
        $em = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $em = [string]$_.ErrorDetails.Message }
        if ($em.Length -gt 100) { $em = $em.Substring(0, 100) + "..." }
        $script:LastSummaryError = $em
        Write-Host ("  API error body: " + $em) -ForegroundColor DarkYellow
        return $null
    }
}
function Send-WorkerText([string]$url, [string]$session, [string]$text) {
    # fleet fix v2.4: direct HTTP delivery to the opencode serve API with REAL
    # confirmation. The old CLI spawn (opencode run --attach ...) was fire-and-
    # forget: "sent to X" printed even when the subprocess died instantly with
    # its error discarded. Returns $true only when the server accepted the text.
    $flat = $text -replace "`r?`n", " "
    $body = @{ parts = @(@{ type = "text"; text = $flat }) } | ConvertTo-Json -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        [void](Invoke-RestMethod -Method Post -Uri ($url + "/session/" + $session + "/prompt_async") -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 10)
        return $true
    } catch {
        Write-Host ("  send failed (" + $url + "): " + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}
function Invoke-WorkerInterrupt([string]$url, [string]$session, [string]$advice) {
    try { [void](Invoke-RestMethod -Method Post -Uri ($url + "/session/" + $session + "/abort") -TimeoutSec 15) } catch {}
    Start-Sleep -Seconds 3
    $wrapped = "INTERRUPT FROM THE OPERATOR (this is not a new task - retain exactly where you were and what you had done): " + $advice + " Take this on board, briefly confirm what you will change, then continue your work with it applied."
    Send-WorkerText $url $session $wrapped
}
function Get-WorkerPort($wk) {
    # fleet fix v4.7: the port is the worker's identity - parse it off its url.
    if ([string]$wk.url -match ':(\d+)\s*$') { return [int]$Matches[1] }
    return 0
}
function Stop-WorkerProcess($wk) {
    # fleet fix v4.7: the overseer can kill an agent. The agent IS the process
    # listening on the worker's port - found via Get-NetTCPConnection, the one
    # network API already proven reliable on this machine (Find-LiveWorkers uses
    # it). No Win32_Process / WMI. Refuses to kill this overseer or system PIDs,
    # and names exactly what it killed.
    $port = Get-WorkerPort $wk
    if (-not $port) { return ($wk.name + ": no port known - cannot kill") }
    $kpid = 0
    try {
        $kpid = [int](@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty OwningProcess)[0])
    } catch {}
    if (-not $kpid -or $kpid -le 4) {
        return ($wk.name + ": nothing is listening on port " + $port + " - that agent already looks dead. /detect to rescan")
    }
    if ($kpid -eq $PID) { return ($wk.name + ": REFUSED - port " + $port + " belongs to this overseer process itself") }
    $pname = ""
    try { $pname = [string](Get-Process -Id $kpid -ErrorAction Stop).ProcessName }
    catch { return ($wk.name + ": listener PID " + $kpid + " on port " + $port + " vanished before the kill") }
    try {
        Stop-Process -Id $kpid -Force -ErrorAction Stop
        Write-Host ("  killed " + $wk.name + " serve process " + $pname + " (PID " + $kpid + ", port " + $port + ")") -ForegroundColor Yellow
        return ("killed " + $wk.name + "'s agent: " + $pname + " (PID " + $kpid + ", port " + $port + "). Its console window may stay open, but the agent is dead - /detect to rescan the fleet")
    } catch {
        return ($wk.name + ": kill failed for " + $pname + " (PID " + $kpid + "): " + $_.Exception.Message)
    }
}
function ConvertFrom-WorkerText([string]$s) {
    # fleet fix v3.6: strip <think> blocks (they flood relays and choke the
    # summary API) and repair PS 5.1 Latin-1 mojibake (â€ style) from UTF-8 APIs
    $s = [regex]::Replace($s, "(?s)<think>.*?</think>", "").Trim()
    if ($s -match 'â€|Ã.') {
        try { $s = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($s)) } catch {}
    }
    return $s
}
function Get-WorkerDoing($wk, [int]$TimeoutSec = 15) {   # fleet fix v4.6: dashboard polls cheap so a hung worker cannot stall the board
    # intent fix v2.1: strip think tags from the tail
    # fleet fix v3.9: also report WHEN the current state began (busy = last user
    # message created; idle = last assistant turn completed) and run the tail
    # through the mojibake/think cleaner.
    $msgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec $TimeoutSec
    $lastAny = $null; $lastAssistant = $null
    foreach ($mm in @($msgs)) {
        $role = [string]$mm.info.role
        if ($role) { $lastAny = $mm }
        if ($role -eq "assistant") { $lastAssistant = $mm }
    }
    $busy = ($lastAny -and [string]$lastAny.info.role -eq "user")
    $tail = ""
    $sinceMs = 0
    if ($lastAssistant) {
        $parts = @($lastAssistant.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
        $tail = ConvertFrom-WorkerText ($parts -join " ")
        $tail = ($tail -replace "\s+", " ").Trim()
        if ($tail.Length -gt 500) { $tail = $tail.Substring(0, 500) + "..." }
    }
    try {
        if ($busy -and $lastAny) {
            $sinceMs = [long]$lastAny.info.time.created
        } elseif ($lastAssistant) {
            $sinceMs = [long]$lastAssistant.info.time.completed
            if (-not $sinceMs) { $sinceMs = [long]$lastAssistant.info.time.created }
        }
    } catch {}
    return @{ busy = $busy; tail = $tail; sinceMs = $sinceMs }
}

function Invoke-WorkerQuery([string]$url, [string]$session, [string]$question, [string]$who) {
    try {
        $msgs = Invoke-RestMethod -Method Get -Uri ($url + "/session/" + $session + "/message") -TimeoutSec 20

        $history = @()

        foreach ($mm in @($msgs)) {
            $role = [string]$mm.info.role
            if (-not $role) { continue }

            $parts = @(
                $mm.parts |
                ForEach-Object { [string]$_.text } |
                Where-Object { $_ }
            )

            $text = ($parts -join "`n").Trim()
            if ($text) {
                $history += (($role.ToUpper()) + ": " + $text)
            }
        }

        $context = ($history -join "`n`n")

        if ($context.Length -gt 30000) {
            $context = $context.Substring($context.Length - 30000)
        }

        $sys = "You are the intelligence layer for the CICADA worker fleet. Answer the operator's question using ONLY the supplied worker session history. Be specific and factual. Distinguish completed work, current work, errors, blockers, and uncertainty. Do not invent anything. Worker: " + $who + ". Return a concise but useful answer."

        $body = @{
            model = ($Model -replace "^minimax/", "")
            messages = @(
                @{ role = "system"; content = $sys }
                @{ role = "user"; content = "OPERATOR QUESTION:`n" + $question + "`n`nWORKER SESSION:`n" + $context }
            )
            temperature = 0.1
            max_tokens = 1200
        } | ConvertTo-Json -Depth 10

        $resp = Invoke-RestMethod `
            -Method Post `
            -Uri "https://api.minimax.io/v1/chat/completions" `
            -Headers @{
                Authorization = ("Bearer " + $env:MINIMAX_API_KEY)
                "Content-Type" = "application/json; charset=utf-8"
            } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -TimeoutSec 120

        $answer = [string]$resp.choices[0].message.content
        $answer = [regex]::Replace($answer, "(?s)<think>.*?</think>", "").Trim()

        return $answer
    }
    catch {
        return $null
    }
}
function Invoke-IntentDecode([string]$text, [string]$rosterNames) {
    # intent fix v2.1: steer is the default for worker-bound messages
    $sys = "You are the command decoder for a worker-fleet overseer bot. The operator types free-form messages about workers identified by callsigns. Decode into a JSON object with exactly these keys: action (one of: interrupt, steer, query, doing, status, fleet, detect, none), target (the worker callsign mentioned, or empty string), text (the message to deliver, or empty string). Rules: steer = the message is FOR the worker to act on - an instruction, a task, or a question the worker itself should answer in its next turn (examples: ask alpha whats next to implement, tell bravo to run the tests, get charlie to fix the gate, alpha do phase 7). Put the operator's actual instruction in text, phrased as a message to the worker, minus the leading callsign/ask/tell phrasing. doing = ONLY a live state check (is X busy right now, what is X mid-way through) - never a question the worker should answer. query = the operator wants YOU to answer from the worker's session history WITHOUT messaging it (what did X finish, why did X fail). Golden rule: if the words could be typed into the worker's own console for it to act on, choose steer; when in doubt between steer and anything else, choose steer. interrupt = only when the operator explicitly wants to abort the worker's current in-flight turn. status/fleet = whole-fleet overview. detect = rescan for workers. none = not about the fleet at all. Live workers: " + $rosterNames + ". Reply with ONLY the JSON object - no markdown fences, no commentary."
    $body = @{ model = ($Model -replace "^minimax/", ""); messages = @(@{ role = "system"; content = $sys }, @{ role = "user"; content = $text }); temperature = 0; max_tokens = 200 } | ConvertTo-Json -Depth 10
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20
        $t = [string]$resp.choices[0].message.content
        $t = [regex]::Replace($t, "(?s)<think>.*?</think>", "").Trim()
        $t = $t -replace '(?s)^```(json)?', '' -replace '```\s*$', ''
        $t = $t.Trim()
        if ($resp.usage) { Write-Host ("  (decode: " + $resp.usage.prompt_tokens + " in / " + $resp.usage.completion_tokens + " out)") -ForegroundColor DarkGray }
        return ($t | ConvertFrom-Json)
    } catch {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host ("  decode API error: " + $_.ErrorDetails.Message) -ForegroundColor DarkYellow }
        return $null
    }
}

function Get-NewAssistantMessages {
    param(
        [Parameter(Mandatory=$true)]
        $Messages,

        [string]$AfterId
    )

    $found = @()
    $passed = [string]::IsNullOrEmpty($AfterId)

    foreach ($mm in @($Messages)) {
        if ([string]$mm.info.role -ne "assistant") {
            continue
        }

        $mid = [string]$mm.info.id
        if (-not $mid) {
            continue
        }

        if (-not $passed) {
            if ($mid -eq $AfterId) {
                $passed = $true
            }
            continue
        }

        $parts = @(
            $mm.parts |
            Where-Object { $_.type -eq "text" } |
            ForEach-Object { [string]$_.text } |
            Where-Object { $_ -and $_.Trim() }
        )

        $text = ($parts -join "`n").Trim()

        $found += @{
            id = $mid
            text = $text
        }
    }

    return @($found)
}
function Find-LiveWorkers {
    # fleet fix v4.2: detection is now pure TCP+HTTP. The per-scan CIM process
    # enumeration (an advisory orphan tag) could hang
    # for minutes on a stressed WMI service and take /detect down with it -
    # gone. Newest worker session per port, one log line per stale port,
    # session dedupe, every call timeout-bounded.
    $found = @()

    $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.LocalAddress -eq "127.0.0.1" -or $_.LocalAddress -eq "::1" -or $_.LocalAddress -eq "0.0.0.0") -and   # fleet fix v4.6: catch workers bound to any/ipv6 loopback too
            $_.LocalPort -ge 4311 -and
            $_.LocalPort -le 4320
        } |
        Sort-Object LocalPort -Unique

    foreach ($conn in @($ports)) {
        $port = [int]$conn.LocalPort
        $url = "http://127.0.0.1:" + $port

        try {
            $sessions = Invoke-RestMethod `
                -Method Get `
                -Uri ($url + "/session") `
                -TimeoutSec 2

            $newest = @(
                $sessions |
                Where-Object { [string]$_.title -match '^worker-\d+$' } |
                Sort-Object { [long]$_.time.updated } -Descending |
                Select-Object -First 1
            )

            if ($newest.Count -eq 0) { continue }
            $sess = $newest[0]

            # fleet fix v4.4: a live serve IS a live worker - never skip on
            # session age. Idle time is logged for information only.
            $ageHours = 999
            try {
                $updMs = [long]$sess.time.updated
                if ($updMs -lt 100000000000) { $updMs = $updMs * 1000 }
                $ageHours = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds($updMs)).TotalHours
            } catch {}
            Write-Host ("  detect: port " + $port + " worker session idle " + [math]::Round($ageHours, 1) + "h - adopted") -ForegroundColor DarkGray

            $found += @{
                id = "pending"
                name = ""
                url = $url
                session = [string]$sess.id
                project = [string]$sess.directory
            }
        }
        catch {}
    }

    $seen = @{}
    $bySession = @()
    foreach ($fw in $found) {
        $sid = [string]$fw.session
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        $bySession += $fw
    }
    $seq = 0
    foreach ($fw in $bySession) {
        $seq++
        $fw.id = [string]$seq
        $fw.name = (Get-Callsign $fw.id)
    }
    return $bySession
}
function Resolve-WorkerTarget([string]$target, $fleet) {
    return ($fleet | Where-Object { $_.id -eq $target -or $_.name -ieq $target } | Select-Object -First 1)
}
function Get-FleetRoster($fleet) {
    if (-not $fleet -or $fleet.Count -eq 0) {
        return "no live workers detected - start some consoles, then /detect again."
    }

    $roster = @()

    foreach ($w in $fleet) {
        $project = ""

        if ($w.session) {
            try {
                $sessions = Invoke-RestMethod `
                    -Method Get `
                    -Uri ($w.url + "/session") `
                    -TimeoutSec 5

                $sess = $sessions |
                    Where-Object { [string]$_.id -eq [string]$w.session } |
                    Select-Object -First 1

                if ($sess) {
                    $project = [string]$sess.directory
                }
            }
            catch {}
        }

        $roster += (
            $w.name +
            "  [" +
            $project +
            "]  (" +
            $w.url +
            ", session " +
            $w.session +
            ")"
        )
    }

    return (
        "fleet: " +
        $fleet.Count +
        " worker(s):`n" +
        ($roster -join "`n")
    )
}
try { $host.UI.RawUI.WindowTitle = "CICADA overseer (Telegram)" } catch {}
Write-Host ("overseer v4.7 live (poll " + $PollSeconds + "s) - /detect /fleet /status /doing <name> /interrupt <name> <advice>") -ForegroundColor Cyan
Write-Host "  workers are Alpha, Bravo, Charlie... by detection order. answer yes to send a suggestion, '<name>: <text>' to steer. Ctrl+C to stop." -ForegroundColor DarkGray
Send-OverseerTelegram ("overseer v4.7 online (PID " + $PID + "). Shorthand: /<letter><action> - /am message Alpha, /as status, /an next, /ai interrupt, /ak kill Alpha (b/c/d = Bravo/Charlie/Delta). /detect adopts the fleet; /menu = cheat sheet.")
Remove-OverseerPinnedMenu   # fleet fix v3.1: clear any stale pinned menu
Send-OverseerKeyboardRemove "keyboards off - shorthand: /am message Alpha, /bs status, /cn next, /di interrupt (/menu for help)"   # fleet fix v3.4

$detectedWorkers = @()
$lastHash = @{}
$lastSuggested = @{}
$lastRelayedWorker = $null
$pendingMsgFor = $null   # v2.6: message-mode worker id (button-driven)
$pendingIntFor = $null   # v2.6: interrupt-advice-mode worker id
$stablePolls = @{}          # v3.8: streaming-stability counter per worker
$pendingStreamHash = @{}    # v3.8: last seen streaming hash per worker
$dashMsgId = $null          # v3.8: pinned dashboard message id
$dashLastText = ""          # v3.8: last dashboard text (change detection)
$dashLastUpdate = $null     # v3.8: dashboard throttle clock
$tgOffset = 0

# fleet fix v4.6: NEVER replay the update backlog. Telegram keeps unconfirmed
# updates for 24h; starting at offset 0 re-executed up to 100 old commands
# on every restart - including stale steers/interrupts being SENT TO WORKERS
# again. offset -1 confirms everything pending; we listen from right now.
try {
    $blResp = Invoke-RestMethod -Method Get -Uri ("https://api.telegram.org/bot" + $token + "/getUpdates?timeout=0&offset=-1") -TimeoutSec 15
    $backlog = @($blResp.result)
    if ($backlog.Count -gt 0) {
        $tgOffset = [long]$backlog[$backlog.Count - 1].update_id + 1
        Write-Host ("startup: dropped " + $backlog.Count + " stale telegram update(s) - listening from now") -ForegroundColor DarkGray
    }
} catch {}
$workers = @()

# fleet: optional startup auto-detect - wait for consoles to boot, adopt every
# live worker, baseline quietly (no history replay), post the roster to Telegram.
if ($AutoDetect) {
    # fleet fix v2.3: single scan - no startup stall. Telegram listens from
    # the first second; /detect rescans anytime (it is fast now).
    $detectedWorkers = Find-LiveWorkers
    $workers = @($detectedWorkers)
    $lastHash = @{}
    foreach ($wk in @($workers)) {
        if (-not $wk.session) { continue }
        try {
            $pMsgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 8
            $pLast = $null
            foreach ($pm in @($pMsgs)) { if ([string]$pm.info.role -eq "assistant") { $pLast = $pm } }
            if ($pLast) {
                $pParts = @($pLast.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
                $pText = ConvertFrom-WorkerText ($pParts -join "`n")
                if ($pText) {
                    $pHashInput = $pText.Length.ToString() + ":" + $pText.Substring(0, [Math]::Min(64, $pText.Length))
                    $lastHash[$wk.id] = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pHashInput))
                }
            }
        } catch {}
    }
    if ($workers.Count -eq 0) {
        Send-OverseerTelegram "auto-detect: no live workers found yet - a worker appears once its console sends its first task; /detect anytime to adopt later ones."
    } else {
        Send-OverseerInlineMenu ("auto-adopted " + $workers.Count + " worker(s) - watching:`n" + (Get-FleetRoster $workers)) @(@(@{ text = "Fleet status (live)"; callback_data = "menu:dash" }))
        Update-FleetDashboard $workers -Force   # fleet fix v4.1: pin the live board at startup
    }
}

while ($true) {

    # ========================================================
    # TELEGRAM FIRST
    #
    # Workers begin empty.
    # ONLY /detect explicitly adopts workers.
    # The state file is NOT used to resurrect workers.
    # ========================================================

    $updates = Get-OverseerUpdates $tgOffset

    foreach ($u in @($updates)) {
        $tgOffset = [long]$u.update_id + 1

        # fleet fix v2.6: button taps arrive as callback_query, not message.
        if ($u.callback_query) {
            $cb = $u.callback_query
            $cbData = [string]$cb.data
            Send-OverseerAnswerCallback ([string]$cb.id)
            if ($cbData -eq "menu:main") {
                if (@($workers).Count -gt 0) { Send-OverseerTelegram "shorthand: /<letter><action> - m message, s status, n next, i interrupt, k kill (e.g. /am, /bs, /ak) - /menu for help" }
                else { Send-OverseerTelegram "no adopted workers - /detect first." }
                continue
            }
            elseif ($cbData -eq "menu:detect") { $txt = "/detect" }
            elseif ($cbData -eq "menu:status") { $txt = "/status" }
            elseif ($cbData -match '^w:(\d+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr) {
                    $wl = $wkr.name.Substring(0, 1).ToLower()
                    Send-OverseerTelegram ($wkr.name + " shorthand: /" + $wl + "m message, /" + $wl + "s status, /" + $wl + "n next, /" + $wl + "i interrupt, /" + $wl + "k kill")
                }
                else { Send-OverseerTelegram "that menu is stale - /menu for a fresh one" }
                continue
            }
            elseif ($cbData -match '^msg:(\d+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) {
                    $pendingIntFor = $null
                    $pendingMsgFor = $wkr.id
                    Send-OverseerTelegram ("message mode: " + $wkr.name + " - your next typed message goes straight to it, no /prompt needed. /cancel to abort")
                } else { Send-OverseerTelegram "that menu is stale - /menu for a fresh one" }
                continue
            }
            elseif ($cbData -match '^int:(\d+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) {
                    $pendingMsgFor = $null
                    $pendingIntFor = $wkr.id
                    Send-OverseerTelegram ("interrupt mode: " + $wkr.name + " - your next typed message becomes the interrupt advice. /cancel to abort")
                } else { Send-OverseerTelegram "that menu is stale - /menu for a fresh one" }
                continue
            }
            elseif ($cbData -match '^doing:(\d+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) {
                    try {
                        $d = Get-WorkerDoing $wkr
                        $state = if ($d.busy) { "busy" } else { "idle" }
                        $brief = [string]$d.tail
                        if ($brief.Length -gt 200) { $brief = $brief.Substring(0, 200) + "..." }
                        Send-OverseerTelegram ($wkr.name + " - " + $state + " - " + $brief)
                    } catch { Send-OverseerTelegram ($wkr.name + " - unreachable") }
                } else { Send-OverseerTelegram "that menu is stale - /menu for a fresh one" }
                continue
            }
            elseif ($cbData -match '^next:(\d+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) { $txt = "/prompt " + $wkr.name + " what is next to implement? answer in two or three short lines" }
                else { Send-OverseerTelegram "that menu is stale - /menu for a fresh one"; continue }
            }
            elseif ($cbData -match '^sugs:(\d+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                $sg = $null
                if ($wkr) { $sg = $lastSuggested[$wkr.id] }
                if ($wkr -and $wkr.session -and $sg -and $sg -notmatch '^none') {
                    $ok = Send-WorkerText $wkr.url $wkr.session $sg
                    if ($ok) { Send-OverseerTelegram ("sent suggestion to " + $wkr.name + ": " + $sg) }
                    else { Send-OverseerTelegram ("DELIVERY FAILED to " + $wkr.name + " - server rejected it") }
                } else { Send-OverseerTelegram "that suggestion is stale - nothing sent" }
                continue
            }
            elseif ($cbData -match '^sugn:(\d+)$') { continue }
            elseif ($cbData -eq "menu:dash") {
                # fleet fix v4.7: the button must SHOW something. It used to only
                # edit the pinned board (a silent no-op when the text was unchanged)
                # and answered with no toast - a click looked dead. Now it refreshes
                # the board AND replies with the live status in the chat.
                Update-FleetDashboard $workers -Force
                $txt = "/status"
            }
            else { continue }
        }
        else {
            $txt = [string]$u.message.text
        }
        if (-not $txt) { continue }

        # fleet fix v2.6: button-driven modes and menu command
        if ($txt -match '^/cancel') {
            $pendingMsgFor = $null
            $pendingIntFor = $null
            Send-OverseerTelegram "cancelled."
            continue
        }
        if ($txt -match '^/menu') {
            Send-OverseerTelegram "shorthand (case-insensitive): /<worker letter><action> - m message, s status, n next, i interrupt, k kill the agent process. Examples: /am message Alpha, /bs status Bravo, /cn next Charlie, /di interrupt Delta, /ak kill Alpha. Plain commands: /detect /fleet /status /doing <name> /prompt <name> <text> /interrupt <name> <advice> /kill <name> /killall"
            continue
        }

        # fleet fix v3.4: shorthand commands - /<worker letter><action letter>,
        # case-insensitive (PowerShell -match already is). No AI decode involved.
        if ($txt -match '^/ping') {
            Send-OverseerTelegram ("pong - overseer v4.7 alive (PID " + $PID + ", " + (Get-Date -Format HH:mm:ss) + ", " + $workers.Count + " worker(s))")   # fleet fix v4.3: instant liveness
            continue
        }
        if ($txt -match '^/([a-z])([a-z])(?:\s+(.+))?$') {   # v3.5: optional inline text, e.g. /am run the tests
            $wLetter = $Matches[1].ToLower()
            $cmdLetter = $Matches[2].ToLower()
            $extra = ""
            if ($Matches.Count -gt 3) { $extra = ([string]$Matches[3]).Trim() }
            $wkr = $null
            foreach ($w in @($workers)) {
                if ($w.name.Substring(0, 1).ToLower() -eq $wLetter) { $wkr = $w; break }
            }
            if (-not $wkr) {
                Send-OverseerTelegram ("no adopted worker starting with '" + $wLetter + "' - /detect first")
                continue
            }
            if ($cmdLetter -eq "m") {
                if ($extra) {
                    $ok = Send-WorkerText $wkr.url $wkr.session $extra
                    if ($ok) { Send-OverseerTelegram ("sent to " + $wkr.name + ": " + $extra) }
                    else { Send-OverseerTelegram ("DELIVERY FAILED to " + $wkr.name + " - server rejected it; see overseer console") }
                } else {
                    $pendingIntFor = $null
                    $pendingMsgFor = $wkr.id
                    Send-OverseerTelegram ("message mode: " + $wkr.name + " - your next typed message goes straight to it, no /prompt needed. /cancel to abort")
                }
                continue
            }
            elseif ($cmdLetter -eq "s") {
                try {
                    $d = Get-WorkerDoing $wkr
                    $state = if ($d.busy) { "busy" } else { "idle" }
                    $brief = [string]$d.tail
                    if ($brief.Length -gt 200) { $brief = $brief.Substring(0, 200) + "..." }
                    Send-OverseerTelegram ($wkr.name + " - " + $state + " - " + $brief)
                } catch { Send-OverseerTelegram ($wkr.name + " - unreachable") }
                continue
            }
            elseif ($cmdLetter -eq "i") {
                if ($extra) {
                    Invoke-WorkerInterrupt $wkr.url $wkr.session $extra
                    Send-OverseerTelegram ("interrupted " + $wkr.name + " with advice: " + $extra)
                } else {
                    $pendingMsgFor = $null
                    $pendingIntFor = $wkr.id
                    Send-OverseerTelegram ("interrupt mode: " + $wkr.name + " - your next typed message becomes the interrupt advice. /cancel to abort")
                }
                continue
            }
            elseif ($cmdLetter -eq "n") {
                if (-not $extra) { $extra = "whats next to implement? answer in two or three short lines" }
                $txt = "/prompt " + $wkr.name + " " + $extra
            }
            elseif ($cmdLetter -eq "k") {
                Send-OverseerTelegram (Stop-WorkerProcess $wkr)   # fleet fix v4.7: /ak kills Alpha's agent process
                continue
            }
            else {
                Send-OverseerTelegram ("unknown action '" + $cmdLetter + "' - use m (message), s (status), n (next), i (interrupt), k (kill), e.g. /am")
                continue
            }
        }
        # fleet fix v2.7: persistent-keyboard labels arrive as plain text.
        # Handles navigation labels first so they are never swallowed by a
        # pending message/interrupt mode.
        if ($txt -match '^(Back|Hide|Refresh|Status all)$' -or $txt -match '^(Message|Next|Status|Interrupt)\s+(\w+)$' -or @($workers | Where-Object { $_.name -ieq $txt }).Count -gt 0) {
            if ($txt -eq "Back") {
                $pendingMsgFor = $null; $pendingIntFor = $null
                if (@($workers).Count -gt 0) { Send-OverseerTelegram "shorthand: /<letter><action> - m message, s status, n next, i interrupt, k kill (e.g. /am, /bs, /ak) - /menu for help" }
                else { Send-OverseerTelegram "no adopted workers - /detect first." }
                continue
            }
            if ($txt -eq "Hide") {
                $pendingMsgFor = $null; $pendingIntFor = $null
                Send-OverseerKeyboardRemove "keyboard hidden - /menu brings it back"
                continue
            }
            if ($txt -eq "Refresh") { $txt = "/detect" }
            elseif ($txt -eq "Status all") { $txt = "/status" }
            elseif ($txt -match '^Message\s+(\w+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) {
                    $pendingIntFor = $null
                    $pendingMsgFor = $wkr.id
                    Send-OverseerTelegram ("message mode: " + $wkr.name + " - your next typed message goes straight to it, no /prompt needed. Back or /cancel to abort")
                } else { Send-OverseerTelegram ("no adopted worker '" + $Matches[1] + "' - /detect first") }
                continue
            }
            elseif ($txt -match '^Interrupt\s+(\w+)$') {
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) {
                    $pendingMsgFor = $null
                    $pendingIntFor = $wkr.id
                    Send-OverseerTelegram ("interrupt mode: " + $wkr.name + " - your next typed message becomes the interrupt advice. Back or /cancel to abort")
                } else { Send-OverseerTelegram ("no adopted worker '" + $Matches[1] + "' - /detect first") }
                continue
            }
            elseif ($txt -match '^Status\s+(\w+)$') {
                $pendingMsgFor = $null; $pendingIntFor = $null
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) {
                    try {
                        $d = Get-WorkerDoing $wkr
                        $state = if ($d.busy) { "busy" } else { "idle" }
                        $brief = [string]$d.tail
                        if ($brief.Length -gt 200) { $brief = $brief.Substring(0, 200) + "..." }
                        Send-OverseerTelegram ($wkr.name + " - " + $state + " - " + $brief)
                    } catch { Send-OverseerTelegram ($wkr.name + " - unreachable") }
                } else { Send-OverseerTelegram ("no adopted worker '" + $Matches[1] + "' - /detect first") }
                continue
            }
            elseif ($txt -match '^Next\s+(\w+)$') {
                $pendingMsgFor = $null; $pendingIntFor = $null
                $wkr = Resolve-WorkerTarget $Matches[1] $workers
                if ($wkr -and $wkr.session) {
                    $txt = "/prompt " + $wkr.name + " whats next to implement? answer in two or three short lines"
                } else { Send-OverseerTelegram ("no adopted worker '" + $Matches[1] + "' - /detect first"); continue }
            }
            else {
                $wkr = @($workers | Where-Object { $_.name -ieq $txt })[0]
                $pendingMsgFor = $null; $pendingIntFor = $null
                if ($wkr) {
                    $wl = $wkr.name.Substring(0, 1).ToLower()
                    Send-OverseerTelegram ($wkr.name + " shorthand: /" + $wl + "m message, /" + $wl + "s status, /" + $wl + "n next, /" + $wl + "i interrupt, /" + $wl + "k kill")
                }
                continue
            }
        }

        if ($pendingMsgFor -and $txt -notmatch '^/') {
            $wkr = Resolve-WorkerTarget $pendingMsgFor $workers
            $pendingMsgFor = $null
            if ($wkr -and $wkr.session) {
                $ok = Send-WorkerText $wkr.url $wkr.session $txt
                if ($ok) { Send-OverseerTelegram ("sent to " + $wkr.name + ": " + $txt) }
                else { Send-OverseerTelegram ("DELIVERY FAILED to " + $wkr.name + " - server rejected it; see overseer console") }
            } else { Send-OverseerTelegram "worker no longer adopted - /detect to rescan" }
            continue
        }
        if ($pendingIntFor -and $txt -notmatch '^/') {
            $wkr = Resolve-WorkerTarget $pendingIntFor $workers
            $pendingIntFor = $null
            if ($wkr -and $wkr.session) {
                Invoke-WorkerInterrupt $wkr.url $wkr.session $txt
                Send-OverseerTelegram ("interrupted " + $wkr.name + " with advice: " + $txt)
            } else { Send-OverseerTelegram "worker no longer adopted - /detect to rescan" }
            continue
        }

        # ----------------------------------------------------
        # /detect
        # ----------------------------------------------------

        if ($txt -match '^/detect') {

            $detectedWorkers = Find-LiveWorkers
            $workers = @($detectedWorkers)

            # Baseline the current assistant response for every
            # adopted worker. This prevents stale session output
            # from being immediately treated as a new reply.
            $lastHash = @{}

            # fleet fix: prime with the watch loop's hash format so adoption is
            # silent - only genuinely new replies relay from here on.
            foreach ($wk in @($workers)) {
                if (-not $wk.session) { continue }
                try {
                    $pMsgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 8
                    $pLast = $null
                    foreach ($pm in @($pMsgs)) { if ([string]$pm.info.role -eq "assistant") { $pLast = $pm } }
                    if ($pLast) {
                        $pParts = @($pLast.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
                        $pText = ConvertFrom-WorkerText ($pParts -join "`n")
                        if ($pText) {
                            $pHashInput = $pText.Length.ToString() + ":" + $pText.Substring(0, [Math]::Min(64, $pText.Length))
                            $lastHash[$wk.id] = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pHashInput))
                        }
                    }
                } catch {}
            }
            # fleet fix v2.3: adoption is SILENT. Baselines were primed above;
            # only replies that arrive AFTER this moment relay via the watch loop.

            if ($workers.Count -eq 0) {
                Send-OverseerTelegram "no live workers detected."
            }
            else {
                Send-OverseerInlineMenu (Get-FleetRoster $workers) @(@(@{ text = "Fleet status (live)"; callback_data = "menu:dash" }))
                Update-FleetDashboard $workers -Force   # fleet fix v4.1: refresh the board on adoption
            }

            continue
        }

        # ----------------------------------------------------
        # /fleet
        # ----------------------------------------------------

        if ($txt -match '^/fleet') {
            Send-OverseerTelegram (Get-FleetRoster $workers)
            continue
        }

        # ----------------------------------------------------
        # /status
        # ----------------------------------------------------

        if ($txt -match '^/status') {

            if (-not $workers -or $workers.Count -eq 0) {
                Send-OverseerTelegram "no adopted workers - /detect first."
                continue
            }

            $linesOut = @()

            foreach ($wk in @($workers)) {

                $d = $null

                try {
                    $d = Get-WorkerDoing $wk
                }
                catch {}

                if ($d) {

                    $state = if ($d.busy) {
                        "busy"
                    }
                    else {
                        "idle"
                    }

                    $brief = $d.tail

                    if ($brief.Length -gt 120) {
                        $brief = $brief.Substring(0, 120) + "..."
                    }

                    $linesOut += (
                        $wk.name +
                        " - " +
                        $state +
                        " - " +
                        $brief
                    )
                }
                else {
                    $linesOut += (
                        $wk.name +
                        " - unreachable"
                    )
                }
            }

            Send-OverseerTelegram ($linesOut -join "`n")
            continue
        }

        # ----------------------------------------------------
        # /doing
        # ----------------------------------------------------

        # /prompt <worker> <message>
        # Pure delivery layer: everything after the worker name
        # is sent directly to that worker's existing session.
        $promptMatch = [regex]::Match($txt, '(?is)^/prompt\s+(\w+)\s+(.+)$')

        if ($promptMatch.Success) {
            $target = $promptMatch.Groups[1].Value
            $message = $promptMatch.Groups[2].Value.Trim()
            $wk2 = Resolve-WorkerTarget $target $workers

            if (-not $wk2 -or -not $wk2.session) {
                Send-OverseerTelegram ("no adopted worker '" + $target + "' - /detect first")
                continue
            }

            $ok = Send-WorkerText $wk2.url $wk2.session $message

            Send-OverseerTelegram (
                $(if ($ok) { "sent directly to " } else { "DELIVERY FAILED to " }) +
                $wk2.name +
                " [" +
                $wk2.project +
                "]: " +
                $message
            )

            continue
        }
        $doingMatch = [regex]::Match(
            $txt,
            '(?i)^(?:/doing\s+(\w+)|what(?:''s|\s+is)\s+(\w+)\s+doing)'
        )

        if ($doingMatch.Success) {

            $target = $doingMatch.Groups[1].Value

            if (-not $target) {
                $target = $doingMatch.Groups[2].Value
            }

            $wk2 = Resolve-WorkerTarget $target $workers

            if (-not $wk2) {
                Send-OverseerTelegram (
                    "no adopted worker '" +
                    $target +
                    "' - /detect to scan"
                )

                continue
            }

            try {

                $d = Get-WorkerDoing $wk2

                $state = if ($d.busy) {
                    "is mid-turn right now"
                }
                else {
                    "is idle (last turn finished)"
                }

                $msg =
                    $wk2.name +
                    " " +
                    $state

                if ($d.tail) {
                    $msg += (
                        ". Last word from " +
                        $wk2.name +
                        ": " +
                        $d.tail
                    )
                }
                else {
                    $msg += " - nothing said yet."
                }

                Send-OverseerTelegram $msg
            }
            catch {

                Send-OverseerTelegram (
                    $wk2.name +
                    " did not answer - /detect to rescan"
                )
            }

            continue
        }

        # ----------------------------------------------------
        # /kill <worker>  and  /killall   (fleet fix v4.7: kill agent processes)
        # ----------------------------------------------------
        if ($txt -match '(?i)^/killall\s*$') {
            if (-not $workers -or $workers.Count -eq 0) {
                Send-OverseerTelegram "no adopted workers - /detect first."
                continue
            }
            $killLines = @()
            foreach ($wk3 in @($workers)) { $killLines += (Stop-WorkerProcess $wk3) }
            Send-OverseerTelegram ($killLines -join "`n")
            continue
        }
        if ($txt -match '(?i)^/kill\s+(\w+)\s*$') {
            $wk2 = Resolve-WorkerTarget $Matches[1] $workers
            if (-not $wk2) {
                Send-OverseerTelegram ("no adopted worker '" + $Matches[1] + "' - /detect to scan")
                continue
            }
            Send-OverseerTelegram (Stop-WorkerProcess $wk2)
            continue
        }

        # ----------------------------------------------------
        # /interrupt
        # ----------------------------------------------------

        $intMatch = [regex]::Match(
            $txt,
            '(?i)^(?:/interrupt\s+(\w+)\s+(.+)|interrupt\s+(\w+)\s*:?\s*(.+))$'
        )

        if ($intMatch.Success) {

            $target = $intMatch.Groups[1].Value
            $advice = $intMatch.Groups[2].Value

            if (-not $target) {
                $target = $intMatch.Groups[3].Value
                $advice = $intMatch.Groups[4].Value
            }

            $wk2 = Resolve-WorkerTarget $target $workers

            if (-not $wk2 -or -not $wk2.session) {

                Send-OverseerTelegram (
                    "no adopted worker '" +
                    $target +
                    "' - /detect to scan"
                )

                continue
            }

            Invoke-WorkerInterrupt `
                $wk2.url `
                $wk2.session `
                $advice

            Send-OverseerTelegram (
                "interrupted " +
                $wk2.name +
                " - advice sent into the same session: '" +
                $advice +
                "'"
            )

            continue
        }

        # ----------------------------------------------------
        # <name>: <message>
        # ----------------------------------------------------

        if ($txt -match '^(\w+)\s*:\s*(.+)$') {

            $target = $Matches[1]
            $body2 = $Matches[2].Trim()

            $wk2 = Resolve-WorkerTarget $target $workers

            if ($wk2 -and $wk2.session) {

                $ok = Send-WorkerText `
                    $wk2.url `
                    $wk2.session `
                    $body2

                Send-OverseerTelegram (
                    $(if ($ok) { "sent to " } else { "DELIVERY FAILED to " }) +
                    $wk2.name +
                    ": " +
                    $body2
                )
            }
            else {

                Send-OverseerTelegram (
                    "no adopted worker '" +
                    $target +
                    "' - nothing sent"
                )
            }

            continue
        }

        # ----------------------------------------------------
        # yes / y
        # ----------------------------------------------------

        if ($txt -match '^(yes|y)$' -and $lastRelayedWorker) {

            $wk2 =
                Resolve-WorkerTarget `
                    $lastRelayedWorker `
                    $workers

            $sug2 =
                $lastSuggested[$lastRelayedWorker]

            if (
                $wk2 -and
                $wk2.session -and
                $sug2 -and
                $sug2 -notmatch '^none needed'
            ) {

                $ok = Send-WorkerText `
                    $wk2.url `
                    $wk2.session `
                    $sug2

                Send-OverseerTelegram (
                    $(if ($ok) { "sent suggestion to " } else { "DELIVERY FAILED to " }) +
                    $wk2.name +
                    ": " +
                    $sug2
                )
            }
            else {

                Send-OverseerTelegram (
                    "nothing to send (no suggestion on the last relay)"
                )
            }

            continue
        }

        # ----------------------------------------------------
        # Free-form operator message
        # ----------------------------------------------------

        if ($txt -notmatch '^/') {

            $names =
                (
                    $workers |
                    ForEach-Object { $_.name }
                ) -join ", "

            $decoded =
                Invoke-IntentDecode `
                    $txt `
                    $names

            # fleet fix v2.5: never swallow a free-form message silently.
            if (-not $decoded) {
                Send-OverseerTelegram ("could not decode that - the decoder API failed or timed out (see overseer console). To send without the decoder: /prompt Alpha <message> or Alpha: <message>")
                continue
            }
            if (-not [string]$decoded.action -or [string]$decoded.action -eq "none") {
                Send-OverseerTelegram ("not recognised as a fleet command - nothing done. Direct send: /prompt Alpha <message>; commands: /detect /fleet /status /doing <name> /interrupt <name> <advice>")
                continue
            }

            if (
                $decoded -and
                [string]$decoded.action -and
                [string]$decoded.action -ne "none"
            ) {

                $act =
                    [string]$decoded.action

                $tgt =
                    [string]$decoded.target

                $body3 =
                    [string]$decoded.text

                $wk2 = $null

                if ($tgt) {
                    $wk2 =
                        Resolve-WorkerTarget `
                            $tgt `
                            $workers
                }

                if ($act -eq "interrupt") {

                    if ($wk2 -and $wk2.session) {

                        Invoke-WorkerInterrupt `
                            $wk2.url `
                            $wk2.session `
                            $body3

                        Send-OverseerTelegram (
                            "interrupted " +
                            $wk2.name +
                            ": '" +
                            $body3 +
                            "'"
                        )
                    }
                    else {

                        Send-OverseerTelegram (
                            "decoded an interrupt but no adopted worker matched"
                        )
                    }
                }
                elseif ($act -eq "query") {
                    if ($wk2 -and $wk2.session) {
                        $answer = Invoke-WorkerQuery $wk2.url $wk2.session $body3 $wk2.name
                        if ($answer) {
                            Send-OverseerTelegram ("[" + $wk2.name + "] " + $answer)
                        } else {
                            Send-OverseerTelegram ("could not query " + $wk2.name + " right now")
                        }
                    } else {
                        Send-OverseerTelegram "query decoded, but no matching adopted worker was found"
                    }
                }                elseif ($act -eq "steer") {

                    if ($wk2 -and $wk2.session) {

                        $ok = Send-WorkerText `
                            $wk2.url `
                            $wk2.session `
                            $body3

                        Send-OverseerTelegram (
                            $(if ($ok) { "sent to " } else { "DELIVERY FAILED to " }) +
                            $wk2.name +
                            ": " +
                            $body3
                        )
                    }
                    else {

                        Send-OverseerTelegram (
                            "decoded a message but no adopted worker matched"
                        )
                    }
                }
                elseif ($act -eq "doing") {

                    if ($wk2) {

                        try {

                            $d =
                                Get-WorkerDoing $wk2

                            $state = if ($d.busy) {
                                "is mid-turn right now"
                            }
                            else {
                                "is idle (last turn finished)"
                            }

                            $msg =
                                $wk2.name +
                                " " +
                                $state

                            if ($d.tail) {
                                $msg += (
                                    ". Last word: " +
                                    $d.tail
                                )
                            }

                            Send-OverseerTelegram $msg
                        }
                        catch {

                            Send-OverseerTelegram (
                                $wk2.name +
                                " did not answer - /detect to rescan"
                            )
                        }
                    }
                    else {

                        Send-OverseerTelegram (
                            "decoded a status question but no adopted worker matched"
                        )
                    }
                }
                elseif ($act -eq "fleet") {

                    Send-OverseerTelegram (
                        Get-FleetRoster $workers
                    )
                }
                elseif ($act -eq "detect") {

                    $detectedWorkers =
                        Find-LiveWorkers

                    $workers =
                        @($detectedWorkers)

                    # Baseline newly detected sessions.
                    $lastHash = @{}

                    foreach ($wk in @($workers)) {

                        if (-not $wk.session) {
                            continue
                        }

                        try {

                            $msgs =
                                Invoke-RestMethod `
                                    -Method Get `
                                    -Uri (
                                        $wk.url +
                                        "/session/" +
                                        $wk.session +
                                        "/message"
                                    ) `
                                    -TimeoutSec 15

                            $last = $null

                            foreach ($mm in @($msgs)) {

                                if (
                                    [string]$mm.info.role -eq
                                    "assistant"
                                ) {
                                    $last = $mm
                                }
                            }

                            if ($last) {

                                $parts = @(
                                    $last.parts |
                                    ForEach-Object {
                                        [string]$_.text
                                    } |
                                    Where-Object {
                                        $_
                                    }
                                )

                                $text =
                                    ($parts -join "`n").Trim()

                                if ($text) {

                                    $hashInput =
                                        $text.Length.ToString() +
                                        ":" +
                                        $text.Substring(
                                            0,
                                            [Math]::Min(
                                                64,
                                                $text.Length
                                            )
                                        )

                                    $lastHash[$wk.id] =
                                        [Convert]::ToBase64String(
                                            [System.Text.Encoding]::UTF8.GetBytes(
                                                $hashInput
                                            )
                                        )
                                }
                            }
                        }
                        catch {}
                    }

                    Send-OverseerTelegram (
                        Get-FleetRoster $workers
                    )
                }
                elseif ($act -eq "status") {

                    if (
                        -not $workers -or
                        $workers.Count -eq 0
                    ) {

                        Send-OverseerTelegram (
                            "no adopted workers - /detect first."
                        )
                    }
                    else {

                        $linesOut = @()

                        foreach ($wk in @($workers)) {

                            $d = $null

                            try {
                                $d =
                                    Get-WorkerDoing $wk
                            }
                            catch {}

                            if ($d) {

                                $state = if ($d.busy) {
                                    "busy"
                                }
                                else {
                                    "idle"
                                }

                                $brief =
                                    $d.tail

                                if (
                                    $brief.Length -gt 120
                                ) {
                                    $brief =
                                        $brief.Substring(
                                            0,
                                            120
                                        ) +
                                        "..."
                                }

                                $linesOut += (
                                    $wk.name +
                                    " - " +
                                    $state +
                                    " - " +
                                    $brief
                                )
                            }
                            else {

                                $linesOut += (
                                    $wk.name +
                                    " - unreachable"
                                )
                            }
                        }

                        Send-OverseerTelegram (
                            $linesOut -join "`n"
                        )
                    }
                }
            }

            continue
        }
    }

    # ========================================================
    # WORKER WATCH
    #
    # This executes ONLY for workers previously adopted by
    # /detect. No automatic discovery occurs here.
    # ========================================================

    foreach ($wk in @($workers)) {

        if (-not $wk.session) {
            continue
        }

        try {

            $msgs =
                Invoke-RestMethod `
                    -Method Get `
                    -Uri (
                        $wk.url +
                        "/session/" +
                        $wk.session +
                        "/message"
                    ) `
                    -TimeoutSec 8   # fleet fix v4.6: hung workers must not stall the poll loop

            $last = $null

            foreach ($mm in @($msgs)) {

                if (
                    [string]$mm.info.role -eq
                    "assistant"
                ) {
                    $last = $mm
                }
            }

            if (-not $last) {
                continue
            }

            $parts = @(
                $last.parts |
                ForEach-Object {
                    [string]$_.text
                } |
                Where-Object {
                    $_
                }
            )

            $text =
                ConvertFrom-WorkerText ($parts -join "`n")

            if (-not $text) {
                continue
            }

            $hashInput =
                $text.Length.ToString() +
                ":" +
                $text.Substring(
                    0,
                    [Math]::Min(
                        64,
                        $text.Length
                    )
                )

            $h =
                [Convert]::ToBase64String(
                    [System.Text.Encoding]::UTF8.GetBytes(
                        $hashInput
                    )
                )

            # fleet fix v3.8: ONE relay per completed turn. opencode stamps
            # info.time.completed when an assistant turn finishes; while it is
            # still streaming we wait. Fallback if a build never stamps it:
            # relay once the text has been stable for 6 polls.
            $isFinal = $false
            try { if ($last.info.time.completed) { $isFinal = $true } } catch {}

            if ($isFinal) {
                $stablePolls[$wk.id] = 0
                $pendingStreamHash[$wk.id] = ""
            } else {
                if ($pendingStreamHash[$wk.id] -eq $h) {
                    $stablePolls[$wk.id] = [int]$stablePolls[$wk.id] + 1
                } else {
                    $pendingStreamHash[$wk.id] = $h
                    $stablePolls[$wk.id] = 0
                }
                if ([int]$stablePolls[$wk.id] -lt 6) { continue }
            }

            # fleet fix v4.6: first sight BASELINES, never relays. If adoption
            # priming failed (hung worker), the old code relayed the worker's
            # entire last turn as if it were brand new.
            if (-not $lastHash.ContainsKey($wk.id)) { $lastHash[$wk.id] = $h; continue }

            if ($lastHash[$wk.id] -eq $h) {
                continue
            }

            Write-Host (
                "[" +
                (Get-Date -Format HH:mm:ss) +
                "] " +
                $wk.name +
                " turn finished (" +
                $text.Length +
                " chars) - summarizing"
            ) -ForegroundColor DarkGray

            $sum =
                Invoke-OverseerSummary `
                    $text `
                    $wk.name

            # fleet fix v2.4: never silently drop a reply. If the summarizer
            # fails, relay the raw text (truncated); mark seen only when there
            # is something to send.
            if (-not $sum) {
                # fleet fix v3.7: the tag now carries the actual failure reason
                $why = [string]$script:LastSummaryError
                if (-not $why) { $why = "no detail" }
                $sum = $text
                if ($sum.Length -gt 900) {
                    $sum = $sum.Substring(0, 900) + "`n...[truncated; summary: " + $why + "]"
                } else {
                    $sum = $sum + "`n[raw relay - summary: " + $why + "]"
                }
            }

            $lastHash[$wk.id] = $h

            $sug = ""

            $sm =
                [regex]::Match(
                    $sum,
                    '(?im)^SUGGESTION:\s*(.+)$'
                )

            if ($sm.Success) {
                $sug =
                    $sm.Groups[1].Value.Trim()
            }

            $lastSuggested[$wk.id] =
                $sug

            $lastRelayedWorker =
                $wk.id

            $relay =
                "[" +
                $wk.name +
                " | " +
                $wk.project +
                "]`n" +
                $sum
            # fleet fix v3.8: one-tap suggestion buttons on the relay
            if ($sug -and $sug -notmatch '^none') {
                # fleet fix v4.6: comma-pins the row - @(@(a,b)) flattens one pipeline level, arriving as two 1-button rows
                $sugRows = ,@(@{ text = "Send suggestion"; callback_data = ("sugs:" + $wk.id) }, @{ text = "Skip"; callback_data = ("sugn:" + $wk.id) })
                Send-OverseerInlineMenu $relay $sugRows
            } else {
                Send-OverseerTelegram $relay
            }
        }
        catch {

            Write-Host (
                "  " +
                $wk.name +
                " poll failed: " +
                $_.Exception.Message
            ) -ForegroundColor DarkYellow
        }
    }

    Update-FleetDashboard $workers   # fleet fix v3.8: live pinned status

    Write-OverseerLock   # fleet fix v4.3: heartbeat for the split-brain guard
    Start-Sleep -Seconds $PollSeconds
}
























