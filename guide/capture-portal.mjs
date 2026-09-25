// One authenticated browser, all packet specs. The lead runs this batch after owner sign-in.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { loadSteps, selectSteps, documentedOutputs, documentationProblems, isBlockedAction } from './lib/portal-specs.mjs';
import { AuthenticationSurface, authenticationReason, parseArguments, peopleRedactionPairs, proxyPacArguments, resolvePlan, runBatch, uncommittedCaptureCode } from './lib/portal-batch.mjs';
import { lockProfile } from './lib/portal-profile.mjs';

const root = process.cwd();
const options = parseArguments(process.argv.slice(2));
const allSteps = loadSteps(root);
const documented = documentedOutputs(root);
const missing = documentationProblems(allSteps, documented);
if (missing.length) throw new Error(missing.join('\n'));
const steps = selectSteps(allSteps, options.only);

if (options.list) {
  console.log(JSON.stringify(steps.map(({ id, output, target, specFile }) => ({ id, output, discover: target.discover, specFile })), null, 2));
} else {
  const { createResolver } = await import('./lib/portal-discovery.mjs');
  const resolution = await resolvePlan(steps, await createResolver(options));
  if (options.dryRun) {
    console.log(JSON.stringify({
      dry_run: true, browser_opened: false,
      resolved: resolution.resolved.map(({ step, url }) => ({ id: step.id, output: step.output, url })),
      failed: resolution.failed,
    }, null, 2));
    if (resolution.failed.length) process.exitCode = 1;
  } else {
    if (resolution.failed.length) {
      console.log(JSON.stringify({ captured: [], failed: resolution.failed,
        skipped: resolution.resolved.map(({ step }) => ({ id: step.id, reason: 'Resolve all selected targets before opening a browser' })),
        remaining: steps.map((step) => step.id) }, null, 2));
      process.exit(1);
    }
    if (!options.profile) throw new Error('Pass --profile with the single owner-authenticated profile; it is never opened implicitly');
    const uncommitted = uncommittedCaptureCode(execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }));
    if (uncommitted.length)
      throw new Error(`Commit the capture code before a batch: each record names the commit that took it, and these files differ from it:\n  ${uncommitted.join('\n  ')}`);
    // Validate every private map and version field before consuming the authenticated window.
    const maps = new Map();
    for (const { step } of resolution.resolved) {
      const variable = step.redaction.mapEnv;
      if (!process.env[variable]) throw new Error(`Set ${variable} to the private redaction map before starting the batch`);
      const pairs = JSON.parse(fs.readFileSync(process.env[variable], 'utf8').replace(/^\uFEFF/, ''));
      if (!Array.isArray(pairs) || !pairs.length || pairs.some((pair) => !Array.isArray(pair) || pair.length !== 2
        || pair.some((value) => typeof value !== 'string') || !pair[0]))
        throw new Error(`${variable} must contain a non-empty array of [real, replacement] string pairs`);
      maps.set(variable, pairs);
    }
    if (steps.some((step) => step.output.startsWith('docs/guide/turnstile-')) && !/^[a-f0-9]{40}$/.test(process.env.TURNSTILE_FORK_COMMIT ?? ''))
      throw new Error('Set TURNSTILE_FORK_COMMIT to update the existing Turnstile provenance manifest');
    const { chromium } = await import('playwright');
    const { Redactor, capturePixels, recordCapture, captureMetadata } = await import('./lib/turnstile-live.mjs');
    const release = lockProfile(path.resolve(options.profile));
    const reportFile = path.resolve(options.report ?? '.finops-evidence/portal-batch-result.json');
    let context;
    let summary = { captured: [], skipped: [], failed: [], remaining: steps.map((step) => step.id) };
    const started = new Date().toISOString();
    try {
      context = await chromium.launchPersistentContext(path.resolve(options.profile), {
        channel: 'msedge', headless: !options.headed, viewport: { width: 1600, height: 1000 },
        args: ['--no-first-run', ...proxyPacArguments(process.env.PORTAL_PROXY_PAC_URL)],
      });
      const page = context.pages()[0] ?? await context.newPage();
      async function ensureAuthenticated() {
        for (const openPage of context.pages()) {
          const texts = [];
          let credentialInput = false;
          for (const frame of openPage.frames()) {
            let body;
            try {
              body = await frame.evaluate(() => ({
                text: document.body?.innerText ?? '',
                credentialInput: !!document.querySelector('input[type="password"],input[name="loginfmt"]'),
              }));
            } catch (error) {
              // The portal redirects after load, so a frame can navigate or detach while it is
              // read. It has nothing to judge yet; the next check reads its replacement, and a
              // sign-in page is still caught by its URL below or on that next check.
              if (/Execution context was destroyed|frame was detached|Target page, context or browser has been closed|Cannot find context/i.test(String(error?.message))) continue;
              throw error;
            }
            texts.push(body.text);
            credentialInput ||= body.credentialInput;
          }
          const reason = authenticationReason({ url: openPage.url(), texts, credentialInput });
          if (reason) throw new AuthenticationSurface(reason);
        }
      }
      async function find(locator) {
        // The portal keeps hidden copies of many labels (collapsed menus, tooltips, other
        // blades), so the first match in the DOM is often not the one on screen.
        for (const frame of page.frames()) {
          const matches = locator.selector ? frame.locator(locator.selector)
            : frame.getByText(locator.text, { exact: locator.exact ?? false });
          const count = await matches.count().catch(() => 0);
          for (let index = 0; index < Math.min(count, 20); index++) {
            const target = matches.nth(index);
            if (await target.isVisible().catch(() => false)) return target;
          }
        }
        return null;
      }
      async function wait(locator) {
        const deadline = Date.now() + 90_000;
        while (Date.now() < deadline) {
          await ensureAuthenticated();
          const found = await find(locator);
          if (found) return found;
          await page.waitForTimeout(500);
        }
        // Name the locator: a batch report that only says "did not render" cannot be fixed
        // without replaying the step. Spec locators are repository text, never deployment names.
        throw new Error(`Expected ${locator.selector ? `selector ${locator.selector}` : `text "${locator.text}"`} did not render within 90 seconds`);
      }
      const commit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
      const tool = `Playwright ${JSON.parse(fs.readFileSync('node_modules/playwright/package.json', 'utf8')).version} / Chromium CDP`;
      await ensureAuthenticated();
      summary = await runBatch(resolution.resolved, {
        navigate: async (url) => page.goto(url, { waitUntil: 'domcontentloaded', timeout: 90_000 }),
        ensureAuthenticated,
        wait,
        settle: async (ms) => {
          // Blades render their frame first and fill values from later calls, so a short spec
          // settle captured "undefined" and "NaN". A floor applies to every step.
          const deadline = Date.now() + Math.max(ms, Number(process.env.PORTAL_MIN_SETTLE_MS ?? 8000));
          while (Date.now() < deadline) {
            await ensureAuthenticated();
            await page.waitForTimeout(Math.min(500, deadline - Date.now()));
          }
          await ensureAuthenticated();
        },
        click: async (locator) => {
          // A menu group toggles, and the portal remembers it open: clicking one that is already
          // open closes it and hides the item the next click needs. A click whose expected result
          // is already on screen is not needed.
          if (locator.waitFor && await find(locator.waitFor)) return;
          const target = await wait(locator);
          const labels = await target.evaluate((node) => {
            const control = node.closest('button,a,input,[role="button"]') ?? node;
            return [control.innerText ?? '', control.getAttribute('aria-label') ?? '',
              control.getAttribute('title') ?? '', control.getAttribute('type') ?? ''];
          });
          if (labels.some((value) => isBlockedAction(value) || /\bpassword\b|grant.+consent|approve.+sign.in/i.test(value)))
            throw new Error('Refusing authentication or configuration-commit control');
          await target.click({ timeout: 15_000 });
        },
        capture: async ({ step, target, url }) => {
          const pairs = [...maps.get(step.redaction.mapEnv)];
          // A target named with the product's own word (the AUM registration is "AUM") is not
          // a tenant secret, and replacing it would also rewrite values such as AUM.Manager.
          if (target.name && !step.redaction.keepTargetName) pairs.push([target.name, `${step.target.discover}-contoso`]);
          if (target.resourceGroup) pairs.push([target.resourceGroup, 'rg-contoso']);
          if (target.subscriptionName) pairs.push([target.subscriptionName, 'Contoso subscription']);
          pairs.push(...peopleRedactionPairs(target.people, { required: step.redaction.people === true }));
          const redactor = new Redactor(pairs);
          for (const frame of page.frames()) for (const selector of step.redaction.hideSelectors ?? [])
            await frame.locator(selector).evaluateAll((nodes) => nodes.forEach((node) => { node.style.visibility = 'hidden'; }));
          await ensureAuthenticated();
          const pixels = await capturePixels(page, step.id, redactor, null, false);
          const destination = path.resolve(root, step.output);
          let existing = path.dirname(destination);
          while (!fs.existsSync(existing)) existing = path.dirname(existing);
          const realRoot = fs.realpathSync(root).toLowerCase();
          const realParent = fs.realpathSync(existing).toLowerCase();
          if (realParent !== realRoot && !realParent.startsWith(realRoot + path.sep))
            throw new Error('Output parent resolves outside the repository');
          fs.mkdirSync(path.dirname(destination), { recursive: true });
          const captured = {
            id: step.id, output: step.output, live: true, captured_at_utc: new Date().toISOString(),
            route: redactor.redact(url), identity_kind: 'authenticated_portal_profile',
            accel_commit: commit, accel_dirty: false, tool, spec_file: step.specFile,
            spec_sha256: createHash('sha256').update(JSON.stringify(Object.fromEntries(Object.entries(step).filter(([key]) => key !== 'specFile')))).digest('hex'),
            redaction: { applied: true, leak_check_passed: true },
            sha256: createHash('sha256').update(pixels).digest('hex'),
          };
          // Only the route comes from the deployment; the id, output and spec file are this
          // repository's own names, and a short target name can occur inside them.
          if (redactor.leaks(JSON.stringify({ route: captured.route })).length) throw new Error('Public capture metadata contains an identifier');
          if (step.output.startsWith('docs/guide/turnstile-')) {
            recordCapture(path.basename(step.output), pixels, {
              route: captured.route, identity_kind: captured.identity_kind, surface: step.id,
            }, redactor, captureMetadata());
          } else fs.writeFileSync(destination, pixels);
          const manifestFile = path.join(root, 'docs', 'guide', 'portal-captures.json');
          const manifest = fs.existsSync(manifestFile) ? JSON.parse(fs.readFileSync(manifestFile, 'utf8')) : { version: 1, captures: [] };
          manifest.captures = [...manifest.captures.filter((item) => item.output !== step.output), captured];
          fs.mkdirSync(path.dirname(manifestFile), { recursive: true });
          fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + '\n');
          console.log(`captured ${step.id}`);
          return { captured_at_utc: captured.captured_at_utc, sha256: captured.sha256 };
        },
      });
    } catch (error) {
      summary.failed.push({ id: 'batch', reason: String(error.message) });
      if (error instanceof AuthenticationSurface) {
        summary.stoppedForAuthentication = true;
        summary.skipped = steps.map((step) => ({ id: step.id, reason: 'Authentication surface before capture' }));
      }
    } finally {
      try { if (context) await context.close(); }
      catch { summary.failed.push({ id: 'browser-close', reason: 'Browser cleanup failed; inspect the profile before another run' }); }
      try { release(); }
      catch { summary.failed.push({ id: 'profile-unlock', reason: 'Profile lock cleanup failed; do not force a second browser' }); }
      const record = { started_at_utc: started, ended_at_utc: new Date().toISOString(), ...summary };
      fs.mkdirSync(path.dirname(reportFile), { recursive: true });
      fs.writeFileSync(reportFile, JSON.stringify(record, null, 2));
      console.log(JSON.stringify(record, null, 2));
    }
    if (summary.failed.length || summary.skipped.length) process.exitCode = 1;
  }
}
