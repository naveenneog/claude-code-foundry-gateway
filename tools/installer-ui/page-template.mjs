export async function renderHtml(loadSchema) {
  const schema = JSON.stringify(await loadSchema());
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude gateway installer</title>
  <link rel="stylesheet" href="./installer-ui.css">
  <script type="application/json" id="schema-json">${schema.replaceAll('<', '\\u003c')}</script>
  <script defer src="./ui-model.js"></script>
  <script defer src="./installer-ui.js"></script>
</head>
<body>
  <header>
    <h1>Claude gateway installer</h1>
    <p id="identity">Signed-in account: read-only checks use the Azure CLI session in this terminal.</p>
    <button id="refresh-identity" type="button">Refresh account</button>
    <button id="signin" type="button">Show sign-in command</button>
    <pre id="signin-command"></pre>
    <p class="small">Cloud Shell ends a session after 20 minutes without interactive activity. Keep the shell active before long waits.</p>
  </header>
  <main>
    <section><h2>Prerequisites</h2><button id="preflight" type="button">Run preflight</button><div id="preflight-output"></div></section>
    <section><h2>Foundation</h2><div id="foundation" class="grid"></div></section>
    <section><h2>Access</h2><div id="access" class="grid"></div></section>
    <section><h2>Optional parts</h2><div id="optional" class="grid"></div></section>
    <section><h2>Business units and teams</h2><div id="business-unit-tree"></div><button id="add-unit" type="button">Add unit</button><label>Add team under <select id="team-parent"></select></label><button id="add-team" type="button">Add team</button><details><summary>JSON view</summary><textarea id="business-units" rows="8" cols="80"></textarea></details><pre id="business-unit-problems"></pre></section>
    <section><h2>Review</h2><button id="download" type="button">Download answers.json</button><button id="plan" type="button">Plan fingerprint</button><pre id="commands"></pre><pre id="plan-output"></pre></section>
    <section><h2>Run</h2><button id="steps" type="button">List steps</button><div id="step-list"></div><button id="run" type="button">Run selected steps</button><button id="full-run" type="button">Full run</button><button id="rerun" type="button" disabled>Re-run failed step</button><button id="stop-run" type="button" disabled>Stop run</button><pre id="run-output"></pre></section>
    <pre id="errors"></pre>
  </main>
</body>
</html>`;
}
