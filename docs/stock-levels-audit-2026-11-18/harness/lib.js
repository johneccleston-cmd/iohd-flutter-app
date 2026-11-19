'use strict';
const puppeteer = require('puppeteer-core');
const S = '/private/tmp/claude-501/-Users-johneccleston/e0fe426c-cf68-4768-a8a4-e98e686cade3/scratchpad';
const ORIGIN = 'http://127.0.0.1:8765';
const ALLOWED = [/^http:\/\/127\.0\.0\.1:8765\//, /^https:\/\/www\.gstatic\.com\//, /^https:\/\/fonts\.gstatic\.com\//, /^https:\/\/fonts\.googleapis\.com\//, /^data:/, /^blob:/];

const blocked = [];
const external = [];
async function launch() {
    return puppeteer.launch({
        executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        headless: true,
        args: ['--no-first-run', '--no-default-browser-check', '--disable-extensions', '--hide-scrollbars', '--force-color-profile=srgb'],
    });
}
async function open(browser, w, h, { semantics = true, hash = '/inventory', waitNet = true, settleMs = 2500 } = {}) {
    const page = await browser.newPage();
    await page.setViewport({ width: w, height: h, deviceScaleFactor: 1 });
    await page.setRequestInterception(true);
    page.on('request', (r) => {
        const u = r.url();
        if (ALLOWED.some((re) => re.test(u))) {
            if (!u.startsWith(ORIGIN)) external.push(u.split('?')[0]);
            return r.continue();
        }
        blocked.push(u);
        return r.abort();
    });
    page.on('pageerror', (e) => console.log('   pageerror:', String(e).slice(0, 160)));
    await page.goto(`${ORIGIN}/#${hash}`, { waitUntil: waitNet ? 'networkidle0' : 'domcontentloaded', timeout: 90000 });
    await page.waitForSelector('flt-glass-pane, flutter-view', { timeout: 60000 });
    await sleep(settleMs);
    if (semantics) await enableSemantics(page);
    return page;
}
async function enableSemantics(page) {
    await page.evaluate(() => {
        const p = document.querySelector('flt-semantics-placeholder');
        if (p) p.click();
    });
    await sleep(900);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function ctl(q) {
    const r = await fetch(`${ORIGIN}/__ctl?${q}`);
    return r.json();
}
/** Semantics nodes whose label/text matches re: [{label, x, y, w, h}] (centre coordinates). */
async function nodes(page, re) {
    const src = re.source, flags = re.flags;
    return page.evaluate((src, flags) => {
        const re = new RegExp(src, flags);
        const out = [];
        for (const el of document.querySelectorAll('flt-semantics, [role], input, textarea')) {
            const label = (el.getAttribute('aria-label') || el.getAttribute('placeholder') || '') + ' ' + (el.childElementCount === 0 ? el.textContent : '');
            if (!re.test(label.trim())) continue;
            const b = el.getBoundingClientRect();
            if (b.width === 0 || b.height === 0) continue;
            out.push({ label: label.trim().slice(0, 120), x: b.x + b.width / 2, y: b.y + b.height / 2, w: b.width, h: b.height, role: el.getAttribute('role') || '' });
        }
        return out;
    }, src, flags);
}
async function clickNode(page, re, idx = 0) {
    const n = (await nodes(page, re))[idx];
    if (!n) throw new Error(`no node ${re}`);
    await page.mouse.click(n.x, n.y);
    await sleep(900);
    return n;
}
async function shot(page, name) {
    const file = `${S}/shots/${name}.png`;
    await page.screenshot({ path: file });
    console.log('   saved', name);
    return file;
}
module.exports = { launch, open, ctl, nodes, clickNode, shot, sleep, blocked, external, S, enableSemantics };
