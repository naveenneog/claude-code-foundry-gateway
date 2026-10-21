# ADR-0065: Client-declared project identifier for chargeback

**Status:** Proposed
**Date:** 2026-10-21
**Packet:** P119

## Context

Chargeback groups spend by the caller's business unit, which comes from Entra
membership and the access projection. Customers also need spend by project,
and one person works on several projects, so membership cannot supply it.

Claude Code adds custom request headers from `ANTHROPIC_CUSTOM_HEADERS`
(`Name: Value`, newline-separated; Claude Code v2.1.227 or later). The variable
can be set per repository in `.claude/settings.json` `env`, or through managed
settings
([environment variables](https://code.claude.com/docs/en/env-vars),
[settings files](https://code.claude.com/docs/en/settings), read 2026-10-21).

## Decision

1. The gateway reads one request header, `x-claude-project`.
2. The value is trimmed and lower-cased. It is accepted when it matches
   `^[a-z0-9][a-z0-9._-]{0,63}$`. A missing or empty header is recorded as
   `unspecified`; any other value is recorded as `invalid`. The request is not
   refused: the identifier is reporting data, not an authorization input.
3. The gateway removes the header before forwarding to Foundry and returns the
   recorded value to the client in the `x-claude-project` response header, so
   a developer can see `unspecified` or `invalid`.
4. The chargeback identity trace carries `ProjectId`. `ClaudeChargeback()`
   exposes `project_id`; `ClaudeCost()` groups metered spend by it.
5. Cache-read spend comes from a per-user metric with no request identity, so
   it is reported as project `cache (no project)` rather than allocated.
6. The chargeback workbook adds a Project filter and a spend-by-project table
   alongside the business-unit view.

## Consequences

+ Business unit (who pays, from membership) and project (what the work was for,
  from the client) are independent columns in the same report.
+ No per-project configuration is needed in APIM; new projects appear on first use.
- The person or repository supplies the value, so it is showback data. It
  cannot enforce a project budget and can be mislabeled.
- Clients that do not support custom headers report `unspecified`.
- Cache-read cost cannot be split by project.

## Alternatives considered

**Registered project list in a named value.** Rejects typos but adds an
administrative step for every project; deferred until per-project budgets are
needed.

**Refuse requests without a project.** Would block every client that cannot set
headers; rejected for a reporting dimension.
