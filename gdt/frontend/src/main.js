import './style.css';
import { t, setCurrentLang, getCurrentLang } from './i18n.js';

import {
  GetModules,
  GetLang,
  GetSudoState,
  GetSubscriptionURL,
  GetStatus,
  RunModule,
  CancelModule,
  SetLang,
  StartProxy,
  StopProxy,
  IsProxyRunning,
  VerifySudo,
  SetSudoPassword,
  SetSubscriptionURL,
  OpenTavern,
  GetVersion,
  CheckUpdate,
  LaunchUpdater,
} from '../wailsjs/go/main/App.js';

import { EventsOn, BrowserOpenURL } from '../wailsjs/runtime/runtime.js';
const sbLinks = document.querySelectorAll('.sb-links a[data-url]');
console.log('found links:', sbLinks.length);
sbLinks.forEach(a => {
  console.log('binding link:', a.dataset.url);
  a.addEventListener('click', (e) => {
    e.preventDefault();
    console.log('clicked:', a.dataset.url);
    BrowserOpenURL(a.dataset.url);
  });
});

// ---- DOM refs ---------------------------------------------------------------

const sidebar    = document.getElementById('sidebar');
const sidebarSec = document.getElementById('sidebar-section');
const log        = document.getElementById('log');
const phase      = document.getElementById('phase');
const pct        = document.getElementById('pct');
const barFill    = document.getElementById('bar-fill');
const sudoDot    = document.getElementById('sudo-dot');
const sudoLabel  = document.getElementById('sudo-label');
const btnSudo    = document.getElementById('btn-sudo');
const cancelBar  = document.getElementById('cancel-bar');
const btnCancel  = document.getElementById('btn-cancel');
const btnLang    = document.getElementById('btn-lang');

// ---- state ------------------------------------------------------------------

let running         = false;
let proxyOn         = false;
let subscriptionURL = '';

// ---- timestamp helper -------------------------------------------------------

function ts() {
  return new Date().toLocaleTimeString(getCurrentLang(), {
    hour: '2-digit', minute: '2-digit', second: '2-digit'
  });
}

// ---- log helpers ------------------------------------------------------------

function logLine(text, cls = 'info') {
  const el = document.createElement('div');
  el.className = 'log-line log-' + cls;
  el.textContent = ts() + ' ' + text;
  log.appendChild(el);
  log.scrollTop = log.scrollHeight;
}

function clearLog() {
  log.innerHTML = '';
  phase.textContent = t('phaseIdle');
  pct.textContent = '—';
  setProgress(0);
}

function setProgress(n) {
  n = Math.min(100, Math.max(0, Number(n) || 0));
  barFill.style.width = n + '%';
  barFill.classList.toggle('done', n >= 100);
  pct.textContent = n > 0 ? n + '%' : '—';
}

// ---- modal ------------------------------------------------------------------

let _modalResolve = null;

const modalOverlay = document.getElementById('modal-overlay');
const modalTitle   = document.getElementById('modal-title');
const modalHint    = document.getElementById('modal-hint');
const modalMsg     = document.getElementById('modal-msg');
const modalInput   = document.getElementById('modal-input');
const modalError   = document.getElementById('modal-error');
const modalCancel  = document.getElementById('modal-cancel');
const modalOk      = document.getElementById('modal-ok');

// opts: { title, message?, placeholder?, type? }
// If placeholder provided → input dialog → resolves string|null
// If no placeholder      → alert dialog  → resolves true
function showModal({ title, message = '', placeholder = '', type = 'text' }) {
  return new Promise(resolve => {
    _modalResolve = resolve;
    modalTitle.textContent = title;
    modalHint.textContent  = '';
    modalError.textContent = '';

    if (message) {
      modalMsg.textContent   = message;
      modalMsg.style.display = '';
    } else {
      modalMsg.style.display = 'none';
    }

    if (placeholder) {
      modalInput.placeholder    = placeholder;
      modalInput.type           = type;
      modalInput.value          = '';
      modalInput.style.display  = '';
      modalCancel.style.display = '';
    } else {
      modalInput.style.display  = 'none';
      modalCancel.style.display = 'none';
    }

    modalOverlay.style.display = 'flex';
    if (placeholder) setTimeout(() => modalInput.focus(), 30);
  });
}

function _closeModal(value) {
  modalOverlay.style.display = 'none';
  modalCancel.style.display  = '';
  if (_modalResolve) { _modalResolve(value); _modalResolve = null; }
}

modalOk.addEventListener('click', () =>
  _closeModal(modalInput.style.display !== 'none' ? modalInput.value : true)
);
modalCancel.addEventListener('click', () => _closeModal(null));
modalInput.addEventListener('keydown', e => {
  if (e.key === 'Enter')  _closeModal(modalInput.value);
  if (e.key === 'Escape') _closeModal(null);
});
modalOverlay.addEventListener('click', e => {
  if (e.target === modalOverlay) _closeModal(null);
});

// ---- static UI strings ------------------------------------------------------

function refreshStaticUI() {
  document.getElementById('console-title').textContent = t('logTitle');
  document.getElementById('btn-copy').textContent      = t('btnCopy');
  document.getElementById('btn-export').textContent    = t('btnExport');
  document.getElementById('btn-clear').textContent     = t('btnClear');
  document.getElementById('btn-cancel').textContent    = t('btnCancel');
  document.getElementById('btn-tavern').textContent    = t('tavernBtn');
  document.getElementById('modal-cancel').textContent  = t('cancel');
  document.getElementById('modal-ok').textContent      = t('ok');
  phase.textContent = t('phaseIdle');
  const themeLabel = document.getElementById('theme-label');
  if (themeLabel) themeLabel.textContent = currentTheme === 'dark' ? t('themeLight') : t('themeDark');
}

// ---- module events ----------------------------------------------------------

function handleMsg(msg) {
  switch (msg.type) {
    case 'LOG':      logLine(msg.payload); break;
    case 'PROGRESS': setProgress(msg.payload); break;
    case 'STATE':    phase.textContent = msg.payload; break;
    case 'DONE':
      setRunning(false);
      if (msg.payload !== '0') {
        logLine('exit: ' + msg.payload, 'err');
      } else {
        setProgress(100);
        phase.textContent = t('phaseDone');
      }
      break;
  }
}

// ---- running state ----------------------------------------------------------

function setRunning(state) {
  running = state;
  if (state) cancelBar.classList.add('visible');
  else cancelBar.classList.remove('visible');
  document.querySelectorAll('.action-btn').forEach(btn => {
    btn.disabled = state;
  });
}

// ---- icon map ---------------------------------------------------------------

const iconMap = {
  'arrow-up': '↑',
  'grid':     '⊞',
  'play':     '▶',
  'shield':   '⊕',
  'vpn':      '⇌',
};
function iconFor(name) { return iconMap[name] || '●'; }

// ---- render sidebar ---------------------------------------------------------

function renderSidebar(modules) {
  document.querySelectorAll('.action-btn').forEach(b => b.remove());
  document.querySelectorAll('.proxy-wrap').forEach(b => b.remove());

  const tavernBtn = document.getElementById('btn-tavern');
  const lang = getCurrentLang();

  modules.forEach((mod, i) => {
    if (mod.ID === 'proxy') return;

    const label = lang === 'ru' ? mod.LabelRu : mod.LabelEn;
    const desc  = lang === 'ru' ? mod.DescRu  : mod.DescEn;

    const btn = document.createElement('button');
    btn.className = 'action-btn' + (i === 0 ? ' primary' : '');
    btn.dataset.id = mod.ID;
    btn.innerHTML = `
      <div class="btn-icon">${iconFor(mod.Icon)}</div>
      <div class="btn-text">
        <div class="btn-label">${label}</div>
        <div class="btn-desc">${desc}</div>
      </div>
    `;
    btn.addEventListener('click', () => {
      if (running) return;
      clearLog();
      setRunning(true);
      document.querySelectorAll('.action-btn').forEach(b =>
        b.classList.toggle('primary', b.dataset.id === mod.ID)
      );
      RunModule(mod.ID).catch(err => {
        logLine(t('error') + ': ' + err, 'err');
        setRunning(false);
      });
    });

    sidebar.insertBefore(btn, tavernBtn);
  });

  sidebarSec.textContent = t('actions');
  renderProxyBlock();
}

// ---- proxy block (button + optional gear) -----------------------------------

function renderProxyBlock() {
  const old = document.getElementById('proxy-wrap');
  if (old) old.remove();

  const tavernBtn = document.getElementById('btn-tavern');
  const wrap = document.createElement('div');
  wrap.className = 'proxy-wrap';
  wrap.id = 'proxy-wrap';

  const btn = document.createElement('button');
  btn.className = 'action-btn' + (proxyOn ? ' primary' : '');
  btn.id = 'proxy-btn';
  btn.innerHTML = `
    <div class="btn-icon">${iconFor('vpn')}</div>
    <div class="btn-text">
      <div class="btn-label">${proxyOn ? t('proxyActive') : t('proxyLabel')}</div>
      <div class="btn-desc">${proxyOn ? t('proxyStopHint') : t('proxyDesc')}</div>
    </div>
  `;
  btn.addEventListener('click', toggleProxy);
  wrap.appendChild(btn);

  if (subscriptionURL) {
    const gear = document.createElement('button');
    gear.className = 'proxy-gear';
    gear.id = 'proxy-gear';
    gear.title = t('proxyUrlChange');
    gear.textContent = '⚙';
    gear.addEventListener('click', openUrlModal);
    wrap.appendChild(gear);
  }

  sidebar.insertBefore(wrap, tavernBtn);
}

// ---- proxy toggle -----------------------------------------------------------

async function toggleProxy() {
  clearLog();
  if (proxyOn) {
    try {
      await StopProxy();
      proxyOn = false;
      renderProxyBlock();
      logLine(t('proxyStopped'), 'ok');
    } catch (err) {
      logLine('proxy stop: ' + err, 'err');
    }
    return;
  }

  if (subscriptionURL) {
    try {
      await StartProxy();
      proxyOn = true;
      renderProxyBlock();
      logLine(t('proxyStarted'), 'ok');
    } catch (err) {
      await showModal({ title: t('error'), message: String(err) });
    }
    return;
  }

  const url = await showModal({
    title:       t('proxyUrlTitle'),
    placeholder: t('proxyUrlPlaceholder'),
    type:        'text',
  });
  if (!url) return;
  try {
    await SetSubscriptionURL(url);
    subscriptionURL = url;
    await StartProxy();
    proxyOn = true;
    renderProxyBlock();
    logLine(t('proxyStarted'), 'ok');
  } catch (err) {
    await showModal({ title: t('error'), message: String(err) });
  }
}

async function openUrlModal() {
  const url = await showModal({
    title:       t('proxyUrlTitle'),
    placeholder: subscriptionURL,
    type:        'text',
  });
  if (!url) return;
  try {
    await SetSubscriptionURL(url);
    subscriptionURL = url;
    renderProxyBlock();
  } catch (err) {
    logLine('url: ' + err, 'err');
  }
}

// ---- sudo state -------------------------------------------------------------

function updateSudo(state) {
  if (state === 'active') {
    sudoDot.style.background = '#3d6b3d';
    sudoLabel.textContent    = t('sudoActive');
    sudoLabel.style.color    = '#3d6b3d';
    btnSudo.style.display    = 'none';
  } else if (state === 'has') {
    sudoDot.style.background = '#c47a3a';
    sudoLabel.textContent    = t('sudoInactive');
    sudoLabel.style.color    = '#c47a3a';
    btnSudo.style.display    = 'inline-block';
    btnSudo.textContent      = t('btnEnterPass');
  } else {
    sudoDot.style.background = '#3d2e1a';
    sudoLabel.textContent    = t('sudoNone');
    sudoLabel.style.color    = '#4a3520';
    btnSudo.style.display    = 'inline-block';
    btnSudo.textContent      = t('btnCreatePass');
  }
}

// ---- sudo prompt ------------------------------------------------------------

async function sudoPrompt() {
  const state = await GetSudoState().catch(() => 'none');
  if (state === 'active') return;

  const isNone = state === 'none';

  const overlay = document.createElement('div');
  overlay.className = 'sudo-overlay';

  overlay.innerHTML = `
    <div class="sudo-box">
      <div class="sudo-title">${isNone ? t('sudoTitleCreate') : t('sudoTitleEnter')}</div>
      <div class="sudo-hint">${isNone ? t('sudoHintCreate') : t('sudoHintEnter')}</div>
      <input id="sudo-pass-input" class="sudo-input" type="password" placeholder="${t('sudoPlaceholder')}" />
      <div id="sudo-pass-error" class="sudo-error"></div>
      <div class="sudo-btns">
        <button id="sudo-pass-cancel" class="sudo-cancel">${t('cancel')}</button>
        <button id="sudo-pass-ok" class="sudo-ok">${t('ok')}</button>
      </div>
    </div>`;

  document.body.appendChild(overlay);
  const input     = overlay.querySelector('#sudo-pass-input');
  const error     = overlay.querySelector('#sudo-pass-error');
  const btnOk     = overlay.querySelector('#sudo-pass-ok');
  const btnCancelEl = overlay.querySelector('#sudo-pass-cancel');
  setTimeout(() => input.focus(), 30);

  btnCancelEl.onclick = () => document.body.removeChild(overlay);

  btnOk.onclick = async () => {
    const pass = input.value;
    if (!pass) return;
    error.textContent = '';
    btnOk.disabled    = true;
    btnOk.textContent = '...';
    try {
      if (isNone) {
        await SetSudoPassword(pass);
      } else {
        await VerifySudo(pass);
      }
      document.body.removeChild(overlay);
      const newState = await GetSudoState().catch(() => 'none');
      updateSudo(newState);
    } catch (e) {
      const msg = String(e);
      if (msg.includes('exit status 1')) {
        error.textContent = t('sudoWrongPass');
      } else if (msg.includes('exit status 5')) {
        error.textContent = t('sudoLocked');
      } else {
        error.textContent = t('sudoError');
      }
      input.value = '';
      input.focus();
      btnOk.disabled    = false;
      btnOk.textContent = t('ok');
    }
  };

  input.addEventListener('keydown', e => {
    if (e.key === 'Enter')  btnOk.click();
    if (e.key === 'Escape') btnCancelEl.click();
  });
}

btnSudo.addEventListener('click', sudoPrompt);

// ---- console toolbar --------------------------------------------------------

document.getElementById('btn-clear').addEventListener('click', clearLog);

document.getElementById('btn-copy').addEventListener('click', () => {
  const text = Array.from(log.querySelectorAll('.log-line'))
    .map(el => el.textContent).join('\n');
  navigator.clipboard.writeText(text).then(() => logLine(t('copied'), 'ok'));
});

document.getElementById('btn-export').addEventListener('click', () => {
  logLine(t('exportNotImpl'), 'info');
});

btnCancel.addEventListener('click', () => {
  CancelModule().catch(console.error);
});

// ---- theme toggle -----------------------------------------------------------

let currentTheme = localStorage.getItem('gdt-theme') || 'dark';

function applyTheme(theme) {
  currentTheme = theme;
  document.documentElement.setAttribute('data-theme', theme === 'light' ? 'light' : '');
  localStorage.setItem('gdt-theme', theme);
  const label = document.getElementById('theme-label');
  if (label) label.textContent = theme === 'dark' ? t('themeLight') : t('themeDark');
}

document.getElementById('btn-theme').addEventListener('click', () => {
  applyTheme(currentTheme === 'dark' ? 'light' : 'dark');
});

applyTheme(currentTheme);

// ---- lang toggle ------------------------------------------------------------

btnLang.addEventListener('click', async () => {
  const newLang = getCurrentLang() === 'ru' ? 'en' : 'ru';
  setCurrentLang(newLang);
  btnLang.textContent = newLang.toUpperCase();
  await SetLang(newLang).catch(console.error);
  refreshStaticUI();
  const [mods, sudoState] = await Promise.all([
    GetModules().catch(() => []),
    GetSudoState().catch(() => 'none'),
  ]);
  renderSidebar(mods || []);
  updateSudo(sudoState);
});

// ---- statusbar --------------------------------------------------------------

function updateStatusBar(s) {
  // OS
  document.getElementById('sb-os').innerHTML = `
    <div><span class="sb-dot ok"></span><span class="sb-label">${t('sbOS')}</span></div>
    <div class="sb-value">${s.OSBranch || '—'} · ${s.OSVersion || '—'}</div>
    <div class="sb-value">${s.OSBuildID || ''}</div>`;

  // Flatpak
  const fDot = s.FlatpakUpdates > 0 ? 'warn' : 'ok';
  const fVal = s.FlatpakUpdates > 0
    ? `${s.FlatpakUpdates} ${t('sbFlatpakUpdates')}`
    : t('sbFlatpakOk');
  document.getElementById('sb-flatpak').innerHTML = `
    <div><span class="sb-dot ${fDot}"></span><span class="sb-label">${t('sbFlatpak')}</span></div>
    <div class="sb-value">${fVal}</div>`;

  // OpenH264
  const hDot = s.OpenH264 ? 'ok' : 'warn';
  const hVal = s.OpenH264 ? `${t('sbOpenH264Ok')} · ${s.OpenH264Ver}` : t('sbOpenH264Missing');
  document.getElementById('sb-openh264').innerHTML = `
    <div><span class="sb-dot ${hDot}"></span><span class="sb-label">${t('sbOpenH264')}</span></div>
    <div class="sb-value">${hVal}</div>`;

  // Tunnel
  const tDot = s.TunnelActive ? 'ok' : 'dim';
  const tVal = s.TunnelActive
    ? `${t('sbTunnelActive')}${s.TunnelCountry ? ' · ' + s.TunnelCountry : ''}`
    : t('sbTunnelInactive');
  document.getElementById('sb-tunnel').innerHTML = `
    <div><span class="sb-dot ${tDot}"></span><span class="sb-label">${t('sbTunnel')}</span></div>
    <div class="sb-value">${tVal}</div>`;
}

async function refreshStatus() {
  try {
    const s = await GetStatus();
    updateStatusBar(s);
  } catch (e) {
    // non-fatal
  }
}

// ---- tavern -----------------------------------------------------------------

document.getElementById('btn-tavern').addEventListener('click', () => {
  OpenTavern().catch(err => logLine('tavern: ' + err, 'err'));
});

// ---- greetings --------------------------------------------------------------

const greetings = {
  ru: [
    'У Каджита есть товар, если у тебя есть монеты, друг!',
    'Странник выглядит усталым. Может, отдохнёшь у костра?',
    'Каджит не кусается. Обычно.',
    'Этот Каджит слышал о твоих подвигах. Впечатляет.',
    'Хочешь купить что-нибудь? Нет? Просто смотришь? Хорошо.',
  ],
  en: [
    'Khajiit has wares, if you have coin.',
    'You look tired, traveller. Rest by the fire.',
    'Khajiit does not bite. Usually.',
    'This one has heard of your exploits. Impressive.',
    'Interested in a purchase? No? Just looking? That is fine.',
  ],
};

function randomGreeting(lang) {
  const list = greetings[lang] || greetings.ru;
  return list[Math.floor(Math.random() * list.length)];
}

// ---- update checker ---------------------------------------------------------

const mikePhrases = {
  ru: [
    'Обновление вышло. Я в этом уверен. Честно.',
    'Новая версия. Она лучше. Намного. Доверяй мне.',
    'Это обновление изменит всё. Ну, или что-то изменит.',
    'Я бы обновился. Если бы был тобой. А я не ты.',
    'Новая версия вышла. Это правда. На этот раз.',
  ],
  en: [
    "Update is out. I'm sure of it. Honest.",
    "New version. It's better. Much better. Trust me.",
    'This update will change everything. Or something.',
    'I would update. If I were you. Which I\'m not.',
    "New version is out. It's true. This time.",
  ],
};

function showUpdateModal(latest, lang) {
  if (document.getElementById('update-modal')) return;

  const phrases = mikePhrases[lang] || mikePhrases.ru;
  const phrase = phrases[Math.floor(Math.random() * phrases.length)];

  const overlay = document.createElement('div');
  overlay.className = 'sudo-overlay';
  overlay.id = 'update-modal';
  overlay.innerHTML = `
    <div class="sudo-box" style="width:360px">
      <div class="sudo-title">
        ${lang === 'ru' ? 'Доступно обновление ' : 'Update available '} ${latest}
      </div>
      <div class="sudo-hint" style="font-style:italic;margin-bottom:20px">
        "${phrase}"
      </div>
      <div class="sudo-hint">
        ${lang === 'ru'
          ? 'GDT закроется и запустится установщик обновления.'
          : 'GDT will close and launch the updater.'}
      </div>
      <div class="sudo-btns">
        <button class="sudo-cancel" id="upd-cancel">
          ${lang === 'ru' ? 'Позже' : 'Later'}
        </button>
        <button class="sudo-ok" id="upd-ok">
          ${lang === 'ru' ? 'Обновить' : 'Update'}
        </button>
      </div>
    </div>`;

  overlay.querySelector('#upd-cancel').onclick = () =>
    document.body.removeChild(overlay);
  overlay.querySelector('#upd-ok').onclick = () => LaunchUpdater();

  document.body.appendChild(overlay);
}

async function checkAndShowUpdate() {
  const current = await GetVersion().catch(() => '');
  const ver = document.getElementById('ver');
  ver.textContent = current;

  const latest = await CheckUpdate().catch(() => '');
  if (!latest || latest === current) return;

  const lang = getCurrentLang();
  ver.style.cursor = 'pointer';
  ver.style.color = 'var(--accent)';
  ver.textContent = current + ' → ' + latest + ' ↑';

  // Показываем попап сразу при старте
  showUpdateModal(latest, lang);

  // И по клику на версию тоже
  ver.addEventListener('click', () => showUpdateModal(latest, lang));
}

// ---- init -------------------------------------------------------------------

async function init() {
  try {
    EventsOn('module:msg', handleMsg);
    EventsOn('status:update', s => updateStatusBar(s));

    const [modules, l, sudoState, proxyState, subURL] = await Promise.all([
      GetModules(),
      GetLang(),
      GetSudoState(),
      IsProxyRunning(),
      GetSubscriptionURL(),
    ]);

    setCurrentLang(l || 'ru');
    proxyOn         = !!proxyState;
    subscriptionURL = subURL || '';

    refreshStaticUI();
    btnLang.textContent = getCurrentLang().toUpperCase();
    renderSidebar(modules || []);
    updateSudo(sudoState || 'none');
    logLine(randomGreeting(getCurrentLang()), 'info');
    refreshStatus();
    checkAndShowUpdate();

  } catch (err) {
    logLine('init error: ' + err, 'err');
  }
}

init();
