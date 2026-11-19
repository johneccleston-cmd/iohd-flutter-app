// Serves a COPY of the deployed office web build (integrity-backend/src/public, API URL rewritten to /__api) and a mock
// API, so the real Stock Levels screen can be rendered with a snapshot of the real Sheet without touching production.
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const S = '/private/tmp/claude-501/-Users-johneccleston/e0fe426c-cf68-4768-a8a4-e98e686cade3/scratchpad';
const WEB = path.join(S, process.env.WEB_DIR || 'web');
const REAL = JSON.parse(fs.readFileSync(path.join(S, 'harness', 'stock_rows.json'), 'utf8'));
const state = { mode: 'real', delayMs: 0, failNext: false, calls: [] };

function big(n) {
    const out = [];
    for (let i = 0; i < n; i++) {
        const b = REAL[i % REAL.length];
        out.push({ ...b, name: `${b.name} #${Math.floor(i / REAL.length) + 1}` });
    }
    return out;
}

const SEED = `<script>(function(){try{
var exp=Date.now()+7*864e5;
var p=btoa(JSON.stringify({id:1,name:'Audit Viewer',role:'Admin',exp:exp})).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
var s={token:p+'.audit',name:'Audit Viewer',role:'Admin',is_admin:true,denied:[],badges:[]};
localStorage.setItem('flutter.iohd_auth_session',JSON.stringify(JSON.stringify(s)));
window.__lt=[];try{new PerformanceObserver(function(l){l.getEntries().forEach(function(e){window.__lt.push({t:e.startTime,d:e.duration});});}).observe({type:'longtask',buffered:true});}catch(e){}
}catch(e){}})();</script>`;

const types = { '.js': 'text/javascript', '.html': 'text/html', '.json': 'application/json', '.png': 'image/png', '.wasm': 'application/wasm',
    '.css': 'text/css', '.otf': 'font/otf', '.ttf': 'font/ttf', '.ico': 'image/x-icon', '.frag': 'application/octet-stream', '.bin': 'application/octet-stream' };

function api(req, res, p) {
    state.calls.push({ at: Date.now(), method: req.method, path: p });
    const send = (code, body) => {
        res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' });
        res.end(JSON.stringify(body));
    };
    if (req.method === 'OPTIONS') return send(204, {});
    if (p === '/get_full_inventory') {
        const go = () => {
            if (state.failNext || state.mode === 'error') { state.failNext = false; return send(500, { error: 'Sheets API error (mock)' }); }
            if (state.mode === 'empty') return send(200, []);
            if (state.mode === 'big') return send(200, big(5000));
            return send(200, REAL);
        };
        return state.delayMs ? setTimeout(go, state.delayMs) : go();
    }
    // Everything else the shell asks for at start-up: empty, so the shell renders without data.
    return send(200, req.method === 'GET' && /dashboard|summary|status|me$|profile/.test(p) ? {} : []);
}

http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    if (u.pathname.startsWith('/__ctl')) {
        for (const [k, v] of u.searchParams) state[k] = k === 'delayMs' ? Number(v) : k === 'failNext' ? v === '1' : v;
        if (u.searchParams.has('resetCalls')) state.calls = [];
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ mode: state.mode, delayMs: state.delayMs, calls: state.calls }));
    }
    if (u.pathname.startsWith('/__api')) return api(req, res, u.pathname.slice('/__api'.length));
    let file = path.join(WEB, decodeURIComponent(u.pathname));
    if (!file.startsWith(WEB)) { res.writeHead(403); return res.end(); }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) { res.writeHead(404); return res.end(); }
    let body = fs.readFileSync(file);
    if (file.endsWith('index.html')) body = Buffer.from(body.toString().replace('<base href="/">', `<base href="/">${SEED}`));
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(body);
}).listen(8765, '127.0.0.1', () => console.log('harness server on http://127.0.0.1:8765'));
