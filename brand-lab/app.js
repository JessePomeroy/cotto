'use strict';
const ids = ['murmur', 'sotto', 'tempo'];
const $ = (query) => document.querySelector(query);
const $$ = (query) => [...document.querySelectorAll(query)];
const storage = {
  get(key, fallback) { try { return JSON.parse(localStorage.getItem(`murmur-brand-lab:${key}`)) ?? fallback; } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(`murmur-brand-lab:${key}`, JSON.stringify(value)); return true; } catch { return false; } }
};
const state = { concepts: [], selected: 'murmur', view: 'app', theme: 'light', status: 'ready', shortlist: storage.get('shortlist', []), timers: [], toastTimer: null };
if (!Array.isArray(state.shortlist)) state.shortlist = [];
const icon = (name) => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;
const recommendations = {
  murmur: ['My starting point', 'The name already feels human. A stronger mark and warmer materials give it character without making the product feel unfamiliar.'],
  sotto: ['The strongest rename', 'A little more editorial, a little more intimate. This is the direction if the app should feel closer to a writing companion.'],
  tempo: ['The sharper alternative', 'The clearest departure: more immediate and purposeful. Best if speed and staying in your train of thought lead the story.']
};
const esc = (value) => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
function announce(message) {
  clearTimeout(state.toastTimer);
  $('#toast').textContent = message;
  $('#toast').classList.add('visible');
  state.toastTimer = setTimeout(() => $('#toast').classList.remove('visible'), 2200);
}
function renderDirections() {
  $('#directions').innerHTML = state.concepts.map((concept, index) => `
    <article class="direction-card" data-id="${concept.id}" style="--concept-paper:${concept.ui.paper};--concept-ink:${concept.ui.ink}">
      <button class="direction-select" data-concept="${concept.id}" aria-pressed="${state.selected === concept.id}" aria-label="Explore ${esc(concept.name)}: ${esc(concept.descriptor)}">
        <div class="concept-face">
          <img class="concept-motif" src="concepts/${concept.id}/motif.svg" alt="" width="600" height="360">
          <div class="concept-top"><span>Direction 0${index + 1}</span><span class="concept-colors">${concept.palette.map(color => `<i style="background:${color.hex}"></i>`).join('')}</span></div>
          <div class="concept-lockup"><img src="concepts/${concept.id}/mark.svg" alt="" width="90" height="90"><span class="concept-word">${esc(concept.name)}</span></div>
          <div class="concept-bottom"><span>${index === 0 ? 'Evolve the familiar' : index === 1 ? 'A softer voice' : 'A new rhythm'}</span><span class="selected-marker">Selected</span></div>
        </div>
        <div class="concept-caption"><b>${esc(concept.descriptor)}</b><span>${esc(concept.personality.slice(0, 2).join(' · '))}</span></div>
      </button>
    </article>`).join('');
  $$('[data-concept]').forEach(button => button.addEventListener('click', () => selectConcept(button.dataset.concept)));
}
function renderNames() {
  $('#names-list').innerHTML = state.concepts.flatMap(concept => concept.names.map(name => ({...name, id: concept.id}))).map(name => `
    <div class="name-row"><span>${esc(name.name)}</span><p>${esc(name.reason)}</p><button data-shortlist-name="${esc(name.name)}" aria-label="Shortlist ${esc(name.name)}" aria-pressed="${state.shortlist.includes(name.name)}"><span class="name-star" aria-hidden="true">${state.shortlist.includes(name.name) ? '★' : '☆'}</span></button></div>`).join('');
  $$('[data-shortlist-name]').forEach(button => button.addEventListener('click', () => toggleShortlist(button.dataset.shortlistName)));
}
function toggleShortlist(name) {
  const adding = !state.shortlist.includes(name);
  state.shortlist = adding ? [...state.shortlist, name] : state.shortlist.filter(item => item !== name);
  const saved = storage.set('shortlist', state.shortlist);
  renderNames(); updateSaveButton();
  announce(`${name} ${adding ? 'added to' : 'removed from'} your shortlist${saved ? '' : ' (this session)'}.`);
}
function updateSaveButton() {
  const concept = state.concepts.find(item => item.id === state.selected);
  const saved = state.shortlist.includes(concept.name);
  $('#save-direction').setAttribute('aria-pressed', String(saved));
  $('#save-direction span').textContent = saved ? 'On your shortlist' : 'Add to shortlist';
}
function selectConcept(id, updateURL = true) {
  const concept = state.concepts.find(item => item.id === id);
  if (!concept) return;
  state.selected = id;
  const vars = {accent: concept.ui.accent, 'accent-ink': concept.ui.accentInk, tint: concept.ui.tint, 'brand-ink': concept.ui.ink, paper: concept.ui.paper};
  Object.entries(vars).forEach(([key, value]) => document.documentElement.style.setProperty(`--${key}`, value));
  $$('[data-concept]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.concept === id)));
  $$('[data-name]').forEach(element => element.textContent = concept.name);
  $$('[data-asset]').forEach(image => image.src = `concepts/${id}/${image.dataset.asset}`);
  $('#preview-direction').textContent = concept.name;
  $('#direction-number').textContent = `0${ids.indexOf(id) + 1}`;
  $('#direction-title').textContent = concept.name;
  $('#descriptor').textContent = concept.descriptor;
  $('#tagline').textContent = concept.tagline;
  $('#rationale').textContent = concept.rationale;
  $('#personality').innerHTML = concept.personality.map(word => `<span>${esc(word)}</span>`).join('');
  $('#recommendation-title').textContent = recommendations[id][0];
  $('#recommendation').textContent = recommendations[id][1];
  $('#logo-idea').textContent = concept.logoIdea;
  $('#download-set').href = `downloads/${id}-svg-set.zip`;
  $('#download-set').setAttribute('aria-label', `Download ${concept.name} SVG set`);
  $('#type-sample').textContent = concept.tagline;
  $('#type-sample').style.fontFamily = id === 'sotto' ? '"Iowan Old Style", Baskerville, Georgia, serif' : 'inherit';
  $('#type-style').textContent = id === 'sotto' ? 'An editorial name. A system interface.' : id === 'tempo' ? 'System sans, clear and purposeful.' : 'System sans, with softer edges.';
  $('#swatches').innerHTML = concept.palette.map(color => `<button class="swatch" data-color="${color.hex}" aria-label="Copy ${esc(color.name)}, ${color.hex}"><span class="swatch-face" style="background:${color.hex};color:${isDark(color.hex) ? '#ffffff' : '#252825'}">${icon('copy')}</span><span class="swatch-caption"><b>${esc(color.name)}</b><span>${color.hex}</span></span><span class="swatch-role">${esc(color.role)}</span></button>`).join('');
  $$('[data-color]').forEach(button => button.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(button.dataset.color); announce(`${button.dataset.color} copied.`); }
    catch { announce(`Color value: ${button.dataset.color}`); }
  }));
  const notes = storage.get(`notes:${id}`, '');
  $('#personal-notes').value = typeof notes === 'string' ? notes : '';
  $('#personal-notes').placeholder = `What would you keep or change about ${concept.name}?`;
  $('#notes-status').textContent = `Notes for ${concept.name} · Saved in this browser.`;
  updateSaveButton();
  if (updateURL) { const url = new URL(location.href); url.searchParams.set('direction', id); history.replaceState(null, '', url); }
}
function isDark(hex) { const colors = hex.slice(1).match(/../g).map(part => parseInt(part, 16)); return .2126 * colors[0] + .7152 * colors[1] + .0722 * colors[2] < 140; }
function cancelPlayback() { state.timers.forEach(clearTimeout); state.timers = []; $$('[data-play]').forEach(button => button.disabled = false); }
function setStatus(status, manual = true) {
  if (manual) cancelPlayback();
  state.status = status;
  $('#preview-stage').dataset.state = status;
  $$('[data-state]').filter(element => element.tagName === 'BUTTON').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.state === status)));
  const labels = {ready: 'Ready when you are', listening: 'Listening to you', processing: 'Putting it into words'};
  $$('[data-status-label]').forEach(element => element.textContent = labels[status]);
  $('#hud-title').textContent = status === 'processing' ? 'Finding your words' : 'Listening';
  $('#hud-subtitle').textContent = status === 'processing' ? 'Just a moment.' : 'Your voice, right here.';
  $('#hud-time').textContent = status === 'processing' ? '···' : '0:04';
  $('#transcript-copy').innerHTML = status === 'processing' ? 'A thought, taking shape.<br>A moment to make it clear.' : status === 'listening' ? 'Make space for a good idea.<br>The words will follow.' : 'Make space for a good idea.<br>The words will follow.';
  $$('[data-delivery]').forEach(element => element.textContent = status === 'processing' ? 'Processing on this Mac' : 'Saved on this Mac');
}
function setView(view) {
  state.view = view;
  $('#preview-stage').dataset.view = view;
  $$('[role=tabpanel]').forEach(panel => panel.hidden = panel.id !== `surface-${view}`);
  $$('[role=tab]').forEach(button => { const selected = button.dataset.view === view; button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1; });
}
function playInteraction() {
  cancelPlayback();
  if (state.view === 'icon') setView('app');
  setStatus('listening', false);
  $$('[data-play]').forEach(button => button.disabled = true);
  state.timers.push(setTimeout(() => setStatus('processing', false), 2200));
  state.timers.push(setTimeout(() => {setStatus('ready', false); $('#transcript-copy').innerHTML = 'A thought, now in words.<br>Keep going. You were onto something.'; $$('[data-play]').forEach(button => button.disabled = false); state.timers = [];}, 3450));
}
async function init() {
  state.concepts = await Promise.all(ids.map(async id => { const response = await fetch(`concepts/${id}/concept.json`); if (!response.ok) throw new Error(`Could not load ${id}`); return response.json(); }));
  const requested = new URL(location.href).searchParams.get('direction');
  state.selected = ids.includes(requested) ? requested : 'murmur';
  renderDirections(); renderNames(); selectConcept(state.selected, false);
  $$('[data-theme]').filter(element => element.tagName === 'BUTTON').forEach(button => button.addEventListener('click', () => {
    state.theme = button.dataset.theme; $('#preview-stage').dataset.theme = state.theme;
    $$('button[data-theme]').forEach(item => item.setAttribute('aria-pressed', String(item.dataset.theme === state.theme)));
  }));
  $$('[role=tab]').forEach((button, index, tabs) => {
    button.addEventListener('click', () => setView(button.dataset.view));
    button.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = tabs.length - 1;
      if (next === undefined) return;
      event.preventDefault(); setView(tabs[next].dataset.view); tabs[next].focus();
    });
  });
  $$('button[data-state]').forEach(button => button.addEventListener('click', () => setStatus(button.dataset.state)));
  $$('[data-play]').forEach(button => button.addEventListener('click', playInteraction));
  $('#save-direction').addEventListener('click', () => toggleShortlist(state.concepts.find(item => item.id === state.selected).name));
  $('#personal-notes').addEventListener('input', event => {
    const saved = storage.set(`notes:${state.selected}`, event.target.value);
    $('#notes-status').textContent = saved ? `Notes for ${state.concepts.find(item => item.id === state.selected).name} · Saved in this browser.` : 'Browser storage unavailable. Keep a copy of these notes.';
  });
}
init().catch(error => { $('#directions').innerHTML = `<div class="loading-note">The board couldn’t load. Start the local server from the README, then reload.</div>`; console.error(error); });
