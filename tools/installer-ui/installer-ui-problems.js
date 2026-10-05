(function () {
  "use strict";

  function createProblems(deps) {
    const { byId, checkFields } = deps;

    function fieldForPath(path) {
      const text = String(path || "");
      const exact = document.querySelector(`[name="${CSS.escape(text)}"]`);
      if (exact) return exact;
      const bu = text.match(/^BusinessUnits\[(\d+)\](?:\.([A-Za-z]+))?$/);
      if (bu) {
        const row = document.querySelector(`[data-bu-index="${CSS.escape(bu[1])}"]`);
        if (row && bu[2]) return row.querySelector(`[data-bu-field="${CSS.escape(bu[2])}"]`);
        if (row) return row.querySelector("input, select, button");
      }
      if (text.startsWith("BusinessUnits")) return byId("business-units");
      const rootName = text.split(/[.\[]/)[0];
      if (!rootName) return null;
      if (rootName === "BusinessUnits") return byId("business-units");
      return document.querySelector(`[name="${CSS.escape(rootName)}"], [name^="${CSS.escape(rootName)}."]`);
    }

    function markFieldProblem(path, message, remedy) {
      const field = fieldForPath(path);
      if (!field) return null;
      field.setAttribute("aria-invalid", "true");
      const described = field.getAttribute("aria-describedby") || "";
      const errorId = described.split(/\s+/).filter(Boolean)[0];
      const err = errorId ? byId(errorId) : null;
      if (err) err.textContent = `${message || "Review this field."} ${remedy || ""}`.trim();
      return field;
    }

    function focusProblemPath(path) {
      const field = fieldForPath(path);
      field?.focus();
    }

    function appendProblemButton(parent, path, label) {
      if (!fieldForPath(path)) return;
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = label || `Review ${path}`;
      button.addEventListener("click", () => focusProblemPath(path));
      parent.append(button);
    }

    function preflightProblemPaths(check) {
      if (check.result !== "FAIL") return [];
      const out = [];
      for (const problem of check.problems || []) {
        if (problem.path) out.push({ path: problem.path, message: problem.message, remedy: problem.remedy });
      }
      if (!out.length) {
        for (const path of checkFields[check.id] || []) out.push({ path, message: check.message, remedy: check.remedy });
      }
      return out;
    }

    function markFields(checks) {
      for (const check of checks) {
        if (check.result === "PASS") continue;
        for (const p of preflightProblemPaths(check)) markFieldProblem(p.path, p.message || check.message, p.remedy || check.remedy);
      }
    }

    return { appendProblemButton, markFieldProblem, markFields, preflightProblemPaths };
  }

  globalThis.ClaudeInstallerProblems = { create: createProblems };
})();
