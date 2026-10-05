import assert from "node:assert/strict";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createContext, runInContext } from "node:vm";
import { createInstallerUiServer } from "../tools/installer-ui/server.mjs";

const stubInstaller = fileURLToPath(new URL("./installer-ui-stub.mjs", import.meta.url));
const root = fileURLToPath(new URL("..", import.meta.url)).replace(/[\\/]+$/, "");
const modelContext = createContext({ globalThis: {} });
runInContext(await readFile(new URL("../tools/installer-ui/ui-model.js", import.meta.url), "utf8"), modelContext);
const model = modelContext.globalThis.ClaudeInstallerUiModel;
const schema = JSON.parse(await readFile(new URL("../schemas/claude-gateway.answers.schema.json", import.meta.url), "utf8"));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g3-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const env = {
    P93_INSTALLER_UI_STUB_LOG: join(scratch, "stub.ndjson"),
    ...(extra.env || {}),
  };
  if (extra.az) {
    const az = join(scratch, "az.cmd");
    await writeFile(az, `@echo off\r\nnode "${az.replace(/\\/g, "\\\\")}.mjs" %*\r\n`, "utf8");
    await writeFile(
      `${az}.mjs`,
      `
import { appendFileSync } from 'node:fs';
const args = process.argv.slice(2);
const joined = args.join(' ');
appendFileSync(process.env.P93_AZ_LOG, joined + '\\n');
if (joined.startsWith('account show')) { console.log(JSON.stringify({ id: '00000000-0000-4000-8000-000000000093', name: 'Sub One', tenantId: 'tenant-1', user: { name: 'operator@example.com' } })); process.exit(0); }
if (joined.startsWith('account list')) {
  if (process.env.P93_G3_SUBSCRIPTION_FAIL) { console.error('subscription list failed for P93'); process.exit(9); }
  console.log(JSON.stringify([{ id: '00000000-0000-4000-8000-000000000093', name: 'Sub One', tenantId: 'tenant-1' }]));
  process.exit(0);
}
if (joined.startsWith('cognitiveservices account list')) {
  const resourceGroup = process.env.P93_G3_PREFILL_RG_PARENS ? 'rg(prod)' : 'rg-ai-p93';
  console.log(JSON.stringify([{ name: 'ai-p93', resourceGroup, location: 'eastus2' }]));
  process.exit(0);
}
if (joined.startsWith('cognitiveservices account deployment list')) { console.log(JSON.stringify([{ name: 'claude-sonnet-5', properties: { model: { name: 'claude', version: '5' } } }, { name: 'claude-opus-5', properties: { model: { name: 'claude', version: '5' } } }])); process.exit(0); }
console.error('unexpected az ' + joined); process.exit(2);
`,
      "utf8",
    );
    env.PATH = `${scratch};${process.env.PATH}`;
    env.P93_AZ_LOG = join(scratch, "az.log");
  }
  const server = await createInstallerUiServer({
    token: "test-token-with-at-least-32-bytes-0000",
    stubInstaller,
    idleMs: 60_000,
    env,
    readIdentity: extra.readIdentity ?? (async () => ({ signedIn: false, user: '', tenantId: '', subscriptionId: '' })),
  });
  const address = await server.listenAsync("127.0.0.1");
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: "manual" });
  const cookie = boot.headers.get("set-cookie").split(";")[0];
  const session = await (await fetch(`${base}/api/session`, { headers: { cookie } })).json();
  return {
    base,
    scratch,
    token: server.token,
    cookie,
    csrfToken: session.csrfToken,
    async fetch(path, options = {}) {
      const headers = { cookie, ...(options.headers || {}) };
      if (options.method === "POST") headers["x-csrf-token"] ??= session.csrfToken;
      return fetch(`${base}${path}`, { ...options, headers });
    },
    async close() {
      await server.cleanup();
      server.close();
      await once(server, "close").catch(() => {});
      await rm(scratch, { recursive: true, force: true });
    },
  };
}

async function browserPage(url, cookieApp) {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  if (cookieApp)
    await page.context().addCookies([
      {
        name: "installer_token",
        value: cookieApp.cookie.split('=')[1],
        domain: "127.0.0.1",
        path: "/",
        httpOnly: true,
        sameSite: "Strict",
      },
    ]);
  await page.goto(url);
  await page.waitForSelector('[name="SubscriptionId"]');
  await page.locator("#commands").waitFor();
  return { browser, page };
}

test("F1 drift covers every Install-ClaudeGateway answer and rejects Start-only or ungrouped fields", () => {
  const drift = model.checkFieldGroupDrift(schema);
  assert.deepEqual(JSON.parse(JSON.stringify(drift)), {
    ok: true,
    missing: [],
    duplicate: [],
    startOnly: [],
    unknown: [],
  });
  assert.equal(model.installerFieldNames(schema).length, 52);
  const copied = structuredClone(schema);
  copied.properties.P93Missing = {
    title: "Missing",
    type: "string",
    "x-appliedBy": ["Install-ClaudeGateway.ps1"],
  };
  assert.deepEqual(JSON.parse(JSON.stringify(model.checkFieldGroupDrift(copied).missing)), ["P93Missing"]);
  const startOnly = structuredClone(schema);
  startOnly.properties.ResourceGroup["x-appliedBy"] = ["Start-ClaudeGateway.ps1"];
  const startOnlyDrift = JSON.parse(JSON.stringify(model.checkFieldGroupDrift(startOnly)));
  assert.equal(startOnlyDrift.ok, false);
  assert.deepEqual(startOnlyDrift.startOnly, ["ResourceGroup"]);
  const removedFromSchema = structuredClone(schema);
  delete removedFromSchema.properties.ResourceGroup;
  const unknownDrift = JSON.parse(JSON.stringify(model.checkFieldGroupDrift(removedFromSchema)));
  assert.equal(unknownDrift.ok, false);
  assert.deepEqual(unknownDrift.unknown, ["ResourceGroup"]);
});

test("F1 browser collects Azure DNS, existing APIM, Desktop access token and pending deployment JSON exactly", async () => {
  const { browser, page } = await browserPage(new URL("../tools/installer-ui/index.html", import.meta.url).href);
  try {
    await page.locator('[name="SubscriptionId"]').fill("00000000-0000-4000-8000-000000000093");
    await page.locator('[name="AddressMode"]').selectOption("custom");
    await page.locator('[name="AddressHostname"]').fill("claude.contoso.com");
    await page.locator('[name="AddressCertificateSource"]').selectOption("Pfx");
    await page.locator('[name="AddressPfxPath"]').fill("./company.pfx");
    await page.locator('[name="AddressDnsMode"]').selectOption("AzureDns");
    await page.locator('[name="AddressDnsZoneResourceId"]').fill("/subscriptions/00000000-0000-4000-8000-000000000093/resourceGroups/rg-dns/providers/Microsoft.Network/dnsZones/contoso.com");
    await page.locator('[name="ExistingApimName"]').fill("apimreuse");
    await page.locator('[name="DesktopSignInKind"]').selectOption("external-idp-browser");
    await page.locator('[name="DesktopBearerTokenType"]').selectOption("access_token");
    await page.locator('[name="DesktopEntraClientId"]').fill("00000000-0000-4000-8000-0000000000d3");
    await page.locator('[name="DesktopEntraScopes"]').fill("api://gateway/user_impersonation");
    await page.locator('[name="DesktopEntraAudience"]').fill("api://gateway");
    await page.locator('[name="StandardModels"]').fill("claude-sonnet-5");
    await page.locator('[name="PremiumModels"]').fill("claude-opus-5");
    await page.locator("#pending-deployment-enabled").check();
    await page.locator('[name="PendingClaudeDeployment.name"]').fill("claude-new");
    await page.locator('[name="PendingClaudeDeployment.model"]').fill("claude");
    await page.locator('[name="PendingClaudeDeployment.version"]').fill("5");
    await page.locator('[name="PendingClaudeDeployment.sku"]').fill("GlobalStandard");
    await page.locator('[name="PendingClaudeDeployment.capacity"]').fill("1000");
    await page.locator('[name="PendingClaudeDeployment.account"]').fill("ai-p93");
    await page.locator('[name="PendingClaudeDeployment.resourceGroup"]').fill("rg-ai-p93");
    const downloadPromise = page.waitForEvent("download");
    await page.getByRole("button", { name: "Download answers.json" }).click();
    const download = await downloadPromise;
    const answers = JSON.parse(await readFile(await download.path(), "utf8"));
    assert.deepEqual(answers, {
      schemaVersion: 1,
      SubscriptionId: "00000000-0000-4000-8000-000000000093",
      AddressMode: "custom",
      AddressHostname: "claude.contoso.com",
      AddressCertificateSource: "Pfx",
      AddressPfxPath: "./company.pfx",
      AddressDnsZoneResourceId: "/subscriptions/00000000-0000-4000-8000-000000000093/resourceGroups/rg-dns/providers/Microsoft.Network/dnsZones/contoso.com",
      AddressDnsMode: "AzureDns",
      ExistingApimName: "apimreuse",
      StandardModels: ["claude-sonnet-5"],
      PremiumModels: ["claude-opus-5"],
      DesktopSignInKind: "external-idp-browser",
      DesktopBearerTokenType: "access_token",
      DesktopEntraClientId: "00000000-0000-4000-8000-0000000000d3",
      DesktopEntraScopes: "api://gateway/user_impersonation",
      DesktopEntraAudience: "api://gateway",
      PendingClaudeDeployment: {
        name: "claude-new",
        model: "claude",
        version: "5",
        sku: "GlobalStandard",
        capacity: 1000,
        account: "ai-p93",
        resourceGroup: "rg-ai-p93",
      },
    });
    await page.locator('[name="AddressMode"]').selectOption("azure");
    await page.locator('[name="AddressDnsZoneResourceId"]').waitFor({ state: "hidden" });
    const secondDownloadPromise = page.waitForEvent("download");
    await page.getByRole("button", { name: "Download answers.json" }).click();
    const secondDownload = await secondDownloadPromise;
    assert.equal(JSON.parse(await readFile(await secondDownload.path(), "utf8")).AddressDnsZoneResourceId, undefined);
  } finally {
    await browser.close();
  }
});

test("F2 page cascades prefill and passes subscription, resource group and account to az", async () => {
  const app = await start({ az: true });
  const { browser, page } = await browserPage(`${app.base}/`, app);
  try {
    await page.getByRole("button", { name: "Read subscriptions" }).click();
    await page.locator('[data-prefill-select="SubscriptionId"]').selectOption("00000000-0000-4000-8000-000000000093");
    await page.locator('[data-prefill-select="FoundryAccount"]').selectOption("ai-p93");
    await page.locator('[data-model-select="StandardModels"] option[value="claude-sonnet-5"]').waitFor();
    assert.equal(await page.locator('[name="SubscriptionId"]').inputValue(), "00000000-0000-4000-8000-000000000093");
    assert.equal(await page.locator('[name="FoundryResourceGroup"]').inputValue(), "rg-ai-p93");
    await page.locator('[name="FoundryAccount"]').fill("manual-ai-p93");
    assert.equal(await page.locator('[name="FoundryAccount"]').inputValue(), "manual-ai-p93");
    const log = await readFile(join(app.scratch, "az.log"), "utf8");
    assert.match(log, /cognitiveservices account list .*--subscription 00000000-0000-4000-8000-000000000093/);
    assert.match(log, /cognitiveservices account deployment list -g rg-ai-p93 -n ai-p93 .*--subscription 00000000-0000-4000-8000-000000000093/);
  } finally {
    await browser.close();
    await app.close();
  }
});

test("F2 static mode shows no prefill actions", async () => {
  const { browser, page } = await browserPage(new URL("../tools/installer-ui/index.html", import.meta.url).href);
  try {
    assert.deepEqual(await page.locator("[data-prefill-kind]").evaluateAll((nodes) => nodes.map((node) => node.hidden)), [true, true]);
  } finally {
    await browser.close();
  }
});

test("G3-1 prefill choice errors appear on the named field without clearing typed values", async () => {
  const app = await start({ az: true, env: { P93_G3_PREFILL_RG_PARENS: "1" } });
  const { browser, page } = await browserPage(`${app.base}/`, app);
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  try {
    await page.locator('[name="ResourceGroup"]').fill("typed-rg");
    await page.getByRole("button", { name: "Read subscriptions" }).click();
    await page.locator('[data-prefill-select="SubscriptionId"]').selectOption("00000000-0000-4000-8000-000000000093");
    await page.locator('[data-prefill-select="FoundryAccount"]').selectOption("ai-p93");
    const error = page.locator("#field-FoundryResourceGroup-error");
    await error.getByText(/az\.cmd re-reads on Windows/).waitFor();
    await error.getByText(/Type the deployment names/).waitFor();
    assert.equal(await page.locator('[name="FoundryResourceGroup"]').getAttribute("aria-invalid"), "true");
    assert.equal(await page.locator('[name="SubscriptionId"]').inputValue(), "00000000-0000-4000-8000-000000000093");
    assert.equal(await page.locator('[name="FoundryAccount"]').inputValue(), "ai-p93");
    assert.equal(await page.locator('[name="ResourceGroup"]').inputValue(), "typed-rg");
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser.close();
    await app.close();
  }
});

test("G3-1 prefill click errors appear next to SubscriptionId without pageerror", async () => {
  const app = await start({ az: true, env: { P93_G3_SUBSCRIPTION_FAIL: "1" } });
  const { browser, page } = await browserPage(`${app.base}/`, app);
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  try {
    await page.locator('[name="SubscriptionId"]').fill("typed-subscription");
    await page.getByRole("button", { name: "Read subscriptions" }).click();
    await page
      .locator("#field-SubscriptionId-error")
      .getByText(/subscription list failed for P93/)
      .waitFor();
    assert.equal(await page.locator('[name="SubscriptionId"]').getAttribute("aria-invalid"), "true");
    assert.equal(await page.locator('[name="SubscriptionId"]').inputValue(), "typed-subscription");
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser.close();
    await app.close();
  }
});

test("F3 browser validator matches the P92 PowerShell corpus check ids and paths", async () => {
  const corpus = join(tmpdir(), `p93-corpus-${process.pid}-${Date.now()}.json`);
  const script = join(root, "tests", "Test-InstallerAnswersSchema.ps1");
  const child = spawn("pwsh", ["-NoProfile", "-File", script, "-ExportCorpus", corpus], {
    cwd: root,
    shell: false,
    env: { ...process.env, CI: "1", FORCE_COLOR: "0" },
  });
  const exited = once(child, "exit");
  const [code] = await exited;
  assert.equal(code, 0);
  const cases = JSON.parse(await readFile(corpus, "utf8"));
  await rm(corpus, { force: true });
  const source = await readFile(script, "utf8");
  const expectedInstallCases = [...source.matchAll(/Add-Case\s+['"][^'"]+['"]\s+\$pw\b/g)].length;
  const installCases = cases.filter((x) => x.consumer === "Install-ClaudeGateway.ps1");
  assert.ok(expectedInstallCases >= 25, `expected at least 25 Install-ClaudeGateway.ps1 cases, saw ${expectedInstallCases}`);
  assert.equal(installCases.length, expectedInstallCases);
  for (const c of installCases) {
    const js = model.validateAnswers(schema, c.answersText, c.consumer);
    assert.deepEqual([...new Set(js.map((p) => p.checkId))].sort(), [...new Set(c.powerShellProblems.map((p) => p.checkId))].sort(), c.name);
    const psPaths = c.powerShellProblems
      .map((p) => p.path)
      .filter(Boolean)
      .sort();
    assert.deepEqual(JSON.parse(JSON.stringify([...new Set(js.map((p) => p.path).filter((p) => psPaths.includes(p)))].sort())), JSON.parse(JSON.stringify([...new Set(psPaths)].sort())), c.name);
  }
});

test("F3 page marks invalid fields and blocks download, preflight, run and commands", async () => {
  const { browser, page } = await browserPage(new URL("../tools/installer-ui/index.html", import.meta.url).href);
  try {
    await page.locator('[name="NamePrefix"]').fill("-bad");
    await page.getByText(/Validation problems block/).waitFor();
    assert.equal(await page.locator('[name="NamePrefix"]').getAttribute("aria-invalid"), "true");
    assert.equal(await page.getByRole("button", { name: "Download answers.json" }).isDisabled(), true);
    assert.equal(await page.getByText(/Commands are unavailable/).isVisible(), true);
  } finally {
    await browser.close();
  }
});

test("F4 integer coercion accepts exponent form and rejects fractional, text and out-of-range values", () => {
  assert.equal(model.coerceAnswerValue(schema.properties.TpmStandard, "1e3"), 1000);
  for (const raw of ["1.9", "abc", "0"]) {
    const answers = {
      schemaVersion: 1,
      TpmStandard: model.coerceAnswerValue(schema.properties.TpmStandard, raw),
    };
    assert.ok(
      model.validateAnswers(schema, answers).some((p) => p.path === "TpmStandard"),
      raw,
    );
  }
  assert.ok(
    model
      .validateAnswers(schema, {
        schemaVersion: 1,
        PendingClaudeDeployment: {
          name: "claude-new",
          model: "claude",
          version: "5",
          sku: "GlobalStandard",
          capacity: 1.9,
          account: "ai-p93",
          resourceGroup: "rg-ai-p93",
        },
      })
      .some((p) => p.path === "PendingClaudeDeployment.capacity"),
  );
  assert.match(
    model
      .validateBusinessUnits([
        {
          id: "finance",
          group: "claude-bu-finance",
          monthlyUsdBudget: 1.9,
          mode: "Allowance",
          percent: 1.9,
        },
      ])
      .join("\n"),
    /monthlyUsdBudget|percent/,
  );
});

test("F5 business-unit JSON refuses non-array object shapes without pageerror and recovers", async () => {
  const { browser, page } = await browserPage(new URL("../tools/installer-ui/index.html", import.meta.url).href);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.getByRole("button", { name: "Add unit" }).click();
    await page.locator('[data-bu-field="id"]').first().fill("finance");
    await page.locator('[data-bu-field="group"]').first().fill("claude-bu-finance");
    await page.getByText("JSON view").click();
    for (const bad of ["{}", "null", "[null]", "[1]", '"x"']) {
      await page.locator("#business-units").fill(bad);
      await page.getByText(/array of objects/).waitFor();
      assert.equal(await page.locator("[data-bu-index]").count(), 1, bad);
      assert.equal(await page.locator('[data-bu-field="id"]').first().inputValue(), "finance", bad);
    }
    await page.locator("#business-units").fill('[{"id":"sales","group":"claude-bu-sales","monthlyUsdBudget":1000,"mode":"Strict"}]');
    await page.locator('[data-bu-field="id"]').first().waitFor();
    assert.equal(await page.locator('[data-bu-field="id"]').first().inputValue(), "sales");
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
});

test("F1 conditional fields follow their requires conditions in the model and the page", async () => {
  const collect = (pairs) => JSON.parse(JSON.stringify(model.collectAnswersFromEntries(schema, new Map(pairs))));
  const zone = "/subscriptions/00000000-0000-4000-8000-000000000093/resourceGroups/rg-dns/providers/Microsoft.Network/dnsZones/contoso.com";
  const external = collect([["AddressMode", "custom"], ["AddressDnsMode", "External"], ["AddressDnsZoneResourceId", zone]]);
  assert.equal(external.AddressDnsZoneResourceId, undefined, "AddressDnsZoneResourceId is not collected with AddressDnsMode External");
  assert.equal(collect([["AddressMode", "custom"], ["AddressDnsMode", "AzureDns"], ["AddressDnsZoneResourceId", zone]]).AddressDnsZoneResourceId, zone);
  assert.equal(collect([["DesktopSignInKind", "helper-script"], ["DesktopEntraClientId", "00000000-0000-4000-8000-0000000000d3"]]).DesktopEntraClientId, undefined, "DesktopEntraClientId is not collected for helper-script");
  assert.equal(collect([["DesktopSignInKind", "external-idp-broker"], ["DesktopEntraClientId", "00000000-0000-4000-8000-0000000000d3"]]).DesktopEntraClientId, "00000000-0000-4000-8000-0000000000d3");

  const { browser, page } = await browserPage(new URL("../tools/installer-ui/index.html", import.meta.url).href);
  try {
    const zoneField = page.locator('[data-answer="AddressDnsZoneResourceId"]');
    const clientField = page.locator('[data-answer="DesktopEntraClientId"]');
    await page.locator('[name="AddressMode"]').selectOption("custom");
    await page.locator('[name="AddressDnsMode"]').selectOption("External");
    assert.equal(await zoneField.isHidden(), true, "the zone id is hidden with AddressDnsMode External");
    await page.locator('[name="AddressDnsMode"]').selectOption("AzureDns");
    await zoneField.waitFor({ state: "visible" });
    assert.equal(await clientField.isHidden(), true, "the client id is hidden while DesktopSignInKind is not set");
    await page.locator('[name="DesktopSignInKind"]').selectOption("helper-script");
    assert.equal(await clientField.isHidden(), true, "the client id is hidden for helper-script");
    await page.locator('[name="DesktopSignInKind"]').selectOption("external-idp-browser");
    await clientField.waitFor({ state: "visible" });
  } finally {
    await browser.close();
  }
});
