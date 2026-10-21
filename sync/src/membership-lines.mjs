/**
 * The membership a full renewal resolved, as console lines for chargeback (ADR-0066).
 *
 * ClaudeCost() in analytics/chargeback-cost.kql reads these lines from ContainerAppConsoleLogs and
 * uses the newest run whose parts are all present, so a move between business units reaches
 * chargeback on the next run. Each line stays within MEMBERSHIP_LINE_MAX_CHARS (U200); a line the
 * workspace cuts leaves its run incomplete, and ClaudeCost() then ignores that run.
 */
import { MEMBERSHIP_EVENT } from './events.mjs';

export const MEMBERSHIP_LINE_MAX_CHARS = 3500;

/**
 * @param {{ runId: string, at: string, records: Array<{ oid: string, businessUnit?: string }>, parents: Map<string, string> }} input
 *   parents: bu-parents keyed by lower-case team id, as parseBuParents returns it.
 * @returns {string[]} JSON lines; at least one, so a run with no unit still states that.
 */
export function membershipLines({ runId, at, records, parents }) {
  const rows = records
    .filter((record) => record.businessUnit)
    .map((record) => [record.oid, record.businessUnit, parents.get(record.businessUnit.toLowerCase()) ?? '']);
  const head = { event: MEMBERSHIP_EVENT, run: runId, at };
  // Part numbers are written as the largest the run could need, so a chunk measured here never grows
  // when its real numbers are filled in.
  const reserve = Math.max(rows.length, 1);
  const emptyLength = JSON.stringify({ ...head, part: reserve, parts: reserve, rows: [] }).length;

  const chunks = [];
  let current = [];
  let length = emptyLength;
  for (const row of rows) {
    const rowLength = JSON.stringify(row).length;
    if (emptyLength + rowLength > MEMBERSHIP_LINE_MAX_CHARS) {
      throw new Error(`the business unit '${row[1]}' does not fit in one membership line`);
    }
    const added = rowLength + (current.length ? 1 : 0);
    if (length + added > MEMBERSHIP_LINE_MAX_CHARS) {
      chunks.push(current);
      current = [];
      length = emptyLength;
    }
    length += rowLength + (current.length ? 1 : 0);
    current.push(row);
  }
  chunks.push(current);
  return chunks.map((chunk, index) => JSON.stringify({ ...head, part: index + 1, parts: chunks.length, rows: chunk }));
}
