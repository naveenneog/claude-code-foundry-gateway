(function () {
  "use strict";

  function createRunHost(deps) {
    const { byId, csrfToken, getJson, hasBlockingProblems, onPreflightStale, postJson, readIdentityAfterRun, setErrorText, setStatusText, updateRunAdmission } = deps;
    const maxRunOutputLines = 2000;
    let activeRunId = "";
    let activeStepId = "";
    let runActive = false;
    let lastRunSeq = 0;
    let lastFailedStep = "";
    let activeClientRequestId = "";
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
      activeClientRequestId = "";
    }

    function clientRequestId() {
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
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
      const stoppedStep = summary.stepId || activeStepId || parseStoppedStep(summary.message) || summary.failedStepId || lastFailedStep || "the current step";
      activeRunId = "";
      activeStepId = "";
      runActive = false;
      lastFailedStep = summary.failedStepId || "";
      updateRunAdmission();
      if (summary.resumeCommand) appendRunLine(`Resume: ${summary.resumeCommand}`);
      if (summary.state === "stopped") {
        return { statusText: `Run stopped at ${stoppedStep}.` };
      }
      if (summary.state === "exited" && summary.exitCode === 0) return {};
      const code = summary.exitCode === null || summary.exitCode === undefined ? "unknown" : String(summary.exitCode);
      const pieces = [`Installer run failed with exit code ${code}.`];
      if (lastFailedStep) pieces.push(`Failed step: ${lastFailedStep}.`);
      if (summary.resumeCommand) pieces.push(`Resume with: ${summary.resumeCommand}`);
      const error = new Error(pieces.join(" "));
      error.data = { error: error.message, runSummary: true };
      throw error;
    }

    function parseStoppedStep(message) {
      const match = String(message || "").match(/Stopped installer run at ([^.]+)\./);
      return match?.[1] || "";
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
      if (sameRun(status)) {
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
        if (status.state !== "running" && status.state !== "stopping") {
          runActive = false;
          updateRunAdmission();
          const state = status.state || "unknown";
          throw new Error(`The run stream ended without a summary; the server reports state ${state}.`);
        }
        return recoverMissingSummary(reattachCount + 1, before === lastRunSeq ? quietCount + 1 : 0);
      }
      runActive = false;
      updateRunAdmission();
      const state = status.state || "unknown";
      throw new Error(`The run stream ended without a summary; the server reports state ${state}.`);
    }

    async function followRun(read) {
      try {
        const result = (await read()) || (await recoverMissingSummary());
        refreshIdentityAfterRun();
        return result;
      } catch (error) {
        if (!error.data?.runSummary) {
          const recovered = await reconcileBrokenStream().catch(() => null);
          if (recovered) {
            refreshIdentityAfterRun();
            return recovered;
          }
        }
        runActive = false;
        updateRunAdmission();
        if (error.data?.runSummary) refreshIdentityAfterRun();
        throw error;
      }
    }

    function sameRun(status) {
      if (!status?.id) return false;
      return status.id === activeRunId || (activeClientRequestId && status.clientRequestId === activeClientRequestId);
    }

    async function reconcileBrokenStream() {
      const status = await getJson(activeClientRequestId ? `./api/run/status?request=${encodeURIComponent(activeClientRequestId)}` : "./api/run/status");
      const run = status?.admission?.state === "started" ? { ...status, id: status.admission.runId || status.id } : status;
      if (!sameRun(run)) return null;
      activeRunId = run.id;
      activeStepId = run.currentStepId || run.steps?.[0] || activeStepId;
      runActive = true;
      updateRunAdmission();
      return (await readRunStream(await fetchRunStream(`./api/run/attach?after=${lastRunSeq}`))) || null;
    }

    async function recoverLostRequest(requestError) {
      // The request may have reached the server before the connection failed: a run that started is reattached.
      let statusFailures = 0;
      for (let i = 0; i < 400; i++) {
        let status;
        try {
          status = await getJson(`./api/run/status?request=${encodeURIComponent(activeClientRequestId)}`);
        } catch {
          statusFailures++;
          if (statusFailures >= 3) break;
          await new Promise((resolve) => setTimeout(resolve, 500));
          continue;
        }
        if (status?.admission?.state === "admitting") {
          await new Promise((resolve) => setTimeout(resolve, 500));
          continue;
        }
        if (status?.admission?.state === "started") {
          activeRunId = status.admission.runId || status.id || "";
          return followRun(() => fetchRunStream(`./api/run/attach?after=0`).then(readRunStream));
        }
        if (status?.admission?.state === "refused") {
          runActive = false;
          updateRunAdmission();
          const error = new Error(status.admission.error || "run refused");
          error.data = { error: error.message, reason: status.admission.reason };
          if (["identity-changed", "preflight-required"].includes(error.data.reason) && typeof onPreflightStale === "function") onPreflightStale(error.message);
          throw error;
        }
        if (!status?.admission) {
          runActive = false;
          updateRunAdmission();
          const error = new Error(`The run request failed before the server answered (${requestError.message}), and the installer UI server has no record of that request.`);
          error.data = { error: error.message, remedy: "Check that the installer UI server is still running in its terminal, then try again." };
          throw error;
        }
        break;
      }
      runActive = false;
      updateRunAdmission();
      const server = statusFailures ? "the installer UI server did not answer status requests" : "the installer UI server did not finish admitting the run";
      const error = new Error(`The run request failed before the server answered (${requestError.message}), and ${server}.`);
      error.data = { error: error.message, remedy: "Check that the installer UI server is still running in its terminal, then try again." };
      throw error;
    }

    async function streamRun(body) {
      if (hasBlockingProblems()) return undefined;
      runActive = true;
      activeClientRequestId = clientRequestId();
      // A new run's events start at 1; a reattach of this run must not use the previous run's cursor.
      lastRunSeq = 0;
      updateRunAdmission();
      let res;
      try {
        res = await fetch("./api/run/stream", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-csrf-token": csrfToken(),
            "x-client-request-id": activeClientRequestId,
          },
          body: JSON.stringify(body),
        });
      } catch (error) {
        return recoverLostRequest(error);
      }
      if (!res.ok) {
        runActive = false;
        updateRunAdmission();
        const error = await responseError(res, "run failed");
        if (["identity-changed", "preflight-required"].includes(error.data?.reason) && typeof onPreflightStale === "function") onPreflightStale(error.message);
        throw error;
      }
      return followRun(() => readRunStream(res));
    }

    async function refreshRunStatus() {
      if (location.protocol === "file:") return;
      const status = await getJson("./api/run/status");
      if (status.id && (status.state === "running" || status.state === "stopping")) {
        activeRunId = status.id;
        activeClientRequestId = status.clientRequestId || "";
        activeStepId = status.currentStepId || status.steps?.[0] || "";
        runActive = true;
        updateRunAdmission();
        try {
          const result = (await readRunStream(await fetchRunStream(`./api/run/attach?after=${lastRunSeq}`))) || (await recoverMissingSummary());
          refreshIdentityAfterRun();
          return result;
        } catch (error) {
          if (error.data?.runSummary) refreshIdentityAfterRun();
          throw error;
        }
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
