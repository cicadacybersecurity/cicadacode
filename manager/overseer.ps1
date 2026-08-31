param(
    [string]$Project,
    [string]$StateFile = "",
    [string]$Model = "minimax/MiniMax-M2.7",
    [int]$PollSeconds = 2,
    [switch]$Yes,
    [switch]$AutoDetect,
    [int]$ExpectWorkers = 0,
    [int]$AutoDetectTimeoutSec = 180,
    [double]$MaxSessionAgeHours = 6
)
# overseer.ps1 - the Telegram manager for the parallel worker fleet.
# v5: free-form messages are decoded by the cheap model into actions; v4's
# detection, callsigns, summary relay, and yes/custom routing.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "engine.ps1")
Import-CicadaSecrets

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
    $body = @{ chat_id = $chatId; text = $text } | ConvertTo-Json
    try {
        [void](Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $token + "/sendMessage") -Headers @{ "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30)
    } catch { Write-Host ("  telegram send failed: " + $_.Exception.Message) -ForegroundColor DarkYellow }
}
function Get-OverseerUpdates([long]$offset) {
    try {
        $r = Invoke-RestMethod -Method Get -Uri ("https://api.telegram.org/bot" + $token + "/getUpdates?timeout=0&offset=" + $offset) -TimeoutSec 15
        return $r.result
    } catch { return @() }
}
function Invoke-OverseerSummary([string]$workerText, [string]$who) {
    $sys = "You rewrite a worker agent's latest reply for the operator's Telegram chat. Plain English, short labeled lines, no jargon, no markdown, no filler. The worker follows a plan broken into phases; its reply says what it did and what comes next. Output EXACTLY these lines, in this order, nothing else: CHANGED: one or two plain sentences - what the worker actually did, built, or fixed this round; name real files, commands, or results when the reply mentions them. NEXT: what is left to do - the next phase or remaining plan items; if the worker is blocked or waiting for direction, say what it is waiting for; if the plan is finished, say plan complete. NEEDS YOU: include this line ONLY when the worker is blocked, errored, or needs a decision - one plain sentence on exactly what is needed from the operator. SUGGESTION: the single most useful short message the operator could send back verbatim, e.g. implement phase 14, or run the tests, or fix the failing validation; write exactly none needed if there is nothing useful to send. Never invent facts, progress, or blockers. If the reply is only a question or acknowledgement, CHANGED says so, NEXT says what you can tell, SUGGESTION answers it or says none needed.";
    $body = @{ model = ($Model -replace "^minimax/", ""); messages = @(@{ role = "system"; content = $sys }, @{ role = "user"; content = $workerText }); temperature = 0.2; max_tokens = 400 } | ConvertTo-Json -Depth 10
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
        $t = [string]$resp.choices[0].message.content
        $t = [regex]::Replace($t, "(?s)<think>.*?</think>", "").Trim()
        if ($resp.usage) { Write-Host ("  (summary: " + $resp.usage.prompt_tokens + " in / " + $resp.usage.completion_tokens + " out)") -ForegroundColor DarkGray }
        return $t
    } catch {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host ("  API error body: " + $_.ErrorDetails.Message) -ForegroundColor DarkYellow }
        return $null
    }
}
function Send-WorkerText([string]$url, [string]$session, [string]$text) {
    $exe = Resolve-OpenCodeExe
    $logf = Join-Path $env:TEMP ("overseer-send-" + [guid]::NewGuid().ToString("n") + ".log")
    $flat = $text -replace "`r?`n", " "
    Start-Process -FilePath $exe -ArgumentList @("run", "--attach", $url, "--session", $session, "--", $flat) -WindowStyle Hidden -RedirectStandardOutput $logf
}
function Invoke-WorkerInterrupt([string]$url, [string]$session, [string]$advice) {
    try { [void](Invoke-RestMethod -Method Post -Uri ($url + "/session/" + $session + "/abort") -TimeoutSec 15) } catch {}
    Start-Sleep -Seconds 3
    $wrapped = "INTERRUPT FROM THE OPERATOR (this is not a new task - retain exactly where you were and what you had done): " + $advice + " Take this on board, briefly confirm what you will change, then continue your work with it applied."
    Send-WorkerText $url $session $wrapped
}
function Get-WorkerDoing($wk) {
    # intent fix v2.1: strip think tags from the tail
    $msgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 15
    $lastAny = $null; $lastAssistant = $null
    foreach ($mm in @($msgs)) {
        $role = [string]$mm.info.role
        if ($role) { $lastAny = $mm }
        if ($role -eq "assistant") { $lastAssistant = $mm }
    }
    $busy = ($lastAny -and [string]$lastAny.info.role -eq "user")
    $tail = ""
    if ($lastAssistant) {
        $parts = @($lastAssistant.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
        $tail = [regex]::Replace(($parts -join " "), "(?s)<think>.*?</think>", "")
        $tail = ($tail -replace "\s+", " ").Trim()
        if ($tail.Length -gt 500) { $tail = $tail.Substring(0, 500) + "..." }
    }
    return @{ busy = $busy; tail = $tail }
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
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
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
    # fleet fix v2.1: opencode stores sessions per PROJECT, so every serve
    # instance of one project lists the same sessions. A worker's identity is
    # its SESSION, not its port - the same session on two ports is one worker
    # (first port wins; callsigns follow ascending port order).
    # Orphaned serves (console window closed, server still listening) are tagged
    # [zombie-server] but NEVER skipped: opencode's process tree makes parentage
    # unreliable, and a missed live worker is worse than an adopted zombie.
    # Sessions idle over $MaxSessionAgeHours are skipped as stale.
    $found = @()

    $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalAddress -eq "127.0.0.1" -and
            $_.LocalPort -ge 4311 -and
            $_.LocalPort -le 4320
        } |
        Sort-Object LocalPort -Unique

    foreach ($conn in @($ports)) {
        $port = [int]$conn.LocalPort
        $url = "http://127.0.0.1:" + $port

        $orphanNote = ""
        $owningProc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$conn.OwningProcess) -ErrorAction SilentlyContinue
        if ($owningProc) {
            $parentProc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $owningProc.ParentProcessId) -ErrorAction SilentlyContinue
            if (-not $parentProc) { $orphanNote = " [zombie-server]" }
        }

        try {
            $sessions = Invoke-RestMethod `
                -Method Get `
                -Uri ($url + "/session") `
                -TimeoutSec 5

            $workerSessions = @(
                $sessions |
                Where-Object {
                    [string]$_.title -match '^worker-\d+$'
                } |
                Sort-Object { [long]$_.time.updated } -Descending
            )

            foreach ($sess in $workerSessions) {
                $ageHours = 999
                try {
                    $updMs = [long]$sess.time.updated
                    if ($updMs -lt 100000000000) { $updMs = $updMs * 1000 }
                    $ageHours = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds($updMs)).TotalHours
                } catch {}
                if ($ageHours -gt $MaxSessionAgeHours) {
                    Write-Host ("  detect: skipping stale session on port " + $port + " (idle " + [math]::Round($ageHours, 1) + "h - raise -MaxSessionAgeHours to adopt it)") -ForegroundColor DarkGray
                    continue
                }
                $found += @{
                    id = "pending"
                    name = ""
                    url = $url
                    session = [string]$sess.id
                    project = ([string]$sess.directory + $orphanNote)
                }
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
Write-Host ("overseer live (poll " + $PollSeconds + "s) - /detect /fleet /status /doing <name> /interrupt <name> <advice>") -ForegroundColor Cyan
Write-Host "  workers are Alpha, Bravo, Charlie... by detection order. answer yes to send a suggestion, '<name>: <text>' to steer. Ctrl+C to stop." -ForegroundColor DarkGray
Send-OverseerTelegram "overseer online - /detect adopts the fleet; /status /doing <name> /interrupt <name> <advice> work too."

$detectedWorkers = @()
$lastHash = @{}
$lastSuggested = @{}
$lastRelayedWorker = $null
$tgOffset = 0
$workers = @()

# fleet: optional startup auto-detect - wait for consoles to boot, adopt every
# live worker, baseline quietly (no history replay), post the roster to Telegram.
if ($AutoDetect) {
    $deadline = (Get-Date).AddSeconds($AutoDetectTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $detectedWorkers = Find-LiveWorkers
        $workers = @($detectedWorkers)
        if ($ExpectWorkers -gt 0 -and $workers.Count -ge $ExpectWorkers) { break }
        if ($ExpectWorkers -le 0 -and $workers.Count -gt 0) { break }
        Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
    }
    $lastHash = @{}
    foreach ($wk in @($workers)) {
        if (-not $wk.session) { continue }
        try {
            $pMsgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 15
            $pLast = $null
            foreach ($pm in @($pMsgs)) { if ([string]$pm.info.role -eq "assistant") { $pLast = $pm } }
            if ($pLast) {
                $pParts = @($pLast.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
                $pText = ($pParts -join "`n").Trim()
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
        Send-OverseerTelegram ("auto-adopted " + $workers.Count + " worker(s) - watching:`n" + (Get-FleetRoster $workers))
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
        $txt = [string]$u.message.text
        if (-not $txt) { continue }

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
                    $pMsgs = Invoke-RestMethod -Method Get -Uri ($wk.url + "/session/" + $wk.session + "/message") -TimeoutSec 15
                    $pLast = $null
                    foreach ($pm in @($pMsgs)) { if ([string]$pm.info.role -eq "assistant") { $pLast = $pm } }
                    if ($pLast) {
                        $pParts = @($pLast.parts | ForEach-Object { [string]$_.text } | Where-Object { $_ })
                        $pText = ($pParts -join "`n").Trim()
                        if ($pText) {
                            $pHashInput = $pText.Length.ToString() + ":" + $pText.Substring(0, [Math]::Min(64, $pText.Length))
                            $lastHash[$wk.id] = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pHashInput))
                        }
                    }
                } catch {}
            }
            foreach ($wk in @($workers)) {
                if (-not $wk.session) { continue }

                try {
                    $msgs = Invoke-RestMethod `
                        -Method Get `
                        -Uri ($wk.url + "/session/" + $wk.session + "/message") `
                        -TimeoutSec 15

                    $newMessages = Get-NewAssistantMessages $msgs $lastHash[$wk.id]

            foreach ($nm in @($newMessages)) {
                $lastHash[$wk.id] = $nm.id

                if (-not $nm.text) {
                    continue
                }

                Write-Host (
                    "[" +
                    (Get-Date -Format HH:mm:ss) +
                    "] " +
                    $wk.name +
                    " replied (" +
                    $nm.text.Length +
                    " chars) - summarizing"
                ) -ForegroundColor DarkGray

                $sum = Invoke-OverseerSummary $nm.text $wk.name

                if (-not $sum) {
                    continue
                }

                $relay =
                    "[" +
                    $wk.name +
                    " | " +
                    $wk.project +
                    "]`n" +
                    $sum

                Send-OverseerTelegram $relay
            }

            continue
            $last = $null

                    foreach ($mm in @($msgs)) {
                        if ([string]$mm.info.role -eq "assistant") {
                            $last = $mm
                        }
                    }

                    if ($last) {
                        $parts = @(
                            $last.parts |
                            ForEach-Object { [string]$_.text } |
                            Where-Object { $_ }
                        )

                        $text = ($parts -join "`n").Trim()

                        if ($text) {
                            $hashInput =
                                $text.Length.ToString() +
                                ":" +
                                $text.Substring(0, [Math]::Min(64, $text.Length))

                            $lastHash[$wk.id] =
                                [Convert]::ToBase64String(
                                    [System.Text.Encoding]::UTF8.GetBytes($hashInput)
                                )
                        }
                    }
                }
                catch {}
            }

            if ($workers.Count -eq 0) {
                Send-OverseerTelegram "no live workers detected."
            }
            else {
                Send-OverseerTelegram (Get-FleetRoster $workers)
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
                        "working"
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

            Send-WorkerText $wk2.url $wk2.session $message

            Send-OverseerTelegram (
                "sent directly to " +
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

                Send-WorkerText `
                    $wk2.url `
                    $wk2.session `
                    $body2

                Send-OverseerTelegram (
                    "sent to " +
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

                Send-WorkerText `
                    $wk2.url `
                    $wk2.session `
                    $sug2

                Send-OverseerTelegram (
                    "sent suggestion to " +
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

                        Send-WorkerText `
                            $wk2.url `
                            $wk2.session `
                            $body3

                        Send-OverseerTelegram (
                            "sent to " +
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
                                    "working"
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
                ($parts -join "`n").Trim()

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

            if ($lastHash[$wk.id] -eq $h) {
                continue
            }

            $lastHash[$wk.id] = $h

            Write-Host (
                "[" +
                (Get-Date -Format HH:mm:ss) +
                "] " +
                $wk.name +
                " replied (" +
                $text.Length +
                " chars) - summarizing"
            ) -ForegroundColor DarkGray

            $sum =
                Invoke-OverseerSummary `
                    $text `
                    $wk.name

            if (-not $sum) {
                continue
            }

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
            Send-OverseerTelegram $relay
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

    Start-Sleep -Seconds $PollSeconds
}
























