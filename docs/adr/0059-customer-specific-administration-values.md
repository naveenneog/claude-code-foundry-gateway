# ADR-0059: Administration scripts use the customer's own values

Status: Proposed (2026-10-08), at the owner's request of 2026-10-08 after a customer test: "It has to be
customer specific, no hardcoding." Supersedes the default-name step of [ADR-0057](0057-one-sync-command.md)
decision 2 and refines how a dollar budget becomes enforced under [ADR-0026](0026-usd-budget-reconciliation.md).

## Context

A customer ran the business-unit menu and the sync from a clone without the installer's decision record
(`onboarding/claude-gateway.json`), on a gateway installed with the customer's own tier group names. The
failures are listed in [P107 status](../status/P107.md#why):

- The sync resolves tier groups from parameters, then the gateway's `entitlement-groups`, then the decision
  record, then the built-in names `claude-code-standard` and `claude-code-premium`
  (`scripts/ClaudeEntitlementGroups.ps1:70-81`). The record exists only on the machine that ran the installer,
  and `entitlement-groups` exists only after a sync with named groups (ADR-0057 decision 3). The built-in name
  is looked up in the customer's tenant, is not found, and the sync stops.
- `scripts/Manage-ClaudeBusinessUnits.ps1` has no tier group parameters, takes its resource group only from the
  record, and shows the menu for any `-ApimName` text without reading the gateway.
- `Set-ClaudeBusinessUnit.ps1 -MonthlyBudgetUsd` writes a dollar budget for every unit, and a new unit is Strict.
  ADR-0026 fails closed for "an enabled dollar budget without a matching fresh state", and no state exists
  until a reconciler runs. The unit's developers get 503 for every request.

## Options

1. Keep the built-in names and improve the messages. The menu still cannot recover, and any customer that
   named its own groups meets the failure on every new machine.
2. Ask for every missing value in every script. Unattended callers (AUM, the sync job, tests) cannot answer.
3. Resolve each value from the customer's own records: parameters, then what the gateway records, then this
   gateway's decision record; ask a person once in an interactive session and record the answer on the gateway;
   stop without a console, naming the command with this gateway's names. Built-in names are never looked up.

For dollar budgets:

a. Leave the writer as it is and document the reconciler. Typing a budget still stops a unit's traffic.
b. Change the gateway policy so a never-reconciled state does not enforce dollars. This weakens ADR-0026's
   fail-closed rule for every gateway and needs a policy upload.
c. Enforce a dollar budget only when the gateway can reconcile it: the writer writes the dollar budget of a
   Strict or Allowance unit when `usd-budget-state` is valid now, or when the operator passes `-EnforceUsd`
   (the documented opt-in before the first reconciliation); otherwise it writes the token budget and says the
   dollar budget is not enforced. The policy and ADR-0026's fail-closed rule stay unchanged.

## Decision

1. Option 3 for tier groups and the gateway target. Tier groups come from `-StandardGroup`/`-PremiumGroup`,
   then `entitlement-groups`, then this gateway's decision record. With none, an interactive sync asks for both
   groups, shows each one's display name and object id from Microsoft Graph, syncs after confirmation and
   records `entitlement-groups`; a run without a console stops before any write with the full command,
   including `-ResourceGroup` and `-ApimName`. The same order replaces the built-in defaults of the projection,
   import and Turnstile scripts.
2. The installer records `entitlement-groups` for both stores, including a new projection gateway, so a gateway
   carries its tier groups from its first install. Its named defaults stay: they appear in its review before
   any write.
3. The menu resolves the gateway once, through its parameters, `CLAUDE_RG`/`CLAUDE_APIM` or the decision record,
   then the shared chooser (`scripts/ClaudeChoice.ps1`); it reads the gateway before the menu and passes the
   same resource group, gateway and tier groups to every script it starts.
4. Option c for dollar budgets. Whenever a gateway holds a dollar budget for a Strict or Allowance scope and its
   state is not valid, the writer, the sync and the menu name the scopes that return 503 and both remedies:
   deploy a reconciler, or clear the dollar budgets.
5. No pre-filled names: the menu's unit prompt has no default group name.

## Consequences

- A customer with its own group names syncs from any machine after one answered prompt, or one run with
  `-StandardGroup`/`-PremiumGroup`; the answer is stored on the gateway, not on the machine.
- Unattended runs never guess: they stop with a command that names the gateway's own values.
- `docs/BUDGETS.md` step 4 adds `-EnforceUsd` for a budget set before the first reconciliation. A gateway that
  already reconciles is unchanged.
- A gateway that already holds dollar budgets without a reconciler keeps returning 503 for those scopes until
  one of the named remedies; the new detector says so wherever an operator works.
