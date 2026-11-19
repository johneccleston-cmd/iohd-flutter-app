// node sheet.js <out> <width-per-image> <shot names...>: contact sheet of screenshots for review
const L = require('./lib'); const fs = require('fs');
(async () => {
    const [out, wpx, ...files] = process.argv.slice(2);
    const b = await L.launch(); const p = await b.newPage();
    await p.setViewport({ width: 1400, height: 100, deviceScaleFactor: 1 });
    const imgs = files.map((f) => `<figure style="margin:6px;display:inline-block;vertical-align:top"><figcaption style="font:12px sans-serif">${f}</figcaption><img style="width:${wpx}px;border:1px solid #999" src="data:image/png;base64,${fs.readFileSync(`${L.S}/shots/${f}.png`).toString('base64')}"></figure>`).join('');
    await p.setContent(`<body style="margin:0;background:#fff">${imgs}</body>`); await L.sleep(500);
    await p.screenshot({ path: `${L.S}/shots/${out}.png`, fullPage: true }); await b.close();
})();
