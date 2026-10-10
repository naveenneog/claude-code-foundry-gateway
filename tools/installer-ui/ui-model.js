(function () {
  "use strict";

  const INSTALLER = "Install-ClaudeGateway.ps1";
  const specialEditors = Object.freeze(["BusinessUnits", "PendingClaudeDeployment", "StandardModels", "PremiumModels"]);
  const fieldGroups = Object.freeze({
    firstInstall: Object.freeze({
      title: "First install",
      target: "first-install",
      fields: Object.freeze([
        "SubscriptionId",
        "FoundryAccount",
        "FoundryResourceGroup",
        "ResourceGroup",
        "Location",
        "NamePrefix",
        "PublisherEmail",
        "Sku",
        "DeveloperCount",
        "StandardGroup",
        "PremiumGroup",
        "StandardModels",
        "PremiumModels",
        "TpmStandard",
        "QuotaStandard",
        "TpmPremium",
        "QuotaPremium",
        "CallsPerMinute",
      ]),
    }),
    optionalParts: Object.freeze({
      title: "Optional parts",
      target: "optional-parts",
      fields: Object.freeze([
        "AddressMode",
        "AddressHostname",
        "AddressCertificateSource",
        "AddressKeyVaultCertificateId",
        "AddressPfxPath",
        "AddressDnsMode",
        "AddressDnsZoneResourceId",
        "AddressReplaceHostname",
        "ExistingApimName",
        "DeployProjection",
        "EntitlementStore",
        "ResolverInboundAccess",
        "DeploySyncJob",
        "ProjectionSyncInterval",
        "DeployContentSafety",
        "ContentSafetyMode",
        "DesktopSignInKind",
        "DesktopBearerTokenType",
        "DesktopEntraClientId",
        "DesktopEntraIssuer",
        "DesktopEntraScopes",
        "DesktopEntraAudience",
        "DesktopEntraResource",
        "BusinessUnits",
        "PendingClaudeDeployment",
      ]),
    }),
    advanced: Object.freeze({
      title: "Advanced",
      target: "advanced",
      fields: Object.freeze([
        "ProjectionResolverAppId",
        "QuotaOrg",
        "AuthMode",
        "ModelOrganizationName",
        "ModelIndustry",
        "ModelCountryCode",
        "RevocationWindowSeconds",
        "TeamBudgetBehaviour",
        "UnassignedDevelopers",
        "DeveloperEstimate",
      ]),
    }),
  });

  function resolveNode(schema, node) {
    if (!node || !node.$ref) return node;
    const name = String(node.$ref).replace(/^#\/\$defs\//, "");
    return {
      ...(schema.$defs?.[name] || {}),
      ...Object.fromEntries(Object.entries(node).filter(([key]) => key !== "$ref")),
    };
  }

  function allGroupFields() {
    return Object.values(fieldGroups).flatMap((group) => group.fields);
  }

  function installerFieldNames(schema) {
    return Object.entries(schema.properties || {})
      .filter(([name, property]) => property["x-appliedBy"]?.includes(INSTALLER) && !schema["x-secrets"]?.[name])
      .map(([name]) => name);
  }

  function startOnlyFieldNames(schema) {
    return Object.entries(schema.properties || {})
      .filter(([, property]) => !property["x-appliedBy"]?.includes(INSTALLER))
      .map(([name]) => name);
  }

  function checkFieldGroupDrift(schema) {
    const grouped = allGroupFields();
    const counts = new Map();
    for (const name of grouped) counts.set(name, (counts.get(name) || 0) + 1);
    const wanted = installerFieldNames(schema);
    const missing = wanted.filter((name) => counts.get(name) !== 1);
    const duplicate = [...counts].filter(([, count]) => count !== 1).map(([name]) => name);
    const startOnly = startOnlyFieldNames(schema).filter((name) => counts.has(name));
    const unknown = grouped.filter((name) => !schema.properties?.[name]);
    return {
      ok: missing.length === 0 && duplicate.length === 0 && startOnly.length === 0 && unknown.length === 0,
      missing,
      duplicate,
      startOnly,
      unknown,
    };
  }

  function coerceAnswerValue(property, raw) {
    if (raw === undefined || raw === null || raw === "") return undefined;
    if (property.type === "integer") {
      const value = Number(raw);
      return Number.isFinite(value) ? value : String(raw);
    }
    if (property.type === "number") {
      const value = Number(raw);
      return Number.isFinite(value) ? value : String(raw);
    }
    if (property.type === "boolean") {
      if (raw === true || raw === "true") return true;
      if (raw === false || raw === "false") return false;
      return String(raw);
    }
    if (property.type === "array") {
      if (Array.isArray(raw)) return raw.filter((item) => String(item).trim()).map(String);
      return String(raw)
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean);
    }
    return String(raw);
  }

  function holdsCondition(condition, values) {
    const value = values.get ? values.get(condition.answer) : values[condition.answer];
    if (typeof value !== "string") return false;
    if (Object.prototype.hasOwnProperty.call(condition, "equals")) return value === String(condition.equals);
    if (Object.prototype.hasOwnProperty.call(condition, "in")) return condition.in.includes(value);
    return false;
  }

  function withEffectiveAddressDefaults(values) {
    const out = new Map(typeof values?.entries === "function" ? values.entries() : Object.entries(values || {}));
    // Install-ClaudeGateway.ps1 defaults: scripts/ClaudeGatewayAddressInput.ps1 lines 27-28.
    if (out.get("AddressMode") === "custom" && !out.get("AddressCertificateSource")) out.set("AddressCertificateSource", "KeyVault");
    if (out.get("AddressMode") === "custom" && !out.get("AddressDnsMode")) out.set("AddressDnsMode", out.get("AddressDnsZoneResourceId") ? "AzureDns" : "External");
    return out;
  }

  function effectiveRequires(schema, name) {
    const own = [...(schema.properties?.[name]?.requires || [])];
    if (name.startsWith("Address") && name !== "AddressMode") own.unshift({ answer: "AddressMode", equals: "custom" });
    for (const rule of schema["x-crossField"] || []) {
      if (rule.require === name) own.push(...(rule.when || []));
    }
    return own;
  }

  function isFieldActive(schema, name, values) {
    return effectiveRequires(schema, name).every((condition) => holdsCondition(condition, withEffectiveAddressDefaults(values)));
  }

  function collectAnswersFromEntries(schema, entries, businessUnitsText = "") {
    const out = { schemaVersion: 1 };
    const values = withEffectiveAddressDefaults(entries);
    for (const [name, property] of Object.entries(schema.properties || {})) {
      if (!property["x-appliedBy"]?.includes(INSTALLER) || schema["x-secrets"]?.[name]) continue;
      if (!entries.has(name) || !isFieldActive(schema, name, values)) continue;
      if (name === "BusinessUnits" || name === "PendingClaudeDeployment") continue;
      const value = coerceAnswerValue(resolveNode(schema, property), entries.get(name));
      if (value !== undefined && !(Array.isArray(value) && value.length === 0)) out[name] = value;
    }
    const pending = {};
    for (const [key, value] of entries) {
      if (!String(key).startsWith("PendingClaudeDeployment.")) continue;
      const field = String(key).slice("PendingClaudeDeployment.".length);
      const property = schema.$defs?.PendingClaudeDeployment?.properties?.[field];
      const typed = coerceAnswerValue(resolveNode(schema, property), value);
      if (typed !== undefined) pending[field] = typed;
    }
    if (Object.keys(pending).length) out.PendingClaudeDeployment = pending;
    const text = String(businessUnitsText || "").trim();
    if (text) out.BusinessUnits = JSON.parse(text);
    return out;
  }

  function fieldsByCheckId(schema) {
    const map = {};
    for (const [name, property] of Object.entries(schema.properties || {})) {
      const id = property["x-checkId"];
      if (!id) continue;
      map[id] ??= [];
      map[id].push(name);
    }
    const unit = schema?.$defs?.BusinessUnit;
    for (const [name, property] of Object.entries(unit?.properties || {})) {
      const id = property["x-checkId"];
      if (!id) continue;
      map[id] ??= [];
      map[id].push(`BusinessUnits.${name}`);
    }
    return map;
  }

  function preflightCheckIds(schema) {
    return (schema["x-preflightChecks"] || []).map((check) => check.id);
  }

  function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function validateBusinessUnits(units) {
    const problems = [];
    if (!Array.isArray(units)) return ["BusinessUnits is not a list"];
    const ids = new Set();
    for (const [index, unit] of units.entries()) {
      const label = `BusinessUnits[${index}]`;
      if (!isPlainObject(unit)) {
        problems.push(`${label} is not an object`);
        continue;
      }
      if (!/^[a-z0-9][a-z0-9-]*$/.test(String(unit.id || "")) || String(unit.id || "").length > 64) problems.push(`${label}.id is not lower-case letters, digits and hyphens, max 64`);
      if (ids.has(unit.id)) problems.push(`${label}.id duplicates another unit`);
      ids.add(unit.id);
      if (!unit.group || /[',:]/.test(String(unit.group))) problems.push(`${label}.group name contains ', comma or colon`);
      if (unit.parent && !/^[a-z0-9][a-z0-9-]*$/.test(String(unit.parent))) problems.push(`${label}.parent is not a business-unit id`);
      if (typeof unit.monthlyUsdBudget !== "number" || !Number.isFinite(unit.monthlyUsdBudget) || unit.monthlyUsdBudget < 0 || unit.monthlyUsdBudget > 100000000) problems.push(`${label}.monthlyUsdBudget is outside the monthly budget range`);
      if (!["Strict", "Allowance", "Notify"].includes(unit.mode)) problems.push(`${label}.mode is not Strict, Allowance or Notify`);
      if (unit.mode === "Allowance" && unit.percent === undefined) problems.push(`${label}.percent is required for Allowance`);
      else if (unit.mode === "Allowance" && (!Number.isInteger(unit.percent) || unit.percent < 1 || unit.percent > 100)) problems.push(`${label}.percent must be 1-100`);
      if (unit.mode !== "Allowance" && unit.percent !== undefined) problems.push(`${label}.percent applies only with Allowance`);
    }

    for (const unit of units.filter(isPlainObject)) {
      if (unit.parent && !ids.has(unit.parent)) problems.push(`${unit.id || "unit"} parent ${unit.parent} is not defined`);
      const parent = units.find((candidate) => candidate?.id === unit.parent);
      if (parent?.parent) problems.push(`${unit.id} is deeper than two levels`);
    }
    return problems;
  }

  function problem(checkId, path, message, remedy) {
    return { checkId, path, message, remedy };
  }

  function typeOf(value) {
    if (value === null) return "null";
    if (Array.isArray(value)) return "array";
    if (typeof value === "boolean") return "boolean";
    if (typeof value === "number") return "number";
    if (typeof value === "string") return "string";
    if (typeof value === "object") return "object";
    return "other";
  }
  const typeWords = {
    string: "text",
    number: "a number",
    boolean: "true or false",
    array: "a list",
    object: "an object",
    null: "null",
    other: "an unsupported value",
  };
  const expectWords = {
    string: "text",
    integer: "a whole number",
    number: "a number",
    boolean: "true or false",
    array: "a list",
    object: "an object",
  };

  function andList(items, last = "and") {
    if (items.length <= 1) return items[0] || "";
    return `${items.slice(0, -1).join(", ")} ${last} ${items[items.length - 1]}`;
  }

  function validateValue(schema, value, node, path) {
    const n = resolveNode(schema, node);
    const names = new Set(Object.keys(n || {}));
    const out = [];
    const add = (message, remedy, checkId = "answers.schema") => {
      out.push(problem(checkId, path, message, remedy));
    };
    const actual = typeOf(value);
    if (names.has("const")) {
      if (typeOf(n.const) !== actual || value !== n.const) add(`${path} is not ${JSON.stringify(n.const)}`, n["x-remedy"] || `Use ${JSON.stringify(n.const)}.`);
      return out;
    }
    const expected = n.type;
    switch (expected) {
      case "string": {
        if (actual !== "string") {
          add(`${path} is ${typeWords[actual]}, not text`, `Give ${path} as text.`);
          return out;
        }
        if (/[\x00-\x1f]/.test(value)) {
          add(`${path} holds a control character`, "Remove the control character.");
          return out;
        }
        if (value.startsWith("@")) {
          add(`${path} begins with @, which Azure CLI reads as a file name`, "Remove the leading @.");
          return out;
        }
        if (names.has("minLength") && [...value].length < n.minLength) {
          add(value.length === 0 ? `${path} is empty` : `${path} is shorter than ${n.minLength} characters`, `Give a value for ${path}, or leave it out.`);
          return out;
        }
        if (names.has("maxLength") && [...value].length > n.maxLength) {
          add(`${path} is longer than ${n.maxLength} characters`, `Shorten it to ${n.maxLength} characters.`);
          return out;
        }
        if (names.has("enum") && !n.enum.includes(value)) {
          const list = n.enum.join(", ");
          add(`${path} '${value}' is not one of: ${list}`, `Use one of: ${list}.`);
          return out;
        }
        if (names.has("pattern") && !new RegExp(n.pattern).test(value)) {
          add(`${path} '${value}' ${n["x-patternMessage"] || "does not have the expected form"}`, n["x-remedy"] || "Correct the value.", n["x-checkId"] || "answers.schema");
          return out;
        }
        break;
      }
      case "integer":
      case "number": {
        if (actual !== "number" || !Number.isFinite(value)) {
          add(`${path} is ${typeWords[actual]}, not ${expectWords[expected]}`, `Give ${path} as ${expectWords[expected]}.`);
          return out;
        }
        if (expected === "integer" && !Number.isInteger(value)) {
          add(`${path} is not a whole number`, `Give ${path} as a whole number.`);
          return out;
        }
        if (names.has("minimum") && value < n.minimum) {
          add(`${path} is below ${n.minimum}`, `Use a value from ${n.minimum} to ${n.maximum}.`);
          return out;
        }
        if (names.has("maximum") && value > n.maximum) {
          add(`${path} is above ${n.maximum}`, `Use a value from ${n.minimum} to ${n.maximum}.`);
          return out;
        }
        break;
      }
      case "boolean":
        if (actual !== "boolean") add(`${path} is ${typeWords[actual]}, not true or false`, `Give ${path} as true or false.`);
        break;
      case "array": {
        if (actual !== "array") {
          add(`${path} is ${typeWords[actual]}, not a list`, `Give ${path} as a list.`);
          return out;
        }
        if (names.has("minItems") && value.length < n.minItems) {
          add(`${path} is an empty list`, "Give at least one.");
          return out;
        }
        value.forEach((item, index) => out.push(...validateValue(schema, item, n.items, `${path}[${index}]`)));
        break;
      }
      case "object": {
        if (actual !== "object") {
          add(`${path} is ${typeWords[actual]}, not an object`, `Give ${path} as an object.`);
          return out;
        }
        const props = n.properties || {};
        for (const key of Object.keys(value)) {
          if (props[key]) out.push(...validateValue(schema, value[key], props[key], `${path}.${key}`));
          else add(`${path}.${key} is not a field of ${n.title}`, `Remove it; the fields are ${andList(Object.keys(props))}.`);
        }
        for (const req of n.required || []) if (!Object.prototype.hasOwnProperty.call(value, req)) add(`${path} has no ${req}`, `Add ${req}.`);
        out.push(...validateCrossField(n["x-crossField"] || [], new Map(Object.entries(value)), path, true));
        break;
      }
    }
    return out;
  }

  function validateCrossField(rules, values, pathPrefix = "", item = false) {
    const out = [];
    for (const rule of rules || []) {
      if (!(rule.when || []).every((condition) => holdsCondition(condition, values))) continue;
      if (rule.require && !values.has(rule.require)) {
        const p = item ? pathPrefix : rule.require;
        out.push(problem(rule.checkId, p, `${p} ${rule.message}`, rule.remedy));
      }
      if (rule.forbid && values.has(rule.forbid)) {
        const p = item ? `${pathPrefix}.${rule.forbid}` : rule.forbid;
        out.push(problem(rule.checkId, p, `${p} ${rule.message}`, rule.remedy));
      }
    }
    return out;
  }

  function duplicateCaseNames(text) {
    const names = [];
    let depth = 0,
      inString = false,
      escaped = false,
      start = -1;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
          continue;
        }
        if (c === "\\") {
          escaped = true;
          continue;
        }
        if (c === '"') {
          inString = false;
          let j = i + 1;
          while (/\s/.test(text[j] || "")) j++;
          if (depth === 1 && text[j] === ":") names.push(text.slice(start, i));
        }
        continue;
      }
      if (c === '"') {
        inString = true;
        start = i + 1;
        continue;
      }
      if (c === "{") depth++;
      else if (c === "}") depth--;
    }
    const seen = new Map();
    const dupes = [];
    for (const name of names) {
      const key = name.toLowerCase();
      if (seen.has(key)) {
        dupes.push(seen.get(key), name);
      } else seen.set(key, name);
    }
    return [...new Set(dupes)].sort();
  }

  function validateAnswers(schema, input, consumer = INSTALLER) {
    let answers = input;
    if (typeof input === "string") {
      if (!input.trim()) return [problem("answers.schema", "", "the answers file is empty", "Write the answers as one JSON object.")];
      try {
        answers = JSON.parse(input);
      } catch {
        return [problem("answers.schema", "", "the answers file is not valid JSON", "Correct the JSON: one object, with no comments and no trailing commas.")];
      }
      const dupes = duplicateCaseNames(input);
      if (dupes.length) return [problem("answers.schema", "", `the answers file names properties that differ only in case or repeat: ${dupes.join(", ")}`, "Keep one spelling of each name.")];
    }
    if (!isPlainObject(answers)) return [problem("answers.schema", "", "the answers file is not a JSON object", "Write the answers as one JSON object.")];
    const out = [];
    const canon = new Map();
    const keyOf = new Map();
    const props = schema.properties || {};
    const aliases = new Map(Object.entries(props).flatMap(([name, prop]) => (prop["x-flowKeys"] || []).map((alias) => [alias, name])));
    for (const [key, value] of Object.entries(answers)) {
      const add = (message, remedy) => out.push(problem("answers.schema", key, message, remedy));
      const matchingPattern = Object.entries(schema.patternProperties || {}).find(([pattern]) => new RegExp(pattern).test(key));
      if (schema["x-secrets"]?.[key]) {
        add(`${key} is a secret, and an answers file holds no secrets`, `Pass it when the program runs, as -${key}, or answer its prompt.`);
        continue;
      }
      if (props[key]) {
        const by = props[key]["x-appliedBy"] || [];
        if (!by.includes(consumer)) add(`${key} is applied by ${andList(by)}; ${consumer} does not apply it`, `Remove it, or use ${by[0]}, which applies it.`);
        canon.set(key, value);
        keyOf.set(key, key);
        out.push(...validateValue(schema, value, props[key], key));
      } else if (aliases.has(key)) {
        const name = aliases.get(key);
        if (consumer !== "Start-ClaudeGateway.ps1") add(`${key} is a guided-flow name; an installer answers file names it ${name}`, `Name it ${name}.`);
        else {
          canon.set(name, value);
          keyOf.set(name, key);
          out.push(...validateValue(schema, value, props[name], key));
        }
      } else if (matchingPattern) {
        const node = matchingPattern[1];
        const by = node["x-appliedBy"] || [];
        if (!by.includes(consumer)) add(`${key} is applied by ${andList(by)}; ${consumer} does not apply it`, `Remove it, or use ${by[0]}, which applies it.`);
        out.push(...validateValue(schema, value, node, key));
      } else if (schema["x-runControls"]?.[key]) {
        const c = schema["x-runControls"][key];
        add(`${key} is a run option, not an answer`, `Pass it on the command line: ${andList([c["Install-ClaudeGateway.ps1"], c["install-claude-gateway.sh"]].filter(Boolean), "or")}.`);
      } else {
        add(`${key} is not an answer in the answers schema`, "Remove it, or use a name from schemas/claude-gateway.answers.schema.json.");
      }
    }
    out.push(...validateCrossField(schema["x-crossField"] || [], canon));
    for (const [name, value] of canon) {
      const node = props[name];
      for (const c of node?.requires || []) {
        const given = canon.get(c.answer);
        if (typeof given !== "string") continue;
        const holds = holdsCondition(c, canon);
        if (holds) continue;
        const want = Object.prototype.hasOwnProperty.call(c, "equals") ? c.equals : andList(c.in || [], "or");
        const key = keyOf.get(name);
        out.push(problem("answers.crossField", key, `${key} applies only when ${c.answer} is ${want}; the answers give ${c.answer} '${given}'`, `Remove ${key}, or set ${c.answer} to ${want}.`));
        break;
      }
    }
    if (canon.has("BusinessUnits")) out.push(...validateBusinessUnitProblems(canon.get("BusinessUnits")));
    return out;
  }

  function validateEffectiveAddressDefaults(schema, answers) {
    if (!isPlainObject(answers)) return [];
    const out = [];
    if (answers.AddressMode === "custom" && !answers.AddressCertificateSource && !answers.AddressKeyVaultCertificateId) {
      out.push(problem("address.inputs", "AddressKeyVaultCertificateId", "AddressKeyVaultCertificateId is required because the installer uses Key Vault when no certificate source is given", "Give the Key Vault certificate URL, or choose Pfx and give the PFX path."));
    }
    return out;
  }

  function validateBusinessUnitProblems(units) {
    const out = [];
    if (Array.isArray(units)) {
      const firstById = new Map();
      units.forEach((unit, index) => {
        if (!isPlainObject(unit)) return;
        if (typeof unit.id === "string") {
          if (firstById.has(unit.id)) out.push(problem("businessUnits.ids", `BusinessUnits[${index}].id`, `BusinessUnits[${index}].id '${unit.id}' repeats BusinessUnits[${firstById.get(unit.id)}].id`, "Give each unit and team its own id."));
          else firstById.set(unit.id, index);
        }
      });
      units.forEach((unit, index) => {
        if (!isPlainObject(unit) || typeof unit.parent !== "string" || !/^[a-z0-9][a-z0-9-]*$/.test(unit.parent)) return;
        const path = `BusinessUnits[${index}].parent`;
        if (unit.parent === unit.id) {
          out.push(problem("businessUnits.depth", path, `BusinessUnits[${index}] names itself as its parent`, "Name a unit as parent, or leave parent out."));
          return;
        }
        const parentIndex = firstById.get(unit.parent);
        if (parentIndex === undefined) {
          out.push(problem("businessUnits.depth", path, `${path} '${unit.parent}' names no unit in BusinessUnits`, "Name a unit listed in BusinessUnits, or leave parent out."));
          return;
        }
        const parent = units[parentIndex];
        if (typeof parent?.parent === "string" && parent.parent)
          out.push(problem("businessUnits.depth", path, `BusinessUnits[${index}] is a team of '${parent.id}', which is a team of '${parent.parent}'; units hold teams and teams hold none (two levels, ADR-0008)`, "Name a unit without a parent as the parent."));
      });
    }
    for (const text of validateBusinessUnits(units)) {
      const path = text.match(/^(BusinessUnits\[\d+\](?:\.[A-Za-z]+)?)/)?.[1] || "BusinessUnits";
      if (out.some((p) => p.path === path)) continue;
      const checkId =
        text.includes("percent is required") || text.includes("applies only")
          ? "answers.crossField"
          : text.includes("duplicates") || text.includes("lower-case")
            ? "businessUnits.ids"
            : text.includes("parent") || text.includes("deeper")
              ? "businessUnits.depth"
              : text.includes("group")
                ? "entra.groupNames"
                : "answers.schema";
      out.push(problem(checkId, path, text, "Correct the business-unit entry."));
    }
    return out;
  }

  function quotePowerShell(value) {
    return `'${String(value).replaceAll("'", "''")}'`;
  }
  function quoteBash(value) {
    return `'${String(value).replaceAll("'", "'\"'\"'")}'`;
  }

  // The steps the bash installer runs: CKPT_ORDER in scripts/install-checkpoint.sh.
  const bashInstallerSteps = Object.freeze(["resource-group", "gateway-deployment", "entra-groups", "sync", "onboarding-package"]);

  function installerArguments({ engine, action, answersPath = "./answers.json", progressPath = "./install-progress.ndjson", steps = [], fullRun = false, terminalPfx = false }) {
    if (engine === "pwsh") {
      const args = ["-AnswersPath", answersPath];
      if (action === "preflight") return [...args, "-Preflight", "-Json"];
      if (action === "run") {
        const run = terminalPfx ? [...args, "-ProgressPath", progressPath] : [...args, "-Yes", "-ProgressPath", progressPath];
        if (!fullRun && steps.length) run.push("-Steps", steps.join(","));
        return run;
      }
    }
    if (engine === "bash") {
      const args = ["--answers-file", answersPath];
      if (action === "preflight") return [...args, "--preflight", "--json"];
      if (action === "run") {
        const run = [...args, "--yes", "--progress-file", progressPath];
        if (!fullRun && steps.length) run.push("--steps", steps.join(","));
        return run;
      }
    }
    throw new Error(`unsupported installer action: ${engine} ${action}`);
  }

  function shellCommand(engine, action, options) {
    const args = installerArguments({ engine, action, ...options });
    const plain = (value) => /^[A-Za-z0-9_./,-]+$/.test(String(value));
    if (engine === "pwsh") return ["./Install-ClaudeGateway.ps1", ...args].map((part) => (plain(part) ? String(part) : quotePowerShell(part))).join(" ");
    return ["./install-claude-gateway.sh", ...args].map((part) => (plain(part) ? String(part) : quoteBash(part))).join(" ");
  }

  function buildPortableCommands(schema, answersPath = "./answers.json", options = {}) {
    const steps = options.steps || [];
    const fullRun = Boolean(options.fullRun);
    const progressPath = options.progressPath || "./install-progress.ndjson";
    const bashSteps = new Set(options.bashSteps || bashInstallerSteps);
    const presentAnswers = new Set(options.presentAnswers || []);
    const bashDoesNotApply = [];
    for (const [name, property] of Object.entries(schema.properties || {})) {
      if (presentAnswers.has(name) && Array.isArray(property["x-appliedBy"]) && !property["x-appliedBy"].includes("install-claude-gateway.sh")) bashDoesNotApply.push(name);
    }
    const bashStepsNotApply = steps.filter((step) => !bashSteps.has(step));
    const effective = Object.fromEntries(withEffectiveAddressDefaults(options.answers || {}));
    const terminalPfx = effective.AddressMode === "custom" && effective.AddressCertificateSource === "Pfx";
    const bashAvailable = bashDoesNotApply.length === 0 && bashStepsNotApply.length === 0;
    return {
      powershell: shellCommand("pwsh", "preflight", { answersPath }),
      powershellRun: shellCommand("pwsh", "run", {
        answersPath,
        progressPath,
        steps,
        fullRun,
        terminalPfx,
      }),
      bash: bashAvailable ? shellCommand("bash", "preflight", { answersPath }) : "",
      bashRun: bashAvailable
        ? shellCommand("bash", "run", {
            answersPath,
            progressPath,
            steps,
            fullRun,
          })
        : "",
      bashDoesNotApply,
      bashStepsNotApply,
      cloudShell: "Manage files > Upload answers.json, then paste the PowerShell or bash command above.",
      terminalPfx,
    };
  }

  globalThis.ClaudeInstallerUiModel = {
    INSTALLER,
    bashInstallerSteps,
    buildPortableCommands,
    checkFieldGroupDrift,
    coerceAnswerValue,
    collectAnswersFromEntries,
    effectiveRequires,
    withEffectiveAddressDefaults,
    fieldGroups,
    fieldsByCheckId,
    preflightCheckIds,
    installerArguments,
    installerFieldNames,
    isFieldActive,
    isPlainObject,
    specialEditors,
    validateAnswers,
    validateBusinessUnits,
    validateEffectiveAddressDefaults,
  };
})();
