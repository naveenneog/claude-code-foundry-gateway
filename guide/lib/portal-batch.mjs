// Browser-independent orchestration; injected operations keep the contract tests offline.
export class AuthenticationSurface extends Error {
  constructor(reason) { super(reason); this.name = 'AuthenticationSurface'; }
}

export function authenticationReason({ url, texts = [], credentialInput = false }) {
  const body = texts.join('\n');
  const prompt = body.match(/Enter password|Pick an account|Approve sign in request|Verify your identity|Sign in to your account|Email, phone, or Skype|Stay signed in\?/i);
  if (prompt) return `Authentication prompt: ${prompt[0]}`;
  if (credentialInput && /login\.microsoftonline\.com|login\.live\.com/i.test(url))
    return 'Authentication credential form';
  return null; // A silent redirect without a prompt may return by itself.
}

// People are not deployment resources, so no private map can list them all in advance. A
// directory page (a group's members, an application's assignments) is redacted with the
// principals discovery read from the directory for that page; emails are removed by the
// Redactor's own rule. A people page whose principals were not discovered is refused.
export function peopleRedactionPairs(people, { required = false } = {}) {
  const names = [...new Set((people ?? []).map((person) => person?.displayName?.trim()).filter(Boolean))];
  if (required && !names.length)
    throw new Error('A page that lists people needs discovery to read them first; discover the principals before capturing');
  return names.map((name, index) => [name, `Contoso user ${index + 1}`]);
}

// The manifest names the commit that took each picture, so the capture code itself (the runner
// and its libraries) must be committed. Spec files may change between runs; each record
// carries the hash of the step it ran instead. Input: `git status --porcelain` output.
export function uncommittedCaptureCode(status) {
  return String(status).split(/\r?\n/).filter(Boolean)
    .map((line) => line.slice(3).trim().replace(/^"|"$/g, ''))
    .filter((file) => /^guide\/(?:[^/]+|lib\/.+)\.mjs$/.test(file) && !file.endsWith('.test.mjs'));
}

export function portalUrl(step, target) {
  const guid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
  const requireGuid = (value, name) => {
    if (!guid.test(value ?? '')) throw new Error(`Discovery did not provide a valid ${name}`);
    return value;
  };
  if (step.entraBlade) {
    const { kind, name } = step.entraBlade;
    if (kind === 'app-registration')
      return `https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/${name}/appId/${requireGuid(target.appId, 'application id')}`;
    if (kind === 'enterprise-application')
      return `https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/${name}/objectId/${requireGuid(target.servicePrincipalId, 'service principal id')}/appId/${requireGuid(target.appId, 'application id')}`;
    return `https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/${name}/groupId/${requireGuid(target.id, 'group id')}`;
  }
  if (typeof target.id !== 'string' || !target.id.startsWith('/subscriptions/') || /[?#]/.test(target.id))
    throw new Error('Discovery did not provide an ARM resource id');
  return `https://portal.azure.com/#@${requireGuid(target.tenantId, 'tenant id')}/resource${encodeURI(target.id)}${step.blade}`;
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  return value;
}

export async function resolvePlan(steps, resolver) {
  const cache = new Map();
  const resolved = [];
  const failed = [];
  for (const step of steps) {
    try {
      const key = JSON.stringify(stable(step.target));
      if (!cache.has(key)) cache.set(key, Promise.resolve().then(() => resolver(step.target)));
      const target = await cache.get(key);
      resolved.push({ step, target, url: portalUrl(step, target) });
    } catch (error) {
      failed.push({ id: step.id, output: step.output, reason: String(error.message) });
    }
  }
  return { resolved, failed };
}

export async function runBatch(plan, actions) {
  const result = { captured: [], skipped: [], failed: [], remaining: [], stoppedForAuthentication: false };
  for (let index = 0; index < plan.length; index++) {
    const item = plan[index];
    try {
      await actions.navigate(item.url);
      await actions.ensureAuthenticated();
      await actions.wait(item.step.waitFor);
      for (const click of item.step.clicks ?? []) {
        await actions.ensureAuthenticated();
        await actions.click(click);
        await actions.ensureAuthenticated();
        if (click.waitFor) await actions.wait(click.waitFor);
        if (click.settle) await actions.settle(click.settle);
      }
      if (item.step.settle) await actions.settle(item.step.settle);
      await actions.ensureAuthenticated();
      const capture = await actions.capture(item);
      result.captured.push({ id: item.step.id, output: item.step.output, ...capture });
    } catch (error) {
      if (!(error instanceof AuthenticationSurface)) {
        try { await actions.ensureAuthenticated(); }
        catch (auth) { if (auth instanceof AuthenticationSurface) error = auth; }
      }
      result.failed.push({ id: item.step.id, output: item.step.output, reason: String(error.message) });
      if (error instanceof AuthenticationSurface) {
        result.stoppedForAuthentication = true;
        result.remaining = plan.slice(index).map((entry) => entry.step.id);
        result.skipped.push(...plan.slice(index + 1).map((entry) => ({
          id: entry.step.id, output: entry.step.output, reason: 'Stopped at preceding authentication surface',
        })));
        break;
      }
    }
  }
  return result;
}

export function parseArguments(args) {
  const options = { only: [], selections: {}, nonInteractive: false, list: false, dryRun: false };
  for (let i = 0; i < args.length; i++) {
    const argument = args[i];
    if (['--list', '--dry-run', '--non-interactive', '--headed'].includes(argument)) {
      options[{ '--list': 'list', '--dry-run': 'dryRun', '--non-interactive': 'nonInteractive', '--headed': 'headed' }[argument]] = true;
      continue;
    }
    const value = args[++i];
    if (!value || value.startsWith('--')) throw new Error(`Missing value for ${argument}`);
    if (argument === '--only') options.only.push(...value.split(',').filter(Boolean));
    else if (argument === '--select') {
      const split = value.indexOf('=');
      if (split < 1 || split === value.length - 1) throw new Error('--select requires key=discovered-id-or-name');
      options.selections[value.slice(0, split)] = value.slice(split + 1);
    } else {
      const key = { '--profile': 'profile', '--subscription': 'subscription',
        '--resource-group': 'resourceGroup', '--report': 'report' }[argument];
      if (!key) throw new Error(`Unknown option ${argument}`);
      options[key] = value;
    }
  }
  if (options.list && options.dryRun) throw new Error('Choose --list or --dry-run, not both');
  return options;
}
