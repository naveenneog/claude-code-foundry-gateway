# ADR-0056: User guides open with quickstarts and use section disclosures

- **Status:** Accepted

- **Date:** 2026-10-07

- **Packet:** P103

- **Deciders:** Owner, implementing agent

## Context

The owner stated the intent for P103 as:

> "my intention is to keep the sections of quickstart at the start and have sections accordions in our documentation"

>

> "crisp and follow through documentation is whats intended"

A read-only documentation review on 2026-10-06 found that the repository's user-facing guides mix long introductions, historical evidence, reference material and procedures before the first copyable route. The same review found stale projection facts in `docs/AUTHENTICATION.md` and `docs/DECISIONS.md`, real person names in `docs/BUSINESS-UNITS.md`, and many guides whose prerequisite and input definitions follow commands that use them.

GitHub documents collapsed sections with `<details>` and `<summary>` and requires blank lines around Markdown content for reliable parsing ([GitHub collapsed sections](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/organizing-information-with-collapsed-sections), read 2026-10-06; [GFM HTML blocks](https://github.github.com/gfm/#html-blocks), read 2026-10-06). GitHub documents automatic heading links and custom anchors, while excluding custom anchors from the Outline ([GitHub basic writing syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax), read 2026-10-06). The HTML standard's ancestor revealing algorithm covers closed `details` for fragment and find-in-page navigation, but the review did not verify GitHub's browser-specific behavior for every target ([WHATWG ancestor revealing algorithm](https://html.spec.whatwg.org/multipage/interaction.html#ancestor-revealing-algorithm), read 2026-10-06).

## Options considered

1. **Summary-only accordion headings.** Each H2 becomes only a `<summary>` label and its body, including the old heading, is hidden. This gives the most compact closed view, but depends on hidden heading navigation and a GitHub Outline behavior that the review did not verify.

2. **Visible headings with disclosed bodies.** The H1, purpose, `## Quickstart`, every H2 heading and a terminal navigation section remain visible. Each non-terminal H2 body sits inside one flat `<details>` block whose summary is plain text. This keeps heading anchors and main navigation visible.

3. **No structural convention.** Guides receive piecemeal wording fixes. This leaves the owner's follow-through problem unresolved and creates no testable authoring contract.

## Decision

Choose option 2.

Each enrolled user guide has one visible H1, a short purpose line, a visible first H2 named `Quickstart`, prerequisite and input definitions before the first command or route, an `Expected result`, every other non-terminal H2 heading visible with its whole body inside one flat `<details><summary>plain text</summary> ... </details>` block, H3 and deeper headings unchanged inside bodies, and a visible final Next/Related/See also section. The convention uses native `details` and `summary`; it does not use CSS, JavaScript, exclusive disclosure groups, summary-heading tricks or handwritten ARIA.

The rollout is staged by an explicit enrollment list in `tests/Test-DocStructure.ps1`. The list only grows during P103. Original heading anchors are checked for the full guide set from the start.

Permanent exceptions:

| Guide/artifact | Exception | Reason |

|---|---|---|

| `docs/CLI-FINOPS.md` | No mandatory Quickstart/disclosures | Nine-line redirect; visible canonical links are the shortest path |

| `docs/aum-usd-budgets-client-contract.md` | Reference entry and schema may remain visible | HTTP schema/revision reference; an executable bearer-token sample would invent prerequisites |

| `docs/AZ-COMMANDS.md` | Reference-navigation Quickstart; command-reference bodies may remain visible during this rollout | Strict fence, marker, portal-purpose and receipt contracts; broader rewrite waits for P99/P100 merges |

| `docs/REFERENCE.md` | Repository-layout reference body may remain visible | The visible index is the reference artifact |

| `docs/STATUS.md`, `docs/ROADMAP.md`, `docs/UNKNOWNS.md`, `docs/CHARTER.md`, `CHANGELOG.md`, ADRs and status archives | Outside guide-structure scope | Ledgers, history and version records have their own shapes; links remain validated |

## Consequences

+ Primary guide anchors remain visible and stable.

+ Quickstarts become testable as the first reader path instead of a convention held in prose.

+ Long evidence and reference sections remain available without dominating the first screen.

− Diffs are large because whole section bodies move into HTML disclosure blocks.

− Closed H3/H4 targets still rely on each browser and GitHub revealing closed ancestors, or on the reader opening the containing section.

− Printing and screen-reader behavior need rendered/human review; offline tests cannot prove them.

## How we'd know this was wrong

The decision should be revisited if GitHub stops parsing Markdown inside blank-separated `details` bodies, repository Outline omits headings inside bodies that readers need, fragment navigation to body headings remains closed in supported browsers, print previews omit required content without a practical reader workaround, screen-reader testing shows worse navigation than the current long pages, or support requests show readers miss required steps hidden outside the Quickstart.

