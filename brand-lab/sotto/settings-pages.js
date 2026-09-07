const escape = value => String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);

const paths = {
  microphone: '<rect x="6" y="2" width="4" height="8" rx="2"/><path d="M3.5 7.5V8a4.5 4.5 0 0 0 9 0v-.5M8 12.5V15M5.5 15h5"/>',
  headphones: '<path d="M2 9V8a6 6 0 0 1 12 0v1"/><rect x="1.5" y="8" width="3.5" height="6" rx="1.5"/><rect x="11" y="8" width="3.5" height="6" rx="1.5"/>',
  display: '<rect x="1.5" y="2" width="13" height="9" rx="1.5"/><path d="M8 11v3M5 14h6"/>',
  up: '<path d="m4 10 4-4 4 4"/>',
  down: '<path d="m4 6 4 4 4-4"/>',
  plus: '<path d="M8 3v10M3 8h10"/>',
  close: '<path d="m4 4 8 8m0-8-8 8"/>',
  check: '<path d="m3 8 3.2 3.2L13 4.5"/>',
  chip: '<rect x="4" y="4" width="8" height="8" rx="2"/><path d="M6 1v3m4-3v3M6 12v3m4-3v3M1 6h3m-3 4h3m8-4h3m-3 4h3"/>',
  play: '<path d="m6 3 6 5-6 5V3Z"/>',
  lock: '<rect x="3.5" y="7" width="9" height="7" rx="2"/><path d="M5.5 7V4.5a2.5 2.5 0 0 1 5 0V7M8 10v1"/>',
};

const icon = (name, className = '') => `<svg class="pref-icon ${className}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.45" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.microphone}</svg>`;
const switchControl = (setting, checked, label, disabled = false) => `<input class="pref-switch" type="checkbox" data-setting="${setting}" aria-label="${escape(label)}" ${checked ? 'checked' : ''} ${disabled ? 'disabled' : ''}>`;
const heading = (title, subtitle) => `<header class="settings-page-heading"><h1>${title}</h1><p>${subtitle}</p></header>`;
const group = (title, contents, footnote = '') => `<section class="pref-section">${title ? `<h2>${title}</h2>` : ''}<div class="pref-group">${contents}</div>${footnote ? `<p class="pref-footnote">${footnote}</p>` : ''}</section>`;
const row = (label, control, detail = '') => `<div class="pref-row"><div class="pref-label"><span>${label}</span>${detail ? `<small>${detail}</small>` : ''}</div><div class="pref-control">${control}</div></div>`;
const select = (setting, value, options, label, disabled = false) => `<select class="pref-select" data-setting="${setting}" aria-label="${escape(label)}" ${disabled ? 'disabled' : ''}>${options.map(option => `<option value="${escape(option.value)}" ${String(value) === String(option.value) ? 'selected' : ''} ${option.disabled ? 'disabled' : ''}>${escape(option.label)}</option>`).join('')}</select>`;

export const initialSettings = {
  devices: [
    { id: 'studio-display', name: 'Studio Display Microphone', connected: true, detail: 'Built into your display' },
    { id: 'macbook', name: 'MacBook Pro Microphone', connected: true, detail: 'Built into your Mac' },
    { id: 'airpods', name: 'AirPods Pro', connected: false, detail: 'Bluetooth' },
    { id: 'usb-mic', name: 'USB Microphone', connected: false, detail: 'USB audio' },
  ],
  micPriority: ['studio-display', 'usb-mic', 'airpods', 'macbook'],
  micMode: 'priority',
  fixedMic: 'studio-display',
  words: [
    { id: 'word-codex', term: 'Codex', aliases: ['code x', 'codecks'] },
    { id: 'word-minimax', term: 'MiniMax', aliases: ['mini max'] },
    { id: 'word-sotto', term: 'Sotto', aliases: ['soto'] },
    { id: 'word-raycast', term: 'Raycast', aliases: ['ray cast'] },
  ],
  correction: true,
  modelLoaded: true,
  keepHistory: true,
  keepAudio: true,
  hotkey: 'fn',
  unloadAfter: '5',
  launchAtLogin: false,
  dictionaryAdding: false,
};

function activeDevice(state) {
  const connected = state.devices.filter(device => device.connected);
  if (state.micMode === 'fixed') {
    const fixed = connected.find(device => device.id === state.fixedMic);
    if (fixed) return fixed;
  }
  return state.micPriority.map(id => connected.find(device => device.id === id)).find(Boolean) || connected[0];
}

const settingsBusy = state => ['listening', 'transcribing', 'correcting'].includes(state.status);

function renderMicrophone(state) {
  const active = activeDevice(state);
  const inputOptions = state.devices.map(device => ({ value: device.id, label: device.name + (device.connected ? '' : ' · Offline'), disabled: !device.connected }));
  if (!active) inputOptions.unshift({ value: '', label: 'No microphone connected', disabled: true });
  const selectedInput = !active ? '' : state.micMode === 'priority' ? active.id : state.fixedMic;
  const ordered = state.micPriority.map(id => state.devices.find(device => device.id === id)).filter(Boolean);
  const deviceRows = ordered.map((device, index) => {
    const current = active?.id === device.id;
    const symbol = device.id === 'airpods' ? 'headphones' : device.id === 'studio-display' ? 'display' : 'microphone';
    return `<div class="pref-device-row ${device.connected ? '' : 'is-disconnected'}">
      <span class="pref-priority" aria-label="Priority ${index + 1}">${index + 1}</span>
      <span class="pref-device-icon">${icon(symbol)}</span>
      <div class="pref-device-name"><span>${escape(device.name)}</span><small>${current ? '<span class="pref-active-dot"></span>In use' : escape(device.detail)}</small></div>
      <button class="pref-connection ${device.connected ? 'is-connected' : ''}" data-settings-action="toggle-connection" data-device="${escape(device.id)}" aria-label="${device.connected ? 'Disconnect' : 'Connect'} ${escape(device.name)}" aria-pressed="${device.connected}" title="Simulate ${device.connected ? 'disconnecting' : 'connecting'} this microphone">${device.connected ? 'Connected' : 'Connect'}</button>
      <div class="pref-reorder" aria-label="Reorder ${escape(device.name)}">
        <button class="pref-icon-button" data-settings-action="move-mic-up" data-device="${escape(device.id)}" aria-label="Move ${escape(device.name)} up" ${index === 0 ? 'disabled' : ''}>${icon('up')}</button>
        <button class="pref-icon-button" data-settings-action="move-mic-down" data-device="${escape(device.id)}" aria-label="Move ${escape(device.name)} down" ${index === ordered.length - 1 ? 'disabled' : ''}>${icon('down')}</button>
      </div>
    </div>`;
  }).join('');
  return heading('Microphone', 'Your voice, from the right input.') +
    group('', row('Choose input', select('micMode', state.micMode, [{ value: 'priority', label: 'By priority' }, { value: 'fixed', label: 'Preferred microphone' }], 'How to choose a microphone')) +
      row(state.micMode === 'fixed' ? 'Preferred microphone' : 'Microphone', select('fixedMic', selectedInput, inputOptions, 'Selected microphone', state.micMode === 'priority' || !active))) +
    group('Input priority', deviceRows, state.micMode === 'fixed' ? 'Uses your preferred microphone when connected, then falls back to this priority order.' : 'The highest connected microphone is used for your next dictation. Connect a device here to try it.') +
    `<button class="pref-mic-test" data-settings-action="test-microphone" ${active ? '' : 'disabled'}>${icon('microphone')}<span>Test ${escape(active?.name || 'microphone')}</span>${icon('play')}</button>`;
}

function renderDictionary(state) {
  const words = state.words.map(word => `<div class="pref-word-row"><div class="pref-word"><span>${escape(word.term)}</span><small>${word.aliases.length ? word.aliases.map(escape).join(' · ') : 'Preferred spelling'}</small></div><button class="pref-icon-button" data-settings-action="remove-word" data-word="${escape(word.id)}" aria-label="Remove ${escape(word.term)}" title="Remove word">${icon('close')}</button></div>`).join('');
  const editor = state.dictionaryAdding ? `<div class="pref-word-editor">
    <div class="pref-word-fields"><label>Word<input type="text" data-word-input="term" maxlength="64" placeholder="e.g. Anthropic" autocomplete="off" spellcheck="false"></label><label>Sounds like <span>Optional</span><input type="text" data-word-input="aliases" maxlength="256" placeholder="e.g. an thropic" autocomplete="off" spellcheck="false"></label></div>
    <div class="pref-editor-actions"><span>Separate alternate spellings with commas.</span><button class="pref-button" data-settings-action="cancel-word">Cancel</button><button class="pref-button is-primary" data-settings-action="save-word">Add word</button></div>
  </div>` : `<div class="pref-add-word"><button class="pref-button" data-settings-action="show-word-editor">${icon('plus')}Add a word</button><span>Names, tools, and words you use often.</span></div>`;
  return heading('Dictionary', 'Your vocabulary, understood.') +
    group('', row('Personal dictionary', '<span class="pref-enabled">' + icon('check') + 'Always on</span>', 'Your vocabulary is applied to every dictation.')) +
    `<section class="pref-section"><div class="pref-section-title"><h2>Your words</h2><span>${state.words.length} ${state.words.length === 1 ? 'word' : 'words'}</span></div><div class="pref-group pref-word-list">${words || '<div class="pref-empty-words">Add your first word below.</div>'}</div><div class="pref-editor-slot">${editor}</div></section>`;
}

function renderModels(state) {
  const memoryStatus = state.modelLoaded ? 'Loaded' : 'Unloaded';
  const busy = settingsBusy(state);
  const guardTitle = busy ? 'Available when this dictation is finished.' : '';
  return heading('Models', 'A little intelligence. All on your Mac.') +
    group('Speech recognition', row('Whisper large-v3-turbo', `<span class="pref-enabled">${icon('check')}Available</span>`, 'Converts your voice into text.')) +
    group('Text correction', row('Polish your dictation', `<span class="pref-guard" title="${guardTitle}">${switchControl('correction', state.correction, 'Text correction', busy)}</span>`, 'Punctuation, formatting, and harder words.') +
      row('Qwen3 4B', '<span class="pref-secondary">MLX · 4-bit</span>', 'Runs locally on Apple silicon.')) +
    group('Memory', row('Text model', `<span class="pref-memory-state">${state.modelLoaded ? '<span class="pref-active-dot"></span>' : ''}${memoryStatus}</span>`) +
      row(state.modelLoaded ? 'Ready for your next dictation.' : 'Loads when you need it.', `<span class="pref-guard" title="${guardTitle}"><button class="pref-button" data-settings-action="toggle-model-memory" ${!state.correction || busy ? 'disabled' : ''}>${state.modelLoaded ? 'Unload from memory' : 'Load into memory'}</button></span>`) +
      row('Unload when idle', select('unloadAfter', state.unloadAfter, [{ value: '1', label: 'After 1 minute' }, { value: '5', label: 'After 5 minutes' }, { value: '15', label: 'After 15 minutes' }, { value: '30', label: 'After 30 minutes' }, { value: 'never', label: 'Keep loaded' }], 'Unload model when idle')), 'Models stay on disk when unloaded. Only their working memory is released.') +
    `<p class="pref-private-note">${icon('lock')}Your words stay on this Mac.</p>`;
}

function renderGeneral(state) {
  return heading('General', 'Make room for your own rhythm.') +
    group('Dictation', row('Hold to dictate', select('hotkey', state.hotkey, [{ value: 'fn', label: 'Fn / Globe' }, { value: 'right-option', label: 'Right Option' }, { value: 'control-space', label: 'Control + Space' }], 'Dictation shortcut')) +
      row('Start Sotto at login', switchControl('launchAtLogin', state.launchAtLogin, 'Start Sotto at login'))) +
    group('Local history', row('Save transcripts', switchControl('keepHistory', state.keepHistory, 'Save transcripts'), 'Keep your words and their details.') +
      row('Keep original audio', switchControl('keepAudio', state.keepAudio, 'Keep original audio', !state.keepHistory), 'Listen back or transcribe again.') +
      row('Archive folder', '<span class="pref-folder-path">~/.sotto/transcripts</span>'), 'You control what stays. New dictations follow these settings.') +
    `<div class="pref-about"><span class="pref-about-wordmark">Sotto</span><span>Thought, softly spoken.</span><span class="pref-about-local">${icon('lock')}Private and on-device</span></div>`;
}

export function renderSettingsPage(page, state) {
  const renders = { microphone: renderMicrophone, dictionary: renderDictionary, models: renderModels, general: renderGeneral };
  return renders[page] ? `<div class="settings-pane">${renders[page](state)}</div>` : '';
}

export function handleSettingsAction(action, element, api) {
  const state = api.state;
  if (action === 'move-mic-up' || action === 'move-mic-down') {
    const priority = [...state.micPriority];
    const index = priority.indexOf(element.dataset.device);
    const next = index + (action === 'move-mic-up' ? -1 : 1);
    if (index >= 0 && next >= 0 && next < priority.length) {
      [priority[index], priority[next]] = [priority[next], priority[index]];
      api.update({ micPriority: priority });
    }
    return true;
  }
  if (action === 'toggle-connection') {
    const device = state.devices.find(item => item.id === element.dataset.device);
    if (!device) return true;
    api.update({ devices: state.devices.map(item => item.id === device.id ? { ...item, connected: !item.connected } : item) });
    api.notify(`${device.name} ${device.connected ? 'disconnected' : 'connected'}.`);
    return true;
  }
  if (action === 'test-microphone') {
    api.startDictation();
    return true;
  }
  if (action === 'show-word-editor' || action === 'cancel-word') {
    api.update({ dictionaryAdding: action === 'show-word-editor' });
    return true;
  }
  if (action === 'save-word') {
    const editor = element.closest('.pref-word-editor');
    const term = editor?.querySelector('[data-word-input="term"]')?.value.trim();
    const aliases = [...new Set((editor?.querySelector('[data-word-input="aliases"]')?.value || '').split(',').map(value => value.trim()).filter(Boolean))];
    if (!term) { api.notify('Add a word first.'); editor?.querySelector('[data-word-input="term"]')?.focus(); return true; }
    if (state.words.some(word => word.term.toLocaleLowerCase() === term.toLocaleLowerCase())) { api.notify('That word is already in your dictionary.'); return true; }
    api.update({ words: [...state.words, { id: `word-${globalThis.crypto?.randomUUID?.() || Date.now()}`, term, aliases }], dictionaryAdding: false });
    api.notify(`${term} added to your dictionary.`);
    return true;
  }
  if (action === 'remove-word') {
    api.update({ words: state.words.filter(word => word.id !== element.dataset.word) });
    api.notify('Word removed.');
    return true;
  }
  if (action === 'toggle-model-memory') {
    if (state.correction && !settingsBusy(state)) {
      const wasLoaded = state.modelLoaded;
      api.update({ modelLoaded: !wasLoaded });
      api.notify(wasLoaded ? 'Text model unloaded.' : 'Text model ready.');
    }
    return true;
  }
  return false;
}

export function handleSettingsChange(element, api) {
  const setting = element.dataset.setting;
  if (!setting) return false;
  if (setting === 'correction' && settingsBusy(api.state)) {
    element.checked = api.state.correction;
    return true;
  }
  const toggles = ['correction', 'keepHistory', 'keepAudio', 'launchAtLogin'];
  const selections = ['micMode', 'fixedMic', 'hotkey', 'unloadAfter'];
  if (toggles.includes(setting)) {
    const value = element.checked;
    api.update(setting === 'correction' ? { correction: value, modelLoaded: value } : { [setting]: value });
    return true;
  }
  if (selections.includes(setting)) {
    api.update({ [setting]: element.value });
    return true;
  }
  return false;
}
