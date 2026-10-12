(function () {
  "use strict";

  function createBusinessUnitsEditor(deps) {
    const { byId, clearChildren, appendText, markPreflightStale, validateCurrentAnswers, validateBusinessUnits, isPlainObject } = deps;
    let businessUnits = [];
    let jsonDraftProblem = "";

    function defaultBusinessUnit(parent = "") {
      return { id: "", group: "", parent, monthlyUsdBudget: 0, mode: "Strict" };
    }

    function orderedBusinessUnits() {
      return [...businessUnits.filter((u) => !u.parent), ...businessUnits.filter((u) => u.parent)];
    }

    function sync() {
      if (jsonDraftProblem) {
        renderValidation();
        throw new Error(jsonDraftProblem);
      }
      businessUnits = [...document.querySelectorAll("[data-bu-index]")].map((row) => {
        const unit = {
          id: row.querySelector('[data-bu-field="id"]').value.trim(),
          group: row.querySelector('[data-bu-field="group"]').value.trim(),
          monthlyUsdBudget: Number(row.querySelector('[data-bu-field="monthlyUsdBudget"]').value),
          mode: row.querySelector('[data-bu-field="mode"]').value,
        };
        const parent = row.dataset.parent || "";
        if (parent) unit.parent = parent;
        if (unit.mode === "Allowance") unit.percent = Number(row.querySelector('[data-bu-field="percent"]').value);
        return unit;
      });
      businessUnits = orderedBusinessUnits();
      byId("business-units").value = businessUnits.length ? JSON.stringify(businessUnits, null, 2) : "";
      renderValidation();
    }

    function renderValidation() {
      const problems = jsonDraftProblem ? [jsonDraftProblem] : validateBusinessUnits(businessUnits);
      byId("business-unit-problems").textContent = problems.join("\n");
      return problems;
    }

    function refuseTreeAction() {
      if (!jsonDraftProblem) return false;
      byId("business-unit-problems").textContent = `${jsonDraftProblem}\nCorrect the JSON view before changing the tree.`;
      byId("business-unit-problems").focus();
      validateCurrentAnswers();
      return true;
    }

    function refreshParentOptions() {
      const parentSelect = byId("team-parent");
      const current = parentSelect.value;
      clearChildren(parentSelect);
      for (const unit of businessUnits.filter((u) => !u.parent && u.id)) {
        const option = document.createElement("option");
        option.value = unit.id;
        option.textContent = unit.id;
        option.selected = unit.id === current;
        parentSelect.append(option);
      }
    }

    function field(row, label, name, value, type = "text") {
      const wrapper = document.createElement("label");
      appendText(wrapper, label);
      const input = document.createElement("input");
      input.dataset.buField = name;
      input.type = type === "number" ? "text" : type;
      input.value = value ?? "";
      const error = document.createElement("div");
      error.id = `business-unit-${row.dataset.buIndex || "new"}-${name}-error`;
      error.className = "field-error";
      error.setAttribute("role", "alert");
      input.setAttribute("aria-describedby", error.id);
      wrapper.append(input, error);
      row.append(wrapper);
      return input;
    }

    function focusRow(index) {
      const row = document.querySelector(`[data-bu-index="${index}"]`);
      row?.querySelector("input, select, button")?.focus();
    }

    function render() {
      const tree = byId("business-unit-tree");
      clearChildren(tree);
      businessUnits = orderedBusinessUnits();
      refreshParentOptions();
      businessUnits.forEach((unit, index) => {
        const row = document.createElement("fieldset");
        row.dataset.buIndex = String(index);
        row.dataset.parent = unit.parent || "";
        appendText(row, unit.parent ? `Team under ${unit.parent}` : "Business unit", "legend");
        field(row, "Id", "id", unit.id);
        field(row, "Entra group", "group", unit.group);
        field(row, "Monthly USD budget", "monthlyUsdBudget", unit.monthlyUsdBudget, "number");
        const modeLabel = document.createElement("label");
        appendText(modeLabel, "Mode");
        const mode = document.createElement("select");
        mode.dataset.buField = "mode";
        mode.setAttribute("aria-describedby", `business-unit-${index}-mode-error`);
        for (const value of ["Strict", "Allowance", "Notify"]) {
          const option = document.createElement("option");
          option.value = value;
          option.textContent = value;
          option.selected = unit.mode === value;
          mode.append(option);
        }
        const modeError = document.createElement("div");
        modeError.id = `business-unit-${index}-mode-error`;
        modeError.className = "field-error";
        modeError.setAttribute("role", "alert");
        modeLabel.append(mode, modeError);
        row.append(modeLabel);
        const percent = field(row, "Allowance percent", "percent", unit.percent ?? "", "number");
        percent.closest("label").hidden = unit.mode !== "Allowance";
        mode.onchange = () => {
          if (refuseTreeAction()) return;
          percent.closest("label").hidden = mode.value !== "Allowance";
          sync();
          markPreflightStale();
        };
        const remove = document.createElement("button");
        remove.type = "button";
        remove.textContent = "Remove";
        remove.onclick = () => {
          if (refuseTreeAction()) return;
          businessUnits.splice(index, 1);
          const nextIndex = Math.min(index, businessUnits.length - 1);
          render();
          sync();
          markPreflightStale();
          if (nextIndex >= 0) focusRow(nextIndex);
          else byId("add-unit").focus();
        };
        row.append(remove);
        row.oninput = () => {
          if (refuseTreeAction()) return;
          sync();
          validateCurrentAnswers();
        };
        tree.append(row);
      });
      byId("business-units").value = businessUnits.length ? JSON.stringify(businessUnits, null, 2) : "";
      refreshParentOptions();
      renderValidation();
    }

    function addUnit() {
      if (refuseTreeAction()) return;
      sync();
      businessUnits.push(defaultBusinessUnit());
      const index = businessUnits.length - 1;
      render();
      markPreflightStale();
      focusRow(index);
    }

    function addTeam() {
      if (refuseTreeAction()) return;
      sync();
      refreshParentOptions();
      const parent = byId("team-parent").value;
      if (!parent) {
        byId("business-unit-problems").textContent = "Give a business unit an id before adding a team.";
        return;
      }
      businessUnits.push(defaultBusinessUnit(parent));
      const index = businessUnits.length - 1;
      render();
      markPreflightStale();
      focusRow(index);
    }

    function applyJsonText(text) {
      let candidate;
      try {
        candidate = text.trim() ? JSON.parse(text.trim()) : [];
      } catch (error) {
        jsonDraftProblem = `JSON parse error: ${error.message}`;
        renderValidation();
        validateCurrentAnswers();
        return;
      }
      if (!Array.isArray(candidate) || candidate.some((item) => !isPlainObject(item))) {
        jsonDraftProblem = "BusinessUnits JSON must be an array of objects.";
        renderValidation();
        validateCurrentAnswers();
        return;
      }
      jsonDraftProblem = "";
      businessUnits = candidate;
      render();
      markPreflightStale();
    }

    return { addTeam, addUnit, applyJsonText, render, sync };
  }

  globalThis.ClaudeInstallerBusinessUnits = { create: createBusinessUnitsEditor };
})();
