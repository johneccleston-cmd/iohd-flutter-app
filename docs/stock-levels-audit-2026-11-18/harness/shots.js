// node shots.js <prefix> <webDir-is-served-by-server.js>   (prefix: live | source)
'use strict';
const L = require('./lib');
const fs = require('fs');
const prefix = process.argv[2] || 'live';
const SIZES = [[1280, 600], [1366, 768], [1500, 800], [1920, 940]];
const NARROW = [[1000, 760], [420, 800]];
const metrics = { prefix, sizes: {}, states: {}, perf: {} };

async function measureOpen(b, w, h) {
    const t0 = Date.now();
    const p = await L.open(b, w, h);
    return { p, ms: Date.now() - t0 };
}
async function longTasks(p) { return p.evaluate(() => (window.__lt || []).map((e) => Math.round(e.d))); }
async function resetLT(p) { await p.evaluate(() => { window.__lt = []; }); }

(async () => {
    fs.mkdirSync(`${L.S}/shots`, { recursive: true });
    const b = await L.launch();

    // 1) target desktop sizes with the real Sheet snapshot
    for (const [w, h] of [...SIZES, ...NARROW]) {
        await L.ctl('mode=real&delayMs=0&resetCalls=1');
        const { p, ms } = await measureOpen(b, w, h);
        await L.shot(p, `${prefix}_${w}x${h}`);
        const docH = await p.evaluate(() => document.documentElement.scrollHeight);
        const calls = (await L.ctl('')).calls;
        metrics.sizes[`${w}x${h}`] = { openMs: ms, apiCalls: calls.map((c) => c.path), inventoryCalls: calls.filter((c) => c.path === '/get_full_inventory').length };
        await p.close();
    }

    // 2) states at 1366x768
    const W = 1366, H = 768;
    await L.ctl('mode=real&delayMs=14000');
    let p = await L.open(b, W, H, { semantics: false, waitNet: false, settleMs: 4500 });
    await L.shot(p, `${prefix}_state_loading_1366`);
    await L.sleep(6000);
    await L.shot(p, `${prefix}_state_loading_slow_1366`);
    await L.sleep(5000);
    await p.close();

    await L.ctl('mode=error&delayMs=0');
    p = await L.open(b, W, H);
    await L.shot(p, `${prefix}_state_error_1366`);
    await p.close();

    await L.ctl('mode=empty&delayMs=0');
    p = await L.open(b, W, H);
    await L.shot(p, `${prefix}_state_empty_1366`);
    await p.close();

    // stale: loaded fine, then a refresh fails
    await L.ctl('mode=real&delayMs=0');
    p = await L.open(b, W, H);
    await L.ctl('failNext=1');
    try {
        await L.clickNode(p, /^Refresh$/);
        await L.sleep(1500);
        await L.shot(p, `${prefix}_state_refresh_failed_1366`);
    } catch (e) { console.log('   refresh-failed state skipped:', e.message); }
    await p.close();

    // filter: Low
    await L.ctl('mode=real&delayMs=0');
    p = await L.open(b, W, H);
    try {
        await L.clickNode(p, /^Low( stock)?[ ,]+\d+$/);
        await L.sleep(800);
        await L.shot(p, `${prefix}_filter_low_1366`);
    } catch (e) { console.log('   low filter skipped:', e.message); }
    // search
    try {
        const box = (await L.nodes(p, /Search/i))[0];
        if (box) {
            await p.mouse.click(box.x, box.y);
            await L.sleep(400);
            await p.keyboard.type('stop mold 7', { delay: 60 });
            await L.sleep(1200);
            await L.shot(p, `${prefix}_search_1366`);
        }
    } catch (e) { console.log('   search skipped:', e.message); }
    await p.close();

    // narrow: filters / category control
    await L.ctl('mode=real&delayMs=0');
    p = await L.open(b, 1000, 760);
    try {
        await L.clickNode(p, /^(Filters|All categories)/);
        await L.sleep(800);
        await L.shot(p, `${prefix}_narrow_filters_1000`);
    } catch (e) { console.log('   narrow filters skipped:', e.message); }
    await p.close();

    // 3) responsiveness with 446 rows and a synthetic 5,000 rows: long tasks (>50 ms) while typing, filtering, sorting
    for (const mode of ['real', 'big']) {
        await L.ctl(`mode=${mode}&delayMs=0`);
        const t0 = Date.now();
        p = await L.open(b, W, H);
        const openMs = Date.now() - t0;
        const r = { openMs };
        await resetLT(p);
        const box = (await L.nodes(p, /Search/i))[0];
        if (box) {
            await p.mouse.click(box.x, box.y);
            const s0 = Date.now();
            await p.keyboard.type('weather seal black', { delay: 80 });
            await L.sleep(1200);
            r.typeMsWall = Date.now() - s0;
            r.typeLongTasks = await longTasks(p);
            await p.keyboard.down('Meta'); await p.keyboard.press('a'); await p.keyboard.up('Meta'); await p.keyboard.press('Backspace');
            await L.sleep(1200);
        }
        await resetLT(p);
        try { await L.clickNode(p, /^(Out( of stock)?[ ,]+\d+)$/); await L.sleep(1200); } catch (e) { r.filterErr = e.message; }
        r.filterLongTasks = await longTasks(p);
        await resetLT(p);
        try { await L.clickNode(p, /^(Part|Item)$/); await L.sleep(1200); } catch (e) { r.sortErr = e.message; }
        r.sortLongTasks = await longTasks(p);
        const heap = await p.metrics();
        r.jsHeapMB = Math.round(heap.JSHeapUsedSize / 1048576);
        if (mode === 'big') await L.shot(p, `${prefix}_big5000_1366`);
        metrics.perf[mode] = r;
        await p.close();
    }

    metrics.blocked = L.blocked;
    metrics.external = [...new Set(L.external)];
    fs.writeFileSync(`${L.S}/shots/${prefix}_metrics.json`, JSON.stringify(metrics, null, 2));
    console.log(JSON.stringify(metrics, null, 2));
    await b.close();
})().catch((e) => { console.error(e); process.exit(1); });
