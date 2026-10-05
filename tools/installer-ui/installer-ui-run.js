(function () {
  "use strict";

  function createRunHost(deps) {
    const { byId, csrfToken, getJson, hasBlockingProblems, onIdentityStale, postJson, readIdentityAfterRun, setErrorText, setStatusText, updateRunAdmission } = deps;
    const maxRunOutputLines = 2000;
    let activeRunId = "";
    let activeStepId = "";
    let runActive = false;
    let lastRunSeq = 0;
    let lastFailedStep = "";
    let runOutputLines = [];
    let removedRunOutputLines = 0;

    function isActive() {
      return runActive;
    }

    function failedStep() {
      return lastFailedStep;
    }

    function currentStep() {
      return activeStepId;
    }

    function resetActiveRun() {
      activeRunId = "";
    }

    function appendRunLine(text) {
      const output = byId("run-output");
      runOutputLines.push(text);
      if (runOutputLines.length > maxRunOutputLines) {
        const removed = runOutputLines.length - maxRunOutputLines;
        runOutputLines.splice(0, removed);
        removedRunOutputLines += removed;
      }
      const shown = removedRunOutputLines ? [`Earlier run output lines were removed (${removedRunOutputLines}).`, ...runOutputLines] : runOutputLines;
      output.textContent = `${shown.join("\n")}\n`;
    }

    function resetOutputIfNewRun() {
      if (activeRunId) return;
      byId("run-output").textContent = "";
      runOutputLines = [];
      removedRunOutputLines = 0;
    }

    function finishRun(summary) {
      activeRunId = "";
      activeStepId = "";
      runActive = false;
      lastFailedStep = summary.failedStepId || "";
      updateRunAdmission();
      if (summary.resumeCommand) appendRunLine(`Resume: ${summary.resumeCommand}`);
      if (summary.state === "stopped") {
        return { statusText: `Run stopped at ${summary.stepId || activeStepId || lastFailedStep || "the current step"}.` };
      }
      if (summary.state === "exited" && summary.exitCode === 0) return {};
      const code = summary.exitCode === null || summary.exitCode === undefined ? "unknown" : String(summary.exitCode);
      const pieces = [`Installer run failed with exit code ${code}.`];
      if (lastFailedStep) pieces.push(`Failed step: ${lastFailedStep}.`);
      if (summary.resumeCommand) pieces.push(`Resume with: ${summary.resumeCommand}`);
      const error = new Error(pieces.join(" "));
      error.data = { error: error.message };
      throw error;
    }

    async function readRunStream(res) {
      resetOutputIfNewRun();
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let summary = null;
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split(/\r?\n/);
        buffer = lines.pop() || "";
        for (const line of lines) {
          if (!line) continue;
          const event = JSON.parse(line);
          lastRunSeq = event.seq || lastRunSeq;
          if (event.type === "progress" && event.event === "started") activeStepId = event.stepId || activeStepId;
          appendRunLine(`${event.type}: ${event.stepId || ""} ${event.event || ""} ${event.line || event.message || ""}`);
          if (event.type === "summary") summary = event;
        }
      }
      if (summary) return finishRun(summary);
      return null;
    }

    async function fetchRunStream(path) {
      const res = await fetch(path);
      if (!res.ok) throw await responseError(res, "run stream failed");
      return res;
    }

    async function responseError(res, fallback) {
      let data = {};
      try {
        data = await res.json();
      } catch {}
      const error = new Error(data.error || `${fallback} with HTTP ${res.status}`);
      error.data = { ...data, status: res.status };
      return error;
    }

    async function recoverMissingSummary(reattachCount = 0, quietCount = 0) {
      const status = await getJson("./api/run/status");
      if (status.id && status.state === "running") {
        if (quietCount >= 3) {
          runActive = false;
          updateRunAdmission();
          throw new Error("The run stream keeps ending without new events. Reloading the page reattaches to the run.");
        }
        activeRunId = status.id;
        activeStepId = status.currentStepId || status.steps?.[0] || "";
        const before = lastRunSeq;
        const result = await readRunStream(await fetchRunStream(`./api/run/attach?after=${lastRunSeq}`));
        if (result) return result;
        return recoverMissingSummary(reattachCount + 1, before === lastRunSeq ? quietCount + 1 : 0);
      }
      runActive = false;
      updateRunAdmission();
      const state = status.state || "unknown";
      throw new Error(`The run stream ended without a summary; the server reports state ${state}.`);
    }

    async function streamRun(body) {
      if (hasBlockingProblems()) return undefined;
      runActive = true;
      updateRunAdmission();
      const res = await fetch("./api/run/stream", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken(),
        },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        runActive = false;
        updateRunAdmission();
        const error = await responseError(res, "run failed");
        if (error.data?.reason === "identity-changed" && typeof onIdentityStale === "function") onIdentityStale(error.message);
        throw error;
      }
      try {
        const result = (await readRunStream(res)) || (await recoverMissingSummary());
        refreshIdentityAfterRun();
        return result;
      } catch (error) {
        runActive = false;
        updateRunAdmission();
        throw error;
      }
    }

    async function refreshRunStatus() {
      if (location.protocol === "file:") return;
      const status = await getJson("./api/run/status");
      if (status.id && status.state === "running") {
        activeRunId = status.id;
        activeStepId = status.currentStepId || status.steps?.[0] || "";
        runActive = true;
        updateRunAdmission();
        const result = (await readRunStream(await fetchRunStream(`./api/run/attach?after=${lastRunSeq}`))) || (await recoverMissingSummary());
        refreshIdentityAfterRun();
        return result;
      }
    }

    async function stopRun() {
      const status = await getJson("./api/run/status");
      const runId = status.id || activeRunId;
      const step = status.currentStepId || activeStepId || "the current step";
      if (!runId) return { statusText: "No run is active, so nothing was stopped." };
      if (!globalThis.confirm(`Stop run at ${step}? Running the same steps again resumes from the install checkpoint.`)) return { statusText: "No stop was requested." };
      const result = await postJson("./api/run/stop", { runId });
      appendRunLine(`stopped: ${result.message}`);
      return { statusText: "Stop requested." };
    }

    function handleAttachError(error) {
      setErrorText("run", error.message || String(error));
    }

    function refreshIdentityAfterRun() {
      void readIdentityAfterRun().catch(() => {});
    }

    return { appendRunLine, currentStep, failedStep, handleAttachError, isActive, resetActiveRun, streamRun, stopRun, refreshRunStatus };
  }

  globalThis.ClaudeInstallerRun = { create: createRunHost };
})();
