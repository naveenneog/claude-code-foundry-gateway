/**
 * Captures the annotated screenshots for the UI guide.
 *
 * Steps are declared as data: where to go, what to wait for, which live
 * elements to ring, and what the caption says. Auth-gated steps are marked
 * `needsAuth` and skipped with a clear message when the profile has no portal
 * session, so the script always produces whatever it can rather than failing
 * wholesale.
 *
 * Run `node guide/auth.mjs` once first to sign the profile in.
 */
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { annotate, resolveTargets } from './lib/annotate.mjs';

const PROFILE = path.resolve('.pw-profile');
const OUT = path.resolve('docs/guide');
const ONLY = process.argv.slice(2).filter((a) => !a.startsWith('-'));

const RESOURCE = process.env.FOUNDRY_RESOURCE ?? 'ai-contosohub530569751908';
const RG = process.env.GATEWAY_RG ?? 'rg-contosohub';
const APIM = process.env.APIM_NAME ?? 'apim-claude-gw-fzgql9';
const SUB = process.env.AZURE_SUB ?? '';
const TENANT = process.env.AZURE_TENANT ?? '';

const portal = (p) => `https://portal.azure.com/#@${TENANT}/resource${p}`;
const apimId = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}`;
const aiId = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Insights/components/appi-claude-gateway`;
const foundryId = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${RESOURCE}`;

const STEPS = [
  {
    id: 'a1-repo',
    url: 'https://github.com/naveenneog/claude-code-foundry-gateway',
    needsAuth: false,
    maskIdentity: false,
    settle: 4500,
    banner: {
      n: 1,
      title: 'Get the accelerator',
      note: 'git clone https://github.com/naveenneog/claude-code-foundry-gateway',
    },
    targets: [{ sel: 'a[href*="portal.azure.com/#create"] img', n: 1, pad: 6 }],
  },
  {
    id: 'a2-deploy-form',
    url: 'https://portal.azure.com/#create/Microsoft.Template',
    needsAuth: true,
    settle: 16000,
    banner: {
      n: 2,
      title: 'Custom deployment — supply the Foundry account',
      note: 'Everything else is defaulted by the template',
    },
  },
  {
    id: 'a3-apim-overview',
    url: () => portal(apimId + '/overview'),
    needsAuth: true,
    settle: 16000,
    banner: {
      n: 3,
      title: 'Confirm the gateway tier',
      note: 'Must be a v2 SKU — classic tiers cannot meter Anthropic tokens',
    },
  },
  {
    id: 'a4-identity',
    url: () => portal(apimId + '/identity'),
    needsAuth: true,
    settle: 14000,
    banner: {
      n: 4,
      title: 'Turn on the gateway managed identity',
      note: 'This becomes the only principal that may call Foundry',
    },
  },
  {
    id: 'a5-foundry-rbac',
    url: () => portal(foundryId + '/users'),
    needsAuth: true,
    settle: 16000,
    banner: {
      n: 5,
      title: 'Grant Cognitive Services User to the gateway only',
      note: 'Any other principal here is a way around the budget',
    },
  },
  {
    id: 'a6-named-values',
    url: () => portal(apimId + '/namedValues'),
    needsAuth: true,
    settle: 16000,
    banner: {
      n: 6,
      title: 'Set the budgets',
      note: 'tpm-* and quota-* are per-developer limits; allow-* hold entitled object ids',
    },
  },
  {
    id: 'a7-policy',
    url: () => portal(apimId + '/apis'),
    needsAuth: true,
    settle: 16000,
    banner: {
      n: 7,
      title: 'The claude API and its inbound policy',
      note: 'Token validation, tier lookup, rate limit, quota, metric, identity swap',
    },
  },
  {
    id: 'a8-chargeback',
    url: () => portal(aiId + '/metrics'),
    needsAuth: true,
    settle: 17000,
    banner: {
      n: 8,
      title: 'Chargeback',
      note: 'Namespace claudecode → Total Tokens → split by User',
    },
  },
  {
    id: 'b1-marketplace',
    url: 'https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code',
    needsAuth: false,
    maskIdentity: false,
    settle: 6000,
    banner: {
      n: 9,
      title: 'Developer step — install the extension',
      note: 'code --install-extension anthropic.claude-code',
    },
    targets: [{ sel: '.install-button-container, .ux-oneclick-install-button-container', n: 9, pad: 6 }],
  },
];

async function isSignedIn(page) {
  await page.goto('https://portal.azure.com/', { waitUntil: 'domcontentloaded' }).catch(() => {});
  await page.waitForTimeout(9000);
  return page.url().includes('portal.azure.com') && !page.url().includes('login.microsoftonline');
}

const ctx = await chromium.launchPersistentContext(PROFILE, {
  channel: 'msedge',
  headless: false,
  viewport: { width: 1600, height: 1000 },
  args: ['--no-first-run', '--no-default-browser-check'],
});

const page = ctx.pages()[0] ?? (await ctx.newPage());
fs.mkdirSync(OUT, { recursive: true });

const wanted = STEPS.filter((s) => !ONLY.length || ONLY.includes(s.id));
const needAuth = wanted.some((s) => s.needsAuth);
const authed = needAuth ? await isSignedIn(page) : false;

if (needAuth) {
  console.log(authed ? 'portal session: active' : 'portal session: NONE — run `node guide/auth.mjs` first');
  console.log('');
}

const done = [];
const skipped = [];

for (const step of wanted) {
  if (step.needsAuth && !authed) {
    skipped.push(step.id);
    console.log(`skip ${step.id}  (needs portal sign-in)`);
    continue;
  }

  const url = typeof step.url === 'function' ? step.url() : step.url;
  console.log(`shot ${step.id}  ${step.banner?.title ?? ''}`);

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(step.settle ?? 8000);

    const highlights = await resolveTargets(page, step.targets ?? []);
    const buf = await page.screenshot({ type: 'png' });

    await annotate(buf, path.join(OUT, `${step.id}.png`), {
      banner: step.banner,
      highlights,
      maskIdentity: step.maskIdentity !== false,
    });
    done.push(step.id);
  } catch (err) {
    console.log(`  FAILED: ${String(err).split('\n')[0]}`);
    skipped.push(step.id);
  }
}

console.log('');
console.log(`captured ${done.length}: ${done.join(', ') || '(none)'}`);
if (skipped.length) console.log(`skipped  ${skipped.length}: ${skipped.join(', ')}`);

await ctx.close();
