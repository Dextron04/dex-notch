/* Passkeys: sign in with Touch ID, and open the vault with the same touch. Progressive enhancement: every page works without this file, and the buttons
   stay hidden in a browser that cannot do passkeys. The secret a passkey makes for the vault (its PRF output) goes to the server like a passphrase would: over https, once. */
(() => {
  if (!window.PublicKeyCredential || !navigator.credentials) return;
  const enc = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const dec = (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0));
  const post = async (url, body) => {
    const r = await fetch(url, { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw Object.assign(new Error(j.error || "That didn't work. Try again."), { status: r.status });
    return j;
  };
  // the password manager keeps its own list: tell it when a passkey is gone or unknown here (Chrome and Safari; elsewhere this does nothing)
  const forget = (rpId, credentialId) => PublicKeyCredential.signalUnknownCredential?.({ rpId, credentialId }).catch(() => {});
  let autofill = new AbortController();
  const prfOf = (cred) => { const f = cred.getClientExtensionResults?.().prf?.results?.first; return f ? enc(f) : ''; };
  const prfExt = (opts) => { const e = opts.extensions?.prf?.eval; if (e) e.first = dec(e.first); return opts; };

  const loginOptions = async () => {
    const o = await post('/webauthn/login/options'), pk = prfExt(o.publicKey);
    pk.challenge = dec(pk.challenge); return pk;
  };
  const finishLogin = async (cred, pk, b) => {
    const r = cred.response;
    try {
      const j = await post('/webauthn/login/finish', { id: enc(cred.rawId), clientDataJSON: enc(r.clientDataJSON), authenticatorData: enc(r.authenticatorData), signature: enc(r.signature),
        prf: prfOf(cred), fields: JSON.parse(b.dataset.fields || '{}') });
      location.assign(j.next);
    } catch (e) { if (e.status === 404) forget(pk.rpId, enc(cred.rawId)); throw e; }
  };
  // passkeys offered in the email field's own autofill list: no button needed
  const conditional = async (b) => {
    try {
      const caps = await PublicKeyCredential.getClientCapabilities?.();
      if (!(caps ? caps.conditionalGet === true : await PublicKeyCredential.isConditionalMediationAvailable?.())) return;
      const pk = await loginOptions();
      await finishLogin(await navigator.credentials.get({ publicKey: pk, mediation: 'conditional', signal: autofill.signal }), pk, b);
    } catch (e) { /* cancelled, replaced by the button, or not available: nothing to say */ }
  };

  const unlockWith = async (ids) => {                      // the passkey's own secret, via a normal sign-in prompt
    const o = await post('/webauthn/login/options');
    const pk = prfExt(o.publicKey); pk.challenge = dec(pk.challenge);
    pk.allowCredentials = ids.map((id) => ({ type: 'public-key', id: dec(id) }));
    const cred = await navigator.credentials.get({ publicKey: pk });
    return { id: enc(cred.rawId), prf: prfOf(cred) };
  };

  const run = {
    async login(b) {
      autofill.abort(); autofill = new AbortController();      // the autofill request and the button must not both be waiting
      const pk = await loginOptions();
      try { await finishLogin(await navigator.credentials.get({ publicKey: pk }), pk, b); }
      catch (e) { if (e.status !== 404) conditional(b); throw e; }          // cancelled: offer the autofill again
    },
    async create(b, setup) {
      const o = await post('/webauthn/register/options');
      const pk = prfExt(o.publicKey); pk.challenge = dec(pk.challenge); pk.user.id = dec(pk.user.id);
      pk.excludeCredentials = pk.excludeCredentials.map((c) => ({ ...c, id: dec(c.id) }));
      const cred = await navigator.credentials.create({ publicKey: pk }), r = cred.response;
      let prf = prfOf(cred);
      if (!prf) { try { prf = (await unlockWith([enc(cred.rawId)])).prf; } catch { prf = ''; } }     // some authenticators only give the secret on a second touch
      const pass = document.getElementById('pk-pass');
      let j;
      try { j = await post('/webauthn/register/finish', { clientDataJSON: enc(r.clientDataJSON), attestationObject: enc(r.attestationObject), prf, setup,
        passphrase: pass ? pass.value : '', next: b.dataset.next || '', name: /Mac/.test(navigator.platform) ? 'Touch ID on this Mac' : 'Passkey' }); }
      catch (e) { forget(pk.rp.id, enc(cred.rawId)); throw e; }
      location.assign(j.next);
    },
    setup(b) { return run.create(b, true); },
    add(b) { return run.create(b, false); },
    async unlock(b) {
      const form = b.closest('form'), got = await unlockWith(JSON.parse(b.dataset.creds || '[]'));
      if (!got.prf) throw new Error("This passkey can't open your notes here. Use your passphrase.");
      form.elements.credential.value = got.id; form.elements.prf.value = got.prf;
      const pass = form.elements.passphrase; if (pass) pass.required = false;
      form.requestSubmit(b.dataset.submit ? form.querySelector(b.dataset.submit) : undefined);
    },
  };

  const signIn = document.querySelector('[data-passkey="login"]');
  if (signIn) conditional(signIn);
  const sync = document.querySelector('[data-passkey-sync]');
  if (sync) PublicKeyCredential.signalAllAcceptedCredentials?.({ rpId: sync.dataset.rp, userId: sync.dataset.user, allAcceptedCredentialsIds: JSON.parse(sync.dataset.ids || '[]') }).catch(() => {});

  document.querySelectorAll('[data-passkey]').forEach((b) => {
    b.hidden = false;
    const msg = b.nextElementSibling?.matches('[data-passkey-msg]') ? b.nextElementSibling : null;
    b.addEventListener('click', async () => {
      if (msg) msg.hidden = true;
      b.disabled = true;
      try { await run[b.dataset.passkey](b); }
      catch (e) {
        b.disabled = false;
        if (e.name === 'NotAllowedError' || e.name === 'AbortError') return;      // the person cancelled
        if (msg) { msg.textContent = e.message || "That didn't work."; msg.hidden = false; }
      }
    });
  });
})();
