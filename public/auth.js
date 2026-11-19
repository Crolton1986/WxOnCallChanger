'use strict';
/* Sign-in and one-time setup pages (network mode). */
const $ = (sel) => document.querySelector(sel);

const loginError = $('#login-error');
if (loginError) {
  const msg = new URLSearchParams(location.search).get('error');
  if (msg) { loginError.textContent = msg; loginError.hidden = false; }
}

const setupForm = $('#setup-form');
if (setupForm) {
  const err = $('#setup-error');
  const show = (m) => { err.textContent = m; err.hidden = false; };
  fetch('/api/setup').then(async (r) => {
    if (r.status === 404) { location.href = '/login'; return; }
    const s = await r.json();
    $('#redirect-uri').textContent = s.redirectUri;
    if (s.orgId) setupForm.orgId.value = s.orgId;
    if (s.locked) show('Too many wrong codes. Restart the app to get a new code.');
  });
  setupForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.hidden = true;
    const btn = setupForm.querySelector('button');
    btn.disabled = true;
    const body = Object.fromEntries(new FormData(setupForm).entries());
    try {
      const r = await fetch('/api/setup', {
        method: 'POST', headers: { 'X-OnCall': '1', 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(data.error || `Setup failed (HTTP ${r.status})`);
      location.href = '/login';
    } catch (ex) { show(ex.message); } finally { btn.disabled = false; }
  });
}
