/* Dex Notch hosted service: progressive enhancement only. Every page works without this file. */
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const live = $('#live');
  const say = (t) => { if (live) { live.textContent = ''; setTimeout(() => { live.textContent = t; }, 50); } };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');

  /* copy buttons: <button data-copy-from="id"> or data-copy="text" */
  document.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-copy-from], [data-copy]');
    if (!b) return;
    const text = (b.dataset.copy ?? document.getElementById(b.dataset.copyFrom)?.textContent ?? '').trim();
    const label = b.dataset.label || b.textContent;
    b.dataset.label = label;
    try {
      await navigator.clipboard.writeText(text);
      b.setAttribute('data-copied', ''); b.textContent = 'Copied'; say('Copied to clipboard');
    } catch {
      const el = document.getElementById(b.dataset.copyFrom);   // no clipboard permission: select it so ⌘C works
      if (el) { const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
      say('Press Command C to copy');
    }
    setTimeout(() => { b.removeAttribute('data-copied'); b.textContent = label; }, 1800);
  });

  /* dialogs: invoker commands where the browser has them, a tiny shim where it does not */
  if (!('commandForElement' in HTMLButtonElement.prototype)) {
    document.addEventListener('click', (e) => {
      const b = e.target.closest('button[command][commandfor]');
      const d = b && document.getElementById(b.getAttribute('commandfor'));
      if (!d) return;
      const c = b.getAttribute('command');
      if (c === 'show-modal') d.showModal(); else if (c === 'close' || c === 'request-close') d.close();
    });
  }
  if (!('closedBy' in HTMLDialogElement.prototype)) {          // light dismiss where closedby is missing (Safari)
    const outside = (e, d) => { const r = d.getBoundingClientRect(); return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom; };
    $$('dialog[closedby="any"]').forEach((d) => {
      let down = false;
      d.addEventListener('pointerdown', (e) => { down = outside(e, d); });
      d.addEventListener('pointerup', (e) => { if (down && outside(e, d)) d.close(); });
    });
  }

  /* typed confirmations: native validity message until the text matches */
  $$('input[data-must-equal]').forEach((i) => {
    const want = i.dataset.mustEqual.trim().toLowerCase();
    const check = () => i.setCustomValidity(i.value.trim().toLowerCase() === want ? '' : 'Type your email address exactly to confirm.');
    i.addEventListener('input', check); check();
  });

  /* one submit per form: disable after a valid submit, never before (so validation can still speak) */
  document.addEventListener('submit', (e) => {
    const f = e.target.closest('form[data-once]');
    if (!f || e.defaultPrevented) return;
    const b = $('button[type="submit"], button:not([type])', f);
    if (b) setTimeout(() => { b.setAttribute('aria-busy', 'true'); b.disabled = true; }, 0);
  });
  addEventListener('pageshow', (e) => { if (e.persisted) $$('form[data-once] button[aria-busy]').forEach((b) => { b.disabled = false; b.removeAttribute('aria-busy'); }); });

  /* menubar clock */
  const clock = $$('[data-clock]');
  if (clock.length) {
    const fmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' });
    const tick = () => clock.forEach((c) => { c.textContent = fmt.format(new Date()); });
    tick(); setInterval(tick, 20000);
  }

  /* the notch demo: idle -> next scene, on a loop you can pause, choose from, or leave off entirely */
  const notch = $('[data-notch]');
  if (!notch) return;
  $$('[data-needs-js]').forEach((el) => el.removeAttribute('hidden'));
  const scenes = $$('[data-scene-id]', notch);
  const chips = $$('[data-scene-chip]');
  const toggle = $('[data-scene-toggle]');
  const HOLD = 4800;
  let index = 0, run = 0, timer = 0, playing = !reduced.matches, visible = true;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const wait = () => (reduced.matches ? 0 : 420);

  function fit(scene) {                                           // block-size can't animate to `auto`, so measure the scene and hand CSS a number
    notch.style.setProperty('--h', Math.ceil(scene.scrollHeight) + 'px');
  }
  function label() {
    if (!toggle) return;
    toggle.textContent = playing ? 'Pause' : 'Play';
    toggle.setAttribute('aria-label', playing ? 'Pause the notch demo' : 'Play the notch demo');
  }
  async function show(n, { instant = false } = {}) {
    const mine = ++run; clearTimeout(timer);
    index = (n + scenes.length) % scenes.length;
    chips.forEach((c, i) => c.setAttribute('aria-pressed', String(i === index)));
    if (!instant) { notch.dataset.scene = 'idle'; notch.style.setProperty('--h', '1.9rem'); await sleep(wait()); if (mine !== run) return; }
    scenes.forEach((s, i) => { s.hidden = i !== index; });
    notch.dataset.scene = scenes[index].dataset.sceneId;
    fit(scenes[index]);
    schedule();
  }
  function schedule() {
    clearTimeout(timer);
    if (playing && visible && !document.hidden) timer = setTimeout(() => show(index + 1), HOLD);
  }
  chips.forEach((c, i) => c.addEventListener('click', () => { playing = false; label(); show(i, { instant: reduced.matches }); }));
  toggle?.addEventListener('click', () => { playing = !playing; label(); schedule(); });
  document.addEventListener('visibilitychange', schedule);
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; schedule(); }, { threshold: 0.25 }).observe(notch);
  reduced.addEventListener('change', () => { if (reduced.matches) { playing = false; label(); } });
  addEventListener('resize', () => fit(scenes[index]));
  document.fonts?.ready.then(() => fit(scenes[index]));
  label(); show(0, { instant: true });
})();
