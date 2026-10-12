(function () {
  "use strict";

  function createRenderHost(deps) {
    const { appendText, buildPortableCommands, byId, clearChildren, collectAnswers, hasBlockingProblems, liveMode } = deps;

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
        if (commands.terminalPfx) appendText(root, "The installer asks for the PFX password in the terminal.", "p");
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
      if (commands.terminalPfx) appendText(root, "The installer asks for the PFX password in the terminal.", "p");
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

    function renderPreflight(result, problems) {
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
    }

    function selectedSteps() {
      return [...document.querySelectorAll("#step-list input:checked")].map((input) => input.value);
    }

    function refreshCommands(schema) {
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

    function renderSteps(payload) {
      const parent = byId("step-list");
      clearChildren(parent);
      const steps = Array.isArray(payload) ? payload : payload.steps || [];
      for (const step of steps) {
        const label = document.createElement("label");
        const input = document.createElement("input");
        input.type = "checkbox";
        input.value = step.id;
        label.append(input);
        appendText(label, ` ${step.id} - ${step.title || ""}`);
        parent.append(label);
      }
    }

    return { refreshCommands, renderPreflight, renderSteps, selectedSteps };
  }

  globalThis.ClaudeInstallerRender = { create: createRenderHost };
})();
