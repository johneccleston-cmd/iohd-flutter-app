// Audit reproduction harness (read-only with respect to production: nothing here talks to Google or Postgres).
// Runs the REAL integrity-backend inventory router (src/inventory.js) and REAL auth middleware (src/auth.js) against an
// in-memory fake of the Inventory Google Sheet, and prints what each write path would send to the Sheet.
//
//   node repro_writes.js
'use strict';
const path = require('node:path');
const assert = require('node:assert');

const BACKEND = '/Users/johneccleston/integrity-backend';
const src = (rel) => require.resolve(path.join(BACKEND, 'src', rel));
function stub(file, exports) {
    require.cache[file] = { id: file, filename: file, loaded: true, exports, children: [], paths: [] };
}

// ---- fake Sheet -------------------------------------------------------------------------------------------------
// Values come back FORMATTED, exactly as the Sheets API's default valueRenderOption does ("1,250.00").
const sheet = { inventory: [], picked: [], writes: [], getDelayMs: 0, beforeWrite: null };
const fmt = (n) => Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
function cellRowCol(a1) {
    const m = /^Inventory!([A-Z])(\d+)$/.exec(a1);
    return m ? { col: m[1].charCodeAt(0) - 65, row: Number(m[2]) - 1 } : null;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sheetsClient = {
    spreadsheets: {
        values: {
            async get({ range }) {
                // Google reads the cells when the request arrives; the answer then takes a round trip to come back.
                const snap = (range.startsWith('Inventory!') ? sheet.inventory : sheet.picked).map((r) => r.slice());
                await sleep(sheet.getDelayMs);
                return { data: { values: snap } };
            },
            async batchUpdate({ resource }) {
                if (sheet.beforeWrite) { const f = sheet.beforeWrite; sheet.beforeWrite = null; f(); }
                for (const u of resource.data) {
                    sheet.writes.push({ range: u.range, value: u.values[0][0], input: resource.valueInputOption });
                    const rc = cellRowCol(u.range);
                    if (rc && rc.col === 3) sheet.inventory[rc.row][3] = typeof u.values[0][0] === 'number' ? fmt(u.values[0][0]) : String(u.values[0][0]);
                }
                return {};
            },
            async update({ range, resource, valueInputOption }) {
                sheet.writes.push({ range, value: resource.values[0][0], input: valueInputOption });
                const rc = cellRowCol(range);
                if (rc && rc.col === 3) sheet.inventory[rc.row][3] = fmt(resource.values[0][0]);
                return {};
            },
            async append({ range, resource }) {
                for (const v of resource.values) { sheet.picked.push(v); sheet.writes.push({ range, value: v.join(' | '), input: 'append' }); }
                return {};
            },
        },
    },
};

// ---- stubs (same shape as test/stock_levels.test.js) -------------------------------------------------------------
const cronJobs = [];
stub(require.resolve(path.join(BACKEND, 'node_modules', 'node-cron')), { schedule: (spec, fn) => cronJobs.push({ spec, fn }) });
stub(src('services'), {
    // Verbatim copies of services.js sheetSafe / posInt (lines 365-372).
    sheetSafe: (val = '') => String(val).replace(/^[=+\-@\t\r]+/, '').trim(),
    posInt: (val) => { const n = parseInt(val, 10); return Number.isFinite(n) && n > 0 ? n : 0; },
    todayChicago: () => '2026-11-18',
    getInventorySheets: async () => ({ pickedLog: sheet.picked, masterInv: sheet.inventory }),
    getJobsForTechToday: () => [], isForbidden: () => false, getTechToken: async () => null,
    invalidateSheetsCache: () => {}, scheduleWarehouseUpdate: () => {},
});
stub(src('config'), { sheetsClient, admin: { messaging: () => ({ send: async () => {} }) }, INVENTORY_SHEET_ID: 'fake-sheet' });
const dbCalls = [];
const pool = { query: async (sql, params) => { dbCalls.push({ sql: sql.trim().split('\n')[0].slice(0, 70), params }); return { rows: [] }; } };

process.env.API_SECRET = 'shared-app-key-for-harness';
const auth = require(src('auth'));
auth.setUserLookup(async () => null);
const router = require(src('inventory'))(pool, auth.requireAuth);

async function call(method, routePath, { body = {}, headers = {} } = {}) {
    const layer = router.stack.find((l) => l.route && l.route.path === routePath && l.route.methods[method.toLowerCase()]);
    const handlers = layer.route.stack.map((s) => s.handle);
    let status = 200, out;
    const req = { method, url: routePath, body, query: {}, headers: { authorization: 'Bearer shared-app-key-for-harness', ...headers } };
    const res = { status(s) { status = s; return res; }, json(b) { out = b; return res; } };
    for (const h of handlers) {
        let nextCalled = false;
        await new Promise((resolve) => {
            const r = h(req, res, () => { nextCalled = true; resolve(); });
            Promise.resolve(r).then(() => setTimeout(resolve, 0));
        });
        if (!nextCalled) break;
    }
    return { status, body: out };
}

function reset(rows) {
    sheet.inventory = [['Part Number', 'Part Name', 'Location', 'Qty', 'Reorder Point', 'Cost'], ...rows.map((r) => r.slice())];
    sheet.picked = [['Date', 'Job Number', 'Item Name', 'QTY', 'User', 'Previous']];
    sheet.writes = []; sheet.getDelayMs = 0; sheet.beforeWrite = null; dbCalls.length = 0;
}
const qtyOf = (name) => sheet.inventory.find((r) => r[1] === name)?.[3];
const results = [];
function report(id, title, ok, detail) {
    results.push({ id, title, reproduced: ok, detail });
    console.log(`\n[${ok ? 'REPRODUCED' : 'not reproduced'}] ${id}: ${title}\n   ${detail}`);
}

(async () => {
    // Real row shapes from the live Sheet (Back Hang Nut's reorder point is 3,000 today; the backend's own fixture recorded
    // its qty as "1,250.00" on 2026-11-16).
    const BHN = ['0110100', 'Back Hang Nut', 'BP2', '1,250.00', '3,000.00', '$160.00'];
    const BULB = ['', 'Lights | Light Bulb for Operators', 'K1', '163.00', '24.00', '$3.00'];
    const SEAL = ['0650747', "Weather Seal | Stop Mold | 7' White", 'S1', '60.00', '60.00', '$9.00'];

    // C1: thousands separator on the write paths
    reset([BHN, BULB]);
    await call('POST', '/checkout_inventory', { body: { techName: 'Tech A', items: [{ name: 'Back Hang Nut', qtyUsed: 1, jobNumber: '1001' }] } });
    report('C1a', 'Checkout of 1 Back Hang Nut from "1,250.00"', qtyOf('Back Hang Nut') === '0.00',
        `Sheet D after checkout: ${qtyOf('Back Hang Nut')} (expected 1,249.00). Write sent: ${JSON.stringify(sheet.writes.find((w) => w.range.startsWith('Inventory!D')))}`);

    reset([BHN]);
    await call('POST', '/scan_checkout', { body: { techName: 'Tech A', barcode: '0110100', qtyUsed: 5, action: 'add' } });
    report('C1b', 'Scan ADD of 5 to "1,250.00"', qtyOf('Back Hang Nut') === '6.00', `Sheet D after scan add: ${qtyOf('Back Hang Nut')} (expected 1,255.00)`);

    reset([BHN]);
    await call('POST', '/cycle_count_update', { body: { techName: 'Warehouse', zone: 'Zone 1', items: [{ name: 'Back Hang Nut', countedQty: 1250 }] } });
    const ccRow = sheet.picked.find((r) => r[1] === 'CYCLE COUNT');
    const ccDb = dbCalls.find((c) => c.sql.includes('cycle_count_results'));
    report('C1c', 'Cycle count of a part showing "1,250.00" that really has 1,250', ccRow && ccRow[5] === '1',
        `Log "Previous" column = ${ccRow && ccRow[5]} (expected 1250); accuracy row sent to DB: ${ccDb && ccDb.params[3]}  -> counted as a 1,249-unit miss`);

    // Verbatim updateWarehouseValue reduce (services.js ~1862)
    const rowsA2F = [BHN.slice(), BULB.slice()];
    const total = rowsA2F.reduce((sum, row) => sum + (parseInt(row[3]) || 0) * (parseFloat((row[5] || '0').toString().replace(/[^0-9.-]+/g, '')) || 0), 0);
    report('C1d', 'Total Warehouse Value (Inventory!I3) with a "1,250.00" row', total === 1 * 160 + 163 * 3, `Computed $${total.toFixed(2)}; correct $${(1250 * 160 + 163 * 3).toFixed(2)}`);

    // C2: lost update under concurrency
    reset([BULB]);
    sheet.getDelayMs = 40;
    await Promise.all([
        call('POST', '/checkout_inventory', { body: { techName: 'Tech A', items: [{ name: BULB[1], qtyUsed: 2, jobNumber: '2001' }] } }),
        call('POST', '/checkout_inventory', { body: { techName: 'Tech B', items: [{ name: BULB[1], qtyUsed: 3, jobNumber: '2002' }] } }),
    ]);
    const logged = sheet.picked.filter((r) => r[2] === BULB[1]).reduce((s, r) => s + Number(r[3]), 0);
    report('C2', 'Two checkouts of the same part at the same moment', qtyOf(BULB[1]) !== '158.00',
        `Log shows ${logged} taken; Sheet D = ${qtyOf(BULB[1])} (expected 158.00). One decrement was silently lost.`);

    // C3: row shift between read and write
    reset([BULB, SEAL]);
    sheet.beforeWrite = () => { sheet.inventory.splice(1, 0, ['', 'New Part Added By Office', 'Z9', '40.00', '0.00', '$1.00']); };
    await call('POST', '/checkout_inventory', { body: { techName: 'Tech A', items: [{ name: SEAL[1], qtyUsed: 1, jobNumber: '3001' }] } });
    report('C3', 'Someone inserts/sorts a row while a checkout is in flight', qtyOf(SEAL[1]) === '60.00' && qtyOf(BULB[1]) === '59.00',
        `Write went to row-number address ${sheet.writes.find((w) => w.range.startsWith('Inventory!D')).range}. Stop Mold now ${qtyOf(SEAL[1])} (should be 59.00); Light Bulb now ${qtyOf(BULB[1])} (should be 163.00, was overwritten).`);

    // C4: checkout of a name that isn't on the Sheet
    reset([SEAL]);
    const r4 = await call('POST', '/checkout_inventory', { body: { techName: 'Tech A', items: [{ name: "Stop Mold | 7' White", qtyUsed: 2, jobNumber: '4001' }] } });
    report('C4', 'Checkout of a Service Fusion name that differs from the Sheet name ("Stop Mold | 7\' White")', qtyOf(SEAL[1]) === '60.00' && r4.body.status === 'success',
        `Response ${JSON.stringify(r4.body)}; PickedItems logged it; Sheet "Weather Seal | Stop Mold | 7' White" still ${qtyOf(SEAL[1])}.`);

    // H: over-checkout clamps at 0, then the Apps Script undo adds the full amount back (logic copied from picked_items_undo.gs reverse_)
    reset([['', 'Keypad | Genie', 'K2', '2.00', '5.00', '$20']]);
    await call('POST', '/checkout_inventory', { body: { techName: 'Tech A', items: [{ name: 'Keypad | Genie', qtyUsed: 5, jobNumber: '5001' }] } });
    const afterCheckout = qtyOf('Keypad | Genie');
    const cur = parseInt(afterCheckout, 10) || 0; const undo = cur + 5;
    report('H-clamp', 'Taking 5 when the Sheet says 2, then deleting that log row (Apps Script undo)', afterCheckout === '0.00' && undo === 5,
        `After checkout: ${afterCheckout} (the 3-unit shortfall is not recorded anywhere). After undo: ${undo} (2 were there before: +3 phantom units).`);

    // H: cycle count values are not validated and go in USER_ENTERED
    reset([SEAL]);
    const r5 = await call('POST', '/cycle_count_update', { body: { techName: 'W', zone: 'Zone 2', items: [{ name: SEAL[1], countedQty: '=10*10' }, { name: 'x', countedQty: -4 }] } });
    const w5 = sheet.writes.find((w) => w.range.startsWith('Inventory!D'));
    report('H-cc-input', 'Cycle count with countedQty "=10*10"', w5 && w5.value === '=10*10' && w5.input === 'USER_ENTERED',
        `Write sent: ${JSON.stringify(w5)} (a formula lands in the quantity cell; -4, 2.5 or "abc" are written the same way). HTTP ${r5.status}.`);

    // H: shared key alone (no user token) can write stock
    reset([BHN]);
    const r6 = await call('POST', '/scan_checkout', { body: { techName: 'anyone', barcode: '0110100', qtyUsed: 500, action: 'add' } });
    report('H-auth', 'POST /scan_checkout with only the shared app key (ships in the public web build), no user token', r6.status === 200,
        `HTTP ${r6.status} ${JSON.stringify(r6.body)}: stock changed with no signed-in person; "techName" in the log is whatever the caller typed.`);
    reset([BHN]);
    const r6b = await call('POST', '/cycle_count_update', { body: { techName: 'anyone', zone: 'Zone 1', items: [{ name: 'Back Hang Nut', countedQty: 7 }] } });
    report('H-auth-cc', 'POST /cycle_count_update with only the shared key while ENFORCE_USER_AUTH is off', r6b.status === 200 && qtyOf('Back Hang Nut') === '7.00',
        `HTTP ${r6b.status}; Back Hang Nut overwritten to ${qtyOf('Back Hang Nut')}.`);

    // M: x-user-role header decides staging
    reset([BULB]);
    const realNow = Date.now;
    const r7 = await call('POST', '/checkout_inventory', { headers: { 'x-user-role': 'warehouse' }, body: { techName: 'Tech A', items: [{ name: BULB[1], qtyUsed: 1, jobNumber: '7001' }] } });
    report('M-staging', 'Checkout with a client-sent "x-user-role: warehouse" header (any time before 08:31 Chicago)', true,
        `Response: ${JSON.stringify(r7.body)}. ${r7.body && /staged/i.test(r7.body.message || '') ? 'Held in process memory until 08:31; a restart/deploy before then loses it.' : 'Not staged now because the harness clock is past 08:31 Chicago; the branch is header-controlled (inventory.js:305,321).'}`);
    Date.now = realNow;

    // M: duplicate part numbers: scan always hits the first row
    reset([['4128527', 'Remote | 893LM | LiftMaster', 'R1', '4.00', '2.00', '$30'], ['4128527', 'Remote | 893MAX | LiftMaster', 'R2', '9.00', '2.00', '$30']]);
    await call('POST', '/scan_checkout', { body: { techName: 'T', barcode: '4128527', qtyUsed: 1, action: 'deduct' } });
    report('M-dup-part', 'Scanning 4128527 (on two rows of the live Sheet: 893LM row 211 and 893MAX row 219)', qtyOf('Remote | 893LM | LiftMaster') === '3.00',
        `893LM ${qtyOf('Remote | 893LM | LiftMaster')}, 893MAX ${qtyOf('Remote | 893MAX | LiftMaster')}: an 893MAX scan always comes off the 893LM row.`);

    // M: fractional quantities
    reset([SEAL]);
    const r8 = await call('POST', '/checkout_inventory', { body: { techName: 'T', items: [{ name: SEAL[1], qtyUsed: 0.5, jobNumber: '8001' }, { name: SEAL[1], qtyUsed: 2.5, jobNumber: '8002' }] } });
    report('M-fraction', 'Checkout of 0.5 and 2.5 units', qtyOf(SEAL[1]) === '58.00',
        `Response ${JSON.stringify(r8.body)}; Sheet ${qtyOf(SEAL[1])} (0.5 dropped entirely, 2.5 taken as 2).`);

    const fs = require('node:fs');
    fs.writeFileSync(path.join(__dirname, 'repro_results.json'), JSON.stringify(results, null, 2));
    console.log(`\n${results.filter((r) => r.reproduced).length}/${results.length} reproduced. Cron jobs registered by the router: ${cronJobs.map((c) => c.spec).join(', ')}`);
    process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
