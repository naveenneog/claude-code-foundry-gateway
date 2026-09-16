/**
 * Asks Astra to review a document for plain language.
 *
 * The brief is deliberately narrow: not "make it better", which produces
 * rewriting for its own sake, but "find what a competent reader who is not a
 * specialist would trip over". Vague review prompts get vague reviews.
 *
 *   node guide/ask-astra.mjs docs/BUSINESS-UNITS.md
 */
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const file = process.argv[2];
if (!file) { console.error('usage: node guide/ask-astra.mjs <file>'); process.exit(1); }

const ENDPOINT = 'https://foundry-plus-resource.cognitiveservices.azure.com';
const MODEL = 'gpt-6-astra';

const token = execSync(
  'az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv',
  { encoding: 'utf8' },
).trim();

const doc = readFileSync(file, 'utf8');

const brief = `You are reviewing documentation for an open-source Azure accelerator. The
reader is a competent platform engineer or IT admin who is NOT a specialist in
this product and has not read the rest of the repository.

Judge it on exactly these four things, and nothing else:

1. JARGON. Terms used without being explained on the page. Quote the term and
   the line. Ignore terms that are genuinely standard for an Azure admin
   (resource group, managed identity, RBAC). Flag ones that are ours or
   Anthropic's (business unit, tier, unassigned, ledger, cascade, soft cap,
   named value, 3P, surface).

2. ORDER. Does it answer "what do I type" before "why is it designed this way"?
   A reader with a task in hand wants the command first. Flag places where
   rationale blocks the instruction.

3. UNNECESSARY LENGTH. Sentences or paragraphs that could go entirely without
   losing information a reader needs. Quote the first few words. Be specific -
   "it is too long" is not useful.

4. MISSING STEP. Anywhere a reader would get stuck because something is assumed.

Answer as a list. For each item: the quoted text, which of the four it is, and
a concrete replacement. If a section is genuinely fine, say so briefly rather
than inventing work. Do not rewrite the whole document. Do not comment on
style, tone or formatting.

DOCUMENT: ${file}

---
${doc}`;

const res = await fetch(`${ENDPOINT}/openai/v1/responses`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({
    model: MODEL,
    input: brief,
    reasoning: { effort: 'medium' },
    max_output_tokens: 16000,
  }),
});

if (!res.ok) {
  console.error(`HTTP ${res.status}`);
  console.error((await res.text()).slice(0, 1200));
  process.exit(1);
}

const json = await res.json();
if (json.status === 'incomplete') {
  console.error(`Astra stopped early: ${json.incomplete_details?.reason}. Raise max_output_tokens or lower reasoning effort.`);
}
const text = (json.output ?? [])
  .flatMap((o) => o.content ?? [])
  .filter((c) => c.type === 'output_text')
  .map((c) => c.text)
  .join('\n');

console.log(text || JSON.stringify(json).slice(0, 2000));
