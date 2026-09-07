import { initialSettings, renderSettingsPage, handleSettingsAction, handleSettingsChange } from './settings-pages.js';

const $ = query => document.querySelector(query);
const $$ = query => [...document.querySelectorAll(query)];
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const icon = name => `<svg aria-hidden="true" viewBox="0 0 24 24"><use href="#i-${name}"/></svg>`;
const pages = [['dictation', 'Dictation', 'wave'], ['microphone', 'Microphone', 'mic'], ['dictionary', 'Dictionary', 'book'], ['history', 'History', 'history'], ['models', 'Models', 'chip'], ['general', 'General', 'sliders']];
const darkMaterials = {
  graphite: 'Smoked glass. Silver accents. The quietest of the three.',
  glacier: 'Cool slate glass with a little ice-blue light.',
  moss: 'Soft charcoal glass. A restrained touch of sage.',
  original: 'The original plum and vermilion, kept for comparison.',
};
const starterText = 'Let’s give Sotto a little room to breathe.\n\n1. Keep the interface quiet.\n2. Make the shortcut feel instant.\n3. Let the words take the lead.';
const samples = {
  note: { raw: "Okay, let's keep this simple. The idea is to make room for the next good thought.", polished: 'Okay, let’s keep this simple. The idea is to make room for the next good thought.' },
  list: { raw: '1. keep the interface quiet\n2. make the shortcut feel instant\n3. let the words take the lead', polished: '1. Keep the interface quiet.\n2. Make the shortcut feel instant.\n3. Let the words take the lead.' },
  names: { raw: 'I want to try mini max with code x. then send the notes to ray cast.', polished: null },
};
function makeState() {
  return {
    ...structuredClone(initialSettings), theme: 'light', darkMaterial: 'glacier', scene: 'settings', page: 'dictation', menuOpen: false,
    appOpen: true, sidebarOpen: true, expanded: false, status: 'idle', elapsed: 0, holdKind: null,
    sample: 'note', delivery: 'cursor', lastText: starterText, lastDelivery: 'Saved on this Mac', lastDuration: 12.4,
    processingTime: '0.3', takeMic: '', clipboard: '', clipboardOpen: false,
    noteText: 'A place for the next good idea.\n\n', selection: null, historySelection: 'sample-1',
    history: [
      { id: 'sample-1', text: starterText, time: 'Today, 9:38 AM', seconds: 12.4, correction: true, audio: true },
      { id: 'sample-2', text: 'I want to try MiniMax with Codex. Then send the notes to Raycast.', time: 'Today, 9:26 AM', seconds: 5.8, correction: true, audio: true },
      { id: 'sample-3', text: 'A little less typing. A little more room to think.', time: 'Yesterday, 4:12 PM', seconds: 4.1, correction: false, audio: true },
    ],
  };
}
const state = makeState();
const previewURL = new URL(window.location.href);
const linkedMaterial = previewURL.searchParams.get('material');
if (Object.hasOwn(darkMaterials, linkedMaterial)) state.darkMaterial = linkedMaterial;
if (previewURL.searchParams.get('theme') === 'dark') state.theme = 'dark';
let captureTimer, phaseTimer, toastTimer;
let startedAt = 0;

function activeMicrophone() {
  const connected = state.devices.filter(device => device.connected);
  if (state.micMode === 'fixed') {
    const fixed = connected.find(device => device.id === state.fixedMic);
    if (fixed) return fixed.name;
  }
  return state.micPriority.map(id => connected.find(device => device.id === id)).find(Boolean)?.name || connected[0]?.name || 'No microphone connected';
}
function hotkey() { return state.hotkey === 'right-option' ? '⌥' : state.hotkey === 'control-space' ? '⌃ Space' : 'fn'; }
function statusLabel() { return ({ idle: 'Ready', listening: 'Listening', transcribing: 'Transcribing', correcting: 'Refining', done: state.takeIsTest ? 'Test complete' : state.takeDelivery === 'clipboard' ? 'Copied' : 'Inserted', cancelled: 'Cancelled' })[state.status]; }
function isBusy() { return ['listening', 'transcribing', 'correcting'].includes(state.status); }
function elapsedLabel() { const seconds = Math.floor(state.elapsed); return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`; }
function notify(text) {
  clearTimeout(toastTimer);
  $('#desktop-toast').textContent = text;
  $('#desktop-toast').classList.add('visible');
  toastTimer = setTimeout(() => $('#desktop-toast').classList.remove('visible'), 2400);
}
function update(patch) { Object.assign(state, patch); render(); }
function chooseAppearance(patch) {
  update(patch);
  // Only the visual study is shareable. No mock dictation or settings enter the URL.
  const url = new URL(window.location.href);
  url.searchParams.set('theme', state.theme);
  url.searchParams.set('material', state.darkMaterial);
  window.history.replaceState(null, '', url);
}
const settingsAPI = { get state() { return state; }, update, notify, startDictation: () => toggleRecording(true), activeMicrophone };

function micButton(menu = false) {
  const listening = state.status === 'listening';
  const name = isBusy() ? state.takeMic : activeMicrophone();
  return `<button class="dictation-mic-button" data-action="test" ${state.status === 'transcribing' || state.status === 'correcting' ? 'disabled' : ''} aria-label="${listening ? 'Finish test dictation' : `Test ${esc(name)}`}" title="${listening ? 'Finish dictation' : 'Test this microphone with simulated audio'}">${icon(listening ? 'stop' : 'mic')}<span>${listening ? 'Finish dictation' : esc(name)}</span><span class="mic-button-end">${icon(listening ? 'check' : 'play')}</span></button>`;
}
function renderDictation() {
  const busyText = state.status === 'transcribing' ? 'Putting your voice into words…' : state.status === 'correcting' ? 'A little punctuation. The right names.' : '';
  return `<div class="dictation-page">
    <div class="dictation-hero"><div><h1>Hold to dictate.</h1><p class="page-intro">Your thoughts, in your own words.</p></div><button class="hold-key ${state.status === 'listening' ? 'pressed' : ''}" data-hold="true" aria-label="Hold to dictate; keyboard activation toggles recording" title="Hold this keycap, or hold Space outside a text field">${hotkey()}</button></div>
    ${micButton()}
    <div class="section-title"><h2>Last dictation</h2><div><button class="icon-button" data-action="clear-last" aria-label="Clear last dictation" title="Clear preview" ${!state.lastText || isBusy() ? 'disabled' : ''}>${icon('trash')}</button><button class="icon-button" data-action="copy-last" aria-label="Copy last dictation" title="Copy text" ${!state.lastText ? 'disabled' : ''}>${icon('copy')}</button></div></div>
    <div class="last-transcript"><div class="transcript-body ${!state.lastText ? 'empty' : ''}">${esc(state.lastText || 'Your next thought will appear here.')}</div><div class="transcript-footer"><span>${icon(isBusy() ? 'wave' : 'check')}${esc(busyText || state.lastDelivery)}</span><span class="timings">${state.lastText && !busyText ? `${state.lastDuration.toFixed(1)} s audio · ${state.processingTime} s` : ''}</span></div></div>
    <button class="history-link" data-page="history">${icon('history')}View history${icon('arrow')}</button>
    <p class="quiet-bottom">${icon('lock')}Private and on-device</p>
  </div>`;
}
function renderHistory() {
  const selected = state.history.find(entry => entry.id === state.historySelection) || state.history[0];
  return `<div class="history-page"><h1>History</h1><p>Your words have a place here.</p>
    <div class="history-list">${state.history.map(entry => `<button class="history-row" data-action="select-history" data-id="${entry.id}" aria-pressed="${entry.id === selected?.id}">${icon('wave')}<div><b>${esc(entry.text.split('\n')[0])}</b><small>${esc(entry.time)}</small></div><span>${entry.seconds.toFixed(1)} s</span></button>`).join('')}</div>
    ${selected ? `<section class="history-detail"><div class="section-title"><h2>${esc(selected.time)}</h2><button class="icon-button" data-action="copy-history" aria-label="Copy selected transcript">${icon('copy')}</button></div><div class="last-transcript"><div class="transcript-body">${esc(selected.text)}</div><div class="transcript-footer"><span>${icon('lock')}${selected.audio ? 'Original audio saved' : 'Transcript only'}</span><span>Sample archive</span></div></div><div class="history-models"><span>Whisper large-v3-turbo</span><span>${selected.correction ? 'Qwen3 4B · MLX' : 'Dictionary only'}</span></div></section>` : '<p>No transcripts yet.</p>'}
  </div>`;
}
function renderApp() {
  const scroller = $('.app-scroll');
  const samePage = $('#app-window').dataset.page === state.page;
  const previousScroll = samePage ? scroller?.scrollTop || 0 : 0;
  const drafts = samePage ? $$('[data-word-input]').map(input => [input.dataset.wordInput, input.value]) : [];
  const active = document.activeElement;
  const focusAttributes = ['id', 'data-setting', 'data-settings-action', 'data-device', 'data-word', 'data-word-input', 'data-action', 'data-page'];
  const focusKey = samePage && active?.closest('#app-window') ? focusAttributes.filter(name => active.hasAttribute(name)).map(name => `[${name}="${CSS.escape(active.getAttribute(name))}"]`).join('') : '';
  const selection = active?.matches('input[type=text]') ? [active.selectionStart, active.selectionEnd] : null;
  const pageTitle = pages.find(page => page[0] === state.page)?.[1] || 'Dictation';
  $('#app-window').hidden = !state.appOpen || state.scene === 'identity';
  $('#app-window').classList.toggle('expanded', state.expanded);
  $('#app-window').classList.toggle('sidebar-hidden', !state.sidebarOpen);
  $('#app-window').innerHTML = `<aside class="app-sidebar" ${!state.sidebarOpen ? 'inert' : ''}>
    <div class="traffic-buttons"><button data-action="close-window" aria-label="Close mock settings window">${icon('close')}</button><button data-action="close-window" aria-label="Minimize mock settings window"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M5 12h14"/></svg></button><button data-action="expand-window" aria-label="${state.expanded ? 'Restore' : 'Expand'} mock settings window"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M6 14V6h8m4 4v8h-8"/></svg></button></div>
    <div class="sidebar-brand"><img src="../concepts/sotto/icon.svg" width="39" height="39" alt=""><span>Sotto</span></div>
    <nav class="settings-navigation" aria-label="Settings pages">${pages.map(([id, label, glyph]) => `<button data-page="${id}" title="${label}" aria-label="${label}" ${state.page === id ? 'aria-current="page"' : ''}>${icon(glyph)}<span>${label}</span></button>`).join('')}</nav>
    <div class="sidebar-bottom"><div class="sidebar-status"><i class="tiny-dot"></i><span>${statusLabel()}</span></div><span class="private-label">${icon('lock')}Only on this Mac</span></div>
    </aside><div class="app-detail"><div class="app-toolbar"><span>${pageTitle}</span><button class="icon-button" data-action="sidebar" aria-label="Toggle settings sidebar" title="Toggle sidebar">${icon('sidebar')}</button></div><div class="app-scroll">${state.page === 'dictation' ? renderDictation() : state.page === 'history' ? renderHistory() : renderSettingsPage(state.page, state)}</div></div>`;
  $('.app-scroll').scrollTop = previousScroll;
  $('#app-window').dataset.page = state.page;
  drafts.forEach(([name, value]) => { const input = $(`[data-word-input="${name}"]`); if (input) input.value = value; });
  const nextFocus = focusKey ? $('#app-window').querySelector(focusKey) : null;
  if (nextFocus && !nextFocus.closest('[inert]')) { nextFocus.focus({ preventScroll: true }); if (selection && nextFocus.setSelectionRange) nextFocus.setSelectionRange(...selection); }
}
function renderMenu() {
  $('#menu-popover').hidden = !state.menuOpen;
  $('#status-item').setAttribute('aria-expanded', String(state.menuOpen));
  $('#menu-popover').innerHTML = `<div class="menu-status">${state.status === 'listening' ? '<span class="status-meter" aria-hidden="true"><i></i><i></i><i></i><i></i></span>' : '<i class="tiny-dot"></i>'}<span>${statusLabel()}</span>${state.status === 'listening' ? `<span class="menu-elapsed elapsed">${elapsedLabel()}</span>` : ''}<span class="icon-button" title="Private and on-device" aria-label="Private and on-device">${icon('lock')}</span></div>
    <h2 class="menu-hero">Hold <kbd>${hotkey()}</kbd> to dictate.</h2>
    ${micButton(true)}
    <div class="menu-preview"><p>${esc(state.lastText.replace(/\n+/g, ' ') || 'Your next thought will appear here.')}</p><button class="icon-button" data-action="copy-last" aria-label="Copy latest text from menu" title="Copy last dictation" ${!state.lastText ? 'disabled' : ''}>${icon('copy')}</button></div>
    <button class="menu-row" data-page="dictation">${icon('sidebar')}<span>Open Sotto</span><kbd>⌘ ,</kbd></button>
    <button class="menu-row" data-page="history">${icon('history')}<span>History</span><kbd>⌘ H</kbd></button>
    <div class="menu-divider"></div><button class="menu-row" data-action="quit">${icon('quit')}<span>Quit Sotto</span><kbd>⌘ Q</kbd></button>`;
}
function renderHUD() {
  const hud = $('#listening-hud');
  const shown = state.status !== 'idle' && state.scene !== 'identity';
  const hadCancelFocus = document.activeElement?.matches('.hud-cancel');
  hud.hidden = !shown;
  if (!shown) return;
  const content = {
    listening: ['Listening', `${state.takeMic} · Release to finish · Esc to cancel`, `<div class="hud-wave">${'<i></i>'.repeat(9)}</div>`],
    transcribing: ['Transcribing', 'Whisper · On this Mac · Esc to cancel', '<div class="hud-spinner"></div>'],
    correcting: ['Refining', 'Qwen3 4B · On this Mac · Esc to cancel', '<div class="hud-spinner"></div>'],
    done: [state.takeIsTest ? 'Test complete' : state.takeDelivery === 'clipboard' ? 'Copied to clipboard' : 'Inserted', state.takeIsTest ? 'Nothing was pasted.' : state.takeDelivery === 'clipboard' ? 'Saved in the prototype clipboard' : 'Inserted in your example note', icon('check')],
    cancelled: ['Dictation cancelled', 'Nothing was saved or inserted.', icon('close')],
  }[state.status];
  const description = `${content[0]}. ${content[1]}`;
  hud.setAttribute('role', 'group');
  hud.setAttribute('aria-label', 'Sotto dictation');
  hud.title = description;
  hud.innerHTML = `<span class="hud-logo" aria-hidden="true"></span><span class="hud-center" aria-hidden="true">${content[2]}</span><span class="hud-end"><span class="hud-time elapsed" aria-hidden="true">${elapsedLabel()}</span><button class="hud-cancel" data-action="${isBusy() ? 'cancel' : 'dismiss-hud'}" aria-label="${isBusy() ? 'Cancel dictation' : 'Dismiss status'}" title="${isBusy() ? 'Cancel dictation (Escape)' : 'Dismiss status'}">${icon('close')}</button></span><span class="hud-description">${esc(description)}</span>`;
  if (hadCancelFocus) hud.querySelector('.hud-cancel').focus({ preventScroll: true });
}
function renderIdentity() {
  $('#identity-view').innerHTML = `<div class="identity-hero"><div class="identity-lockup"><img src="../concepts/sotto/mark.svg" alt="Sotto ribbon S mark"><span>Sotto</span><small class="identity-caption">A quiet voice. A recognizable signature.</small></div><div class="identity-icon"><img class="identity-motif" src="../concepts/sotto/motif.svg" alt=""><img class="app-icon-art" src="../concepts/sotto/icon.svg" alt="Sotto app icon"></div></div>
    <div class="identity-specimens"><div class="identity-specimen dark-specimen"><img src="../concepts/sotto/mark.svg" alt="Sotto mark in inverse monochrome"><span>One color. Still Sotto.</span></div><div class="identity-specimen size-specimen">${[16, 24, 32].map(size => `<div><img src="../concepts/sotto/menu.svg" width="${size}" height="${size}" alt="Menu bar mark at ${size} pixels"><small>${size} px</small></div>`).join('')}<span>At home in the menu bar.</span></div><div class="identity-specimen identity-type"><b>Thought,<br>softly spoken.</b><p>An editorial wordmark.<br>A familiar system interface.</p></div></div>
    <div class="identity-footer"><div class="identity-palette">${[['Paper','#F4F0E8'], ['Plum ink','#352D3A'], ['Vermilion','#C5513E'], ['Blush','#E8D9D4']].map(([name, hex]) => `<button data-action="copy-color" data-color="${hex}" title="Copy ${name} ${hex}" aria-label="Copy ${name} ${hex}"><i style="background:${hex}"></i>${name}</button>`).join('')}</div><a class="download-assets" href="../downloads/sotto-svg-set.zip" download>${icon('download')}Download SVG assets</a></div>`;
}
function renderClipboard() {
  let sheet = $('#clipboard-sheet');
  if (!sheet) { sheet = document.createElement('aside'); sheet.id = 'clipboard-sheet'; sheet.className = 'clipboard-sheet'; $('#desktop').append(sheet); }
  sheet.hidden = !state.clipboardOpen;
  sheet.innerHTML = `<div><strong>Prototype clipboard</strong><button class="icon-button" data-action="close-clipboard" aria-label="Close clipboard preview">${icon('close')}</button></div><p>${esc(state.clipboard || 'Nothing copied yet.')}</p><button data-action="copy-prototype-clipboard" ${!state.clipboard ? 'disabled' : ''}>${icon('copy')}Copy to real clipboard</button>`;
  $('.note-hint').innerHTML = state.clipboard ? `<button class="clipboard-link" data-action="show-clipboard">${icon('copy')}View clipboard preview</button>` : '<span class="note-caret"></span> Your next thought goes here.';
}
function render() {
  document.body.dataset.theme = state.theme;
  document.body.dataset.darkMaterial = state.darkMaterial;
  $$('button[data-material]').forEach(button => button.setAttribute('aria-pressed', String(state.theme === 'dark' && button.dataset.material === state.darkMaterial)));
  $('#material-description').textContent = state.theme === 'dark' ? darkMaterials[state.darkMaterial] : 'Choose a dark finish to compare. Light mode stays as it is.';
  $('#desktop').dataset.appearance = state.theme;
  $('#desktop').dataset.status = state.status;
  $('#desktop').hidden = state.scene === 'identity';
  $('#identity-view').hidden = state.scene !== 'identity';
  $('#simulation-toolbar').hidden = state.scene === 'identity';
  $('#menubar-app').textContent = state.appOpen ? 'Sotto' : 'Notes';
  $('#notes-window').inert = state.appOpen;
  $('#desktop-record').hidden = state.appOpen;
  $$('[data-scene]').forEach(button => { const selected = button.dataset.scene === state.scene; button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1; });
  $$('button[data-theme]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.theme === state.theme)));
  $('#prototype-panel').setAttribute('aria-labelledby', `scene-${state.scene}`);
  $('#sample-select').value = state.sample;
  $('#delivery-select').value = state.delivery;
  $('#sample-select').disabled = isBusy();
  $('#delivery-select').disabled = isBusy();
  renderApp(); renderMenu(); renderHUD(); renderClipboard();
}
function clearTimers() { clearInterval(captureTimer); clearTimeout(phaseTimer); captureTimer = null; phaseTimer = null; }
function chooseScene(scene) {
  if (scene === 'identity' && isBusy()) cancelDictation(true);
  state.scene = scene;
  state.appOpen = scene === 'settings';
  state.menuOpen = scene === 'menu';
  state.clipboardOpen = false;
  render();
  $('#prototype-panel').focus({ preventScroll: true });
}
function openPage(page) {
  state.page = page; state.appOpen = true; state.scene = 'settings'; state.menuOpen = false;
  render(); $('.app-scroll').scrollTop = 0;
}
function startDictation({ test = false, holdKind = null } = {}) {
  if (isBusy()) return;
  if (!state.devices.some(device => device.connected)) { notify('Connect a microphone in the Microphone preview first.'); return; }
  clearTimers();
  if (state.scene === 'identity') chooseScene('listening');
  state.status = 'listening'; state.elapsed = 0; state.holdKind = holdKind; state.takeIsTest = test;
  state.takeMic = activeMicrophone();
  state.takeCorrection = state.correction;
  state.takeDelivery = state.delivery;
  state.takeHistory = state.keepHistory;
  state.takeAudio = state.keepAudio;
  state.takeWords = structuredClone(state.words);
  state.takeSample = state.sample;
  const editor = $('#mock-editor');
  state.selection = { start: editor.selectionStart, end: editor.selectionEnd };
  if (state.correction) state.modelLoaded = true;
  startedAt = performance.now();
  render();
  captureTimer = setInterval(() => {
    state.elapsed = (performance.now() - startedAt) / 1000;
    $$('.elapsed').forEach(element => element.textContent = elapsedLabel());
    if (state.elapsed >= 30) finishDictation();
  }, 100);
}
function toggleRecording(test = false) { if (state.status === 'listening') finishDictation(); else startDictation({ test }); }
function applyDictionary(text, words) {
  return words.reduce((result, word) => [...word.aliases, word.term].reduce((output, alias) => {
    const literal = alias.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return output.replace(new RegExp(`(?<![\\p{L}\\p{N}_])${literal}(?![\\p{L}\\p{N}_])`, 'giu'), () => word.term);
  }, result), text);
}
function finishDictation() {
  if (state.status !== 'listening') return;
  state.elapsed = Math.max(.4, (performance.now() - startedAt) / 1000);
  state.holdKind = null; clearTimers(); state.status = 'transcribing'; render();
  phaseTimer = setTimeout(() => {
    if (!state.takeCorrection) { completeDictation(); return; }
    state.status = 'correcting'; render();
    phaseTimer = setTimeout(completeDictation, 850);
  }, 1000);
}
function completeDictation() {
  const sample = samples[state.takeSample];
  let text = state.takeCorrection && sample.polished ? sample.polished : sample.raw;
  text = applyDictionary(text, state.takeWords);
  if (state.takeCorrection && state.takeSample === 'names') text = text.replace('. then', '. Then');
  state.lastText = text; state.lastDuration = state.elapsed;
  state.processingTime = state.takeCorrection ? '1.9' : '1.0';
  if (state.takeIsTest) {
    state.lastDelivery = 'Test complete. Nothing pasted.';
  } else if (state.takeDelivery === 'clipboard') {
    state.clipboard = text;
    state.lastDelivery = 'Copied to prototype clipboard';
  } else {
    const start = Math.min(state.selection.start, state.noteText.length);
    const end = Math.min(state.selection.end, state.noteText.length);
    const before = state.noteText.slice(0, start);
    const after = state.noteText.slice(end);
    const lastLine = before.split('\n').at(-1);
    const startsList = /^\d+[.)]\s/.test(text);
    const followsList = /^\d+[.)]\s/.test(lastLine);
    const paragraphBreak = before && !before.endsWith('\n') && (startsList || followsList);
    const prefix = paragraphBreak ? '\n\n' : before && !/\s$/.test(before) && /^[\p{L}\p{N}]/u.test(text) ? ' ' : '';
    const suffix = after && !/^\s/.test(after) && /[\p{L}\p{N}]/u.test(after[0]) ? ' ' : '';
    const insertion = prefix + text + suffix;
    state.noteText = before + insertion + after;
    $('#mock-editor').value = state.noteText;
    $('#mock-editor').setSelectionRange(start + insertion.length, start + insertion.length);
    state.lastDelivery = 'Inserted at your cursor';
  }
  if (state.takeHistory) {
    const entry = { id: crypto.randomUUID(), text, time: 'Just now', seconds: state.elapsed, correction: state.takeCorrection, audio: state.takeAudio };
    state.history = [entry, ...state.history]; state.historySelection = entry.id;
  }
  state.status = 'done'; render();
  phaseTimer = setTimeout(() => { state.status = 'idle'; render(); }, 2600);
}
function cancelDictation(silent = false) {
  clearTimers(); state.holdKind = null;
  state.status = silent ? 'idle' : 'cancelled'; render();
  if (!silent) phaseTimer = setTimeout(() => { state.status = 'idle'; render(); }, 1600);
}
async function copyText(text, description = 'Text copied.') {
  if (!text) return;
  try { await navigator.clipboard.writeText(text); notify(description); }
  catch { notify('Clipboard access is unavailable in this browser. You can select the text instead.'); }
}

document.addEventListener('click', event => {
  const element = event.target.closest('button, a[data-action]');
  if (element?.disabled) return;
  if (element?.dataset.scene) return chooseScene(element.dataset.scene);
  if (element?.dataset.theme) return chooseAppearance({ theme: element.dataset.theme });
  if (element?.dataset.material) return chooseAppearance({ theme: 'dark', darkMaterial: element.dataset.material });
  if (element?.dataset.page) return openPage(element.dataset.page);
  if (element?.dataset.settingsAction) return handleSettingsAction(element.dataset.settingsAction, element, settingsAPI);
  if (element?.dataset.hold && event.detail === 0) return toggleRecording();
  const action = element?.dataset.action;
  if (action === 'toggle-menu') { state.menuOpen = !state.menuOpen; renderMenu(); return; }
  if (action === 'record') return toggleRecording();
  if (action === 'test') return toggleRecording(true);
  if (action === 'finish') return finishDictation();
  if (action === 'cancel') return cancelDictation();
  if (action === 'dismiss-hud') { clearTimers(); return update({ status: 'idle' }); }
  if (action === 'sidebar') return update({ sidebarOpen: !state.sidebarOpen });
  if (action === 'expand-window') return update({ expanded: !state.expanded });
  if (action === 'close-window') return update({ appOpen: false });
  if (action === 'copy-last') return copyText(state.lastText);
  if (action === 'clear-last') return update({ lastText: '', lastDelivery: 'Ready for your next thought.' });
  if (action === 'select-history') return update({ historySelection: element.dataset.id });
  if (action === 'copy-history') return copyText(state.history.find(entry => entry.id === state.historySelection)?.text);
  if (action === 'show-clipboard') return update({ clipboardOpen: true, menuOpen: false });
  if (action === 'close-clipboard') return update({ clipboardOpen: false });
  if (action === 'copy-prototype-clipboard') return copyText(state.clipboard);
  if (action === 'copy-color') return copyText(element.dataset.color, `${element.dataset.color} copied.`);
  if (action === 'quit') { cancelDictation(true); update({ appOpen: false, menuOpen: false }); notify('Sotto closed in the mock. Choose a surface above to reopen it.'); return; }
  if (action === 'reset') {
    clearTimers();
    const { theme, darkMaterial, scene } = state;
    Object.assign(state, makeState(), { theme, darkMaterial, scene, appOpen: scene === 'settings', menuOpen: scene === 'menu' });
    $('#mock-editor').value = state.noteText; $('#mock-editor').setSelectionRange(state.noteText.length, state.noteText.length);
    render(); notify('Prototype reset.'); return;
  }
  if (state.menuOpen && !event.target.closest('#menu-popover, #status-item')) { state.menuOpen = false; renderMenu(); }
});
document.addEventListener('change', event => {
  if (event.target.matches('[data-setting]')) handleSettingsChange(event.target, settingsAPI);
  if (event.target.id === 'sample-select') state.sample = event.target.value;
  if (event.target.id === 'delivery-select') state.delivery = event.target.value;
});
$('#mock-editor').addEventListener('input', event => state.noteText = event.target.value);
document.addEventListener('pointerdown', event => {
  if (event.target.closest('[data-hold]') && event.button === 0) { event.preventDefault(); startDictation({ holdKind: 'pointer' }); }
  else if (event.target.closest('#desktop') && !event.target.closest('button,input,textarea,select,a')) $('#prototype-panel').focus({ preventScroll: true });
});
document.addEventListener('pointerup', () => { if (state.holdKind === 'pointer') finishDictation(); });
document.addEventListener('pointercancel', () => { if (state.holdKind === 'pointer') cancelDictation(); });
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    if (isBusy()) cancelDictation();
    else if (state.clipboardOpen) update({ clipboardOpen: false });
    else if (state.menuOpen) update({ menuOpen: false });
    else if (state.status !== 'idle') { clearTimers(); update({ status: 'idle' }); }
    return;
  }
  const editable = event.target.closest('input,textarea,select,button,a,[contenteditable=true]');
  if (event.code === 'Space' && !editable && !event.repeat && !event.metaKey && !event.ctrlKey && !event.altKey && state.scene !== 'identity') {
    event.preventDefault(); startDictation({ holdKind: 'keyboard' });
  }
});
document.addEventListener('keyup', event => { if (event.code === 'Space' && state.holdKind === 'keyboard') { event.preventDefault(); finishDictation(); } });
window.addEventListener('blur', () => { if (state.holdKind) cancelDictation(); });
document.addEventListener('visibilitychange', () => { if (document.hidden && state.holdKind) cancelDictation(); });
$$('[role=tab]').forEach((button, index, tabs) => button.addEventListener('keydown', event => {
  const next = event.key === 'ArrowRight' ? (index + 1) % tabs.length : event.key === 'ArrowLeft' ? (index + tabs.length - 1) % tabs.length : event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : -1;
  if (next >= 0) { event.preventDefault(); chooseScene(tabs[next].dataset.scene); tabs[next].focus(); }
}));
$('#mock-editor').setSelectionRange(state.noteText.length, state.noteText.length);
renderIdentity(); render();
