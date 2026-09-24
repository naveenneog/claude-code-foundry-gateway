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
import { discoverTargets } from './lib/azure-targets.mjs';
import { Redactor, capturePixels } from './lib/turnstile-live.mjs';

const PROFILE = path.resolve('.pw-profile');
const OUT = path.resolve('docs/guide');
const ONLY = process.argv.slice(2).filter((a) => !a.startsWith('-'));

const needsAzure = !ONLY.length || ONLY.some((id) => !['a1-repo', 'b1-marketplace'].includes(id));
const target = needsAzure ? await discoverTargets({
  subscription: process.env.AZURE_SUB, resourceGroup: process.env.GATEWAY_RG,
  apimName: process.env.APIM_NAME, foundry: process.env.FOUNDRY_RESOURCE,
  appInsights: process.env.APP_INSIGHTS_NAME, required: ['apim', 'foundry', 'appInsights'],
}) : null;
const RG = target?.resourceGroup ?? '';
const APIM = target?.apim?.name ?? '';
const SUB = target?.subscriptionId ?? '';
const TENANT = target?.tenantId ?? '';
if (needsAzure && !process.env.REDACTIONS_FILE) throw new Error('Set REDACTIONS_FILE before capturing private portal resources');
const redactor = new Redactor(process.env.REDACTIONS_FILE
  ? JSON.parse(fs.readFileSync(process.env.REDACTIONS_FILE, 'utf8').replace(/^\uFEFF/, '')) : []);

// Object id of the standard tier group, for the "add a member" capture.
// Find it with: az ad group show --group claude-code-standard --query id -o tsv
const STD_GROUP_ID = process.env.STANDARD_GROUP_ID ?? '';

const portal = (p) => `https://portal.azure.com/#@${TENANT}/resource${p}`;
const apimId = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}`;
const aiId = target?.appInsights?.id ?? '';
const foundryId = target?.foundry?.id ?? '';
// Printed by Publish-ClaudeWorkbook.ps1 when it publishes the chargeback
// workbook. It is a generated guid rather than a name, so it cannot be derived.
const WORKBOOK_ID = process.env.CHARGEBACK_WORKBOOK_ID ?? '';
const workbookId = `/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Insights/workbooks/${WORKBOOK_ID}`;

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

  // Day-2 operations. These back the Onboarding and Monitoring guides.
  {
    id: 'c2-entra-groups',
    url: () => `https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupsManagementMenuBlade/~/AllGroups/searchText/claude-code`,
    needsAuth: true,
    settle: 16000,
    banner: { title: 'Entra ID → Groups — the two tier groups', note: 'Membership is the entitlement; there is no per-user RBAC' },
  },
  {
    id: 'c3-group-members',
    url: () => `https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/${STD_GROUP_ID}`,
    needsAuth: true,
    settle: 16000,
    banner: { title: 'Add a developer to a tier', note: 'Adding here is not enough — run Sync-ClaudeAccess.ps1 afterwards' },
  },
  {
    id: 'c4-tier-budget',
    url: () => portal(apimId + '/namedValues'),
    needsAuth: true,
    settle: 16000,
    banner: { title: 'Change what a tier means', note: 'Edit tpm-* or quota-* — applied on the next request, no sync needed' },
  },
  {
    id: 'c5-metrics',
    url: () => portal(aiId + '/metrics'),
    needsAuth: true,
    settle: 17000,
    banner: { title: 'Chargeback — set aggregation to Sum', note: 'Avg is tokens per request, not consumption' },
  },
  // The money workbook. Published by ./scripts/Publish-ClaudeWorkbook.ps1 with
  // -WorkbookFile infra/workbook-chargeback.json, which prints the resource id;
  // set CHARGEBACK_WORKBOOK_ID to it. Workbooks run every tile's query on open,
  // so these settle far longer than a blade that only renders ARM properties.
  {
    id: 'd1-chargeback-totals',
    url: () => portal(workbookId),
    needsAuth: true,
    settle: 20000,
    click: 'text=Open Workbook',
    afterClick: 30000,
    banner: {
      title: 'Chargeback workbook — what the period cost',
      note: 'Spend, input, output and cache-read tokens, then spend per day by business unit',
    },
  },
  {
    id: 'd2-chargeback-units',
    url: () => portal(workbookId),
    needsAuth: true,
    settle: 20000,
    click: 'text=Open Workbook',
    afterClick: 30000,
    scrollTo: 1700,
    banner: {
      title: 'Chargeback workbook — by business unit and by developer',
      note: 'Metered and cache-read priced separately, and the parent each unit rolls up to',
    },
  },
  {
    id: 'd3-chargeback-models',
    url: () => portal(workbookId),
    needsAuth: true,
    settle: 20000,
    click: 'text=Open Workbook',
    afterClick: 30000,
    scrollTo: 3400,
    banner: {
      title: 'Chargeback workbook — by model, surface, and what cannot be trusted',
      note: 'Unpriced models, spend with no owner, and the dates behind the figures',
    },
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
  console.log(authed ? 'portal session: active' : 'portal sign-in required: stopped; report to the lead, do not sign in during capture');
  console.log('');
  if (!authed) { await ctx.close(); process.exit(1); }
}

const done = [];
const skipped = [];

for (const step of wanted) {
  if (step.needsAuth && !authed) {
    skipped.push(step.id);
    console.log(`skip ${step.id}  (needs portal sign-in)`);
    continue;
  }

  if (step.id === 'c3-group-members' && !STD_GROUP_ID) {
    skipped.push(step.id);
    console.log('skip c3-group-members  (set STANDARD_GROUP_ID)');
    continue;
  }

  if (step.id.startsWith('d') && !WORKBOOK_ID) {
    skipped.push(step.id);
    console.log(`skip ${step.id}  (set CHARGEBACK_WORKBOOK_ID - Publish-ClaudeWorkbook.ps1 prints it)`);
    continue;
  }

  const url = typeof step.url === 'function' ? step.url() : step.url;
  console.log(`shot ${step.id}  ${step.banner?.title ?? ''}`);

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    if (step.needsAuth && /login\.microsoftonline\.com|login\.live\.com/.test(page.url())) {
      console.log('  AUTH sign-in required; stopping portal capture without attempting sign-in');
      skipped.push(step.id);
      break;
    }
    await page.waitForTimeout(step.settle ?? 8000);

    // A workbook resource id opens the ARM overview blade, not the rendered
    // workbook - the content sits behind an "Open Workbook" button. Clicking it
    // is what the operator does, so the capture does it too.
    if (step.click) {
      const target = page.locator(step.click).first();
      if (await target.isVisible().catch(() => false)) {
        await target.click().catch(() => {});
        await page.waitForTimeout(step.afterClick ?? 25000);
      } else {
        console.log(`  note: ${step.click} not visible, capturing the page as it is`);
      }
    }

    // A workbook is one long page, so the lower sections are captured by
    // scrolling the blade's own scroll container rather than the window - the
    // portal renders into a nested pane and window.scrollTo moves nothing.
    if (step.scrollTo) {
      await page.evaluate((y) => {
        const scrollable = [...document.querySelectorAll('div')].find(
          (d) => d.scrollHeight > d.clientHeight + 200 && d.clientHeight > 400,
        );
        if (scrollable) scrollable.scrollTop = y;
        else window.scrollTo(0, y);
      }, step.scrollTo);
      await page.waitForTimeout(2500);
    }

    const highlights = await resolveTargets(page, step.targets ?? []);

    // Mask identities in the DOM before the pixels exist.
    //
    // annotate()'s maskIdentity covers the portal account block in the corner,
    // which is all the earlier captures needed. A workbook puts real people in
    // the middle of a table, and d2 shipped a live UPN the first time this ran.
    //
    // Whole identities become Contoso placeholders. Tenant domains are not retained.
    if (step.maskIdentity !== false) {
      await page.evaluate((rules) => {
        const replace = (value) => {
          for (const [source, flags, to] of rules) value = value.replace(new RegExp(source, flags), to);
          return value.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi,
            '00000000-0000-0000-0000-000000000000');
        };
        const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walk.nextNode()) walk.currentNode.nodeValue = replace(walk.currentNode.nodeValue);
      }, redactor.rules());
      if (redactor.leaks(await page.locator('body').innerText()).length) throw new Error('A real identifier survived; refusing the screenshot');
    }

    const buf = await capturePixels(page, `${step.id}.png`, redactor);

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
if (skipped.length) process.exitCode = 1;
