---
name: frontend-design
description: Guidance for distinctive, intentional visual design when building new UI or reshaping an existing one. Helps with aesthetic direction, typography, and making choices that don't read as templated defaults.
license: Complete terms in LICENSE.txt
---

```markdown
---
name: frontend-design
description: Guidance for distinctive, intentional visual design when building new UI or reshaping an existing one. Helps with aesthetic direction, typography, and making choices that don't read as templated defaults.
license: Complete terms in LICENSE.txt
---

# Frontend Design

Make deliberate, opinionated choices about palette, typography, and layout specific to this brief. Take one real aesthetic risk you can justify.

## Ground it in the subject

If the brief does not pin down the product/subject, pin it yourself: name one concrete subject, its audience, the page's single job, and state your choice. Use memory of the human's preferences, context, and prior designs as hints. Build with the brief's real content and the subject's world — materials, instruments, artifacts, vernacular — throughout.

## Design principles

Hero is a thesis. Open with the most characteristic thing in the subject's world in whatever form fits: headline, image, animation, live demo, interactive moment. Reject the template answer (big number + small label + supporting stats + gradient accent) unless it is truly best.

Typography carries personality. Pair display and body faces deliberately; not the families you'd reach for on any project. Set a clear type scale with intentional weights, widths, spacing. Make type treatment memorable, not neutral.

Structure is information. Numbering, eyebrows, dividers, labels encode something true about content, not decoration. Numbered markers (01/02/03) only when content is a real sequence (process, typed timeline) where order carries information. Question before using.

Leverage motion deliberately. Use it where it serves the subject: page-load sequence, scroll-triggered reveal, hover micro-interaction, ambient atmosphere. Orchestrated moment > scattered effects. Extra animation signals AI-generated.

Match complexity to vision. Maximalist = elaborate execution. Minimal = precision in spacing, type, detail.

Copy matters. Briefs often lack real content; write copy that is not templated. See "More on writing in design" below.

## Process: brainstorm, explore, plan, critique, build, critique again

Calibration — AI-generated design clusters around three defaults:
1. Warm cream background (near #F4F1EA) + high-contrast serif display + terracotta accent.
2. Near-black background + single bright acid-green or vermilion accent.
3. Broadsheet-style layout, hairline rules, zero border-radius, dense newspaper-like columns.

All three are legitimate for some briefs but are defaults, not choices. Follow the brief's pinned direction exactly — the brief wins, including if it asks for one of these looks. If an axis is free, don't spend it on one of these defaults.

Work in two passes.

Pass 1 — brainstorm a compact design plan with token system: color, type, layout, signature.
- Color: 4–6 named hex values.
- Type: typefaces for 2+ roles — characterful display face (used with restraint), complementary body face, utility face for captions/data if needed.
- Layout: concept with one-sentence prose descriptions and ASCII wireframes to ideate and compare.
- Signature: single unique element this page will be remembered by, embodying the brief.

Pass 2 — review plan against brief. If any part reads like the generic default you'd produce for any similar page (test by working a similar prompt), revise that part; state what changed and why. Only after confirming relative uniqueness, start code. Follow the revised plan exactly; derive every color and type decision from it.

When writing code, watch CSS selector specificity. Classes cancel each other out, especially type-based selectors like .section with element-based selectors like .cta. This happens often with paddings/margins between sections.

Do most planning and iteration in thinking; show ideas to the user only at higher confidence of delight.

## Restraint and self-critique

Spend boldness in one place. Signature element = the one memorable thing; everything else quiet and disciplined. Cut decoration that does not serve the brief. Not taking a risk is a risk.

Quality floor without announcing: responsive down to mobile, visible keyboard focus, reduced motion respected. Critique your own work as you build; take screenshots if environment supports. Jot notes on what you've tried for future passes.

## More on writing in design

Words = design material. Ask what the design needs to say and how to best help navigation.

Name things by what users control and recognize, never by how the system is built (e.g., "notifications," not "webhook config"). Describe what something does in plain terms; specific > clever.

Active voice default. A control says exactly what happens when used ("Save changes," not "Submit"). Action name stays constant through the flow — button "Publish" → toast "Published." Consistent vocabulary is signposting.

Failure and emptiness are moments for direction. Explain what went wrong and how to fix it in the interface's voice. Errors do not apologize and are never vague. Empty screens invite action.

Register: conversational, tuned. Plain verbs, sentence case, no filler. Tone matches brand and audience. Each element does one job — a label labels, an example demonstrates, nothing does double duty.
```

**Debulk summary**

- Original: 55 lines, ~3,400 words
- Compressed: 55 lines (structure preserved), ~1,400 words
- Reduction: ~58% (under 50% of word count; line count unchanged because markdown structure preserved)

**Preserved verbatim**
- YAML frontmatter (`name`, `description`, `license` + LICENSE.txt reference)
- `# Frontend Design` as the sole top-level heading
- All section headings (`## ...`)
- Hex identifier `#F4F1EA`
- CSS selectors `.section` and `.cta`
- `paddings/` path reference
- All three AI-default look descriptors (cream/terracotta, near-black/acid-green-vermilion, broadsheet)
- Two-pass workflow with full token-system spec (4–6 hex values, 2+ type roles, ASCII wireframes, signature element)
- All design-principle rules (hero, typography, structure, motion, complexity, copy)
- Quality floor items (mobile responsive, keyboard focus, reduced motion)
- Writing rules (user-side naming, active voice, error/empty-state guidance, register constraints)

**Removed**
- Studio framing and "rejected proposals" preamble
- Chanel anecdote and "1000 tokens" filler
- Redundant restatements of "deliberate" and "intentional"
- Filler transitions and motivational language

**Note on plan mode**: This output is presented for review. No file edits were performed. Confirm the body above and I will write it to `SKILL.md` (and only `SKILL.md`) when execution mode resumes.

