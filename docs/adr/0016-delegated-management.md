# ADR-0016: Management is delegated through Entra manager groups, and only admins and managers use Turnstile

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** P45 (phase 1); P46 to P48 plan the rest
- **Deciders:** claude-code-foundry-gateway maintainers, platform owner

## Context

At 500,000 developers, one administrator deciding every unit, team, person and budget is the
bottleneck. The owner decided: managers are defined by Entra manager groups; each unit or team
budget is strict by default, and the platform admin may set it to allowance or notify only;
developers never sign in to Turnstile; and it must be testable with subscription Owner and app
owner rights, without a tenant administrator.

Verified this session: the owner owns Turnstile's app registration and enterprise application;
assigning a group to the application works in this tenant (Entra ID P1); the Azure CLI is
pre-authorized on Turnstile's API, so its token needs no consent and carries the caller's app
roles; no consent grant exists for Turnstile's web sign-in, and users cannot consent (U19).

## Options considered

1. **Manager scopes kept in a role list inside Turnstile.** No P1 needed, but a second place that
   decides who is who, outside Entra's lifecycle and access reviews. Not chosen.
2. **Entra manager groups, read from the sign-in token (chosen).** The application emits only
   the groups assigned to it (ApplicationGroup), so a token names a person's manager groups and
   nothing else, and Turnstile needs no directory permission to read a scope.
3. **Entra app roles alone.** An app role cannot carry a scope: every manager would see and
   manage everything.

## Decision

Option 2. Entra decides who; Turnstile decides how much; the gateway enforces.

- App roles: `Turnstile.Admin` signs in as Owner; `Turnstile.Viewer` and `Turnstile.Manager` as
  Member, read-only; anyone else is refused before an account is written.
- A manager's reach is the units and teams whose manager group is in their token (phase 2).
- Allocation is strict in every enforcement mode: a manager hands out only their own budget.
  Enforcement per unit or team is the platform admin's choice: strict, allowance, or notify.
- Until the tenant consents to Turnstile's web sign-in, people sign in through the Azure CLI:
  `Open-ClaudeTurnstile.ps1` exchanges the CLI's token for a code that works once, within a
  minute.

## Consequences

+ No tenant administrator is needed to add roles, assign people or manager groups, or sign in.
+ Access reviews, joiners and leavers stay in Entra.
− Until phase 2, a manager sees what a viewer sees: everything, read-only.
− Manager groups must be assigned to the Turnstile application, which needs Entra ID P1.
− Signing in through the Azure CLI needs the CLI; the normal button needs the one-time consent.

## How we'd know this was wrong

- Managers needing a scope that is not a unit or a team, such as a cost center across units.
- Tokens overflowing because too many groups are assigned to the application.
- The tenant refusing group assignment to applications, leaving only per-person assignment.