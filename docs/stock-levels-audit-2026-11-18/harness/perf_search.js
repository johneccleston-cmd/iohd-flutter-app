// node perf_search.js <prefix> <placeholder regex>: types into the PAGE search box (not the nav's global search),
// records long tasks and the time until the filtered list settles, for 446 real rows and 5,000 synthetic rows.
'use strict';
const L = require('./lib');
const fs = require('fs');
const [prefix, ph] = process.argv.slice(2);
const re = new RegExp(ph, 'i');
(async () => {
    const out = {};
    const b = await L.launch();
    for (const mode of ['real', 'big']) {
        await L.ctl(`mode=${mode}&delayMs=0`);
        const p = await L.open(b, 1366, 768);
        const boxes = await L.nodes(p, re);
        if (!boxes.length) { out[mode] = { error: 'page search box not found' }; await p.close(); continue; }
        const box = boxes[0];
        await p.mouse.click(box.x, box.y);
        await L.sleep(500);
        await p.evaluate(() => { window.__lt = []; });
        const t0 = Date.now();
        await p.keyboard.type("stop mold 7' white", { delay: 90 });
        const typed = Date.now() - t0;
        await L.sleep(1500);
        const lt = await p.evaluate(() => (window.__lt || []).map((e) => Math.round(e.d)));
        out[mode] = { chars: 18, typingWallMs: typed, longTasksMs: lt, longTaskTotalMs: lt.reduce((a, c) => a + c, 0), worstMs: Math.max(0, ...lt) };
        if (mode === 'real') await L.shot(p, `${prefix}_search_stopmold_1366`);
        await p.close();
    }
    fs.writeFileSync(`${L.S}/shots/${prefix}_search_perf.json`, JSON.stringify(out, null, 2));
    console.log(prefix, JSON.stringify(out));
    await b.close();
})().catch((e) => { console.error(e); process.exit(1); });
