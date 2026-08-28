const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');

const htmlPath = process.argv[2];
const outDir = process.argv[3] || require('os').tmpdir();
if (!htmlPath || !fs.existsSync(htmlPath)) {
  console.error('Usage: node run-browser-qa.js <generated-html> [output-dir]');
  process.exit(2);
}

const fileUrl = 'file:///' + htmlPath.replace(/\\/g, '/').replace(/^([A-Za-z]):/, '$1:');

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function waitForJson(url, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await new Promise((resolve, reject) => {
        http.get(url, r => {
          let data = '';
          r.on('data', c => data += c);
          r.on('end', () => resolve(data));
        }).on('error', reject);
      });
      return JSON.parse(res);
    } catch (e) {
      await sleep(100);
    }
  }
  throw new Error('Timed out waiting for ' + url);
}

class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); this.events = []; }
  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
    const c = new Cdp(ws);
    ws.onmessage = ev => {
      const msg = JSON.parse(ev.data);
      if (msg.id && c.pending.has(msg.id)) {
        const { resolve, reject } = c.pending.get(msg.id);
        c.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      } else if (msg.method) {
        c.events.push(msg);
      }
    };
    return c;
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

async function evaluate(cdp, expression) {
  const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (res.exceptionDetails) throw new Error('Evaluation failed: ' + JSON.stringify(res.exceptionDetails));
  return res.result.value;
}

async function main() {
  const port = await getFreePort();
  const profileDir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'diskpulse-browser-'));
  const chromeCandidates = [
    process.env.CHROME_PATH,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser'
  ].filter(Boolean);
  const chromePath = chromeCandidates.find(p => fs.existsSync(p));
  if (!chromePath) {
    console.error('No Chrome/Edge binary found. Set CHROME_PATH.');
    process.exit(3);
  }

  const chrome = spawn(chromePath, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-sync', '--metrics-recording-only',
    '--user-data-dir=' + profileDir, '--remote-debugging-port=' + port, 'about:blank'
  ], { stdio: ['ignore', 'ignore', 'pipe'] });

  let chromeErr = '';
  chrome.stderr.on('data', d => chromeErr += d.toString());

  let cdp;
  try {
    const version = await waitForJson(`http://127.0.0.1:${port}/json/version`);
    const targets = await waitForJson(`http://127.0.0.1:${port}/json/list`);
    const page = targets.find(t => t.type === 'page');
    if (!page) throw new Error('No page target');
    cdp = await Cdp.connect(page.webSocketDebuggerUrl);

    const runtimeErrors = [];
    cdp.events = [];
    cdp.ws.onmessage = ev => {
      const msg = JSON.parse(ev.data);
      if (msg.id && cdp.pending.has(msg.id)) {
        const { resolve, reject } = cdp.pending.get(msg.id);
        cdp.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      } else if (msg.method === 'Runtime.exceptionThrown') {
        runtimeErrors.push(msg.params.exceptionDetails.text || 'exception');
      } else if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
        runtimeErrors.push('console.error: ' + (msg.params.args || []).map(a => a.value || a.description || '').join(' '));
      } else if (msg.method) {
        cdp.events.push(msg);
      }
    };

    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Log.enable');

    await cdp.send('Page.navigate', { url: fileUrl });
    await sleep(1500);

    const results = {};

    results.loaded = await evaluate(cdp, `!!document.querySelector('main') && document.readyState === 'complete'`);
    results.hasOverview = await evaluate(cdp, `!!document.querySelector('.overview, #attention-center, #capacity, #scan-meta')`);
    results.hasData = await evaluate(cdp, `typeof RAW_DATA !== 'undefined' && RAW_DATA.length > 0`);
    results.noHorizontalOverflowDesktop = await evaluate(cdp, `document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1`);
    results.focusableControls = await evaluate(cdp, `Array.from(document.querySelectorAll('button, a, input, select')).filter(el => !el.disabled && el.tabIndex !== -1).length`);
    results.missingAccessibleNames = await evaluate(cdp, `Array.from(document.querySelectorAll('button, input, select')).filter(el => !el.getAttribute('aria-label') && !el.getAttribute('title') && !(el.labels && el.labels.length) && !el.textContent.trim()).length`);

    fs.mkdirSync(outDir, { recursive: true });
    const shotLight = await cdp.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(outDir, 'browser-desktop-light.png'), Buffer.from(shotLight.data, 'base64'));

    const beforeTheme = await evaluate(cdp, `document.documentElement.getAttribute('data-theme') || 'light'`);
    await evaluate(cdp, `document.getElementById('themeBtn').click()`);
    const afterTheme = await evaluate(cdp, `document.documentElement.getAttribute('data-theme')`);
    const storedTheme = await evaluate(cdp, `localStorage.getItem('diskpulse-theme')`);
    results.themeToggle = beforeTheme !== afterTheme && storedTheme === afterTheme;
    const shotDark = await cdp.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(outDir, 'browser-desktop-dark.png'), Buffer.from(shotDark.data, 'base64'));

    await evaluate(cdp, `document.getElementById('compact').click()`);
    results.compactToggle = await evaluate(cdp, `document.body.classList.contains('compact') || document.documentElement.classList.contains('compact') || document.querySelector('.shell').classList.contains('compact')`);

    // Mobile viewport
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
    await sleep(300);
    results.noHorizontalOverflowMobile = await evaluate(cdp, `document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1`);

    // Screenshots
    fs.mkdirSync(outDir, { recursive: true });
    const shotMobile = await cdp.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(outDir, 'browser-mobile-dark.png'), Buffer.from(shotMobile.data, 'base64'));

    results.runtimeErrors = runtimeErrors;
    const failures = [];
    for (const key of ['loaded', 'hasOverview', 'hasData', 'noHorizontalOverflowDesktop', 'noHorizontalOverflowMobile', 'themeToggle']) {
      if (!results[key]) failures.push(key);
    }
    if (results.runtimeErrors.length) failures.push('runtimeErrors');
    if (results.focusableControls < 1) failures.push('focusableControls');
    if (results.missingAccessibleNames > 0) failures.push('missingAccessibleNames:' + results.missingAccessibleNames);

    console.log(JSON.stringify({ results, failures, chromePath, fileUrl }, null, 2));
    if (failures.length) process.exitCode = 1;
  } finally {
    if (cdp) cdp.close();
    chrome.kill();
    await sleep(300);
    try { fs.rmSync(profileDir, { recursive: true, force: true }); } catch (_) {}
  }
}

main().catch(err => { console.error(err); process.exit(1); });
