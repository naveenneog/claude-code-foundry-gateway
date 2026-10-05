(function () {
  "use strict";
  const { buildPortableCommands, collectAnswersFromEntries, fieldGroups, fieldsByCheckId, isFieldActive, validateAnswers, validateBusinessUnits, validateEffectiveAddressDefaults, isPlainObject, withEffectiveAddressDefaults } = globalThis.ClaudeInstallerUiModel;
  let schema;
  let identity = {};
  let runHost;
  let businessUnitsEditor;
  let csrfToken = "";
  let sessionMode = "live";
  let sessionReason = "";
  let preflightFingerprint = "";
  let preflightStale = true;
  let preflightHadResult = false;
  let preflightIdentity = null;
  let preflightStaleReason = "";
  let preflightScope = null;
  let validationProblems = [];
  let checkFields = {};
  let prefill;
  let actions;
  let problems;
  let azureBusy = false;

  function byId(id) {
    return document.getElementById(id);
  }

  function scopeCovers(steps) {
    if (preflightScope === "full") return true;
    if (!Array.isArray(preflightScope)) return false;
    return steps.every((step) => preflightScope.includes(step));
  }

  function clearChildren(node) {
    while (node?.firstChild) node.removeChild(node.firstChild);
  }

  function appendText(parent, text, tag = "span", className = "") {
    const node = document.createElement(tag);
    node.textContent = text;
    if (className) node.className = className;
    parent.append(node);
    return node;
  }

  function liveMode() {
    return location.protocol !== "file:" && sessionMode === "live";
  }

  async function postJson(path, body) {
    if (location.protocol === "file:") throw new Error("Server mode is not running. Use the generated commands.");
    const res = await fetch(path, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken,
      },
      body: JSON.stringify(body),
    });
    const text = await res.text();
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      data = { text };
    }
    if (!res.ok) {
      const error = new Error(data.error || text || `request failed with HTTP ${res.status}`);
      error.data = { ...data, status: res.status };
      throw error;
    }
    return data;
  }

  async function getJson(path) {
    if (location.protocol === "file:") throw new Error("Server mode is not running. Use the generated commands.");
    const res = await fetch(path);
    const text = await res.text();
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      data = { text };
    }
    if (!res.ok) {
      const error = new Error(data.error || text || `request failed with HTTP ${res.status}`);
      error.data = { ...data, status: res.status };
      throw error;
    }
    return data;
  }

  async function loadSchema() {
    const carried = byId("schema-json")?.textContent?.trim();
    if (carried) return JSON.parse(carried);
    return (await fetch("./api/schema")).json();
  }

  function createErrorNode(id) {
    const node = document.createElement("div");
    node.id = id;
    node.className = "field-error";
    node.setAttribute("role", "alert");
    return node;
  }

  function labelFor(name, property) {
    const label = document.createElement("label");
    label.dataset.answer = name;
    appendText(label, property.title || name);
    return label;
  }

  function renderField(parent, name, property) {
    const label = labelFor(name, property);
    let field;
    if (property.enum || property.type === "boolean") {
      field = document.createElement("select");
      const unset = document.createElement("option");
      unset.value = "";
      unset.textContent = "not set (the installer default)";
      field.append(unset);
      const values = property.type === "boolean" ? ["true", "false"] : property.enum;
      for (const item of values) {
        const option = document.createElement("option");
        option.value = item;
        option.textContent = item;
        field.append(option);
      }
    } else {
      field = document.createElement("input");
      field.type = "text";
      if (property.type === "integer" || property.type === "number") field.inputMode = "numeric";
    }
    field.name = name;
    field.id = `field-${name.replace(/[^A-Za-z0-9_-]/g, "-")}`;
    field.setAttribute("aria-describedby", `${field.id}-error`);
    label.append(field);
    if (property["x-remedy"]) appendText(label, property["x-remedy"], "span", "small");
    label.append(createErrorNode(`${field.id}-error`));
    parent.append(label);
    if (name === "SubscriptionId") renderPrefillControl(label, "subscriptions", name, "Read subscriptions");
    if (name === "FoundryAccount") renderPrefillControl(label, "foundryAccounts", name, "Read Foundry accounts");
  }

  function renderPrefillControl(label, kind, name, text) {
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.prefillKind = kind;
    button.textContent = text;
    const select = document.createElement("select");
    select.dataset.prefillSelect = name;
    select.hidden = true;
    label.append(button, select);
  }

  function renderModelList(parent, name, property) {
    const label = labelFor(name, property);
    const select = document.createElement("select");
    select.multiple = true;
    select.dataset.modelSelect = name;
    select.setAttribute("aria-describedby", `field-${name}-error`);
    const input = document.createElement("input");
    input.name = name;
    input.id = `field-${name}`;
    input.placeholder = "deployment names, comma-separated";
    input.setAttribute("aria-describedby", `field-${name}-error`);
    label.append(select, input, createErrorNode(`field-${name}-error`));
    parent.append(label);
  }

  function renderPendingDeployment(parent, property) {
    const fieldset = document.createElement("fieldset");
    fieldset.dataset.answer = "PendingClaudeDeployment";
    appendText(fieldset, property.title || "Claude deployment to create", "legend");
    const enableLabel = document.createElement("label");
    const enable = document.createElement("input");
    enable.type = "checkbox";
    enable.id = "pending-deployment-enabled";
    enableLabel.append(enable);
    appendText(enableLabel, " Create a deployment during install");
    fieldset.append(enableLabel);
    const fields = document.createElement("div");
    fields.id = "pending-deployment-fields";
    fields.hidden = true;
    for (const [field, node] of Object.entries(schema.$defs.PendingClaudeDeployment.properties)) renderNestedField(fields, `PendingClaudeDeployment.${field}`, node);
    enable.addEventListener("change", () => {
      fields.hidden = !enable.checked;
      markPreflightStale();
      validateCurrentAnswers();
    });
    fieldset.append(fields);
    parent.append(fieldset);
  }

  function renderNestedField(parent, name, node) {
    const property = node.$ref ? { ...schema.$defs[node.$ref.replace(/^#\/\$defs\//, "")], ...node } : node;
    const label = labelFor(name, property);
    const input = document.createElement("input");
    input.name = name;
    input.id = `field-${name.replace(/[^A-Za-z0-9_-]/g, "-")}`;
    input.type = "text";
    input.setAttribute("aria-describedby", `${input.id}-error`);
    label.append(input, createErrorNode(`${input.id}-error`));
    parent.append(label);
  }

  function renderGroupedFields() {
    for (const group of Object.values(fieldGroups)) {
      const parent = byId(group.target);
      for (const name of group.fields) {
        if (name === "BusinessUnits") continue;
        const property = schema.properties[name];
        if (!property) continue;
        if (name === "StandardModels" || name === "PremiumModels") renderModelList(parent, name, property);
        else if (name === "PendingClaudeDeployment") renderPendingDeployment(parent, property);
        else renderField(parent, name, property);
      }
    }
  }

  function currentEntryMap() {
    const entries = new Map();
    for (const field of document.querySelectorAll("[name]")) {
      const root = field.closest("label, fieldset");
      if (root?.hidden || field.closest("[hidden]")) continue;
      entries.set(field.name, field.value);
    }
    return entries;
  }

  function collectAnswers() {
    businessUnitsEditor.sync();
    return collectAnswersFromEntries(schema, currentEntryMap(), byId("business-units").value);
  }

  function refreshConditionalVisibility() {
    const entries = currentEntryMap();
    for (const node of document.querySelectorAll("[data-answer]")) {
      const name = node.dataset.answer;
      if (!schema.properties[name] || name === "PendingClaudeDeployment") continue;
      const active = isFieldActive(schema, name, entries);
      if (node.hidden !== !active) node.hidden = !active;
    }
    const addressMode = document.querySelector('[name="AddressMode"]')?.value || "";
    if (addressMode !== "custom") {
      for (const node of document.querySelectorAll('[data-answer^="Address"]')) {
        if (node.dataset.answer !== "AddressMode") node.hidden = true;
      }
    }
  }

  function validateCurrentAnswers() {
    let answers;
    try {
      answers = collectAnswers();
    } catch (error) {
      validationProblems = [
        {
          checkId: "answers.schema",
          path: "BusinessUnits",
          message: error.message,
          remedy: "Correct the JSON view.",
        },
      ];
      renderValidationProblems();
      return validationProblems;
    }
    validationProblems = [...validateAnswers(schema, answers, "Install-ClaudeGateway.ps1"), ...validateEffectiveAddressDefaults(schema, answers)];
    renderValidationProblems();
    return validationProblems;
  }

  function renderValidationProblems() {
    for (const field of document.querySelectorAll("[aria-invalid]")) field.removeAttribute("aria-invalid");
    for (const node of document.querySelectorAll(".field-error")) node.textContent = "";
    const errors = byId("errors");
    clearChildren(errors);
    if (validationProblems.length) {
      const list = document.createElement("ul");
      for (const p of validationProblems) {
        appendText(list, `${p.path || "answers"}: ${p.message} ${p.remedy || ""}`.trim(), "li");
        problems.markFieldProblem(p.path, p.message, p.remedy);
        problems.appendProblemButton(list.lastChild, p.path, `Review ${p.path}`);
      }
      errors.append(list);
    }
    refreshCommands();
    updateRunAdmission();
    return validationProblems;
  }

  function markPreflightStale() {
    preflightStale = preflightHadResult;
    if (preflightStale) preflightStaleReason = "Run preflight after changing answers or steps.";
    preflightFingerprint = "";
    refreshConditionalVisibility();
    validateCurrentAnswers();
  }

  function hasBlockingProblems() {
    return validationProblems.length > 0;
  }

  function pfxNeedsTerminal() {
    try {
      const answers = Object.fromEntries(withEffectiveAddressDefaults(collectAnswers()));
      return answers.AddressMode === "custom" && answers.AddressCertificateSource === "Pfx";
    } catch {
      return false;
    }
  }

  function identityDiff(before, after) {
    if (!before || !after) return [];
    const fields = [
      ["signedIn", "signed-in state"],
      ["user", "user"],
      ["tenantId", "tenant"],
      ["subscriptionId", "subscription"],
    ];
    return fields.filter(([key]) => String(before[key] ?? "") !== String(after[key] ?? "")).map(([, label]) => label);
  }

  function markIdentityStale(reason) {
    preflightStale = true;
    preflightFingerprint = "";
    preflightStaleReason = reason || "The Azure identity changed. Run preflight again.";
    updateRunAdmission();
  }

  function setActionText(id, text, alert = false) {
    const button = byId(id);
    if (!button) return;
    const status = document.getElementById(`${id}-status`) || document.createElement("p");
    if (!status.id) {
      status.id = `${id}-status`;
      button.insertAdjacentElement("afterend", status);
    }
    status.setAttribute("role", alert ? "alert" : "status");
    status.textContent = text;
  }

  function azureControls() {
    return [
      ...document.querySelectorAll("[data-prefill-kind]"),
      byId("refresh-identity"),
      byId("preflight"),
      byId("run"),
      byId("full-run"),
      byId("rerun"),
    ].filter(Boolean);
  }

  function setAzureBusy(value, starter) {
    azureBusy = value;
    for (const control of azureControls()) {
      if (control === starter || control.dataset.actionBusy === "true") continue;
      control.disabled = value;
    }
    if (!value) updateRunAdmission();
  }

  function updateRunAdmission() {
    const terminalPfx = pfxNeedsTerminal();
    const selected = selectedSteps();
    const scopeBlocksFull = preflightFingerprint && !preflightStale && preflightScope !== "full";
    const runScopeOk = selected.length > 0 && scopeCovers(selected);
    const rerunScopeOk = runHost?.failedStep() && scopeCovers([runHost.failedStep()]);
    const admitted = liveMode() && preflightFingerprint && !preflightStale && !hasBlockingProblems() && !runHost?.isActive() && !azureBusy && !terminalPfx;
    for (const id of ["run", "full-run", "rerun"]) {
      const button = byId(id);
      if (button && button.dataset.actionBusy !== "true") {
        if (id === "full-run") button.disabled = azureBusy || !admitted || scopeBlocksFull;
        else if (id === "run") button.disabled = azureBusy || !admitted || !runScopeOk;
        else button.disabled = azureBusy || !admitted || !rerunScopeOk;
      }
    }
    for (const id of ["preflight", "download"]) {
      const button = byId(id);
      if (button && button.dataset.actionBusy !== "true") button.disabled = hasBlockingProblems() || (id === "preflight" && azureBusy);
    }
    const stop = byId("stop-run");
    if (stop && stop.dataset.actionBusy !== "true") stop.disabled = !runHost?.isActive();
    const state = byId("preflight-state");
    if (!state) return;
    if (hasBlockingProblems()) state.textContent = `${preflightStale ? "Preflight is stale. " : ""}Validation problems block download, preflight, run and command copying.`;
    else if (!liveMode()) state.textContent = `Static fallback: ${sessionReason || "use the generated commands."}`;
    else if (terminalPfx) state.textContent = "A PFX certificate is installed from a terminal because the installer asks for the PFX password only when it runs without -Yes.";
    else if (azureBusy) state.textContent = "Azure CLI work is already active.";
    else if (preflightFingerprint && !preflightStale && scopeBlocksFull) state.textContent = `Passing preflight ${preflightFingerprint.slice(0, 12)} is current. Full run needs a preflight with no step selected.`;
    else if (preflightFingerprint && !preflightStale && selected.length && !scopeCovers(selected)) state.textContent = `Passing preflight ${preflightFingerprint.slice(0, 12)} is current. Run selected steps needs a preflight of that selection.`;
    else if (admitted) state.textContent = `Passing preflight ${preflightFingerprint.slice(0, 12)} is current.`;
    else if (preflightStale && preflightHadResult) state.textContent = `Preflight is stale. ${preflightStaleReason || "Run preflight again."}`;
    else state.textContent = "No passing preflight yet.";
  }

  function renderCommands(commands) {
    const root = byId("commands");
    clearChildren(root);
    if (hasBlockingProblems()) {
      appendText(root, "Commands are unavailable until validation problems are fixed.", "p", "failed");
      return;
    }
    if (!liveMode()) {
      appendText(root, "Cloud Shell handoff", "h3");
      appendText(root, commands.cloudShell, "p");
      appendText(root, "PowerShell command", "h3");
      appendText(root, commands.powershellRun, "pre");
      if (commands.bashRun) {
        appendText(root, "Bash command", "h3");
        appendText(root, commands.bashRun, "pre");
      }
      return;
    }
    for (const [title, value] of [
      ["PowerShell preflight", commands.powershell],
      ["PowerShell run", commands.powershellRun],
    ]) {
      appendText(root, title, "h3");
      appendText(root, value, "pre");
    }
    if (!commands.powershellRun.includes(" -Yes ")) appendText(root, "The installer asks for the PFX password in the terminal.", "p");
    appendText(root, "PowerShell applies every current answer and selected step.", "p");
    if (commands.bash && commands.bashRun) {
      for (const [title, value] of [
        ["Bash preflight", commands.bash],
        ["Bash run", commands.bashRun],
      ]) {
        appendText(root, title, "h3");
        appendText(root, value, "pre");
      }
      return;
    }
    appendText(root, "Bash commands are not shown because bash does not apply the following current inputs.", "p");
    const ul = document.createElement("ul");
    for (const item of commands.bashDoesNotApply || []) appendText(ul, `answer ${item}`, "li");
    for (const item of commands.bashStepsNotApply || []) appendText(ul, `step ${item}`, "li");
    root.append(ul);
  }

  function refreshCommands() {
    if (!schema) return;
    let answers = { schemaVersion: 1 };
    try {
      answers = collectAnswers();
    } catch {}
    renderCommands(
      buildPortableCommands(schema, "./answers.json", {
        answers,
        progressPath: "./install-progress.ndjson",
        steps: selectedSteps(),
        fullRun: !selectedSteps().length,
        presentAnswers: Object.keys(answers).filter((key) => key !== "schemaVersion"),
      }),
    );
  }

  function renderPreflight(result) {
    const container = byId("preflight-output");
    clearChildren(container);
    const checks = result.preflight?.checks || result.preflight || [];
    const table = document.createElement("table");
    const header = document.createElement("tr");
    for (const text of ["Check", "Result", "Message", "Remedy", "Field"]) appendText(header, text, "th");
    table.append(header);
    for (const check of checks) {
      const row = document.createElement("tr");
      appendText(row, check.id || "", "td");
      appendText(row, check.result || "", "td", check.result === "PASS" ? "passed" : "failed");
      appendText(row, check.message || "", "td");
      appendText(row, check.remedy || "", "td");
      const problemCell = appendText(row, "", "td");
      for (const p of problems.preflightProblemPaths(check)) problems.appendProblemButton(problemCell, p.path, `Review ${p.path}`);
      table.append(row);
    }
    container.append(table);
    problems.markFields(checks);
    if (result.preflight?.result === "PASS" && result.fingerprint) {
      preflightFingerprint = result.fingerprint;
      preflightIdentity = result.identity || null;
      preflightScope = result.scope || null;
      preflightStaleReason = "";
      preflightStale = false;
      preflightHadResult = true;
    } else {
      preflightFingerprint = "";
      preflightIdentity = null;
      preflightScope = null;
      preflightStale = false;
      preflightHadResult = true;
    }
    updateRunAdmission();
  }

  function showPreflightError(error) {
    const container = byId("preflight-output");
    clearChildren(container);
    appendText(container, error.message || String(error), "p", "failed");
  }

  function renderSteps(payload) {
    const parent = byId("step-list");
    clearChildren(parent);
    const steps = Array.isArray(payload) ? payload : payload.steps || [];
    for (const step of steps) {
      const label = document.createElement("label");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.value = step.id;
      input.addEventListener("change", () => {
        refreshCommands();
        updateRunAdmission();
      });
      label.append(input);
      appendText(label, ` ${step.id} - ${step.title || ""}`);
      parent.append(label);
    }
  }

  function selectedSteps() {
    return [...document.querySelectorAll("#step-list input:checked")].map((input) => input.value);
  }

  async function refreshIdentity() {
    if (!liveMode()) {
      identity = {
        signedIn: false,
        signInCommand: "az login --use-device-code",
      };
      byId("identity").textContent = `Static fallback: ${sessionReason || "Azure reads and installer runs need the generated commands."}`;
      return;
    }
    identity = await getJson("./api/identity");
    const changed = identityDiff(preflightIdentity, identity);
    if (changed.length) markIdentityStale(`The Azure identity changed (${changed.join(", ")}). Run preflight again.`);
    const target = byId("identity");
    target.textContent = identity.signedIn ? `Signed-in account: ${identity.user}; tenant ${identity.tenantId}; subscription ${identity.subscriptionName} (${identity.subscriptionId}).` : `Signed-in account: not signed in. ${identity.signInCommand || "Run az login --use-device-code."}`;
  }

  async function main() {
    schema = await loadSchema();
    checkFields = fieldsByCheckId(schema);
    problems = globalThis.ClaudeInstallerProblems.create({
      byId,
      checkFields,
    });
    businessUnitsEditor = globalThis.ClaudeInstallerBusinessUnits.create({
      appendText,
      byId,
      clearChildren,
      isPlainObject,
      markPreflightStale,
      validateBusinessUnits,
      validateCurrentAnswers,
    });
    actions = globalThis.ClaudeInstallerActions.create({ onSettled: updateRunAdmission, onAzureBusy: setAzureBusy });
    runHost = globalThis.ClaudeInstallerRun.create({
      byId,
      csrfToken: () => csrfToken,
      getJson,
      hasBlockingProblems,
      postJson,
      onIdentityStale: markIdentityStale,
      readIdentityAfterRun: refreshIdentity,
      setStatusText: setActionText,
      updateRunAdmission,
    });
    prefill = globalThis.ClaudeInstallerPrefill.create({
      liveMode,
      markPreflightStale,
      postJson,
      actions,
    });
    if (location.protocol !== "file:") {
      const session = await (await fetch("./api/session")).json();
      csrfToken = session.csrfToken;
      sessionMode = session.mode || "live";
      sessionReason = session.reason || "";
    } else sessionMode = "static";
    renderGroupedFields();
    byId("refresh-identity").onclick = () => actions.run(byId("refresh-identity"), { busyText: "Refreshing account...", successText: "Account refreshed.", azure: true }, refreshIdentity);
    byId("signin").onclick = () => actions.run(byId("signin"), { busyText: "Preparing sign-in command...", successText: "Sign-in command shown." }, async () => {
      byId("signin-command").textContent = identity.signInCommand || "az login --use-device-code";
    });
    document.addEventListener("click", prefill.handleClick);
    document.addEventListener("change", prefill.handleChoice);
    document.addEventListener("change", prefill.syncModelInput);
    document.addEventListener("input", (event) => {
      if (event.target?.id === "business-units") {
        preflightStale = true;
        preflightFingerprint = "";
        updateRunAdmission();
        return;
      }
      if (event.target?.closest("#business-unit-tree") || event.target?.matches("[name], #business-units")) markPreflightStale();
    });
    document.addEventListener("change", (event) => {
      if (event.target?.matches("[name]")) markPreflightStale();
      else if (event.target?.matches("#step-list input")) {
        refreshCommands();
        updateRunAdmission();
      }
    });
    byId("preflight").onclick = () => actions.run(byId("preflight"), { busyText: "Running preflight...", successText: "Preflight finished.", azure: true }, async () => {
      if (validateCurrentAnswers().length) return;
      const steps = selectedSteps();
      renderPreflight(
        await postJson("./api/preflight", {
          answers: collectAnswers(),
          ...(steps.length ? { steps } : { fullRun: true }),
        }),
      );
    });
    byId("steps").onclick = () => actions.run(byId("steps"), { busyText: "Listing steps...", successText: "Steps listed." }, async () => renderSteps(await getJson("./api/steps")));
    byId("run").onclick = () => actions.run(byId("run"), { busyText: "Running selected steps...", successText: "Run finished.", azure: true }, async () => {
      const steps = selectedSteps();
      if (!steps.length) throw new Error("Select at least one step, or use Full run.");
      runHost.resetActiveRun();
      return runHost.streamRun({
        answers: collectAnswers(),
        steps,
        fingerprint: preflightFingerprint,
      });
    });
    byId("full-run").onclick = () => actions.run(byId("full-run"), { busyText: "Running full installer...", successText: "Full run finished.", azure: true }, async () => {
      const answers = collectAnswers();
      const resourceGroup = answers.ResourceGroup || "(not set)";
      if (!globalThis.confirm(`Run the full installer as ${identity.user || "the current account"} against resource group ${resourceGroup}?`)) return { statusText: "No full run was started." };
      runHost.resetActiveRun();
      return runHost.streamRun({
        answers,
        steps: [],
        fullRun: true,
        confirmFullRun: true,
        account: identity,
        fingerprint: preflightFingerprint,
      });
    });
    byId("rerun").onclick = () => actions.run(byId("rerun"), { busyText: "Re-running failed step...", successText: "Re-run finished.", azure: true }, async () => {
      const lastFailedStep = runHost.failedStep();
      if (lastFailedStep)
        return runHost.streamRun({
          answers: collectAnswers(),
          steps: [lastFailedStep],
          fingerprint: preflightFingerprint,
        });
    });
    byId("stop-run").onclick = () => actions.run(byId("stop-run"), { busyText: "Stopping run...", successText: "Stop requested." }, async () => {
      return runHost.stopRun();
    });
    byId("download").onclick = () => actions.run(byId("download"), { busyText: "Preparing answers.json...", successText: "answers.json is ready." }, async () => {
      if (validateCurrentAnswers().length) return;
      const blob = new Blob([JSON.stringify(collectAnswers(), null, 2) + "\n"], { type: "application/json" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "answers.json";
      a.click();
      URL.revokeObjectURL(a.href);
    });
    byId("add-unit").onclick = () => {
      businessUnitsEditor.addUnit();
    };
    byId("add-team").onclick = () => {
      businessUnitsEditor.addTeam();
    };
    byId("business-units").addEventListener("input", () => {
      businessUnitsEditor.applyJsonText(byId("business-units").value);
    });
    businessUnitsEditor.render();
    refreshConditionalVisibility();
    validateCurrentAnswers();
    updateRunAdmission();
    if (!liveMode()) {
      for (const id of ["preflight", "steps", "run", "full-run", "rerun", "stop-run", "refresh-identity", "signin"]) byId(id).hidden = true;
      for (const node of document.querySelectorAll("[data-prefill-kind], [data-prefill-select]")) node.hidden = true;
    }
    refreshCommands();
    void refreshIdentity().catch((error) => {
      byId("identity").textContent = error.data?.reason === "azure-busy" ? "An installer run is using Azure CLI. Wait for it to finish, then try again." : error.message;
    });
    void runHost.refreshRunStatus().catch((error) => {
      runHost.handleAttachError(error);
    });
  }

  main().catch((error) => {
    byId("errors").textContent = error.message;
  });
})();
