param(
    [string]$Project,
    [string]$StateFile = "",
    [string]$Model = "minimax/MiniMax-M2.7",
    [int]$PollSeconds = 2,
    [switch]$Yes
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
    $sys = "You are the concise operational briefing layer for a multi-agent system. Read the worker response and compress it into exactly three lines: STATE: describe the worker, project, or run itself. Never describe the user, their request, or the conversation. State the concrete answer, current status, progress, result, error, blocker, or outcome. DECISION: state only a real decision, conclusion, or substantive action taken by the worker; write none for questions, factual answers, acknowledgements, or routine observations. SUGGESTION: only include a next action when the worker explicitly identifies a blocker, unresolved issue, failed result, pending decision, or clearly required follow-up. Otherwise write exactly none needed. Never invent verification steps, commands, recommendations, or extra context. Be universal across coding, research, analysis, planning, execution, debugging, investigation, and general tasks. Preserve concrete details that matter: names, paths, files, commands, numbers, test results, errors, constraints, and conclusions. Do not invent facts, context, motives, progress, decisions, or advice. Do not describe the user or the conversation. Do not turn a simple factual answer into a narrative. Compress aggressively without losing operationally important information. Plain text only. No greetings, filler, repetition, generic recommendations, or footer.";
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
        $tail = (($parts -join " ") -replace "\s+", " ").Trim()
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
    $sys = "You are the command decoder for a worker-fleet overseer bot. The operator types free-form instructions. Decode into a JSON object with exactly these keys: action (one of: interrupt, steer, query, doing, status, fleet, detect, none), target (the worker callsign mentioned, or empty string), text (the advice or message to deliver to that worker, or empty string). interrupt = pause a worker mid-work with advice it must take on board while keeping its place. steer = send a worker a new instruction or message. doing = the operator asks what a worker is doing right now. status/fleet = the operator asks about the whole fleet. detect = rescan for workers. none = not a command at all. Live workers: " + $rosterNames + ". Reply with ONLY the JSON object - no markdown fences, no commentary."
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

        try {
            $sessions = Invoke-RestMethod `
                -Method Get `
                -Uri ($url + "/session") `
                -TimeoutSec 5

            $workerSession = @(
                $sessions |
                Where-Object {
                    [string]$_.title -match '^worker-\d+$'
                } |
                Sort-Object { [long]$_.time.updated } -Descending |
                Select-Object -First 1
            )

            if ($workerSession.Count -eq 0) {
                continue
            }

            $sess = $workerSession[0]

            $workerId = (
                [regex]::Match(
                    [string]$sess.title,
                    '^worker-(\d+)$'
                )
            ).Groups[1].Value

            if (-not $workerId) {
                continue
            }

            $found += @{
                id = $workerId
                name = (Get-Callsign $workerId)
                url = $url
                session = [string]$sess.id
                project = [string]$sess.directory
            }
        }
        catch {}
    }

    return @(
        $found |
        Sort-Object { [int]$_.id } -Unique
    )
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
Write-Host ("overseer live (poll " + $PollSeconds + "s) - /detect /fleet /status /doing <name> /interrupt <name> <advice>") -ForegroundColor Cyan
Write-Host "  workers are Alpha, Bravo, Charlie... by detection order. answer yes to send a suggestion, '<name>: <text>' to steer. Ctrl+C to stop." -ForegroundColor DarkGray
Send-OverseerTelegram "overseer online - /detect adopts the fleet; /status /doing <name> /interrupt <name> <advice> work too."

$detectedWorkers = @()
$lastHash = @{}
$lastSuggested = @{}
$lastRelayedWorker = $null
$tgOffset = 0
$workers = @()

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
























