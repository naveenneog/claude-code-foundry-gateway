(function () {
  "use strict";

  function createPrefill(deps) {
    const { liveMode, markPreflightStale, postJson } = deps;
    const deploymentChoices = new Set();

    function showFieldError(field, message, remedy) {
      const input = document.querySelector(`[name="${CSS.escape(field)}"]`);
      input?.setAttribute("aria-invalid", "true");
      const describedBy = input?.getAttribute("aria-describedby") || "";
      const error = describedBy ? document.getElementById(describedBy.split(/\s+/)[0]) : null;
      if (error) error.textContent = `${message} ${remedy || ""}`.trim();
    }

    async function load(kind) {
      const body = { kind };
      if (kind === "foundryAccounts" || kind === "deployments") body.subscriptionId = document.querySelector('[name="SubscriptionId"]')?.value || "";
      if (kind === "deployments") {
        body.foundryAccount = document.querySelector('[name="FoundryAccount"]')?.value || "";
        body.foundryResourceGroup = document.querySelector('[name="FoundryResourceGroup"]')?.value || "";
      }
      const result = await postJson("./api/prefill", body);
      if (result.field || result.error) {
        const error = new Error(result.error || "Prefill failed");
        error.data = { field: result.field || (kind === "subscriptions" ? "SubscriptionId" : "FoundryAccount"), error: result.error || "Prefill failed", remedy: result.remedy || "Type the value manually." };
        throw error;
      }
      return result;
    }

    function showError(error, fallbackField) {
      const data = error?.data || {};
      showFieldError(data.field || fallbackField, data.error || error.message || "Prefill failed", data.remedy || "Type the value manually.");
    }

    function fillSelect(select, items, valueKey, label) {
      while (select.firstChild) select.removeChild(select.firstChild);
      const empty = document.createElement("option");
      empty.value = "";
      empty.textContent = "choose...";
      select.append(empty);
      for (const item of items) {
        const option = document.createElement("option");
        option.value = item[valueKey];
        option.textContent = label(item);
        option.dataset.item = JSON.stringify(item);
        select.append(option);
      }
      select.hidden = false;
    }

    async function handleClick(event) {
      const button = event.target.closest("[data-prefill-kind]");
      if (!button || !liveMode()) return;
      const kind = button.dataset.prefillKind;
      const field = button.closest("label")?.querySelector("[name]");
      const select = button.closest("label")?.querySelector("[data-prefill-select]");
      try {
        const data = await load(kind);
        if (kind === "subscriptions") fillSelect(select, data.subscriptions || [], "id", (item) => `${item.name} (${item.id})`);
        if (kind === "foundryAccounts") fillSelect(select, data.foundryAccounts || [], "name", (item) => `${item.name} / ${item.resourceGroup}`);
        field?.focus();
      } catch (error) {
        showError(error, field?.name || "SubscriptionId");
      }
    }

    async function handleChoice(event) {
      const select = event.target.closest("[data-prefill-select]");
      if (!select || !select.value) return;
      const item = JSON.parse(select.selectedOptions[0].dataset.item || "{}");
      try {
        if (select.dataset.prefillSelect === "SubscriptionId") {
          document.querySelector('[name="SubscriptionId"]').value = item.id || "";
          markPreflightStale();
          const data = await load("foundryAccounts");
          fillSelect(document.querySelector('[data-prefill-select="FoundryAccount"]'), data.foundryAccounts || [], "name", (x) => `${x.name} / ${x.resourceGroup}`);
        }
        if (select.dataset.prefillSelect === "FoundryAccount") {
          document.querySelector('[name="FoundryAccount"]').value = item.name || "";
          document.querySelector('[name="FoundryResourceGroup"]').value = item.resourceGroup || "";
          markPreflightStale();
          const data = await load("deployments");
          updateDeploymentChoices(data.deployments || []);
        }
      } catch (error) {
        showError(error, select.dataset.prefillSelect || "SubscriptionId");
      }
    }

    function updateDeploymentChoices(deployments) {
      for (const item of deployments) deploymentChoices.add(item.name);
      for (const select of document.querySelectorAll("[data-model-select]")) {
        const chosen = new Set([...select.selectedOptions].map((o) => o.value));
        while (select.firstChild) select.removeChild(select.firstChild);
        for (const name of deploymentChoices) {
          const option = document.createElement("option");
          option.value = name;
          option.textContent = name;
          option.selected = chosen.has(name);
          select.append(option);
        }
      }
    }

    function syncModelInput(event) {
      const select = event.target.closest("[data-model-select]");
      if (!select) return;
      const input = select.closest("label").querySelector("input[name]");
      const selected = [...select.selectedOptions].map((o) => o.value);
      const manual = input.value
        .split(",")
        .map((x) => x.trim())
        .filter((x) => x && !deploymentChoices.has(x));
      input.value = [...selected, ...manual].join(", ");
      markPreflightStale();
    }

    return { handleChoice, handleClick, syncModelInput };
  }

  globalThis.ClaudeInstallerPrefill = { create: createPrefill };
})();
