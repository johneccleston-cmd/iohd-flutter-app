// Before/after evidence for the same-part bug (N1) and the 1,000+ parse bug (C2), read-only.
// Runs the REAL src/inventory.js of the backend checkout given as argv[2] against an in-memory fake Sheet.
// No network, no Google, no Postgres.   node same_part_before_after.js /path/to/integrity-backend
'use strict';
const path = require('node:path');
const BACKEND = process.argv[2];
if (!BACKEND) { console.error('usage: node same_part_before_after.js <backend dir>'); process.exit(2); }
const src = (rel) => require.resolve(path.join(BACKEND, 'src', rel));
const stub = (file, exports) => { require.cache[file] = { id: file, filename: file, loaded: true, exports, children: [], paths: [] }; };

// Formatted values, as the Sheets API returns by default.
const fmt = (n) => Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const sheet = { inventory: [], picked: [], writes: [] };
function applyWrite(range, value, input) {
    sheet.writes.push(`${range}=${JSON.stringify(value)} (${input})`);
    const m = /^Inventory!D(\d+)$/.exec(range);
    if (m) sheet.inventory[Number(m[1]) - 1][3] = typeof value === 'number' ? fmt(value) : String(value);
}
const sheetsClient = { spreadsheets: { values: {
    async get({ range }) { return { data: { values: (range.startsWith('Inventory!') ? sheet.inventory : sheet.picked).map((r) => r.slice()) } }; },
    async batchUpdate({ resource }) { for (const u of resource.data) applyWrite(u.range, u.values[0][0], resource.valueInputOption); return {}; },
    async update({ range, resource, valueInputOption }) { applyWrite(range, resource.values[0][0], valueInputOption); return {}; },
    async append({ resource }) { for (const v of resource.values) sheet.picked.push(v); return {}; },
} } };

const crons = [];
stub(require.resolve(path.join(BACKEND, 'node_modules', 'node-cron')), { schedule: (spec, fn) => crons.push({ spec, fn }) });
stub(src('services'), {
    sheetSafe: (val = '') => String(val).replace(/^[=+\-@\t\r]+/, '').trim(),
    posInt: (val) => { const n = parseInt(val, 10); return Number.isFinite(n) && n > 0 ? n : 0; },
    todayChicago: () => '2026-11-18',
    getInventorySheets: async () => ({ pickedLog: sheet.picked, masterInv: sheet.inventory }),
    getJobsForTechToday: () => [], isForbidden: () => false, getTechToken: async () => null,
    invalidateSheetsCache: () => {}, scheduleWarehouseUpdate: () => {},
});
stub(src('config'), { sheetsClient, admin: { messaging: () => ({ send: async () => {} }) }, INVENTORY_SHEET_ID: 'fake' });
const router = require(src('inventory'))({ query: async () => ({ rows: [] }) }, (req, res, next) => next());

// 07:30 Chicago (13:30 UTC on 18 Nov 2026), so warehouse1 checkouts are staged.
const RealDate = Date;
function at(isoUtc) {
    const fixed = new RealDate(isoUtc).getTime();
    global.Date = class extends RealDate { constructor(...a) { super(...(a.length ? a : [fixed])); } static now() { return fixed; } };
}
const realTime = () => { global.Date = RealDate; };

async function checkout(body) {
    const layer = router.stack.find((l) => l.route && l.route.path === '/checkout_inventory');
    let status = 200, out;
    const res = { status(s) { status = s; return res; }, json(b) { out = b; return res; } };
    await layer.route.stack.at(-1).handle({ headers: {}, body }, res);
    return { status, body: out };
}
const qty = (name) => sheet.inventory.find((r) => r[1] === name)[3];
const reset = (rows) => { sheet.inventory = [['Part Number', 'Part Name', 'Location', 'Qty'], ...rows.map((r) => r.slice())]; sheet.picked = []; sheet.writes = []; };
const ANGLE = 'Punched Angle | 16ga | 1-1/4" x 1-1/4" x 8\' | Galvanized';
const KEYPAD = 'Keypad | Genie';
const OPER = 'Operator | 2128 w/ two remotes | Genie';
const BHN = 'Back Hang Nut';

const results = [];
function report(id, title, ok, detail) { results.push({ id, title, ok, detail }); }

(async () => {
    // A. One checkout, the same part on two jobs.
    reset([['', ANGLE, 'A1', '40.00']]);
    let r = await checkout({ techName: 'Tech A', items: [{ name: ANGLE, qtyUsed: 3, jobNumber: '1001' }, { name: ANGLE, qtyUsed: 1, jobNumber: '1002' }] });
    report('A', 'Checkout: Punched Angle 3 (job 1001) + 1 (job 1002), Sheet 40', qty(ANGLE) === '36.00',
        `HTTP ${r.status}; log rows ${sheet.picked.length} (${sheet.picked.reduce((s, x) => s + Number(x[3]), 0)} units); writes ${sheet.writes.filter((w) => w.startsWith('Inventory!D')).join(', ')}; Sheet after ${qty(ANGLE)} (expected 36.00)`);

    // B. Three jobs, two shared parts (the 11/18 Andrew Johnson pattern).
    reset([['', KEYPAD, 'K1', '10.00'], ['', OPER, 'O1', '5.00']]);
    r = await checkout({ techName: 'Tech B', items: [
        { name: OPER, qtyUsed: 1, jobNumber: '1101400456' }, { name: KEYPAD, qtyUsed: 1, jobNumber: '1101400456' },
        { name: OPER, qtyUsed: 1, jobNumber: '1101629245' }, { name: KEYPAD, qtyUsed: 1, jobNumber: '1101629245' },
        { name: OPER, qtyUsed: 1, jobNumber: '1101304568' }, { name: KEYPAD, qtyUsed: 1, jobNumber: '1101304568' },
    ] });
    report('B', 'Checkout: Operator and Keypad, 1 each on three jobs, Sheet 5 and 10', qty(OPER) === '2.00' && qty(KEYPAD) === '7.00',
        `HTTP ${r.status}; log rows ${sheet.picked.length}; Operator after ${qty(OPER)} (expected 2.00), Keypad after ${qty(KEYPAD)} (expected 7.00)`);

    // C. Warehouse staging before 8:31, then the 8:31 flush.
    reset([['', ANGLE, 'A1', '40.00']]);
    at('2026-11-18T13:30:00Z');
    r = await checkout({ techName: 'warehouse1', items: [{ name: ANGLE, qtyUsed: 2, jobNumber: '2001' }, { name: ANGLE, qtyUsed: 2, jobNumber: '2002' }] });
    realTime();
    const staged = r.body && r.body.message;
    await crons.find((c) => c.spec === '31 8 * * *').fn();
    report('C', '8:31 flush: Punched Angle staged 2 (job 2001) + 2 (job 2002), Sheet 40', qty(ANGLE) === '36.00',
        `staging answer "${staged}"; log rows after flush ${sheet.picked.length}; Sheet after ${qty(ANGLE)} (expected 36.00)`);

    // D. A quantity of 1,000 or more.
    reset([['0110100', BHN, 'BP2', '1,250.00']]);
    r = await checkout({ techName: 'Tech A', items: [{ name: BHN, qtyUsed: 1, jobNumber: '3001' }] });
    report('D', 'Checkout: Back Hang Nut 1 from "1,250.00"', qty(BHN) === '1,249.00',
        `HTTP ${r.status}; writes ${sheet.writes.filter((w) => w.startsWith('Inventory!D')).join(', ')}; Sheet after ${qty(BHN)} (expected 1,249.00)`);

    console.log(`Backend: ${BACKEND}`);
    for (const x of results) console.log(`[${x.ok ? 'CORRECT' : 'WRONG  '}] ${x.id}. ${x.title}\n          ${x.detail}`);
    process.exit(0);
})().catch((e) => { realTime(); console.error(e); process.exit(1); });
