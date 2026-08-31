# consult.ps1 - CICADA consult mode: two models, eight conversation formats,
# one shared working document, one structured output contract per format.
# Via menu: .\agent.ps1 -> Consult (two models level up an idea)
# Direct:   .\manager\consult.ps1 -Idea "ideas\app.md" -Format software -ModelA m3 -ModelB m2.7 -Depth medium -Length standard -Label "lead-app v2" -Yes
#           -Idea    typed text or a path to a .md/.txt file (relative paths resolve from the current directory)
#           -Format  develop | software | general | debate | decide | brainstorm | redteam | interviewer
#           -Depth   small | medium | large | auto (converge-detect, small minimum, large cap) - or -Exchanges <n>
#           -Length  short (~150 words/turn) | standard (~300) | long (~500)
#           -Label   optional run name - used in the output folder, history log, and Telegram
#           -NoNotes skip the scribe (notes.md stays as the seeded template; saves one cheap turn per exchange)
# Mid-run:  press S between exchanges to inject an operator steering note.
#
# Run folder contents (state\consult\<stamp>[-label]\):
#   input.md         what you gave them
#   notes.md         the living working document - updated by the scribe after every exchange
#   transcript.md    the full conversation log, written after every exchange
#   FINAL.md         the human-readable deliverable - built primarily from notes.md
#   structured.json  the machine-readable deliverable - the transcript normalised into this
#                    format's output schema (validated JSON; feed it to other modes/scripts)
#
# Adding a new format = one new entry in the $formats table below (label, ask,
# depths, briefs, notes template, synthesis, schema).
param(
    [string]$Idea = "",
    [string]$Format = "",
    [string]$ModelA = "",
    [string]$ModelB = "",
    [string]$Depth = "",
    [string]$Length = "",
    [string]$Label = "",
    [string]$Project = "",
    [string]$Sub = "",
    [string]$Direction = "",
    [string]$Engine = "auto",
    [int]$Exchanges = 0,
    [switch]$NoNotes,
    [switch]$Yes
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root "manager\engine.ps1")
Import-CicadaSecrets
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # kill mojibake in model output

# Pin the config so opencode never falls through to the global cascade.
$ConfigPath = Join-Path $Root "minimax-opencode.json"
$env:OPENCODE_CONFIG = $ConfigPath

# ============================================================
# FORMAT TABLE. Each entry is a complete mode:
#   label      menu text
#   ask        what the human is prompted for
#   depths     @(Small, Medium, Large) exchange counts, tuned per format
#   briefA/B   full role definition for each seat (phase 1)
#   briefA2/B2 optional - role definitions for phase 2 (two-phase formats)
#   notes      the seeded template for notes.md (the shared working document)
#   synthesis  instructions for FINAL.md (human-readable)
#   schema     the normaliser's output contract for structured.json (strict JSON)
# ============================================================
$formats = [ordered]@{

    develop = [ordered]@{
        label  = "Develop an idea (two partners talk it through into a plan)"
        ask    = "Idea (type it, or paste a path to a .md/.txt file)"
        depths = @(3, 5, 8)
        notes  = "## The idea as it stands`n(nothing yet)`n`n## Decisions made`n(none yet)`n`n## Open questions`n(everything)"
        briefA = "ROLE: PARTNER A, the vision half of a two-AI product partnership. MISSION: with Partner B, turn the raw idea below into something concrete, exciting, and buildable - collaborators, not opponents. METHOD: 1) Anchor on the actual last message from Partner B - quote it, extend it, or question it. 2) Every turn, move one aspect forward: a feature, a user, a flow, a name, a constraint. 3) Ask exactly one question that forces a decision. 4) Chase the version genuinely worth building, not the polite version. BANNED: generic filler, adjectives instead of specifics, restating the prompt, re-opening what the WORKING NOTES record as settled. EVERY TURN MUST: respond first, advance the idea, end with the single next thing to nail down."
        briefB = "ROLE: PARTNER B, the execution half of a two-AI product partnership. MISSION: with Partner A, turn the raw idea below into something concrete and buildable - collaborators, not opponents. METHOD: 1) Anchor on the actual last message from Partner A - ground it or pressure-test it. 2) Every turn, make one part more real: how it gets built, sequenced, shipped, or used. 3) Answer the question from Partner A directly, then ask exactly one of your own that forces a decision. 4) Protect the idea from bloat - every feature must earn its place. BANNED: generic filler, cleverness over concreteness, restating the prompt, re-opening what the WORKING NOTES record as settled. EVERY TURN MUST: respond first, make something more concrete, end with the single next thing to nail down."
        synthesis = "Write the final, leveled-up plan as clean markdown with exactly these sections: # (a strong product name) / ## The pitch (2-3 sentences, the elevated version) / ## What the conversation added (vs the original idea) / ## Scope and feature set (decided) / ## Build plan (phased and concrete) / ## Open questions. Build it primarily from the WORKING NOTES - they hold the decisions; dip into the conversation only for context the notes miss. Do not introduce new scope."
        schema = '{"name": "product name", "pitch": "2-3 sentence elevated pitch", "added_by_conversation": ["things the conversation added vs the original idea"], "features_decided": ["decided features"], "build_plan": [{"phase": 1, "goal": "what this phase delivers", "items": ["concrete items"]}], "open_questions": ["unresolved questions"]}'
    }

    software = [ordered]@{
        label  = "Spec out software (two architects work out the full spec - plan, not code)"
        ask    = "Describe the software (text, or a path to a spec/notes file)"
        depths = @(4, 6, 10)
        notes  = "## Architecture decisions`n(none yet)`n`n## Data model`n(undecided)`n`n## API surface`n(undecided)`n`n## Tech choices`n(undecided)`n`n## Delivery sequence`n(undecided)`n`n## Open spec items`n(everything)"
        briefA = "ROLE: ARCHITECT A, the systems half of a two-architect software specification session. MISSION: together, produce a spec so complete a builder could start tomorrow without asking a question. No code - decisions. YOUR TERRITORY: architecture, components and boundaries, data model, storage, scaling, failure modes, technology choices. METHOD: 1) Respond to the actual last message from Architect B. 2) Every turn, close at least one open spec item in your territory - the decision, the options weighed, why this one wins. 3) When a library or tool choice matters, use web access to check what is real and current - never assert from memory what you can verify. 4) Flag anything underspecified and assign it an owner. BANNED: code, pseudocode, possibilities instead of decisions, contradicting the WORKING NOTES silently. EVERY TURN MUST: answer the open question, close one spec item, end with the next item to nail down."
        briefB = "ROLE: ARCHITECT B, the product-and-delivery half of a two-architect software specification session. MISSION: together, produce a spec so complete a builder could start tomorrow without asking a question. No code - decisions. YOUR TERRITORY: API surface, user experience and flows, delivery sequencing, milestones, build order. METHOD: 1) Respond to the actual last message from Architect A. 2) Every turn, close at least one open spec item in your territory - the decision, the options weighed, why this one wins. 3) When a library or service choice matters, use web access to check what is real and current. 4) Flag anything underspecified and assign it an owner. BANNED: code, pseudocode, API decisions without inputs and outputs, milestones without a demonstrable end state, contradicting the WORKING NOTES silently. EVERY TURN MUST: answer the open question, close one spec item, end with the next item to nail down."
        synthesis = "The spec session below is complete. Write the full software specification as clean markdown with exactly these sections: # (software name) / ## Overview (what it is, who it is for, 2-3 sentences) / ## Architecture (components and how they talk) / ## Data model / ## API surface / ## Tech choices (each with one-line justification) / ## Build plan (phased and concrete) / ## Risks and unknowns. Build it primarily from the WORKING NOTES - they hold the settled spec; dip into the conversation only for context the notes miss. Do not introduce new scope."
        schema = '{"name": "software name", "overview": "what it is and who it is for", "architecture": [{"component": "name", "responsibility": "what it owns", "talks_to": ["other components"]}], "data_model": [{"entity": "name", "fields": ["field: type"], "notes": "constraints/relations"}], "api_surface": [{"endpoint": "METHOD /path", "inputs": "what it takes", "outputs": "what it returns"}], "tech_choices": [{"choice": "library/tool", "for": "what it is for", "why": "one-line justification"}], "build_plan": [{"phase": 1, "goal": "what this phase delivers", "done_when": "the demonstrable end state"}], "risks": [{"risk": "what could go wrong", "severity": "low|medium|high", "mitigation": "how it is handled"}]}'
    }

    general = [ordered]@{
        label  = "General (talk anything through and land on a solution or answer)"
        ask    = "What should they figure out? (text, or a path to a file)"
        depths = @(2, 4, 6)
        notes  = "## What we agree on`n(nothing yet)`n`n## Key reasoning`n(none yet)`n`n## Where we differ`n(nothing yet)`n`n## Emerging answer`n(too early)"
        briefA = "ROLE: PARTNER A in a two-AI problem-solving conversation. MISSION: figure out the question below together and land on the best answer you can genuinely defend. No assigned lenses - two sharp minds, one team. METHOD: 1) Reframe the question first if the framing itself is the problem. 2) Explore the angles that matter: causes, incentives, second-order effects, who would disagree and why. 3) Respond to the actual reasoning from Partner B - extend it, sharpen it, or break it with something concrete. 4) Converge as the conversation matures: less exploring, more deciding. BANNED: filler, both-sides mush, restating the question, repeating what the WORKING NOTES already record. EVERY TURN MUST: respond first, then move the thinking forward."
        briefB = "ROLE: PARTNER B in a two-AI problem-solving conversation. MISSION: figure out the question below together and land on the best answer you can genuinely defend. No assigned lenses - two sharp minds, one team. METHOD: 1) Challenge weak reasoning constructively - show the exact crack and offer the fix. 2) Bring the untouched angle: the cost, the human factor, the failure case, the simple version. 3) Respond to the actual reasoning from Partner A, not a summary of it. 4) Converge as the conversation matures: less exploring, more deciding. BANNED: filler, both-sides mush, agreement as a turn (agree in one line and move), repeating what the WORKING NOTES already record. EVERY TURN MUST: respond first, then move the thinking forward."
        synthesis = "The conversation below is complete. Write up the outcome as clean markdown with exactly these sections: # The answer (the conclusion they landed on, stated directly) / ## How they got there (the reasoning that mattered) / ## Key considerations (what shaped the answer) / ## Caveats and open threads. Build it primarily from the WORKING NOTES; dip into the conversation only for context the notes miss."
        schema = '{"question": "what was asked", "answer": "the conclusion landed on", "reasoning": ["the reasoning steps that mattered"], "key_considerations": ["what shaped the answer"], "caveats": ["important caveats"], "open_threads": ["what was left open"]}'
    }

    debate = [ordered]@{
        label  = "Debate a question (strongest case for vs strongest case against, then a verdict)"
        ask    = "Question or claim to debate (text, or a path to a file)"
        depths = @(2, 3, 5)
        notes  = "## Points FOR that survived`n(none yet)`n`n## Points AGAINST that survived`n(none yet)`n`n## Conceded by the proponent`n(nothing)`n`n## Conceded by the challenger`n(nothing)`n`n## Contested ground`n(everything)"
        briefA = "ROLE: the PROPONENT in a formal two-AI debate on the claim below. MISSION: win the case FOR with the best arguments the position can honestly field. METHOD: 1) Open with your single strongest argument, not a list. 2) Every turn, name the weakest point in the ACTUAL last argument from the Challenger and break it. 3) Steelman your own side - never a caricature. 4) Concede a point when it is genuinely lost and pivot to ground you still hold. BANNED: strawmen, rhetoric over evidence-shaped reasoning, repeating an answered point, re-litigating what the WORKING NOTES record as lost. EVERY TURN MUST: answer the last opposing argument first, then advance your case."
        briefB = "ROLE: the CHALLENGER in a formal two-AI debate on the claim below. MISSION: win the case AGAINST with the best arguments the position can honestly field. METHOD: 1) Open with your single strongest objection, not a list. 2) Every turn, name the weakest point in the ACTUAL last argument from the Proponent and break it. 3) Steelman your own side - never a caricature. 4) Concede a point when it is genuinely lost and pivot to ground you still hold. BANNED: strawmen, vibes over evidence-shaped reasoning, repeating an answered point, re-litigating what the WORKING NOTES record as lost. EVERY TURN MUST: answer the last opposing argument first, then advance your case."
        synthesis = "You are the neutral judge of the debate below. Write the verdict as clean markdown with exactly these sections: # Verdict (FOR, AGAINST, or SPLIT - with one sentence why) / ## Strongest argument FOR / ## Strongest argument AGAINST / ## What the judge found decisive / ## What would flip the verdict. Judge only the arguments actually made; the WORKING NOTES record what survived."
        schema = '{"claim": "what was debated", "verdict": "FOR|AGAINST|SPLIT", "verdict_reason": "one sentence", "strongest_for": "the strongest surviving argument FOR", "strongest_against": "the strongest surviving argument AGAINST", "decisive_factors": ["what decided it"], "would_flip": ["what would change the verdict"], "points_for_survived": ["FOR points never beaten"], "points_against_survived": ["AGAINST points never beaten"]}'
    }

    decide = [ordered]@{
        label  = "Make a decision (options in -> they hash it out -> one recommendation)"
        ask    = "The decision and its options (text, or a path to a file)"
        depths = @(2, 3, 5)
        notes  = "## Options alive`n(all of them, so far)`n`n## Options killed (and why)`n(none yet)`n`n## Leaning history`n(no leanings yet)`n`n## Deciding factors`n(not yet identified)"
        briefA = "ROLE: DECISION PARTNER A, making the call below with your partner. MISSION: reach the RIGHT call, not YOUR call. YOUR LENS: payoff and risk - expected value, worst case, what is given up. METHOD: 1) State the options and kill any obviously dominated, saying why. 2) Every turn, engage the actual reasoning from Partner B - if it changes your mind, say so and update. 3) Quantify when you can: cost, time, probability, magnitude. 4) Converge as exchanges run down. BANNED: fence-sitting, restating options, resurrecting a killed option without new evidence (the WORKING NOTES track what is alive and why others died). EVERY TURN MUST: respond, advance the analysis, end with exactly this line: LEANING: <option> (<one-line why>)."
        briefB = "ROLE: DECISION PARTNER B, making the call below with your partner. MISSION: reach the RIGHT call, not YOUR call. YOUR LENS: second-order consequences and reversibility - what each option unlocks or closes off, how hard it is to undo, what it costs in time and attention. METHOD: 1) State what each option looks like six months after choosing it. 2) Every turn, engage the actual reasoning from Partner A - if it changes your mind, say so and update. 3) Quantify when you can: switching costs, lock-in, blast radius. 4) Converge as exchanges run down. BANNED: fence-sitting, restating options, resurrecting a killed option without new evidence (the WORKING NOTES track what is alive and why others died). EVERY TURN MUST: respond, advance the analysis, end with exactly this line: LEANING: <option> (<one-line why>)."
        synthesis = "The decision session below is complete. Write the final recommendation as clean markdown with exactly these sections: # The decision (one sentence - the actual call) / ## Why this option won / ## Runner-up (and the conditions under which it would win instead) / ## Risks and mitigations / ## Revisit triggers (what new information should reopen this). Build it primarily from the WORKING NOTES - the leaning history and killed options are the evidence trail."
        schema = '{"decision": "the actual call in one sentence", "why": ["reasons this option won"], "runner_up": "the second-best option", "runner_up_wins_if": ["conditions under which the runner-up wins instead"], "risks": [{"risk": "what could go wrong", "mitigation": "how it is handled"}], "revisit_triggers": ["new information that should reopen this"], "options_killed": [{"option": "what was killed", "reason": "why"}]}'
    }

    brainstorm = [ordered]@{
        label  = "Brainstorm (first half: divergent, no criticism - second half: converge and pick)"
        ask    = "Topic to brainstorm (text, or a path to a file)"
        depths = @(4, 6, 10)
        notes  = "## Directions on the table`n(none yet)`n`n## Clusters`n(not yet clustered)`n`n## Shortlist`n(convergent phase only)`n`n## The pick`n(end of convergent phase)"
        briefA = "ROLE: BRAINSTORM PARTNER A, DIVERGENT phase. MISSION: flood the zone - the widest, strangest, most valuable set of directions this topic supports. METHOD: 1) Every turn add at least 3 genuinely NEW directions - not variations. 2) Riff on the ideas from Partner B: combine, invert, scale up or down, move to a different audience. 3) Push at least one idea per turn past comfortable - the weird one is often the valuable one. BANNED: criticism, evaluation, hedging (that belongs to the convergent phase), repeating anything the WORKING NOTES already list as on the table - scan them before you speak. EVERY TURN MUST: build on at least one existing idea, then add new ones."
        briefB = "ROLE: BRAINSTORM PARTNER B, DIVERGENT phase. MISSION: flood the zone - the widest, strangest, most valuable set of directions this topic supports. METHOD: 1) Every turn add at least 3 genuinely NEW directions - not variations. 2) Riff on the ideas from Partner A: combine, invert, scale up or down, move to a different audience. 3) Push at least one idea per turn past comfortable - the weird one is often the valuable one. BANNED: criticism, evaluation, hedging (that belongs to the convergent phase), repeating anything the WORKING NOTES already list as on the table - scan them before you speak. EVERY TURN MUST: build on at least one existing idea, then add new ones."
        briefA2 = "ROLE: BRAINSTORM PARTNER A, CONVERGENT phase - divergent is OVER, no new directions. MISSION: turn the pile into a pick. METHOD: 1) Cluster what is on the table and name the clusters. 2) Name the strongest few and argue for your pick using effort, payoff, and fit. 3) Engage the actual picks from Partner B - if theirs beats yours, say so and merge. BANNED: judging anything the WORKING NOTES do not record as on the table, arguments without a concrete criterion. EVERY TURN MUST: respond to the picks, then end with exactly this line: TOP CHOICE: <direction> (<one-line why>)."
        briefB2 = "ROLE: BRAINSTORM PARTNER B, CONVERGENT phase - divergent is OVER, no new directions. MISSION: turn the pile into a pick. METHOD: 1) Cluster what is on the table and name the clusters. 2) Name the strongest few and argue for your pick using effort, payoff, and fit. 3) Engage the actual picks from Partner A - if theirs beats yours, say so and merge. BANNED: judging anything the WORKING NOTES do not record as on the table, arguments without a concrete criterion. EVERY TURN MUST: respond to the picks, then end with exactly this line: TOP CHOICE: <direction> (<one-line why>)."
        synthesis = "The brainstorm below is complete. Write it up as clean markdown with exactly these sections: # The winner (the direction they converged on, named crisply) / ## Why it won / ## The shortlist (the other strong directions, one line each - keep them, they are the backlog) / ## What the winner looks like in practice / ## First three steps. Build it primarily from the WORKING NOTES - the table, clusters, and shortlist live there."
        schema = '{"winner": "the direction converged on", "why_it_won": ["the reasons"], "shortlist": [{"direction": "name", "one_liner": "why it is worth keeping"}], "in_practice": "what the winner looks like in practice", "first_steps": ["step 1", "step 2", "step 3"], "directions_on_table": ["every direction generated in the divergent phase"]}'
    }

    redteam = [ordered]@{
        label  = "Red team (attacker tries to break the plan, defender patches it)"
        ask    = "The plan, system, or design to attack (text, or a path to a file)"
        depths = @(3, 5, 8)
        notes  = "## Holes found`n(none yet)`n`n## Patches applied`n(none yet)`n`n## Lines of attack marked dead`n(none yet)`n`n## Open threats`n(unprobed)"
        briefA = "ROLE: the DEFENDER in a two-AI red team exercise. The plan/system below is yours. MISSION: keep it standing by patching, never by denying. METHOD: 1) Classify each attack out loud: REAL HOLE, KNOWN-AND-ACCEPTED, or INVALID - then deal with it accordingly. 2) Real holes get patched on the spot: what changes, where, why it closes the hole. 3) Invalid attacks get killed with the specific mechanism that defeats them. 4) Stay consistent with your own patches - the WORKING NOTES record them. BANNED: hand-waving, mitigations without a mechanism, dismissing an attack as unlikely without a probability and a reason. EVERY TURN MUST: address every attack from the last message, most severe first."
        briefB = "ROLE: the ATTACKER in a two-AI red team exercise. MISSION: break the plan/system below before reality does. METHOD: 1) Attack the load-bearing assumption first - the thing everything rests on. 2) Every scenario concrete: who does what, in what order, exactly what breaks. 3) Vary surfaces across turns: abuse cases, failure modes, scale walls, cost explosions, security holes, human factors. 4) When a patch lands, probe the patch - most patches leak. BANNED: vague FUD (every attack needs a mechanism and a consequence), re-opening lines the WORKING NOTES record as dead without a new angle. Order by severity. EVERY TURN MUST: bring at least two attack scenarios, or one devastating one."
        synthesis = "The red team exercise below is complete. Write the report as clean markdown with exactly these sections: # Verdict (SURVIVED, PATCHED, or BROKEN - with one sentence why) / ## Holes found (most severe first) / ## Fixes agreed during the exercise / ## Residual risks (unpatched, each with severity). Build it primarily from the WORKING NOTES - holes, patches, and dead lines are all recorded there."
        schema = '{"verdict": "SURVIVED|PATCHED|BROKEN", "verdict_reason": "one sentence", "holes": [{"hole": "what was found", "severity": "low|medium|high", "status": "patched|open"}], "fixes": ["patches agreed during the exercise"], "residual_risks": [{"risk": "unpatched risk", "severity": "low|medium|high"}]}'
    }

    interviewer = [ordered]@{
        label  = "Interviewer (one extracts a complete spec from a vague idea by grilling the other)"
        ask    = "The vague idea (text, or a path to a file)"
        depths = @(3, 5, 8)
        notes  = "## Confirmed decisions`n(none yet)`n`n## Assumptions the idea holder committed to`n(none yet)`n`n## Territory mapped`n(not started)`n`n## Still unasked`n(users, core flow, data, constraints, success criteria)"
        briefA = "ROLE: the INTERVIEWER - a senior engineer and product manager in one seat. MISSION: extract a complete, buildable specification from the vague idea your partner holds. METHOD: 1) Map the territory first: users, core flow, data, constraints, success criteria. 2) Every turn, ask the 2-4 highest-value questions - the ones whose answers change what gets built. 3) Follow up on evasive answers until concrete; never let a hard question slide. 4) As the picture fills in, shift to confirming: state what you believe is now true and ask for correction. BANNED: accepting an adjective as an answer (fast, simple, smart - ask what it means in practice), filler questions, re-asking what the WORKING NOTES already answer. EVERY TURN MUST: acknowledge what the last answer nailed down, then ask the next highest-value questions."
        briefB = "ROLE: the IDEA HOLDER. The vague idea below is yours; the interviewer is grilling you. MISSION: get the idea fully specified by answering honestly and decisively. METHOD: 1) Answer every question directly. 2) When a question forces an undecided decision, DECIDE - commit to the most plausible specifics and own them. 3) Flag something as undecided only when it genuinely needs a human call. 4) Correct the interviewer when an inference is wrong - you are the authority on the vision. BANNED: vagueness, it-depends answers without saying exactly what it depends on. EVERY TURN MUST: answer all questions, then add the one important thing the interviewer did not think to ask."
        synthesis = "The interview below is complete. Write the extracted specification as clean markdown with exactly these sections: # (the idea, named) / ## The idea, fully specified / ## Confirmed decisions (what the idea holder committed to) / ## Assumptions made (what was invented and needs a human check) / ## Still undecided. Build it primarily from the WORKING NOTES - confirmed decisions and assumptions are already separated there."
        schema = '{"idea_name": "the idea, named", "fully_specified": "the complete specification as prose", "confirmed_decisions": ["what the idea holder committed to"], "assumptions_to_verify": ["what was invented and needs a human check"], "still_undecided": ["genuinely undecided items"]}'
    }

    website = [ordered]@{
        label  = "Website experts (principal-level UI/UX + frontend engineering - create or evolve)"
        depths = @(4, 6, 10)
        submodes = [ordered]@{
            create = [ordered]@{
                label = "Create new (award-level frontend, tailored to the brand)"
                ask   = "Describe the website - the company or product, its audience, the vibe (text, or a path to a brief file)"
                notes = "## Strategy (positioning, audience, the one action)`n(undecided)`n`n## UX (flows, hierarchy, key screens)`n(undecided)`n`n## Visual identity system`n(palette / type / spacing / grid - undecided)`n`n## Signature moments and motion`n(none yet)`n`n## Frontend engineering decisions`n(undecided)`n`n## Open items`n(everything)"
                briefA = "ROLE: You are the DESIGN PRINCIPAL - the kind of designer whose interfaces win awards and still convert. SCOPE: pure frontend - UI, UX, interaction, and visual design. If backend concerns appear in the input, note them as out of scope and move on. MISSION: with the Frontend Principal, conceive a website that is the best possible answer for this brand: distinctive, intentional, usable, and buildable. YOUR TERRITORY: UX first (user flows, information hierarchy, interaction states, usability heuristics, content design) and then the visual system (brand expression, typography, color, layout, motion). METHOD: 1) Strategy before pixels: lock positioning (who it is for, what makes it different), the emotional register, and the single action every page drives toward. If the input leaves these open, make bold explicit choices and own them. 2) Every turn commits at least one concrete, named decision: a user flow step, a hierarchy call, palette entries with hex and usage ratios, a type pairing with the reasoning, the spacing scale, the grid, the signature interaction, the motion language (easing, duration, choreography). 3) Name the pattern you are invoking (editorial, brutalist, soft-depth, kinetic type, etc.) and why it fits THIS brand. 4) Meet engineering constraints by adapting the design, never diluting it. BANNED: clean-and-modern filler, default SaaS-gradient sameness, unnamed choices, screens without states, flows that skip the unhappy path. The WORKING NOTES record what is settled - never re-open them silently. EVERY TURN MUST: respond to the Frontend Principal first, commit at least one concrete UX or design decision, end with the next thing to nail down."
                briefB = "ROLE: You are the FRONTEND PRINCIPAL - the engineer designers love, because you make ambitious interfaces real without breaking them. SCOPE: pure frontend - UI engineering, UX implementation, performance, accessibility. If backend concerns appear in the input, note them as out of scope and move on. MISSION: with the Design Principal, conceive a site that is stunning AND shippable to production frontend standard. YOUR TERRITORY: component architecture, CSS strategy (design tokens, custom properties, modern layout - grid, container queries), interaction implementation, animation technology (CSS vs JS libraries vs view transitions) with fallbacks, performance budgets with named targets (LCP, CLS, INP), accessibility to WCAG 2.2 AA (keyboard flows, screen readers, reduced motion), responsive strategy, asset and font loading, SEO and social meta. METHOD: 1) Turn every design intent into a buildable decision: the technique, the library, the fallback, the cost. 2) Flag expensive or fragile choices EARLY, with the cheaper alternative that preserves the intent. 3) When a library or technique matters, use web access to verify it is real, current, and maintained - never assert from memory. 4) Performance and accessibility are UX features, not afterthoughts. BANNED: hand-waved feasibility, unnamed libraries, budgets without numbers, components without states. The WORKING NOTES record what is settled - check them before proposing. EVERY TURN MUST: respond to the Design Principal first, make one thing more buildable, end with the next thing to nail down."
                synthesis = "The design session below is complete. Write the complete frontend specification as clean markdown with exactly these sections: # (the site concept, named) / ## Strategy (positioning, audience, emotional register, the one action every page drives) / ## UX (key user flows step by step, information hierarchy, the screens and their states - including empty, loading, and error states) / ## Visual identity system (palette with hex and usage ratios, type pairing with rationale, spacing scale, grid) / ## Signature moments (the 2-3 interactions that make it memorable, with motion specs: easing, duration, trigger) / ## Page-by-page plan (sections and content direction per page) / ## Component inventory (with states) / ## Frontend engineering approach (stack, CSS token strategy, animation tech with fallbacks, performance budgets with named targets, accessibility commitments, SEO/meta) / ## Build plan (phased, each phase shippable). Build it primarily from the WORKING NOTES; the conversation is backup detail."
                schema = '{"site_name": "the concept name", "strategy": {"positioning": "what makes it different", "audience": "who it is for", "primary_action": "the one action every page drives", "emotional_register": "what it must make visitors feel"}, "ux_flows": [{"flow": "name", "steps": ["step"], "unhappy_path": "what happens when it goes wrong"}], "visual_identity": {"palette": [{"role": "primary|accent|surface|etc", "hex": "#000000", "usage": "where and how much"}], "type_pairing": [{"level": "display|h1|body|etc", "font": "family", "size": "size", "weight": "weight"}], "spacing_scale": "the spacing system", "grid": "the layout grid"}, "signature_moments": [{"name": "the moment", "description": "what happens", "motion_spec": "easing, duration, trigger"}], "pages": [{"page": "name", "purpose": "what it does", "sections": ["section"], "states": ["default|empty|loading|error"], "content_direction": "what the content says"}], "components": [{"name": "component", "states": ["default|hover|etc"], "notes": "behavior"}], "frontend_engineering": {"stack": "chosen stack", "css_strategy": "token/custom-property approach", "animation": "animation tech and fallbacks", "performance_budgets": {"lcp": "target", "cls": "target", "inp": "target"}, "accessibility": "WCAG commitments", "seo_meta": "meta/OG approach"}, "build_plan": [{"phase": 1, "goal": "what ships", "done_when": "the demonstrable end state"}]}'
            }
            evolve = [ordered]@{
                label = "Evolve existing (professional UI/UX + frontend audit, keep the brand equity, level it up)"
                ask   = "Path to the existing website project folder (or a file describing the site)"
                notes = "## Audit - what works (with evidence)`n(not yet audited)`n`n## Audit - what fails (with evidence)`n(not yet audited)`n`n## Brand equity to preserve`n(tokens and patterns that must survive)`n`n## Evolution decisions`n(none yet)`n`n## Migration notes`n(none yet)`n`n## Out of scope (backend items noted and parked)`n(none yet)`n`n## Open items`n(everything)"
                briefA = "ROLE: You are the DESIGN PRINCIPAL, hired to evolve an EXISTING website whose frontend code and structure are in the input digest. SCOPE: pure frontend - UI, UX, interaction, visual design. If the digest exposes backend concerns, note them as out of scope and move on. MISSION: an audit a professional agency would charge for, then a leveled-up direction that protects brand equity. METHOD: 1) First turn is the audit, grounded in the digest with file evidence: user flows and their friction, information hierarchy, visual hierarchy, typography, color consistency, spacing rhythm, interaction states (including missing empty/loading/error states), conversion paths (CTA placement, trust signals), content clarity. For each: what works, what fails, and the evidence. 2) Score the identity: which tokens and patterns carry the brand and must survive. 3) Then evolve: named, specific improvements flow by flow, page by page, component by component - never redesign for its own sake. 4) Refine tokens rather than replace them; if one must change, justify it against the brand. BANNED: generic critique (name the element, the current value, the proposed value, the reason), claims that do not trace to the digest (flag them as assumptions), re-opening what the WORKING NOTES record as settled. EVERY TURN MUST: respond to the Frontend Principal first, advance the audit or the evolution, end with the next thing to nail down."
                briefB = "ROLE: You are the FRONTEND PRINCIPAL, hired to evolve an EXISTING website whose frontend code and structure are in the input digest. SCOPE: pure frontend - UI engineering, UX implementation, performance, accessibility. If the digest exposes backend concerns, note them as out of scope and move on. MISSION: an honest technical audit, then a buildable evolution plan with a safe migration path. METHOD: 1) First turn is the technical audit, grounded in the digest: component structure, CSS architecture, interaction implementation, asset strategy, performance red flags (render-blocking, unoptimized media, font loading), accessibility failures (contrast, focus, semantics, motion), responsive behavior - each with the file or pattern that proves it. 2) Cost every proposed change against the CURRENT codebase: class change, component refactor, or structural rewrite - and say which. 3) Sequence the work so the site is never broken between phases. 4) Use web access to verify any library or technique is real and current. BANNED: changes without migration notes, rewrites where refactors suffice, claims that do not trace to the digest (flag them as assumptions). EVERY TURN MUST: respond to the Design Principal first, advance the audit or the plan, end with the next thing to nail down."
                synthesis = "The evolution session below is complete. Write the website evolution report as clean markdown with exactly these sections: # Audit verdict (where this site stands, one paragraph) / ## What works (with evidence - keep) / ## What fails (with evidence - fix: UX friction, visual, and frontend-technical separated) / ## Brand equity to preserve / ## The leveled-up direction / ## Changes flow by flow and page by page (each costed: class change, refactor, or rewrite) / ## Technical debt and quick wins / ## Out of scope (backend items noted during the audit) / ## Build plan (phased, never broken between phases). Build it primarily from the WORKING NOTES; the conversation is backup detail."
                schema = '{"audit_verdict": "where the site stands in one sentence", "working": [{"what": "what works", "evidence": "the file or pattern that proves it"}], "failing": [{"what": "what fails", "kind": "ux|visual|technical", "evidence": "the file or pattern that proves it"}], "brand_equity_preserved": ["tokens and patterns that must survive"], "evolution": [{"change": "what changes", "where": "flow, page, or component", "cost": "class change|refactor|rewrite", "why": "the reason"}], "quick_wins": ["high-value low-cost fixes"], "out_of_scope_backend": ["backend items noted and parked"], "build_plan": [{"phase": 1, "goal": "what ships", "verified_by": "the check that proves it"}]}'
            }
        }
    }
    extend = [ordered]@{
        label  = "Extend existing software (architects review a codebase and spec its next phase)"
        ask    = "Path to the existing software project folder (or a file describing it plus the goal)"
        depths = @(3, 5, 8)
        notes  = "## Current architecture (as read from the digest)`n(not yet mapped)`n`n## Extension seams`n(where new capability can attach)`n`n## Debt that blocks the goal`n(none identified yet)`n`n## Evolution decisions`n(none yet)`n`n## Migration risks`n(none yet)`n`n## Open items`n(everything)"
        briefA = "ROLE: STAFF ARCHITECT A, the systems specialist evolving an EXISTING codebase whose digest is the input. MISSION: understand the software as actually built, then spec its next evolution precisely. METHOD: 1) First turn maps reality from the digest: components, data flow, storage, seams - facts with file evidence, never guesses. 2) Identify extension seams: where new capability attaches with the least violence to existing code. 3) Spec the evolution: modules changed, modules added, data migrations, what breaks if done carelessly. BANNED: greenfield thinking (the existing system is the constraint and the asset), claims that do not trace to the digest (flag as assumptions), contradicting the WORKING NOTES silently. EVERY TURN MUST: respond first, advance the map or the spec, end with the next thing to nail down."
        briefB = "ROLE: STAFF ARCHITECT B, the delivery-and-quality specialist evolving an EXISTING codebase whose digest is the input. MISSION: make sure the evolution ships safely. YOUR TERRITORY: rollout sequencing, backwards compatibility, testing strategy, migration safety, what done demonstrably means per phase. METHOD: 1) First turn maps delivery reality from the digest: how it is built, tested, deployed today - or the absence of those, stated plainly. 2) For every spec item, name the migration risk and the verification that proves it worked. 3) Sequence phases so the system never breaks between them. BANNED: phases that do not end runnable, changes without a rollback story, claims that do not trace to the digest (flag as assumptions). EVERY TURN MUST: respond first, advance the plan, end with the next thing to nail down."
        synthesis = "The extension session below is complete. Write the evolution specification as clean markdown with exactly these sections: # (the evolution, named) / ## Current architecture (as evidenced, one paragraph) / ## Extension seams (where the new capability attaches) / ## The spec (modules changed, modules added, data migrations) / ## Rollout plan (phased, each phase shippable and verifiable) / ## Migration risks and rollbacks / ## Open questions. Build it primarily from the WORKING NOTES; dip into the conversation only for context the notes miss."
        schema = '{"evolution_name": "the evolution, named", "current_architecture": "the system as it exists, one paragraph", "extension_seams": ["where new capability attaches"], "modules_changed": [{"module": "name", "change": "what changes"}], "modules_added": [{"module": "name", "purpose": "what it owns"}], "data_migrations": [{"what": "the migration", "risk": "what could go wrong"}], "rollout_plan": [{"phase": 1, "goal": "what ships", "verified_by": "the check that proves it"}], "migration_risks": [{"risk": "what could break", "rollback": "how it is undone"}], "open_questions": ["unresolved"]}'
    }

    openclaw = [ordered]@{
        label  = "OpenClaw conversion - convert this software to Linux and optimize it for OpenClaw operation"
        ask    = "Path to the software project folder (or a file describing it)"
        depths = @(3, 5, 8)
        notes  = "## Current architecture (as read from the digest)`n(not yet mapped)`n`n## Extension seams`n(where new capability can attach)`n`n## Debt that blocks the goal`n(none identified yet)`n`n## Evolution decisions`n(none yet)`n`n## Migration risks`n(none yet)`n`n## Open items`n(everything)"
        briefA = "ROLE: STAFF ARCHITECT A, the systems specialist evolving an EXISTING codebase whose digest is the input. MISSION: understand the software as actually built, then spec its next evolution precisely. METHOD: 1) First turn maps reality from the digest: components, data flow, storage, seams - facts with file evidence, never guesses. 2) Identify extension seams: where new capability attaches with the least violence to existing code. 3) Spec the evolution: modules changed, modules added, data migrations, what breaks if done carelessly. BANNED: greenfield thinking (the existing system is the constraint and the asset), claims that do not trace to the digest (flag as assumptions), contradicting the WORKING NOTES silently. EVERY TURN MUST: respond first, advance the map or the spec, end with the next thing to nail down."
        briefB = "ROLE: STAFF ARCHITECT B, the delivery-and-quality specialist evolving an EXISTING codebase whose digest is the input. MISSION: make sure the evolution ships safely. YOUR TERRITORY: rollout sequencing, backwards compatibility, testing strategy, migration safety, what done demonstrably means per phase. METHOD: 1) First turn maps delivery reality from the digest: how it is built, tested, deployed today - or the absence of those, stated plainly. 2) For every spec item, name the migration risk and the verification that proves it worked. 3) Sequence phases so the system never breaks between them. BANNED: phases that do not end runnable, changes without a rollback story, claims that do not trace to the digest (flag as assumptions). EVERY TURN MUST: respond first, advance the plan, end with the next thing to nail down."
        synthesis = "The extension session below is complete. Write the evolution specification as clean markdown with exactly these sections: # (the evolution, named) / ## Current architecture (as evidenced, one paragraph) / ## Extension seams (where the new capability attaches) / ## The spec (modules changed, modules added, data migrations) / ## Rollout plan (phased, each phase shippable and verifiable) / ## Migration risks and rollbacks / ## Open questions. Build it primarily from the WORKING NOTES; dip into the conversation only for context the notes miss."
        schema = '{"blockers":[{"file":"","class":"linux-conversion|openclaw","issue":"","fix":""}],"tasks":[{"title":"","files":[""],"prove":""}],"playbook":[{"step":"","command":"","expected":"","gate":""}],"out_of_scope":[""]}'
    }
}

function Resolve-ConsultModel([string]$m) {
    if (Get-Command Resolve-ModelName -ErrorAction SilentlyContinue) { return (Resolve-ModelName $m) }
    switch -Regex ($m) {
        "(?i)^m3$"     { return "minimax/MiniMax-M3" }
        "(?i)^m2\.?7$" { return "minimax/MiniMax-M2.7" }
        default        { return $m }
    }
}

# ---------- format selection ----------
if (-not $Format -and -not $Yes) {
    $keys = @($formats.Keys)
    $labels = @($keys | ForEach-Object { $formats[$_].label })
    $fi = Show-CicadaMenu -Title "Consult - what kind of conversation?" -Options $labels -Default 0
    $Format = $keys[$fi]
}
if (-not $Format) { $Format = "develop" }
$Format = $Format.ToLower()
if (-not $formats.Contains($Format)) { throw ("Unknown format '" + $Format + "'. Valid: " + ($formats.Keys -join ", ")) }
$f = $formats[$Format]

# ---------- sub-mode selection (formats with missions, e.g. website create/evolve) ----------
if ($f.Contains("submodes")) {
    $subKeys = @($f.submodes.Keys)
    if (-not $Sub -and -not $Yes) {
        $subLabels = @($subKeys | ForEach-Object { $f.submodes[$_].label })
        $si = Show-CicadaMenu -Title ("Consult [" + $Format + "] - which mission?") -Options $subLabels -Default 0
        $Sub = $subKeys[$si]
    }
    if (-not $Sub) { $Sub = $subKeys[0] }
    $Sub = $Sub.ToLower()
    if (-not $f.submodes.Contains($Sub)) { throw ("Unknown sub-mode '" + $Sub + "'. Valid: " + ($subKeys -join ", ")) }
    $subDef = $f.submodes[$Sub]
    foreach ($k in @($subDef.Keys)) { if ($k -ne "label") { $f[$k] = $subDef[$k] } }
    $Format = $Format + ":" + $Sub
}

# ---------- model selection (every format, both seats) ----------
if (-not $ModelA -and -not $Yes) {
    $ai = Show-CicadaMenu -Title "Consult - model for seat A" -Options @("MiniMax-M3 (recommended)", "MiniMax-M2.7", "custom (type full model id)") -Default 0
    if ($ai -eq 0) { $ModelA = "m3" } elseif ($ai -eq 1) { $ModelA = "m2.7" } else { $ModelA = (Read-Host "Full model id").Trim() }
}
if (-not $ModelA) { $ModelA = "m3" }
if (-not $ModelB -and -not $Yes) {
    $bi = Show-CicadaMenu -Title "Consult - model for seat B" -Options @("MiniMax-M2.7", "MiniMax-M3", "custom (type full model id)") -Default 0
    if ($bi -eq 0) { $ModelB = "m2.7" } elseif ($bi -eq 1) { $ModelB = "m3" } else { $ModelB = (Read-Host "Full model id").Trim() }
}
if (-not $ModelB) { $ModelB = "m2.7" }
$ModelA = Resolve-ConsultModel $ModelA
$ModelB = Resolve-ConsultModel $ModelB

# ---------- depth (Small / Medium / Large / Auto, tuned per format) ----------
# 1 exchange = one message from EACH model (two turns total).
$autoConverge = $false
if ($Exchanges -le 0 -and $Depth) {
    switch ($Depth.ToLower()) {
        "small"    { $Exchanges = $f.depths[0] }
        "medium"   { $Exchanges = $f.depths[1] }
        "large"    { $Exchanges = $f.depths[2] }
        "quick"    { $Exchanges = $f.depths[0] }
        "standard" { $Exchanges = $f.depths[1] }
        "deep"     { $Exchanges = $f.depths[2] }
        "auto"     { $Exchanges = $f.depths[2]; $autoConverge = $true }
        default    { $Exchanges = [int]$Depth }
    }
}
if ($Exchanges -le 0 -and -not $Yes) {
    $dopts = @(
        ("Small (" + $f.depths[0] + " exchanges = " + (2 * $f.depths[0]) + " turns)"),
        ("Medium (" + $f.depths[1] + " exchanges = " + (2 * $f.depths[1]) + " turns) - recommended for " + $Format),
        ("Large (" + $f.depths[2] + " exchanges = " + (2 * $f.depths[2]) + " turns)"),
        ("Auto (stop when converged - " + $f.depths[0] + " minimum, " + $f.depths[2] + " cap)"),
        "custom (type a number)"
    )
    $di = Show-CicadaMenu -Title "How much conversation? (1 exchange = one message from each model)" -Options $dopts -Default 1
    if ($di -eq 4) { $Exchanges = [int](Read-Host "Exchanges") }
    elseif ($di -eq 3) { $Exchanges = $f.depths[2]; $autoConverge = $true }
    else { $Exchanges = $f.depths[$di] }
}
if ($Exchanges -le 0) { $Exchanges = $f.depths[1] }
$minExchanges = if ($autoConverge) { $f.depths[0] } else { $Exchanges }

# ---------- turn length ----------
$lengthWords = 0
if ($Length) {
    switch ($Length.ToLower()) {
        "short"    { $lengthWords = 150 }
        "standard" { $lengthWords = 300 }
        "long"     { $lengthWords = 500 }
        default    { $lengthWords = [int]$Length }
    }
}
if ($lengthWords -le 0 -and -not $Yes) {
    $li = Show-CicadaMenu -Title "Turn length (how much each model says per turn)" -Options @("Short (~150 words)", "Standard (~300 words) - recommended", "Long (~500 words)") -Default 1
    $lengthWords = @(150, 300, 500)[$li]
}
if ($lengthWords -le 0) { $lengthWords = 300 }
$lengthRule = "LENGTH OVERRIDE: every reply in this session must be about " + $lengthWords + " words, overriding any other length guidance."

# ---------- project digest: when the input path is a directory, build the brief from the code ----------
function Get-ProjectDigest([string]$dir) {
    $all = Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -notmatch '\\(node_modules|\.git|dist|build|bin|obj|\.next|coverage|\.vs|\.idea|consult)(\\|$)'
    }
    $tree = ($all | ForEach-Object { $_.FullName.Substring($dir.Length).TrimStart("\") } | Select-Object -First 120) -join "`n"
    $priority = @("package.json", "readme.md", "readme", "index.html", "tailwind.config.js", "tailwind.config.ts", "vite.config.ts", "vite.config.js", "next.config.js", "next.config.mjs")
    $sources = @()
    foreach ($name in $priority) {
        $f = $all | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($f) { $sources += $f }
    }
    $sources += $all | Where-Object { $_.Extension -match '^\.(ts|tsx|js|jsx|css|scss|html|vue|svelte)$' -and $sources -notcontains $_ } | Sort-Object Length -Descending | Select-Object -First 12
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("PROJECT DIGEST of: " + $dir)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("FILE TREE (first 120 files):")
    [void]$sb.AppendLine($tree)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("KEY FILE CONTENTS:")
    $budget = 18000
    foreach ($f in $sources) {
        if ($budget -le 0) { break }
        $rel = $f.FullName.Substring($dir.Length).TrimStart("\")
        $content = (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
        if (-not $content) { continue }
        if ($content.Length -gt 3000) { $content = $content.Substring(0, 3000) + "`n... (truncated)" }
        if ($content.Length -gt $budget) { $content = $content.Substring(0, $budget) + "`n... (budget reached)" }
        $budget -= $content.Length
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=== " + $rel + " ===")
        [void]$sb.AppendLine($content)
    }
    return $sb.ToString().Trim()
}

# ---------- the input (typed text or a path to a file) ----------
if (-not $Idea) { $Idea = (Read-Host $f.ask).Trim() }
if (-not $Idea) { Write-Host "Nothing given - aborting." -ForegroundColor Red; exit 1 }
$ideaSource = "typed"
$ideaText = $Idea
if (Test-Path $Idea -ErrorAction SilentlyContinue) {
    if ((Get-Item $Idea).PSIsContainer) {
        Write-Host ("  (directory input - building project digest)") -ForegroundColor DarkGray
        $ideaText = Get-ProjectDigest (Resolve-Path $Idea).Path
        $ideaSource = "project: " + $Idea
    } else {
        $ideaText = (Get-Content $Idea -Raw).Trim()
        $ideaSource = $Idea
    }
}
if (-not $ideaText) { Write-Host "Input file is empty - aborting." -ForegroundColor Red; exit 1 }
Show-ReplayCommand -ParamNames @("Idea","Format","Sub","Depth","Length","Project","Model","Engine","Direction","Label","Yes")

# ---------- optional direction: the human points the conversation ----------
$directionText = ""
if (-not $Direction -and -not $Yes) {
    $dirFormats = @("website", "extend", "openclaw")
    if ($dirFormats -contains $Format.Split(":")[0]) {
        $Direction = (Read-Host "Direction for them (optional - text or path to a prompt file, Enter to skip)").Trim()
    }
}
if ($Direction) {
    if (Test-Path $Direction -ErrorAction SilentlyContinue) {
        $directionText = (Get-Content $Direction -Raw).Trim()
        Write-Host ("  direction loaded from file: " + $Direction) -ForegroundColor DarkGray
    } else {
        $directionText = $Direction
    }
}

# ---------- workspace + history + the shared working document ----------
$stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
$slug = ""
if ($Label) { $slug = "-" + (($Label -replace "[^A-Za-z0-9 -]", "").Trim() -replace "\s+", "-") }
$consultRoot = Join-Path $Root "state\consult"
if ($Project) {
    if (Test-Path $Project) {
        $consultRoot = Join-Path $Project "consult"   # run folders live with the project
    } else {
        Write-Host ("  (project path not found: " + $Project + " - falling back to state\consult)") -ForegroundColor Yellow
    }
}
$ws = Join-Path $consultRoot ($stamp + $slug)
New-Item -ItemType Directory -Force -Path $ws | Out-Null
$ideaText | Set-Content (Join-Path $ws "input.md") -Encoding utf8
$transcriptPath = Join-Path $ws "transcript.md"
$notesPath = Join-Path $ws "notes.md"
$finalPath = Join-Path $ws "FINAL.md"
$jsonPath = Join-Path $ws "structured.json"
$rawJsonPath = Join-Path $ws "structured.raw.txt"
$indexPath = Join-Path $consultRoot "index.log"

# notes.md exists from turn one: seeded with the format's template + the input.
$seeded = "# Working notes - consult [" + $Format + "]" + $(if ($Label) { " - " + $Label } else { "" }) + "`n`n## The input`n" + $ideaText + "`n`n" + $f.notes
if ($directionText) { $seeded += "`n`n## Direction from the human (steer everything toward this)`n" + $directionText }
$seeded | Set-Content $notesPath -Encoding utf8
$notes = $seeded

Write-Host ""
Write-Host ("  consult [" + $Format + "]: " + $ModelA + " (seat A) vs " + $ModelB + " (seat B)") -ForegroundColor Cyan
if ($Label) { Write-Host ("  label:   " + $Label) -ForegroundColor DarkGray }
Write-Host ("  input:   " + $ideaSource) -ForegroundColor DarkGray
$depthDesc = ("" + $Exchanges + " exchanges (" + (2 * $Exchanges) + " turns)")
if ($autoConverge) { $depthDesc += ", auto-stop after " + $minExchanges + " if converged" }
Write-Host ("  depth:   " + $depthDesc + " + synthesis + normaliser") -ForegroundColor DarkGray
Write-Host ("  length:  ~" + $lengthWords + " words per turn") -ForegroundColor DarkGray
$notesDesc = if ($NoNotes) { "off (-NoNotes)" } else { "notes.md, updated by the scribe after every exchange" }
Write-Host ("  notes:   " + $notesDesc) -ForegroundColor DarkGray
Write-Host ("  output:  " + $ws) -ForegroundColor DarkGray
Write-Host "  steer:   press S between exchanges to inject a note" -ForegroundColor DarkGray
Write-Host ""
if (Get-Command Send-CicadaTelegram -ErrorAction SilentlyContinue) {
    Send-CicadaTelegram ("CICADA consult [" + $Format + "] started | " + $ModelA + " vs " + $ModelB + " | " + $Exchanges + " exchanges" + $(if ($Label) { " | " + $Label } else { "" }))
}

# ---------- which seat: pure conversation vs web-enabled formats ----------
$script:agentSeat = "consult"
if (@("software", "website", "extend") -contains $Format.Split(":")[0]) { $script:agentSeat = "consult-web" }

# ---------- turn runner (retry once, then degrade gracefully) ----------
# ---------- direct engine: pure chat completions, zero harness overhead ----------
function Invoke-ConsultTurnDirect([string]$Model, [string]$Prompt) {
    $m = $Model -replace "^minimax/", ""
    $maxTok = [Math]::Max(1500, [int]($script:lengthWords * 3))
    $sys = "You are one half of a structured two-AI conversation. Every message contains a full role definition (ROLE, MISSION, METHOD, BANNED behaviors, and what every turn must contain) - follow it exactly, stay in the assigned seat, respond to what your counterpart actually said, and keep to the requested length. The WORKING NOTES section is the shared record of what has been settled - treat it as ground truth. If a LENGTH OVERRIDE or an OPERATOR NOTE is present, it outranks other guidance. When asked to act as SCRIBE or NORMALISER, return exactly what is requested with no preamble. No tools exist in this session - answer in plain text, in a single step."
    $body = @{
        model = $m
        messages = @(
            @{ role = "system"; content = $sys },
            @{ role = "user"; content = $Prompt }
        )
        temperature = 0.4
        max_tokens = $maxTok
    } | ConvertTo-Json -Depth 10
    Write-Host ("  (payload: " + $body.Length + " chars)") -ForegroundColor DarkGray
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.minimax.io/v1/chat/completions" -Headers @{ Authorization = ("Bearer " + $env:MINIMAX_API_KEY); "Content-Type" = "application/json; charset=utf-8" } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
    } catch {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host ("  API error body: " + $_.ErrorDetails.Message) -ForegroundColor DarkYellow }
        throw
    }
    $text = [string]$resp.choices[0].message.content
    $tin = 0; $tout = 0; $estimated = ""
    if ($resp.usage) { $tin = [int]$resp.usage.prompt_tokens; $tout = [int]$resp.usage.completion_tokens }
    if (-not ($tin -or $tout)) {
        # no usage in the response - estimate at ~4 chars per token and mark it clearly
        $tin = [int][Math]::Ceiling(($sys.Length + $Prompt.Length) / 4)
        $tout = [int][Math]::Ceiling($text.Length / 4)
        $estimated = "~"
    }
    if ($null -eq $script:totalIn) { $script:totalIn = 0; $script:totalOut = 0 }   # ledger works with or without the tokens patch
    $script:totalIn += $tin; $script:totalOut += $tout
    $est = if ($estimated) { " - estimated" } else { "" }
    Write-Host ("  (tokens: " + $estimated + $tin + " in / " + $estimated + $tout + " out" + $est + " | run: " + $script:totalIn + " in / " + $script:totalOut + " out)") -ForegroundColor DarkGray
    $text = [regex]::Replace($text, "(?s)<think>.*?</think>", "").Trim()
    if (-not $text) { throw "direct API returned no text" }
    return $text
}

# ---------- router: direct for pure formats, opencode for web formats ----------
function Invoke-ConsultTurnAny([string]$Model, [string]$Prompt) {
    if ($script:Engine -eq "direct") { return (Invoke-ConsultTurnDirect $Model $Prompt) }   # true override: everything goes direct
    $webFormats = @("software", "website", "extend")
    $needsWeb = ($webFormats -contains $Format.Split(":")[0])
    if ($needsWeb -or $script:Engine -eq "opencode") { return (Invoke-ConsultTurn $Model $Prompt) }
    return (Invoke-ConsultTurnDirect $Model $Prompt)
}

function Invoke-ConsultTurn([string]$Model, [string]$Prompt) {
    $exe = Resolve-OpenCodeExe
    # Flatten newlines and dequote so the prompt survives PS 5.1 native arg passing (same trick as console.ps1).
    $flat = ($Prompt -replace "\r\n?", " " -replace '"', '\"')
    if ($flat.Length -gt 24000) { $flat = $flat.Substring(0, 24000) + " ... (truncated - the full files live in " + $ws + ")" }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"   # never let stderr noise become a terminating NativeCommandError
    $errLog = Join-Path $ws "turn-stderr.log"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"   # never let stderr noise become a terminating NativeCommandError
    $raw = & $exe run $flat --dir $ws --agent `$script:agentSeat -m $Model --pure --format json 2>$errLog
    $code = $LASTEXITCODE
    if ($code -ne 0 -and (($raw | Out-String) -match "(?i)pure")) {
        # this opencode build may not accept --pure standalone - retry without it once
        $raw = & $exe run $flat --dir $ws --agent `$script:agentSeat -m $Model --format json 2>$errLog
        $code = $LASTEXITCODE
    }
    $ErrorActionPreference = $prevEAP
    $turnLog = Join-Path $ws ("turn-" + [Guid]::NewGuid().ToString("N").Substring(0, 6) + ".jsonl")
    ($raw | Out-String) | Set-Content $turnLog -Encoding utf8
    if ($code -ne 0) { throw ("opencode run failed (exit " + $code + ") - raw output: " + $turnLog) }

    # parse the JSONL event stream: assistant text + real token counts
    $texts = @(); $tin = 0; $tout = 0
    foreach ($l in $raw) {
        $e = $null
        try { $e = ($l | ConvertFrom-Json -ErrorAction Stop) } catch { continue }
        if ($e.type -eq "text" -and $e.part.text) { $texts += [string]$e.part.text }
        $tk = $null
        if ($e.part -and $e.part.tokens) { $tk = $e.part.tokens } elseif ($e.tokens) { $tk = $e.tokens }
        if ($tk) {
            if ($tk.input)  { $tin  += [int]$tk.input }
            if ($tk.output) { $tout += [int]$tk.output }
        }
    }
    $text = ($texts -join "")
    if (-not $text) {
        # fallback: extract text fields with a regex if the event shape moved
        $joined = ($raw | Out-String)
        $m = [regex]::Matches($joined, '(?s)"text"\s*:\s*"((?:\\.|[^"\\])*)"')
        if ($m.Count -gt 0) { $text = (($m | ForEach-Object { $_.Groups[1].Value }) -join "") }
    }
    if (-not $text) { throw ("no assistant text found in the event stream - raw output: " + $turnLog) }
    $text = [regex]::Replace($text, "(?s)<think>.*?</think>", "").Trim()   # M2.7 reasoning stays out of the record
    $script:totalIn += $tin; $script:totalOut += $tout
    if ($tin -or $tout) { Write-Host ("  (tokens: " + $tin + " in / " + $tout + " out)") -ForegroundColor DarkGray }
    else { Write-Host "  (tokens: not reported by this opencode build)" -ForegroundColor DarkGray }
    return $text
}

function Invoke-ConsultTurnSafe([string]$Model, [string]$Prompt) {
    try { return (Invoke-ConsultTurnAny $Model $Prompt) }
    catch {
        Write-Host ("  (turn failed: " + $_.Exception.Message + " - retrying once)") -ForegroundColor Yellow
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host ("  API error body: " + $_.ErrorDetails.Message) -ForegroundColor DarkYellow }
        try { return (Invoke-ConsultTurnAny $Model $Prompt) }
        catch {
            Write-Host ("  (turn failed twice - giving up on this turn)") -ForegroundColor Red
            return $null
        }
    }
}

# ---------- the scribe: keeps notes.md current after every exchange ----------
function Update-WorkingNotes([string]$latestExchange) {
    if ($NoNotes) { return }
    $pN = "You are the SCRIBE for a two-AI consultation. Maintain the shared working notes below. Read the latest exchange, then return the COMPLETE updated notes as clean markdown: record every new decision, commitment, or direction; remove anything superseded; keep the existing section structure; keep the input section untouched. Never summarize the exchange itself - only what it SETTLED. If nothing new was settled, return the notes unchanged. Return ONLY the markdown notes, no preamble. CURRENT NOTES: " + $script:notes + " LATEST EXCHANGE: " + $latestExchange
    $updated = Invoke-ConsultTurnSafe $ModelB $pN
    if ($updated -and $updated.Length -gt 100) {
        $script:notes = $updated
        $script:notes | Set-Content $notesPath -Encoding utf8
        Write-Host "  (notes.md updated by the scribe)" -ForegroundColor DarkGray
    } else {
        Write-Host "  (scribe produced nothing usable - notes.md unchanged)" -ForegroundColor DarkGray
    }
}

# ---------- the normaliser: notes + transcript -> strict per-format JSON ----------
function Invoke-Normaliser {
    $full = Get-ContextWindow 6   # windowed: schema fields come from the notes, the tail is backup
    $pNorm = "You are the NORMALISER for a two-AI " + $Format + " consultation. Convert the working notes and conversation below into STRICT JSON matching exactly this schema - every key present, arrays as arrays, no markdown fences, no commentary, JSON only. SCHEMA: " + $f.schema + " RULES: fill every field from the record; use an empty array or the string 'none' when genuinely absent; never invent content that is not in the record. WORKING NOTES: " + $script:notes + " CONVERSATION: " + $full
    $raw = Invoke-ConsultTurnSafe $ModelB $pNorm
    if (-not $raw) { return $false }
    $candidate = ($raw -replace '(?s)^\s*```(json)?\s*', '' -replace '(?s)```\s*$', '').Trim()
    try { $null = ($candidate | ConvertFrom-Json -ErrorAction Stop) }
    catch {
        Write-Host "  (normaliser output was not valid JSON - one corrective retry)" -ForegroundColor Yellow
        $pFix = "Your previous reply was not valid JSON. Return ONLY the corrected JSON object matching the same schema - no fences, no commentary. THE SCHEMA: " + $f.schema + " YOUR PREVIOUS INVALID OUTPUT: " + $candidate
        $raw2 = Invoke-ConsultTurnSafe $ModelB $pFix
        if (-not $raw2) { return $false }
        $candidate = ($raw2 -replace '(?s)^\s*```(json)?\s*', '' -replace '(?s)```\s*$', '').Trim()
        try { $null = ($candidate | ConvertFrom-Json -ErrorAction Stop) }
        catch { return $false }
    }
    ($candidate | ConvertFrom-Json | ConvertTo-Json -Depth 30) | Set-Content $jsonPath -Encoding utf8
    return $true
}

# ---------- mid-run steering ----------
$steerNote = ""
if ($directionText) { $steerNote = $directionText }   # direction rides the operator-note channel into every turn
function Read-SteerKey {
    # brief window after each exchange; an S pressed any time during the last turn is still buffered and lands here
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq 's' -or $k.KeyChar -eq 'S') {
                Write-Host ""
                $script:steerNote = (Read-Host "Steer (note injected into all remaining turns, empty cancels)").Trim()
                if ($script:steerNote) { Write-Host "  steering note armed." -ForegroundColor Magenta }
                return
            }
        }
        Start-Sleep -Milliseconds 100
    }
}

# ---------- context window: notes carry the memory, only the transcript tail rides along ----------
function Get-ContextWindow([int]$tailTurns = 4) {
    if ($script:transcript.Count -eq 0) { return "(nothing yet - you are opening the discussion)" }
    if ($script:transcript.Count -le $tailTurns) { return ($script:transcript -join "`n`n") }
    $tail = ($script:transcript | Select-Object -Last $tailTurns) -join "`n`n"
    return ("(earlier exchanges omitted to save tokens - the WORKING NOTES above carry everything settled so far)`n`n" + $tail)
}

# ---------- the conversation ----------
$sw = [Diagnostics.Stopwatch]::StartNew()
$halfway = [int][Math]::Ceiling($Exchanges / 2)
$twoPhase = ($f.Contains("briefA2") -and $f.briefA2)
$transcript = @()
$script:totalIn = 0; $script:totalOut = 0   # token ledger for the whole run
$completed = 0
:loop for ($x = 1; $x -le $Exchanges; $x++) {
    $phase2 = ($twoPhase -and $x -gt $halfway)
    $briefA = if ($phase2) { $f.briefA2 } else { $f.briefA }
    $briefB = if ($phase2) { $f.briefB2 } else { $f.briefB }
    if ($twoPhase -and $x -eq ($halfway + 1)) {
        Write-Host "=== phase shift: converging ===" -ForegroundColor Magenta
    }

    $steerBlock = if ($steerNote) { "`n`nOPERATOR NOTE FROM THE HUMAN (must be respected): " + $steerNote } else { "" }
    $soFar = Get-ContextWindow
    $pA = @"
$briefA

$lengthRule

WORKING NOTES (the shared record - treat as ground truth):
$notes

CONVERSATION SO FAR:
$soFar$steerBlock

Your turn (exchange $x of $Exchanges):
"@
    Write-Host ("=== A (" + $ModelA + ") - exchange " + $x + "/" + $Exchanges + " [" + $sw.Elapsed.ToString("mm\:ss") + "] ===") -ForegroundColor Cyan
    $rA = Invoke-ConsultTurnSafe $ModelA $pA
    if ($null -eq $rA) { if ($transcript.Count -eq 0) { throw "first turn failed twice - nothing to synthesize" }; Write-Host "  moving to synthesis with the partial transcript." -ForegroundColor Yellow; break loop }
    $transcript += ("A: " + $rA)
    Write-Host $rA
    Write-Host ""

    $soFar = Get-ContextWindow
    $pB = @"
$briefB

$lengthRule

WORKING NOTES (the shared record - treat as ground truth):
$notes

CONVERSATION SO FAR:
$soFar$steerBlock

Your turn (exchange $x of $Exchanges):
"@
    Write-Host ("=== B (" + $ModelB + ") - exchange " + $x + "/" + $Exchanges + " [" + $sw.Elapsed.ToString("mm\:ss") + "] ===") -ForegroundColor Yellow
    $rB = Invoke-ConsultTurnSafe $ModelB $pB
    if ($null -eq $rB) { Write-Host "  moving to synthesis with the partial transcript." -ForegroundColor Yellow; break loop }
    $transcript += ("B: " + $rB)
    Write-Host $rB
    Write-Host ""

    $completed = $x
    ($transcript -join "`n`n---`n`n") | Set-Content $transcriptPath -Encoding utf8
    if (($Exchanges -gt 2) -and (($x % 2 -eq 0) -or ($x -eq $Exchanges) -or ($x -eq $halfway))) { Update-WorkingNotes (($transcript | Select-Object -Last 2) -join "`n`n") }   # scribe: skipped at Small (window covers it); else every 2nd + phase shift + final

    if ($autoConverge -and $x -ge $minExchanges -and $x -lt $Exchanges) {
        $lastTwo = ($transcript | Select-Object -Last 2) -join "`n`n"
        $pJ = "You are the convergence judge for a two-AI conversation. Read the latest exchange below. Did it produce a genuinely new decision, insight, or direction - or are the participants circling what is already settled? Reply with exactly one word: CONTINUE or CONVERGED. LATEST EXCHANGE: " + $lastTwo
        $verdict = Invoke-ConsultTurnSafe $ModelB $pJ
        if ($verdict -and $verdict -match "CONVERGED") {
            Write-Host ("=== auto-stop: converged after " + $x + " exchanges ===") -ForegroundColor Magenta
            break loop
        }
    }

    Read-SteerKey
}
$sw.Stop()

# ---------- synthesis: FINAL.md is built primarily from notes.md ----------
$full = Get-ContextWindow 6   # windowed: notes.md is the primary source, the tail is backup detail
$partial = if ($completed -lt $Exchanges) { "`n`nNOTE: the conversation ended after " + $completed + " of " + $Exchanges + " exchanges - synthesize from what exists." } else { "" }
$pF = @"
$($f.synthesis)

$lengthRule$partial
Return ONLY the markdown document - no preamble, no closing offers, no conversation.

ACTIONABILITY RULE: if the natural output of this conversation is a plan or a spec (software, develop, website, extend/openclaw, brainstorm, interviewer), the document MUST end with a section titled exactly "## Executable plan": numbered tasks in dependency order, each task carrying a Prove: line with a real validation command (a test, a curl, a build, a file check) so the plan can be executed and gate-verified directly. If a plan is not the natural output of this format (debate, general, decide), omit that section entirely.

ORIGINAL INPUT:
$ideaText

WORKING NOTES (the distilled record - your primary source):
$notes

CONVERSATION (backup detail):
$full
"@
Write-Host "=== Synthesis + Normaliser (one call) ===" -ForegroundColor Green
$combinedPrompt = $pF + "`n`nAFTER the markdown document, output exactly this delimiter on its own line: ===STRUCTURED=== - then the STRICT JSON object matching this schema, no markdown fences, no commentary: " + $f.schema + " Fill every field from the record above; use an empty array or the string 'none' when genuinely absent; never invent content."
$combined = Invoke-ConsultTurnSafe $ModelA $combinedPrompt
$final = $null; $jsonText = $null
if ($combined -and $combined -match '===STRUCTURED===') {
    $parts = $combined -split '===STRUCTURED===', 2
    $final = $parts[0].Trim()
    $jsonText = ($parts[1] -replace '(?s)^\s*```(json)?\s*', '' -replace '(?s)```\s*$', '').Trim()
    try { $null = ($jsonText | ConvertFrom-Json -ErrorAction Stop) } catch { $jsonText = $null }
}
if (-not $final) { $final = $combined }
if ($null -eq $final) { $final = "(synthesis failed - notes.md and transcript.md in " + $ws + " hold everything)" }
$final | Set-Content $finalPath -Encoding utf8
Write-Host $final
Write-Host ""
if ($jsonText) {
    ($jsonText | ConvertFrom-Json | ConvertTo-Json -Depth 30) | Set-Content $jsonPath -Encoding utf8
    $normalised = $true
    Write-Host "  structured.json written + validated (same call - one model call saved)" -ForegroundColor Magenta
} else {
    Write-Host "  (combined reply lacked valid JSON - running the standalone normaliser as fallback)" -ForegroundColor Yellow
    $normalised = Invoke-Normaliser
    if (-not $normalised) { Write-Host "  normaliser failed - FINAL.md is unaffected; notes.md + transcript.md hold everything" -ForegroundColor Yellow }
}
# ---------- wrap-up: history, clipboard, telegram ----------
$histLine = $stamp + " | " + $Format + " | " + $ModelA + " vs " + $ModelB + " | " + $completed + "/" + $Exchanges + " exchanges | " + $sw.Elapsed.ToString("mm\:ss") + $(if ($Label) { " | " + $Label } else { "" }) + " | " + $script:totalIn + "in/" + $script:totalOut + "out tok | " + $ws
Add-Content $indexPath $histLine -Encoding utf8
try { $final | Set-Clipboard; Write-Host "(final document copied to clipboard)" -ForegroundColor DarkGray } catch {}
Write-Host ("  tokens:          " + $script:totalIn + " in / " + $script:totalOut + " out (" + ($script:totalIn + $script:totalOut) + " total)") -ForegroundColor Green
Write-Host ("Consult complete in " + $sw.Elapsed.ToString("mm\:ss") + ".") -ForegroundColor Green
Write-Host ("  FINAL.md:        " + $finalPath) -ForegroundColor Green
Write-Host ("  structured.json: " + $jsonPath + $(if ($normalised) { "" } else { " (failed - see notes.md)" })) -ForegroundColor Green
Write-Host ("  notes.md:        " + $notesPath) -ForegroundColor DarkGray
Write-Host ("  transcript.md:   " + $transcriptPath) -ForegroundColor DarkGray
if (Get-Command Send-CicadaTelegram -ErrorAction SilentlyContinue) {
    Send-CicadaTelegram ("CICADA consult [" + $Format + "] complete | " + $completed + "/" + $Exchanges + " exchanges in " + $sw.Elapsed.ToString("mm\:ss") + " | " + $ModelA + " vs " + $ModelB + $(if ($Label) { " | " + $Label } else { "" }))
}



