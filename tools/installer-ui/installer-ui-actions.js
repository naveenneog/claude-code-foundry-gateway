(function () {
  "use strict";

  function createActionHost(hostOptions = {}) {

    function appendText(parent, text, tag = "span", className = "") {
      const node = document.createElement(tag);
      node.textContent = text;
      if (className) node.className = className;
      parent.append(node);
      return node;
    }

    function clearChildren(node) {
      while (node?.firstChild) node.removeChild(node.firstChild);
    }

    function regionFor(button, kind) {
      const id = `${button.id || button.dataset.prefillKind || "action"}-${kind}`;
      let node = document.getElementById(id);
      if (!node) {
        node = document.createElement("p");
        node.id = id;
        node.tabIndex = -1;
        node.className = `action-${kind}`;
        button.insertAdjacentElement("afterend", node);
      }
      node.setAttribute("role", kind === "error" ? "alert" : "status");
      return node;
    }

    function errorText(error) {
      const data = error?.data || {};
      const pieces = [];
      pieces.push(formatError(data, error));
      if (data.reason === "preflight-required") pieces.push("Run the preflight again, then retry this action.");
      else if (data.reason === "azure-busy") pieces.push("Wait for it to finish, then try again.");
      else if (data.remedy) pieces.push(data.remedy);
      else pieces.push("Check the values above and try again.");
      return pieces.join(" ");
    }

    function operationName(operation) {
      return {
        identity: "an account read",
        prefill: "a prefill read",
        preflight: "a preflight",
        run: "an installer run",
      }[operation] || "Azure CLI work";
    }

    function formatError(data, error) {
      if (data.reason === "azure-busy") return `${operationName(data.operation)} is already using Azure CLI.`;
      return data.error || error?.message || "The action failed.";
    }

    async function run(button, options, action) {
      if (button.dataset.actionBusy === "true" || button.disabled) return undefined;
      const hadFocus = document.activeElement === button;
      const oldText = button.textContent;
      const busyText = options.busyText || `${oldText}...`;
      const successText = options.successText || "Done.";
      const status = regionFor(button, "status");
      const error = regionFor(button, "error");
      clearChildren(status);
      clearChildren(error);
      button.dataset.actionBusy = "true";
      button.disabled = true;
      button.textContent = busyText;
      if (options.azure && typeof hostOptions.onAzureBusy === "function") hostOptions.onAzureBusy(true, button);
      appendText(status, busyText);
      if (hadFocus) status.focus();
      try {
        const result = await action();
        clearChildren(status);
        appendText(status, result?.statusText || successText);
        return result;
      } catch (ex) {
        clearChildren(error);
        appendText(error, errorText(ex));
        error.focus();
        return undefined;
      } finally {
        button.textContent = oldText;
        delete button.dataset.actionBusy;
        button.disabled = false;
        if (options.azure && typeof hostOptions.onAzureBusy === "function") hostOptions.onAzureBusy(false, button);

        if (typeof hostOptions.onSettled === "function") hostOptions.onSettled(button);
        if (hadFocus) returnFocus(button, status);
      }
    }

    function returnFocus(button, status) {
      // Chromium moves focus to the body when the focused button is disabled; the status region keeps the keyboard position.
      const active = document.activeElement;
      if (active && active !== document.body && active !== status) return;
      if (button.disabled || button.hidden) status.focus();
      else button.focus();
    }

    return { run };
  }

  globalThis.ClaudeInstallerActions = { create: createActionHost };
})();
