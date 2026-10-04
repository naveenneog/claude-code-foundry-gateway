(function () {
  "use strict";

  function createActionHost() {

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
      pieces.push(data.error || error?.message || "The action failed.");
      if (data.reason === "preflight-required") pieces.push("Run the preflight again, then retry this action.");
      else if (data.remedy) pieces.push(data.remedy);
      else pieces.push("Check the values above and try again.");
      return pieces.join(" ");
    }

    async function run(button, options, action) {
      if (button.dataset.actionBusy === "true" || button.disabled) return undefined;
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
      appendText(status, busyText);
      try {
        const result = await action();
        clearChildren(status);
        appendText(status, successText);
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
      }
    }

    return { run };
  }

  globalThis.ClaudeInstallerActions = { create: createActionHost };
})();

