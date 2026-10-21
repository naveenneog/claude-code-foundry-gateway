import { test } from 'node:test';
import assert from 'node:assert/strict';
import { membershipLines, unitAssignments, MEMBERSHIP_LINE_MAX_CHARS } from '../src/membership-lines.mjs';
import { MEMBERSHIP_EVENT } from '../src/events.mjs';

const at = '2026-10-21T10:00:00.000Z';
const oid = (i) => `30000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
const parse = (lines) => lines.map((line) => JSON.parse(line));

test('membership lines carry the event, run, time, part numbers and [oid, unit, parent] rows', () => {
  const lines = membershipLines({
    runId: 'caj-renew-abc-1',
    gateway: '/subscriptions/S/resourceGroups/RG/providers/Microsoft.ApiManagement/service/APIM',
    at,
    records: [
      { oid: oid(1), businessUnit: 'platform' },
      { oid: oid(2), businessUnit: 'eng' },
    ],
    parents: new Map([['platform', 'eng']]),
  });
  assert.deepEqual(parse(lines), [{
    event: MEMBERSHIP_EVENT,
    gateway: '/subscriptions/s/resourcegroups/rg/providers/microsoft.apimanagement/service/apim',
    run: 'caj-renew-abc-1',
    at,
    part: 1,
    parts: 1,
    rows: [[oid(1), 'platform', 'eng'], [oid(2), 'eng', '']],
  }]);
});

test('members without a unit are omitted, and a run with no unit prints one line with no rows', () => {
  const lines = membershipLines({ runId: 'r', at, records: [{ oid: oid(1), businessUnit: '' }, { oid: oid(2) }], parents: new Map() });
  assert.deepEqual(parse(lines).map(({ part, parts, rows }) => ({ part, parts, rows })), [{ part: 1, parts: 1, rows: [] }]);
});

test('a parent is looked up without case, as bu-parents keys are', () => {
  const [line] = parse(membershipLines({ runId: 'r', at, records: [{ oid: oid(1), businessUnit: 'Platform' }], parents: new Map([['platform', 'eng']]) }));
  assert.deepEqual(line.rows, [[oid(1), 'Platform', 'eng']]);
});

test('25,000 members split into numbered parts that each stay within the line bound and together hold every member once', () => {
  const records = Array.from({ length: 25000 }, (_, i) => ({ oid: oid(i + 1), businessUnit: i % 2 ? 'finance-operations' : 'engineering-platform' }));
  const lines = membershipLines({ runId: 'caj-renew-abcdefghijklm-a1b2c3d', at, records, parents: new Map([['engineering-platform', 'engineering']]) });
  assert.ok(lines.length > 1);
  // U200: 3,500 characters, below the 4,000 a community answer reports for the console path.
  for (const line of lines) assert.ok(line.length <= 3500 && line.length <= MEMBERSHIP_LINE_MAX_CHARS, `line of ${line.length} characters`);
  const parsed = parse(lines);
  assert.deepEqual(parsed.map((p) => p.part), Array.from({ length: lines.length }, (_, i) => i + 1));
  for (const p of parsed) assert.equal(p.parts, lines.length);
  const oids = parsed.flatMap((p) => p.rows.map((row) => row[0]));
  assert.equal(oids.length, 25000);
  assert.equal(new Set(oids).size, 25000);
});

test('a unit name that alone would not fit in a line is refused rather than cut', () => {
  assert.throws(
    () => membershipLines({ runId: 'r', at, records: [{ oid: oid(1), businessUnit: 'u'.repeat(4000) }], parents: new Map() }),
    /does not fit in one membership line/,
  );
});

test('every unit member is assigned, access or not, deepest unit first and first match winning', () => {
  const assigned = unitAssignments([
    { id: 'platform', members: [{ oid: oid(2) }] },
    { id: 'eng', members: [{ oid: oid(1) }, { oid: oid(2) }, { oid: oid(3) }] },
  ]);
  assert.deepEqual(assigned, [
    { oid: oid(2), businessUnit: 'platform' },
    { oid: oid(1), businessUnit: 'eng' },
    { oid: oid(3), businessUnit: 'eng' },
  ]);
});

test('unit names with quotes, backslashes and non-ASCII survive the line and its bound', () => {
  const unit = 'q"\\u\u00e9\n' + 'x'.repeat(300);
  const records = Array.from({ length: 200 }, (_, i) => ({ oid: oid(i + 1), businessUnit: unit }));
  const lines = membershipLines({ runId: 'r', at, records, parents: new Map([[unit.toLowerCase(), 'p"\\']]) });
  for (const line of lines) assert.ok(line.length <= MEMBERSHIP_LINE_MAX_CHARS, `line of ${line.length} characters`);
  const rows = parse(lines).flatMap((p) => p.rows);
  assert.equal(rows.length, 200);
  assert.deepEqual(rows[0], [oid(1), unit, 'p"\\']);
});