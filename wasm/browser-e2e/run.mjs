// THE END-TO-END CHECK OF A `ui_qml` MODULE'S `web` VARIANT, in a browser.
//
// Everything else about the variant is checked without one: the artifact by the
// build's own gate (the image is wasm, every embind export survived, no QML
// engine came with the router), the package by tests/test-web-view-variant.nix,
// and the transport and the bridge on the desktop inside
// logos-view-module-runtime. What none of that can reach is the only question
// slice 27 actually asks — does a module's view RENDER and does the button
// drive the backend — because the answer needs two wasm images, a canvas, a
// MessagePort between them and a pointer event.
//
//     node wasm/browser-e2e/run.mjs <variant dir> <runtime www dir>
//
//     nix build .#checks.<system>.web-view-variant     # builds the variant
//     node wasm/browser-e2e/run.mjs \
//       /nix/store/…-logos-web_counter-web-view-1.0.0/web_counter_web \
//       /nix/store/…-logos-qml-runtime-wasm-1.0.0/www
//
// NOT A NIX CHECK, and it cannot become one: the nix sandbox has no browser and
// darwin nixpkgs has no chromium. Same boundary, same reason, as
// logos-view-module-runtime's own browser smoke.
//
// WHAT IT SERVES. The variant directory at `/` — so the page imports the
// SHIPPED `logos-view-loader.js` and fetches the SHIPPED QML — and the bundled
// runtime under `/logos-runtime/`, which is where the container will serve it.
// The harness page itself is the container: it stands in for the core behind
// `window.logosChannelReady` and answers one module, so a `logos.callModuleAsync`
// from the view is observed as a real logos-protocol frame LEAVING the page.
//
// AND IT COUNTS THE RUNTIME FETCHES. Slice 27's fourth criterion is "the same
// runtime serves a second module's QML without a second runtime download", and
// a download is a thing only the server can see. The page installs a second
// module's document; this counts the requests for the runtime image and refuses
// more than one.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { join, extname, normalize } from 'node:path';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
// --instrumented turns on the assertions that need the module's QML to report
// what it did (see e2e.html). Only tests/fixtures/web-view-counter does; every
// other variant gets the checks that hold for any of them.
const instrumented = args.includes('--instrumented');
const [variantDir, runtimeWww] = args.filter((a) => !a.startsWith('--'));
if (!variantDir || !runtimeWww) {
  console.error('usage: node run.mjs [--instrumented] <variant dir (…_web/)> <runtime www dir>');
  process.exit(2);
}
const here = fileURLToPath(new URL('.', import.meta.url));

// Chrome is not a dependency anything declares, so it is named rather than
// found: a venue without one should say so, not fail obscurely.
const CHROME = process.env.LOGOS_CHROME
  || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const TIMEOUT_MS = Number(process.env.LOGOS_E2E_TIMEOUT_MS || 180000);

const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
  '.qml': 'text/plain', '.svg': 'image/svg+xml', '.json': 'application/json',
};

let settle;
const verdict = new Promise((resolve) => { settle = resolve; });

const runtimeImageRequests = [];

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/result') {
    let body = '';
    for await (const chunk of req) body += chunk;
    res.writeHead(204).end();
    settle(body);
    return;
  }

  const name = normalize(url.pathname === '/' ? '/e2e.html' : url.pathname);

  // The bundled runtime, where the container will serve it: one directory for
  // the whole app, not part of any module's package.
  if (name.startsWith('/logos-runtime/')) {
    const file = name.slice('/logos-runtime/'.length);
    if (file.endsWith('.wasm')) runtimeImageRequests.push(file);
    try {
      const data = await readFile(join(runtimeWww, file));
      res.writeHead(200, { 'Content-Type': MIME[extname(file)] || 'application/octet-stream' })
         .end(data);
    } catch (e) { res.writeHead(404).end('not found'); }
    return;
  }

  // The harness page first, the variant second: the page is served from this
  // directory and everything it loads from the package. `normalize` keeps a
  // request for `/../something` inside the two directories on offer.
  for (const dir of [here, variantDir]) {
    try {
      const data = await readFile(join(dir, name));
      res.writeHead(200, { 'Content-Type': MIME[extname(name)] || 'application/octet-stream' })
         .end(data);
      return;
    } catch (e) { /* try the next directory */ }
  }
  res.writeHead(404).end('not found');
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const profile = mkdtempSync(join(tmpdir(), 'logos-web-view-e2e-'));

  // --enable-unsafe-swiftshader: Qt for WebAssembly needs WebGL2, and a
  // headless Chrome has no GPU. Everything else is noise suppression.
  const chrome = spawn(CHROME, [
    '--headless=new',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--enable-unsafe-swiftshader',
    '--use-gl=angle',
    '--use-angle=swiftshader',
    '--window-size=480,640',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    `--user-data-dir=${profile}`,
    `http://127.0.0.1:${port}/e2e.html${instrumented ? '?instrumented=1' : ''}`,
  ], { stdio: ['ignore', 'pipe', 'pipe'] });

  let chromeErr = '';
  chrome.stderr.on('data', (d) => { chromeErr += d; });
  chrome.on('error', (e) => settle(JSON.stringify({
    ok: false, error: `could not start ${CHROME}: ${e.message} (set LOGOS_CHROME)`,
  })));

  const timer = setTimeout(() => settle(JSON.stringify({
    ok: false,
    error: `the page did not report within ${TIMEOUT_MS} ms`,
    chromeErr: chromeErr.slice(-2000),
  })), TIMEOUT_MS);

  verdict.then((body) => {
    clearTimeout(timer);
    try { chrome.kill(); } catch (e) { /* already gone */ }
    server.close();

    let result;
    try { result = JSON.parse(body); }
    catch (e) { result = { ok: false, error: `unparseable verdict: ${body}` }; }

    const checks = result.checks || [];

    // The server's own assertion, which the page cannot make about itself.
    const onlyOneRuntime = runtimeImageRequests.length === 1;
    checks.push({
      name: 'the runtime image was fetched once for both modules',
      ok: onlyOneRuntime,
      detail: runtimeImageRequests.length + ' request(s): ' + runtimeImageRequests.join(', '),
    });

    for (const c of checks)
      console.log(`${c.ok ? 'PASS' : 'FAIL'}  ${c.name}${c.detail ? '  — ' + c.detail : ''}`);
    for (const line of result.logs || [])
      console.log(`      ${line.trimEnd()}`);
    if (result.error) console.log(`\n${result.error}`);
    const ok = checks.every((c) => c.ok) && !result.error;
    if (!ok && chromeErr) console.log(`\n--- chrome stderr ---\n${chromeErr.slice(-3000)}`);
    console.log(`\n${ok ? 'PASS' : 'FAIL'}: ui_qml web variant, end to end in a browser`
                + `${instrumented ? '' : ' (generic checks only; pass --instrumented for a variant whose QML reports)'}`);
    process.exit(ok ? 0 : 1);
  });
});
