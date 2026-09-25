import { az, ps } from './turnstile-live.mjs';
import { choose } from './azure-targets.mjs';
import { DISCOVERY_TYPES } from './portal-specs.mjs';

export function discoveryArguments(args, account, current) {
  if (args[0] === 'ad') {
    if (!account.tenantId || account.tenantId.toLowerCase() !== current.tenantId?.toLowerCase())
      throw new Error('Entra discovery requires the selected subscription to use the current Azure CLI tenant');
    return [...args, '-o', 'json'];
  }
  return [...args, '--subscription', account.id, '-o', 'json'];
}

export async function createResolver(options) {
  const unattended = options.nonInteractive || !process.stdin.isTTY;
  const current = JSON.parse(az(['account', 'show', '-o', 'json']));
  const account = options.subscription
    ? await choose('subscription', JSON.parse(az(['account', 'list', '-o', 'json']))
      .filter((item) => item.state === 'Enabled'), options.subscription, current.id, unattended)
    : current;
  const recordedGroup = ps('& ./scripts/Get-ClaudeGatewayTarget.ps1 ResourceGroup 3>$null');
  const recordedGateway = ps('& ./scripts/Get-ClaudeGatewayTarget.ps1 ApimName 3>$null');
  const lists = new Map();
  const json = (args) => JSON.parse(az(discoveryArguments(args, account, current)));
  return async (target) => {
    let candidates;
    const filter = target.nameFilterEnv ? process.env[target.nameFilterEnv]?.trim() : undefined;
    if (target.nameFilterEnv && !filter) throw new Error(`Set ${target.nameFilterEnv} to a discovered name filter`);
    if (target.discover === 'entra-app') {
      const key = `apps:${filter}`;
      if (!lists.has(key)) lists.set(key, json(['ad', 'app', 'list', '--display-name', filter, '--all']));
      candidates = lists.get(key).map((item) => ({ ...item, name: item.displayName }));
    } else if (target.discover === 'entra-group') {
      const key = `groups:${filter}`;
      if (!lists.has(key)) lists.set(key, json(['ad', 'group', 'list', '--display-name', filter]));
      candidates = lists.get(key).map((item) => ({ ...item, name: item.displayName }));
    } else {
      const type = DISCOVERY_TYPES[target.discover] ?? target.resourceType;
      if (!lists.has(type)) lists.set(type, json(['resource', 'list', '--resource-type', type]));
      candidates = lists.get(type).filter((item) =>
        (!options.resourceGroup || item.resourceGroup?.toLowerCase() === options.resourceGroup.toLowerCase())
        && (!filter || item.name.toLowerCase().includes(filter.toLowerCase()))
        && Object.entries(target.tags ?? {}).every(([key, value]) => item.tags?.[key] === value));
    }
    const selection = target.selectionKey ?? target.discover;
    const requested = options.selections[selection];
    const preferred = target.discover === 'gateway'
      ? candidates.find((item) => item.name === recordedGateway && (!recordedGroup || item.resourceGroup === recordedGroup))?.id
      : undefined;
    let selected;
    try { selected = await choose(target.discover, candidates, requested, preferred, unattended); }
    catch (error) { throw new Error(`${error.message} Use --select ${selection}=<one-discovered-id-or-name>.`); }
    if (target.discover === 'entra-app') {
      // One application may back registration and enterprise-app captures in this batch.
      let principal;
      try { principal = json(['ad', 'sp', 'show', '--id', selected.appId]); }
      catch { /* Registration-only captures still work; enterprise URL resolution fails closed. */ }
      // Users and service principals assigned to the application appear on its Users and
      // groups page; the capture pseudonymises them (peopleRedactionPairs).
      let people;
      if (principal?.id) {
        try {
          people = JSON.parse(az(['rest', '--method', 'GET', '--url',
            `https://graph.microsoft.com/v1.0/servicePrincipals/${principal.id}/appRoleAssignedTo?$select=principalDisplayName,principalType`, '-o', 'json']))
            .value.filter((item) => item.principalType !== 'Group').map((item) => ({ displayName: item.principalDisplayName }));
        } catch { /* A page that needs them refuses to capture without them. */ }
      }
      return { ...selected, servicePrincipalId: principal?.id, people, tenantId: account.tenantId, subscriptionName: account.name };
    }
    if (target.discover === 'entra-group') {
      // A group's direct members are shown on its Members page; groups among them are this
      // deployment's governance groups, people are pseudonymised by the capture.
      let people;
      try {
        people = json(['ad', 'group', 'member', 'list', '--group', selected.id])
          .filter((item) => !String(item['@odata.type'] ?? '').endsWith('.group'))
          .map((item) => ({ displayName: item.displayName }));
      } catch { /* A page that needs them refuses to capture without them. */ }
      return { ...selected, people, tenantId: account.tenantId, subscriptionName: account.name };
    }
    return { ...selected, tenantId: account.tenantId, subscriptionName: account.name };
  };
}
