'use strict';

/* ---------- helpers ---------- */
const $ = (sel, root = document) => root.querySelector(sel);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

async function api(method, path, body) {
  const opt = { method, headers: {} };
  if (method !== 'GET') {
    opt.headers['X-OnCall'] = '1';
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body ?? {});
  }
  const res = await fetch(path, opt);
  if (res.status === 401) { location.href = '/login'; throw new Error('Signed out'); }
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  if (!res.ok) throw new Error(data?.error || `Request failed (HTTP ${res.status})`);
  return data;
}

let toastTimer;
function toast(msg, bad = false) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = bad ? 'bad' : '';
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, bad ? 7000 : 3000);
}

const pad = (n) => String(n).padStart(2, '0');
/* Local wall-clock string the server expects: yyyy-MM-ddTHH:mm */
const toWall = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;

function fmtPhone(digits) {
  const d = String(digits ?? '');
  if (d.length === 11 && d[0] === '1') return `(${d.slice(1, 4)}) ${d.slice(4, 7)}-${d.slice(7)}`;
  if (d.length === 10) return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`;
  return d || 'Not set';
}
const whenFmt = new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
const fmtWhen = (v) => (v ? whenFmt.format(new Date(v)) : '');
const timeFmt = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' });

function ago(iso) {
  if (!iso) return null;
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins === 1) return '1 minute ago';
  if (mins < 60) return `${mins} minutes ago`;
  return fmtWhen(iso);
}

/* ---------- state ---------- */
const state = { status: null, people: [], rotations: [], calendar: null, hidden: new Set() };
const personName = (id) => state.people.find((p) => p.Id === id)?.Name ?? 'Unknown person';
const teams = () => state.status?.teams ?? [];
const teamOf = (key) => teams().find((t) => t.key === key);
/* Team color class. Always a number 0-7, so it's safe inside innerHTML templates. */
const colorClass = (c) => `tc-${(Number(c) || 0) & 7}`;
const tc = (key) => { const t = teamOf(key); return t ? colorClass(t.color) : ''; };
const onTeam = (p, key) => (p.Teams ?? []).includes(key);
const peopleOn = (key) => state.people.filter((p) => onTeam(p, key));

async function loadPeople() { state.people = (await api('GET', '/api/people')).items.sort((a, b) => a.Name.localeCompare(b.Name)); }
async function loadRotations() { state.rotations = (await api('GET', '/api/rotations')).items; }
async function loadStatus() { state.status = await api('GET', '/api/status'); }

/* ---------- routing ---------- */
const views = {
  now: () => renderNow(),
  calendar: () => renderCalendarView(),
  people: () => renderPeople(),
  teams: () => renderTeams(),
  history: () => renderHistory(),
  settings: () => renderSettings(),
};

async function route() {
  const tab = (location.hash || '#now').slice(1);
  const name = views[tab] ? tab : 'now';
  document.querySelectorAll('.view').forEach((v) => { v.hidden = v.id !== `view-${name}`; });
  document.querySelectorAll('.tabs a').forEach((a) => {
    if (a.dataset.tab === name) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
  try { await views[name](); } catch (e) { toast(e.message, true); }
}

/* ---------- Now ---------- */
function statusLine(t, globalOn) {
  const p = esc(t.person);
  switch (t.action) {
    case 'InSync':
      return { cls: 'ok', text: 'Webex matches the schedule' };
    case 'Change':
      return { cls: 'pending', text: `Switching to ${p} at the next check`, sub: 'Or use Check now to switch right away.' };
    case 'Disabled': {
      const where = t.currentPerson ? esc(t.currentPerson) : fmtPhone(t.current);
      const why = globalOn ? 'Switching is off for this team.' : 'Automatic switching is off.';
      return { cls: 'off', text: `Webex stays on ${where}`, sub: `${why} The schedule says ${p}.` };
    }
    case 'NoSchedule':
      return { cls: 'off', text: 'No one is scheduled', sub: 'Set up the rotation on the Calendar page.' };
    case 'NoNumber':
      return { cls: 'bad', text: `${p} has no phone number`, sub: 'Add one on the People page.' };
    default:
      return { cls: 'bad', text: 'Webex could not be reached', sub: esc(t.error) };
  }
}

function renderLines() {
  const s = state.status;
  $('#global-switch').checked = !!s.globalEnabled;

  $('#lines').innerHTML = s.teams.map((t) => {
    const st = statusLine(t, s.globalEnabled);
    const who = t.currentPerson
      ? `<p class="who">${esc(t.currentPerson)}</p>`
      : `<p class="who unknown">${t.current ? 'Number not in People' : 'No number set'}</p>`;
    const sourceTag = t.source === 'Override' ? 'Cover' : 'Rotation';
    const plan = t.source === 'None' ? '' : `
      <dl class="plan">
        <dt>Scheduled</dt><dd>${esc(t.person)}<span class="tag">${sourceTag}</span>${t.note ? ` ${esc(t.note)}` : ''}</dd>
        <dt>Until</dt><dd>${fmtWhen(t.until)}</dd>
        <dt>Then</dt><dd>${esc(t.nextPerson ?? 'No one scheduled')}</dd>
      </dl>`;
    return `
      <article class="line ${colorClass(t.color)}">
        <div class="line-head">
          <h2>${esc(t.displayName)}</h2>
          <label>Switching
            <input type="checkbox" role="switch" data-team="${esc(t.key)}" ${t.switchOn ? 'checked' : ''}>
            <span class="switch" aria-hidden="true"></span>
          </label>
        </div>
        <div class="readout">
          <p class="lead">Calls go to</p>
          ${who}
          <p class="number">${fmtPhone(t.current)}</p>
        </div>
        ${plan}
        <div class="status ${st.cls}">${st.text}${st.sub ? `<small>${st.sub}</small>` : ''}</div>
      </article>`;
  }).join('');

  const last = ago(s.lastCheckUtc);
  const every = s.checkMinutes ? `Checks every ${s.checkMinutes} minutes, and right at each handoff or cover.` : '';
  $('#last-check').textContent = `${last ? `Last check ${last}.` : 'Not checked yet.'} ${every}`;

  const tok = s.token ?? {};
  const note = $('#token-note');
  if (tok.error) {
    note.innerHTML = `Webex keys missing. <a href="#settings">Add them in Settings</a>.`; note.className = 'warn';
  } else if (tok.refreshDaysRemaining != null) {
    const d = Math.floor(tok.refreshDaysRemaining);
    note.innerHTML = d <= 14
      ? `Webex token expires in ${d} days. <a href="#settings">Update it in Settings</a>.`
      : `Webex token good for ${d} days`;
    note.className = d <= 14 ? 'warn' : '';
  }
}

async function renderNow() {
  await loadStatus();
  renderLines();
}

$('#lines').addEventListener('change', async (e) => {
  const box = e.target.closest('input[data-team]');
  if (!box) return;
  try {
    state.status = await api('POST', '/api/switch', { teamKey: box.dataset.team, enabled: box.checked });
    renderLines();
    toast(box.checked ? 'Switching turned on for this team' : 'Switching turned off for this team');
  } catch (err) { box.checked = !box.checked; toast(err.message, true); }
});

$('#global-switch').addEventListener('change', async (e) => {
  const on = e.target.checked;
  try {
    state.status = await api('POST', '/api/switch', { enabled: on });
    if (!$('#view-now').hidden) renderLines();
    toast(on ? 'Automatic switching is on' : 'Automatic switching is off. Webex will not change.');
  } catch (err) { e.target.checked = !on; toast(err.message, true); }
});

$('#sync-now').addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  btn.disabled = true; btn.textContent = 'Checking…';
  try {
    state.status = await api('POST', '/api/sync');
    renderLines();
    toast('Checked Webex');
  } catch (err) { toast(err.message, true); }
  finally { btn.disabled = false; btn.textContent = 'Check now'; }
});

setInterval(() => { if (!$('#view-now').hidden && !document.hidden) renderNow().catch(() => {}); }, 30000);

/* ---------- Calendar ---------- */
async function renderCalendarView() {
  await Promise.all([loadStatus(), loadPeople(), loadRotations()]);
  renderFilters();
  if (!state.calendar) initCalendar(); else state.calendar.refetchEvents();
  renderRotations();
}

function renderFilters() {
  $('#team-filters').innerHTML = teams().map((t) => `
    <label><input type="checkbox" data-team="${esc(t.key)}" ${state.hidden.has(t.key) ? '' : 'checked'}>
    <span class="dot ${colorClass(t.color)}"></span>${esc(t.displayName)}</label>`).join('');
}
$('#team-filters').addEventListener('change', (e) => {
  const k = e.target.dataset.team;
  if (e.target.checked) state.hidden.delete(k); else state.hidden.add(k);
  state.calendar?.refetchEvents();
});

function initCalendar() {
  state.calendar = new FullCalendar.Calendar($('#calendar'), {
    initialView: 'dayGridMonth',
    headerToolbar: { left: 'prev,next today', center: 'title', right: 'dayGridMonth,timeGridWeek,listWeek' },
    buttonText: { today: 'Today', month: 'Month', week: 'Week', list: 'List' },
    firstDay: 1,
    eventDisplay: 'block',
    height: 'auto',
    nowIndicator: true,
    selectable: true,
    selectMirror: true,
    eventOrder: '-priority,start',
    dayMaxEvents: false,
    eventTimeFormat: { hour: 'numeric', minute: '2-digit', meridiem: 'short' },
    snapDuration: '00:15:00',
    scrollTime: '07:00:00',
    allDayContent: 'Rotation',
    events: async (info, success, failure) => {
      try {
        const q = `start=${encodeURIComponent(info.startStr)}&end=${encodeURIComponent(info.endStr)}`;
        const data = await api('GET', `/api/events?${q}`);
        success(data.items
          .filter((ev) => !state.hidden.has(ev.extendedProps.teamKey))
          .map((ev) => {
            ev.extendedProps.realStart = ev.start;
            ev.extendedProps.realEnd = ev.end;
            // Rotation weeks are drawn as all-day bars so they never cover up the covers.
            // Hovering a bar shows the exact handoff times.
            if (ev.extendedProps.source === 'Rotation') {
              return { ...ev, allDay: true, start: ev.start.slice(0, 10), end: ev.end.slice(0, 10) };
            }
            return ev;
          }));
      } catch (e) { failure(e); toast(e.message, true); }
    },
    select: (info) => {
      state.calendar.unselect();
      openCover({ start: info.start, end: info.end });
    },
    eventClick: (info) => {
      const ev = info.event; const p = ev.extendedProps;
      if (p.source === 'Override') {
        openCover({ id: p.overrideId, swapId: p.swapId, teamKey: p.teamKey, personId: p.personId, start: ev.start, end: ev.end, note: p.note });
      } else {
        openCover({ teamKey: p.teamKey, start: new Date(p.realStart), end: new Date(p.realEnd), coveringFor: p.personName,
                    week: { teamKey: p.teamKey, personId: p.personId, personName: p.personName, start: p.realStart, end: p.realEnd } });
      }
    },
    eventDidMount: (info) => {
      const p = info.event.extendedProps;
      info.el.title = `${p.teamName}: ${p.personName}, ${fmtWhen(p.realStart)} to ${fmtWhen(p.realEnd)}${p.note ? `. ${p.note}` : ''}`;
    },
    eventDrop: moveCover,
    eventResize: moveCover,
  });
  state.calendar.render();
}

async function moveCover(info) {
  const id = info.event.extendedProps.overrideId;
  try {
    await api('PUT', `/api/overrides/${id}`, { start: toWall(info.event.start), end: toWall(info.event.end) });
    toast('Cover moved');
    state.calendar.refetchEvents();
  } catch (e) { info.revert(); toast(e.message, true); }
}

/* Cover dialog */
const dlg = $('#cover-dialog');
const form = $('#cover-form');
let editingId = null;
let editingSwapId = null;
let coverWeek = null;   // set when the dialog was opened from a rotation week

function fillPeople(select, teamKey, keep, exclude = []) {
  const list = peopleOn(teamKey).filter((p) => !exclude.includes(p.Id));
  select.innerHTML = '<option value="">Choose a person</option>' +
    list.map((p) => `<option value="${esc(p.Id)}">${esc(p.Name)}</option>`).join('');
  select.value = list.some((p) => p.Id === keep) ? keep : '';
  if (!list.length) select.innerHTML = '<option value="">No one is on this team yet</option>';
}

function openCover({ id = null, swapId = null, teamKey, personId, start, end, note = '', coveringFor = null, week = null }) {
  editingId = id;
  editingSwapId = swapId;
  coverWeek = week;
  $('#cover-title').textContent = id ? 'Change cover' : (coveringFor ? `Cover for ${coveringFor}` : 'Add cover');
  form.teamKey.innerHTML = teams().map((t) => `<option value="${esc(t.key)}">${esc(t.displayName)}</option>`).join('');
  form.teamKey.value = teamKey ?? teams()[0]?.key ?? '';
  form.teamKey.disabled = !!id;
  fillPeople(form.personId, form.teamKey.value, personId);
  form.start.value = toWall(start);
  form.end.value = toWall(end ?? new Date(start.getTime() + 3600000));
  form.note.value = note ?? '';
  $('#to-swap').hidden = !week;
  $('#cover-swapnote').hidden = !swapId;
  $('#cover-swapnote').textContent = swapId ? 'This cover is half of a week swap. You can delete just this week, or both weeks of the swap.' : '';
  $('#cover-delete').hidden = !id;
  $('#cover-delete').textContent = swapId ? 'Delete this week only' : 'Delete cover';
  $('#cover-delete-swap').hidden = !swapId;
  $('#cover-error').hidden = true;
  dlg.showModal();
  (form.personId.value ? form.start : form.personId).focus();
}

form.teamKey.addEventListener('change', () => fillPeople(form.personId, form.teamKey.value, form.personId.value));
$('#cover-cancel').addEventListener('click', () => dlg.close());
$('#to-swap').addEventListener('click', () => { const w = coverWeek; dlg.close(); openSwap(w); });

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const body = {
    teamKey: form.teamKey.value, personId: form.personId.value,
    start: form.start.value, end: form.end.value, note: form.note.value.trim(),
  };
  const err = $('#cover-error');
  if (!body.personId) { err.textContent = 'Choose who takes the calls.'; err.hidden = false; return; }
  if (new Date(body.end) <= new Date(body.start)) { err.textContent = 'The end has to be after the start.'; err.hidden = false; return; }
  try {
    if (editingId) await api('PUT', `/api/overrides/${editingId}`, body);
    else await api('POST', '/api/overrides', body);
    dlg.close();
    toast('Cover saved');
    state.calendar.refetchEvents();
  } catch (ex) { err.textContent = ex.message; err.hidden = false; }
});

async function deleteCover(whole) {
  const msg = whole
    ? 'Delete both weeks of this swap? The rotation takes over again for both.'
    : 'Delete this cover? The rotation takes over again for that time.';
  if (!editingId || !confirm(msg)) return;
  try {
    await api('DELETE', `/api/overrides/${editingId}${whole ? '?swap=1' : ''}`);
    dlg.close();
    toast(whole ? 'Swap deleted' : 'Cover deleted');
    state.calendar.refetchEvents();
  } catch (ex) { const err = $('#cover-error'); err.textContent = ex.message; err.hidden = false; }
}
$('#cover-delete').addEventListener('click', () => deleteCover(false));
$('#cover-delete-swap').addEventListener('click', () => deleteCover(true));

/* Swap dialog */
const sdlg = $('#swap-dialog');
const sform = $('#swap-form');
let swapWeek = null;
let swapOptions = null;
const shortFmt = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
const weekLabel = (s, e) => `${shortFmt.format(new Date(s))} to ${shortFmt.format(new Date(e))}`;

function openSwap(week) {
  swapWeek = week;
  swapOptions = null;
  $('#swap-week').textContent = `${week.personName} has the week of ${fmtWhen(week.start)} to ${fmtWhen(week.end)}.`;
  fillPeople(sform.withPersonId, week.teamKey, '', [week.personId]);
  sform.otherWeek.innerHTML = '<option value="">Choose who first</option>';
  sform.otherWeek.disabled = true;
  $('#swap-summary').hidden = true;
  $('#swap-error').hidden = true;
  $('#swap-save').disabled = true;
  sdlg.showModal();
  sform.withPersonId.focus();
}

function drawSwapSummary() {
  const o = swapOptions;
  const pick = o?.Options.find((x) => x.Start === sform.otherWeek.value);
  $('#swap-save').disabled = !pick;
  if (!pick) { $('#swap-summary').hidden = true; return; }
  $('#swap-summary').innerHTML =
    `<strong>${esc(o.WithPerson)}</strong> takes ${weekLabel(o.WeekStart, o.WeekEnd)}.<br>` +
    `<strong>${esc(o.FromPerson)}</strong> takes ${weekLabel(pick.Start, pick.End)}.<br>` +
    `Every other week stays on the normal rotation.` +
    (pick.HasCover ? '<br><span class="warn">That week already has a cover. The swap will sit on top of it.</span>' : '');
  $('#swap-summary').hidden = false;
}

sform.withPersonId.addEventListener('change', async () => {
  const who = sform.withPersonId.value;
  sform.otherWeek.disabled = true;
  $('#swap-error').hidden = true;
  if (!who) { sform.otherWeek.innerHTML = '<option value="">Choose who first</option>'; drawSwapSummary(); return; }
  try {
    const q = `team=${encodeURIComponent(swapWeek.teamKey)}&week=${encodeURIComponent(swapWeek.start)}&person=${encodeURIComponent(who)}`;
    swapOptions = await api('GET', `/api/swap-options?${q}`);
    $('#swap-other-label').firstChild.textContent = `In return ${swapOptions.FromPerson} takes `;
    const now = Date.now();
    sform.otherWeek.innerHTML = swapOptions.Options.map((x) => {
      const tags = [x.Suggested ? 'their next week' : '', new Date(x.End) < now ? 'past' : '', x.HasCover ? 'has a cover' : '']
        .filter(Boolean).join(', ');
      return `<option value="${esc(x.Start)}" ${x.Suggested ? 'selected' : ''}>${weekLabel(x.Start, x.End)}${tags ? ` (${tags})` : ''}</option>`;
    }).join('');
    if (!swapOptions.Options.length) sform.otherWeek.innerHTML = '<option value="">They have no rotation weeks</option>';
    sform.otherWeek.disabled = !swapOptions.Options.length;
  } catch (ex) { $('#swap-error').textContent = ex.message; $('#swap-error').hidden = false; }
  drawSwapSummary();
});
sform.otherWeek.addEventListener('change', drawSwapSummary);
$('#swap-cancel').addEventListener('click', () => sdlg.close());

sform.addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    await api('POST', '/api/swaps', {
      teamKey: swapWeek.teamKey, weekStart: swapWeek.start,
      withPersonId: sform.withPersonId.value, otherWeekStart: sform.otherWeek.value,
    });
    sdlg.close();
    toast('Weeks swapped');
    state.calendar.refetchEvents();
  } catch (ex) { $('#swap-error').textContent = ex.message; $('#swap-error').hidden = false; }
});

/* Rotation editor */
const rotDraft = {};   // teamKey -> { members, date, time, anchorPersonId }
const weekday = (dateStr) => (dateStr ? new Date(`${dateStr}T12:00`).toLocaleDateString('en-US', { weekday: 'long' }) : '');

function renderRotations() {
  for (const t of teams()) {
    const r = state.rotations.find((x) => x.TeamKey === t.key) ?? {};
    const [date, time] = (r.AnchorStart ?? '').split('T');
    rotDraft[t.key] = { members: [...(r.Members ?? [])], date: date ?? '', time: time ?? '08:00', anchorPersonId: r.AnchorPersonId ?? '' };
  }
  drawRotations();
}

function drawRotations() {
  $('#rotations').innerHTML = teams().map((t) => {
    const d = rotDraft[t.key];
    const list = d.members.map((id, i) => `
      <li>
        <span class="name">${esc(personName(id))}</span>
        <button class="btn small" data-act="up" data-i="${i}" ${i === 0 ? 'disabled' : ''} aria-label="Move ${esc(personName(id))} up">Up</button>
        <button class="btn small" data-act="down" data-i="${i}" ${i === d.members.length - 1 ? 'disabled' : ''} aria-label="Move ${esc(personName(id))} down">Down</button>
        <button class="btn small danger" data-act="remove" data-i="${i}" aria-label="Remove ${esc(personName(id))}">Remove</button>
      </li>`).join('');
    const available = peopleOn(t.key).filter((p) => !d.members.includes(p.Id));
    const addRow = available.length
      ? `<label>Add to rotation
            <select data-field="add">
              <option value="">Choose a person</option>
              ${available.map((p) => `<option value="${esc(p.Id)}">${esc(p.Name)}</option>`).join('')}
            </select>
          </label>`
      : `<p class="hint">${peopleOn(t.key).length ? 'Everyone on this team is in the rotation.' : 'No one is on this team yet. Add people to it on the People page.'}</p>`;
    const handoff = d.date ? `Handoff every ${weekday(d.date)} at ${timeFmt.format(new Date(`${d.date}T${d.time || '08:00'}`))}.` : 'Pick a handoff date.';
    return `
      <div class="rot ${colorClass(t.color)}" data-team="${esc(t.key)}">
        <h3>${esc(t.displayName)}</h3>
        ${d.members.length ? `<ol>${list}</ol>` : '<p class="hint">No one in this rotation yet.</p>'}
        <div class="row">${addRow}</div>
        <div class="row">
          <label>A handoff date <input type="date" data-field="date" value="${esc(d.date)}"></label>
          <label>Time <input type="time" data-field="time" value="${esc(d.time)}" step="900"></label>
          <label>On call that week
            <select data-field="anchor">
              <option value="">Choose</option>
              ${d.members.map((id) => `<option value="${esc(id)}" ${id === d.anchorPersonId ? 'selected' : ''}>${esc(personName(id))}</option>`).join('')}
            </select>
          </label>
        </div>
        <p class="hint" style="margin-top:10px">${handoff}</p>
        <div class="save-row"><button class="btn primary" data-act="save">Save rotation</button></div>
      </div>`;
  }).join('');
}

$('#rotations').addEventListener('click', async (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const key = btn.closest('.rot').dataset.team;
  const d = rotDraft[key];
  const i = Number(btn.dataset.i);
  if (btn.dataset.act === 'up') [d.members[i - 1], d.members[i]] = [d.members[i], d.members[i - 1]];
  if (btn.dataset.act === 'down') [d.members[i + 1], d.members[i]] = [d.members[i], d.members[i + 1]];
  if (btn.dataset.act === 'remove') {
    const [gone] = d.members.splice(i, 1);
    if (d.anchorPersonId === gone) d.anchorPersonId = '';
  }
  if (btn.dataset.act === 'save') {
    if (!d.members.length) return toast('Add at least one person to the rotation.', true);
    if (!d.date || !d.time) return toast('Pick a handoff date and time.', true);
    if (!d.anchorPersonId) return toast('Choose who is on call that week.', true);
    try {
      await api('PUT', `/api/rotations/${key}`, { members: d.members, anchorStart: `${d.date}T${d.time}`, anchorPersonId: d.anchorPersonId });
      await loadRotations();
      toast('Rotation saved');
      state.calendar?.refetchEvents();
    } catch (err) { toast(err.message, true); }
    return;
  }
  drawRotations();
});

$('#rotations').addEventListener('change', (e) => {
  const el = e.target.closest('[data-field]');
  if (!el) return;
  const d = rotDraft[el.closest('.rot').dataset.team];
  if (el.dataset.field === 'add' && el.value) d.members.push(el.value);
  if (el.dataset.field === 'date') d.date = el.value;
  if (el.dataset.field === 'time') d.time = el.value;
  if (el.dataset.field === 'anchor') d.anchorPersonId = el.value;
  drawRotations();
});

/* ---------- People ---------- */
async function renderPeople() {
  await Promise.all([loadPeople(), loadRotations(), loadStatus()]);
  $('#new-person-teams').innerHTML = '<legend>Teams</legend>' + (teams().length
    ? teams().map((t) => `<label class="pick"><input type="checkbox" name="teams" value="${esc(t.key)}"><span class="dot ${colorClass(t.color)}"></span>${esc(t.displayName)}</label>`).join('')
    : '<span class="hint">Add a team on the Teams page first.</span>');
  drawPeople();
}

function inRotation(personId, key) {
  return (state.rotations.find((r) => r.TeamKey === key)?.Members ?? []).includes(personId);
}

function personCard(p, editing = false) {
  const chips = (p.Teams ?? []).map((k) => {
    const t = teamOf(k);
    const label = t?.displayName ?? k;
    return `<li class="chip ${tc(k)}"><span class="dot"></span>${esc(label)}${inRotation(p.Id, k) ? '<span class="chip-note">in rotation</span>' : ''}
      <button type="button" class="chip-x" data-act="untag" data-team="${esc(k)}" aria-label="Take ${esc(p.Name)} off ${esc(label)}">×</button></li>`;
  }).join('');
  const left = teams().filter((t) => !onTeam(p, t.key));
  const head = editing
    ? `<div class="pcard-edit">
         <label>Name <input name="name" value="${esc(p.Name)}" maxlength="80"></label>
         <label>Phone <input name="number" value="${esc(p.Number)}" inputmode="tel"></label>
       </div>`
    : `<h3>${esc(p.Name)}</h3><p class="phone">${fmtPhone(p.Number)}</p>`;
  const actions = editing
    ? `<button class="btn small primary" data-act="save">Save</button><button class="btn small" data-act="cancel">Cancel</button>`
    : `<button class="btn small" data-act="edit">Edit</button><button class="btn small danger" data-act="remove">Remove</button>`;
  return `
    <article class="pcard" data-id="${esc(p.Id)}">
      <div class="pcard-head">${head}</div>
      ${chips ? `<ul class="chips">${chips}</ul>` : '<p class="hint">Not on any team yet.</p>'}
      ${left.length ? `<select class="add-team" data-act="tag" aria-label="Add ${esc(p.Name)} to a team">
          <option value="">Add to a team</option>
          ${left.map((t) => `<option value="${esc(t.key)}">${esc(t.displayName)}</option>`).join('')}
        </select>` : ''}
      <div class="pcard-actions">${actions}</div>
    </article>`;
}

function drawPeople() {
  $('#people-cards').innerHTML = state.people.length
    ? state.people.map((p) => personCard(p)).join('')
    : '<p class="hint">No one here yet. Add the people who take on-call shifts.</p>';
}

async function setTeams(p, keys, msg) {
  try {
    await api('PUT', `/api/people/${p.Id}`, { teams: keys });
    toast(msg);
    await Promise.all([loadPeople(), loadRotations()]);
    drawPeople();
  } catch (err) { toast(err.message, true); drawPeople(); }
}

$('#person-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  const picked = [...f.querySelectorAll('input[name=teams]:checked')].map((x) => x.value);
  try {
    await api('POST', '/api/people', { name: f.name.value.trim(), number: f.number.value, teams: picked });
    toast(`Added ${f.name.value.trim()}`);
    f.reset();
    await renderPeople();
  } catch (err) { toast(err.message, true); }
});

$('#people-cards').addEventListener('change', (e) => {
  const sel = e.target.closest('select[data-act=tag]');
  if (!sel || !sel.value) return;
  const p = state.people.find((x) => x.Id === sel.closest('.pcard').dataset.id);
  setTeams(p, [...(p.Teams ?? []), sel.value], `Added ${p.Name} to ${teamOf(sel.value)?.displayName}`);
});

$('#people-cards').addEventListener('click', async (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const card = btn.closest('.pcard');
  const p = state.people.find((x) => x.Id === card.dataset.id);
  const act = btn.dataset.act;

  if (act === 'untag') {
    const k = btn.dataset.team;
    const name = teamOf(k)?.displayName ?? k;
    if (inRotation(p.Id, k) && !confirm(`Take ${p.Name} off ${name}?\n\nThey'll also come out of its rotation. This week stays as it is, and the weeks after it shift.`)) return;
    return setTeams(p, (p.Teams ?? []).filter((x) => x !== k), `Took ${p.Name} off ${name}`);
  }
  if (act === 'edit') { card.outerHTML = personCard(p, true); $(`.pcard[data-id="${p.Id}"] input`).focus(); return; }
  if (act === 'cancel') return drawPeople();
  if (act === 'save') {
    try {
      await api('PUT', `/api/people/${p.Id}`, { name: card.querySelector('[name=name]').value.trim(), number: card.querySelector('[name=number]').value });
      toast('Saved');
      await loadPeople(); drawPeople();
    } catch (err) { toast(err.message, true); }
    return;
  }
  if (act === 'remove') {
    if (!confirm(`Remove ${p.Name} from the app?`)) return;
    try {
      await api('DELETE', `/api/people/${p.Id}`);
      toast(`Removed ${p.Name}`);
      await loadPeople(); drawPeople();
    } catch (err) { toast(err.message, true); }
  }
});

/* ---------- Teams ---------- */
let teamList = [];

async function renderTeams() {
  $('#team-cards').innerHTML = '<p class="hint">Checking each team with Webex…</p>';
  teamList = (await api('GET', '/api/teams')).items;
  drawTeams();
}

function teamCard(t, editing = false) {
  const webex = t.error
    ? `<dd class="bad-text">Webex can't read this team. ${esc(t.error)}</dd>`
    : `<dd>${esc(t.webexName)}</dd>`;
  const body = editing
    ? `<div class="pcard-edit">
         <label>Name <input name="displayName" value="${esc(t.displayName)}" maxlength="60"></label>
         <label>Webex team ID <input name="webexTeamId" value="${esc(t.webexTeamId)}" spellcheck="false"></label>
       </div>`
    : `<h3>${esc(t.displayName)}</h3>
       <dl class="kv-mini">
         <dt>Webex team</dt>${webex}
         <dt>Calls go to</dt><dd>${t.error ? 'Unknown' : fmtPhone(t.current)}</dd>
         <dt>People</dt><dd>${t.members} on the team, ${t.inRotation} in the rotation</dd>
         <dt>Team ID</dt><dd class="uuid">${esc(t.webexTeamId)}</dd>
       </dl>`;
  const actions = editing
    ? `<button class="btn small primary" data-act="save">Save</button><button class="btn small" data-act="cancel">Cancel</button>`
    : `<button class="btn small" data-act="edit">Edit</button><button class="btn small danger" data-act="remove">Remove</button>`;
  return `<article class="pcard tcard ${colorClass(t.color)}" data-key="${esc(t.key)}">${body}<div class="pcard-actions">${actions}</div></article>`;
}

function drawTeams() {
  $('#team-cards').innerHTML = teamList.length
    ? teamList.map((t) => teamCard(t)).join('')
    : '<p class="hint">No teams yet. Add the Contact Center team that forwards to the on-call phone.</p>';
}

$('#team-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  const btn = f.querySelector('button[type=submit]');
  btn.disabled = true; btn.textContent = 'Checking with Webex…';
  try {
    const t = await api('POST', '/api/teams', { displayName: f.displayName.value.trim(), webexTeamId: f.webexTeamId.value.trim() });
    toast(`Added ${t.DisplayName}. Switching is off until you turn it on.`);
    f.reset();
    await loadStatus();
    await renderTeams();
  } catch (err) { toast(err.message, true); }
  finally { btn.disabled = false; btn.textContent = 'Add team'; }
});

$('#team-cards').addEventListener('click', async (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const card = btn.closest('.tcard');
  const t = teamList.find((x) => x.key === card.dataset.key);
  const act = btn.dataset.act;
  if (act === 'edit') { card.outerHTML = teamCard(t, true); return; }
  if (act === 'cancel') return drawTeams();
  if (act === 'save') {
    btn.disabled = true;
    try {
      await api('PUT', `/api/teams/${t.key}`, {
        displayName: card.querySelector('[name=displayName]').value.trim(),
        webexTeamId: card.querySelector('[name=webexTeamId]').value.trim(),
      });
      toast('Team saved');
      await loadStatus();
      await renderTeams();
    } catch (err) { btn.disabled = false; toast(err.message, true); }
    return;
  }
  if (act === 'remove') {
    if (!confirm(`Remove ${t.displayName}? Its rotation and past covers go with it. History keeps the record.`)) return;
    try {
      await api('DELETE', `/api/teams/${t.key}`);
      toast(`Removed ${t.displayName}`);
      await loadStatus();
      await renderTeams();
    } catch (err) { toast(err.message, true); }
  }
});

/* ---------- History ---------- */
const eventNames = {
  number_change: 'Switched Webex', sync_error: 'Check failed',
  override_add: 'Cover added', override_update: 'Cover changed', override_remove: 'Cover deleted',
  rotation_set: 'Rotation changed', person_add: 'Person added', person_update: 'Person changed',
  person_remove: 'Person removed', switch: 'Switch changed', credentials_update: 'Webex keys updated',
  settings_update: 'Settings changed', setting_change: 'Settings changed', user_add: 'Can sign in', user_remove: 'Can no longer sign in',
  login: 'Signed in', login_denied: 'Sign-in refused', setup: 'Sign-in set up', setup_denied: 'Wrong setup code',
  login_keys_update: 'Sign-in keys updated',
  team_add: 'Team added', team_update: 'Team changed', team_remove: 'Team removed',
  swap_add: 'Weeks swapped', swap_remove: 'Swap deleted',
};

async function renderHistory() {
  await loadStatus();
  const items = (await api('GET', '/api/audit')).items.reverse();
  const tbody = $('#history-table tbody');
  if (!items.length) { tbody.innerHTML = '<tr><td colspan="5" class="empty">Nothing has happened yet.</td></tr>'; return; }
  tbody.innerHTML = items.map((a) => {
    const team = teams().find((t) => t.key === a.TeamKey)?.displayName ?? (a.TeamKey ?? '');
    // Raw wall-clock stamps like 2026-10-28T08:00 become "Wed, Oct 28, 8:00 AM".
    let detail = esc(a.Detail).replace(/(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/g, (_, d, t) => fmtWhen(`${d}T${t}`));
    if (a.Event === 'switch') {
      const on = /= True$/i.test(a.Detail ?? '');
      detail = `${a.TeamKey ? 'Switching for this team' : 'Automatic switching'} turned ${on ? 'on' : 'off'}`;
    }
    if (a.Event === 'number_change') {
      detail = `${fmtPhone(a.Old)} to ${fmtPhone(a.New)}, ${esc(a.Person)} (${a.Source === 'Override' ? 'cover' : 'rotation'})${a.Detail ? `. ${esc(a.Detail)}` : ''}`;
    }
    return `<tr>
      <td class="nowrap">${fmtWhen(a.Ts)}</td>
      <td class="nowrap">${esc(eventNames[a.Event] ?? a.Event)}</td>
      <td class="nowrap">${a.TeamKey ? `<span class="dot ${tc(a.TeamKey)}"></span>` : ''}${esc(team)}</td>
      <td>${detail}</td>
      <td>${esc(a.Actor)}</td>
    </tr>`;
  }).join('');
}

/* ---------- Settings ---------- */
const regions = [
  ['https://api.wxcc-us1.cisco.com', 'United States (us1)'],
  ['https://api.wxcc-ca1.cisco.com', 'Canada (ca1)'],
  ['https://api.wxcc-eu1.cisco.com', 'Europe, UK (eu1)'],
  ['https://api.wxcc-eu2.cisco.com', 'Europe, Germany (eu2)'],
  ['https://api.wxcc-anz1.cisco.com', 'Australia (anz1)'],
  ['https://api.wxcc-jp1.cisco.com', 'Japan (jp1)'],
  ['https://api.wxcc-sg1.cisco.com', 'Singapore (sg1)'],
];
let zoneList = null;

function options(list, selected) {
  return list.map(([v, label]) => `<option value="${esc(v)}"${v === selected ? ' selected' : ''}>${esc(label)}</option>`).join('');
}

function drawSettings(s) {
  const f = $('#org-form');
  f.orgId.value = s.orgId ?? '';
  const regionList = regions.some(([v]) => v === s.configBaseUrl) ? regions : [...regions, [s.configBaseUrl, s.configBaseUrl]];
  f.configBaseUrl.innerHTML = options(regionList, s.configBaseUrl);
  const zones = [['', `This computer's zone (${s.hostTimeZone})`], ...(zoneList ?? []).map((z) => [z.id, z.name])];
  if (s.timeZone && !zones.some(([v]) => v === s.timeZone)) zones.push([s.timeZone, s.timeZone]);
  f.timeZone.innerHTML = options(zones, s.timeZone ?? '');
  $('#check-form').checkMinutes.value = String(s.checkMinutes ?? 30);
  $('#cred-protection').textContent = `Saved values are encrypted (${s.protection}) and never shown again.`;

  const about = [
    ['Version', s.version ?? 'Unknown'],
    ['Listening', s.listen === 'Network' ? `${s.publicUrl} (network, Webex sign-in)` : 'This computer only (localhost)'],
    ['Runs on', `${s.platform}${s.container ? ', in a container' : ''}, as ${s.runningAs}`],
    ['Schedule time zone', s.timeZoneInUse],
  ];
  $('#about').innerHTML = about.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('');

  const net = s.listen === 'Network';
  $('#network-settings').hidden = !net;
  if (!net) return;
  $('#user-list').innerHTML = (s.users ?? []).map((u) => `<li>
      <span>${esc(u.email)}${u.email === s.me ? ' <span class="chip-note">(you)</span>' : ''}</span>
      <span class="chip-note">${u.addedBy ? `added by ${esc(u.addedBy)}` : ''}</span>
      ${u.email === s.me ? '' : `<button type="button" class="btn small danger" data-remove="${esc(u.email)}">Remove</button>`}
    </li>`).join('');
  const l = s.login ?? {};
  let loginState = l.saved ? 'Saved' : 'Not set up';
  if (l.error) loginState = l.error;
  const lrows = [
    ['Status', loginState],
    ['Client ID', l.clientIdHint ?? 'None'],
    ['Redirect URI', l.redirectUri],
  ];
  $('#login-status').innerHTML = lrows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('');
}

async function renderSettings() {
  if (!zoneList) zoneList = (await api('GET', '/api/timezones')).items.sort((a, b) => a.name.localeCompare(b.name));
  const [c, s] = await Promise.all([api('GET', '/api/credentials'), api('GET', '/api/settings')]);
  const rows = c.saved ? [
    ['Status', 'Connected'],
    ['Last renewed', fmtWhen(c.lastRefresh)],
    ['Token good for', c.refreshDaysRemaining != null ? `${Math.floor(c.refreshDaysRemaining)} days, renewed daily` : 'Unknown'],
    ['Client ID', c.clientIdHint ?? 'Unknown'],
    ['Keys saved by', c.account],
  ] : [
    ['Status', c.error && !c.error.startsWith('No Webex keys') ? c.error : 'No keys saved yet. Paste all three below.'],
  ];
  $('#cred-status').innerHTML = rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('');
  if (!c.saved) $('#cred-form details').open = true;
  drawSettings(s);
}

$('#org-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  const err = $('#org-error');
  err.hidden = true;
  try {
    drawSettings(await api('POST', '/api/settings', { orgId: f.orgId.value, configBaseUrl: f.configBaseUrl.value, timeZone: f.timeZone.value }));
    toast('Settings saved');
  } catch (ex) { err.textContent = ex.message; err.hidden = false; }
});

$('#user-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  const err = $('#user-error');
  err.hidden = true;
  try {
    drawSettings(await api('POST', '/api/users', { email: f.email.value }));
    toast(`${f.email.value} can sign in now`);
    f.reset();
  } catch (ex) { err.textContent = ex.message; err.hidden = false; }
});

$('#user-list').addEventListener('click', async (e) => {
  const email = e.target.closest('[data-remove]')?.dataset.remove;
  if (!email || !confirm(`Remove ${email}? They're signed out right away.`)) return;
  try {
    drawSettings(await api('DELETE', `/api/users/${encodeURIComponent(email)}`));
    toast(`${email} can no longer sign in`);
  } catch (ex) { toast(ex.message, true); }
});

$('#login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  const err = $('#login-error');
  err.hidden = true;
  if (!f.clientId.value.trim() && !f.clientSecret.value.trim()) { err.textContent = 'Enter a new client ID or secret first.'; err.hidden = false; return; }
  try {
    drawSettings(await api('POST', '/api/login-integration', { clientId: f.clientId.value, clientSecret: f.clientSecret.value }));
    f.reset();
    toast('Sign-in keys saved. Sign out and back in to test them.');
  } catch (ex) { err.textContent = ex.message; err.hidden = false; }
});

$('#sign-out').addEventListener('click', async () => {
  try { await api('POST', '/auth/logout'); } catch { /* signed out either way */ }
  location.href = '/login';
});

$('#cred-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.currentTarget;
  const err = $('#cred-error');
  const btn = f.querySelector('button[type=submit]');
  err.hidden = true;
  const body = { refreshToken: f.refreshToken.value, clientId: f.clientId.value, clientSecret: f.clientSecret.value };
  if (!body.refreshToken.trim() && !body.clientId.trim() && !body.clientSecret.trim()) {
    err.textContent = 'Paste a new refresh token first.'; err.hidden = false; return;
  }
  btn.disabled = true; btn.textContent = 'Testing…';
  try {
    await api('POST', '/api/credentials', body);
    f.reset();
    toast('Webex keys saved and working');
    await renderSettings();
  } catch (ex) { err.textContent = ex.message; err.hidden = false; }
  finally { btn.disabled = false; btn.textContent = 'Save and test'; }
});

$('#check-form').addEventListener('change', async (e) => {
  const sel = e.target;
  try {
    const r = await api('POST', '/api/settings', { checkMinutes: Number(sel.value) });
    drawSettings(r);
    toast(`Webex is checked every ${r.checkMinutes} minutes`);
    if (state.status) state.status.checkMinutes = r.checkMinutes;
  } catch (err) { toast(err.message, true); }
});

/* ---------- start ---------- */
window.addEventListener('hashchange', route);
(async () => {
  try {
    const me = await api('GET', '/api/me');
    if (me.listen === 'Network' && me.email) {
      $('#who-name').textContent = me.name || me.email;
      $('#who-name').title = me.email;
      $('#who').hidden = false;
    }
  } catch { /* the 401 handler already redirected */ }
  try { await loadStatus(); $('#global-switch').checked = !!state.status.globalEnabled; } catch (e) { toast(e.message, true); }
  route();
})();
