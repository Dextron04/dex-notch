/* The long read, made to move. Three.js draws one idea: three threads of work braid into a single amber aperture as you read.
   GSAP choreographs the rest. Premium motion: 0.5-0.9s, expo/power3 out, no overshoot, nothing over 500ms of stagger.
   Everything here is decoration: the page is complete without it, and prefers-reduced-motion gets one still frame.
   Source for static/fx.js. Build with fx/build.sh. */
import { gsap } from "gsap";
import { WebGLRenderer, Scene, PerspectiveCamera, Group, BufferGeometry, BufferAttribute, Points, ShaderMaterial, AdditiveBlending, NormalBlending,
         TorusGeometry, Mesh, MeshBasicMaterial, PlaneGeometry, Color } from "three";

const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
const root = document.documentElement;

/* ---------------------------------------------------------------- the scene */
const VERT = `
attribute vec3 aSeed; attribute float aPhase; attribute float aStream;
uniform float uTime, uMerge, uPulse, uPx, uSize;
varying float vA; varying float vS;
const float R = 5.2, RING = 0.9;
void main() {
  float t = fract(aPhase + uTime * (0.045 + aSeed.z * 0.02));
  float e = t * t * (3.0 - 2.0 * t);
  float a = mix(aStream * 2.0944 + 0.6, 0.6, uMerge * 0.92);       // three directions, braiding into one as you read
  float ang = a + e * (2.4 + aSeed.x * 0.5);
  float r = mix(R, RING, e);
  vec3 p = vec3(cos(ang) * r, sin(ang) * r * 0.62, (aSeed.y - 0.5) * 1.2 * (1.0 - e * 0.5));
  p += (aSeed - 0.5) * 1.8 * (1.0 - e) * (1.0 - uMerge * 0.8);
  p *= 1.0 + uPulse * 0.06;
  vec4 mv = modelViewMatrix * vec4(p, 1.0);
  gl_Position = projectionMatrix * mv;
  gl_PointSize = uSize * uPx * (0.5 + aSeed.x) * (6.0 / -mv.z);
  vA = smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.88, 1.0, t)) * (0.35 + 0.65 * e);
  vS = aStream;
}`;
const FRAG = `
uniform float uMerge, uPulse, uLight; varying float vA; varying float vS;
void main() {
  float d = length(gl_PointCoord - 0.5); if (d > 0.5) discard;
  vec3 col = vS < 0.5 ? vec3(1.0, 0.69, 0.35) : (vS < 1.5 ? vec3(0.95, 0.92, 0.87) : vec3(0.56, 0.52, 1.0));
  col = mix(col, vec3(1.0, 0.69, 0.35), uMerge * 0.85);
  col = mix(col, col * 0.45, uLight);                                // on a light page the same threads are ink, not light
  gl_FragColor = vec4(col, vA * smoothstep(0.5, 0.0, d) * (0.55 + uPulse * 0.4));
}`;
const GLOW = `
uniform float uGlow; varying vec2 vUv;
void main() { float d = length(vUv - 0.5) * 2.0; gl_FragColor = vec4(1.0, 0.69, 0.35, exp(-d * d * 3.2) * uGlow); }`;

function makeScene(canvas) {
  let renderer;
  try { renderer = new WebGLRenderer({ canvas, alpha: true, antialias: false, powerPreference: "low-power" }); } catch { return null; }
  renderer.setClearColor(0x000000, 0);
  const scene = new Scene(), cam = new PerspectiveCamera(50, 1, 0.1, 50), group = new Group();
  cam.position.z = 7; scene.add(group);

  const n = innerWidth < 700 ? 900 : 2400, g = new BufferGeometry(), seed = new Float32Array(n * 3), phase = new Float32Array(n), stream = new Float32Array(n);
  for (let i = 0; i < n; i++) { seed.set([Math.random(), Math.random(), Math.random()], i * 3); phase[i] = Math.random(); stream[i] = i % 3; }
  g.setAttribute("position", new BufferAttribute(new Float32Array(n * 3), 3));   // unused: the shader places every point
  g.setAttribute("aSeed", new BufferAttribute(seed, 3)); g.setAttribute("aPhase", new BufferAttribute(phase, 1)); g.setAttribute("aStream", new BufferAttribute(stream, 1));
  const u = { uTime: { value: 0 }, uMerge: { value: 0 }, uPulse: { value: 0 }, uPx: { value: 1 }, uSize: { value: 5 }, uLight: { value: 0 } };
  const mat = new ShaderMaterial({ vertexShader: VERT, fragmentShader: FRAG, uniforms: u, transparent: true, depthWrite: false, blending: AdditiveBlending });
  const points = new Points(g, mat); points.frustumCulled = false; group.add(points);

  const ringMat = new MeshBasicMaterial({ color: new Color("#ffb059"), transparent: true, opacity: 0.55 });
  const ring = new Mesh(new TorusGeometry(0.9, 0.008, 6, 160), ringMat), halo = new Mesh(new TorusGeometry(1.06, 0.005, 6, 160), ringMat.clone());
  halo.material.opacity = 0.18; ring.scale.y = halo.scale.y = 0.62; group.add(ring, halo);
  const glowMat = new ShaderMaterial({ vertexShader: "varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
    fragmentShader: GLOW, uniforms: { uGlow: { value: 0.1 } }, transparent: true, depthWrite: false, blending: AdditiveBlending });
  const glow = new Mesh(new PlaneGeometry(6, 6), glowMat); glow.position.z = -0.2; glow.scale.y = 0.62; group.add(glow);

  const state = { merge: 0, pulse: 0 }, light = matchMedia("(prefers-color-scheme: light)");
  const theme = () => {
    const l = light.matches;
    u.uLight.value = l ? 1 : 0; mat.blending = glowMat.blending = l ? NormalBlending : AdditiveBlending; mat.needsUpdate = glowMat.needsUpdate = true;
    ringMat.color.set(l ? "#c2410c" : "#ffb059"); halo.material.color.copy(ringMat.color);
  };
  const size = () => {
    const w = innerWidth, h = innerHeight; renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75)); renderer.setSize(w, h, false);
    cam.aspect = w / h; cam.updateProjectionMatrix(); u.uPx.value = renderer.getPixelRatio();
    const vh = 2 * Math.tan(25 * Math.PI / 180) * 7, vw = vh * cam.aspect;
    if (cam.aspect > 1.15) { group.position.set(vw * 0.26, 0, 0); group.scale.setScalar(1); }       // beside the text on a wide screen
    else { group.position.set(0, vh * 0.3, 0); group.scale.setScalar(0.8); }                         // above it on a narrow one
  };
  const draw = (t) => {
    u.uTime.value = t; u.uMerge.value = state.merge; u.uPulse.value = state.pulse;
    const k = 1 + state.pulse * 0.12; ring.scale.x = halo.scale.x = k; ring.scale.y = halo.scale.y = 0.62 * k;
    glowMat.uniforms.uGlow.value = (0.1 + state.merge * 0.22 + state.pulse * 0.18) * (light.matches ? 0.5 : 1);
    renderer.render(scene, cam);
  };
  theme(); size();
  light.addEventListener("change", theme); addEventListener("resize", size);
  return { state, group, ring, halo, draw, size, theme, dispose() { light.removeEventListener("change", theme); removeEventListener("resize", size); renderer.dispose(); g.dispose(); mat.dispose(); } };
}

/* ---------------------------------------------------------------- the page */
function words(el) {                       // each word in a clipping box, so it can rise into place
  const out = [], walk = (n) => [...n.childNodes].forEach((c) => {
    if (c.nodeType === 3) {
      const f = document.createDocumentFragment();
      c.textContent.split(/(\s+)/).forEach((t) => {
        if (!t) return;
        if (/^\s+$/.test(t)) { f.append(t); return; }
        const o = document.createElement("span"), i = document.createElement("span"); o.className = "w"; i.textContent = t; o.append(i); f.append(o); out.push(i);
      });
      c.replaceWith(f);
    } else if (c.nodeType === 1) walk(c);
  });
  walk(el); return out;
}

function figure() {                        // the diagram draws itself once, when it is on screen: people, then wires, then the session, then its lines
  const svg = $(".figure svg"); if (!svg) return;
  const wires = $$(".f-wire path", svg), nodes = $$(".f-node", svg), hub = $(".f-hub", svg), hubText = $$(".f-label text", svg).filter((t) => t.getAttribute("x") === "308");
  wires.forEach((p) => { const l = p.getTotalLength(); gsap.set(p, { strokeDasharray: l, strokeDashoffset: l }); });
  const tl = gsap.timeline({ paused: true, defaults: { ease: "power3.out" } });
  tl.from(nodes, { autoAlpha: 0, x: -14, duration: 0.5, stagger: 0.08 })
    .to(wires, { strokeDashoffset: 0, duration: 0.7, stagger: 0.1, ease: "power2.inOut" }, "-=0.25")
    .from(hub, { autoAlpha: 0, scale: 0.94, svgOrigin: "397 140", duration: 0.5 }, "-=0.35")
    .from(hubText, { autoAlpha: 0, y: 6, duration: 0.45, stagger: 0.07 }, "-=0.2");
  new IntersectionObserver((es, io) => { if (es.some((e) => e.isIntersecting)) { tl.play(); io.disconnect(); } }, { threshold: 0.4 }).observe(svg);
}

const mm = gsap.matchMedia();
const canvas = $(".scene-bg");

mm.add("(prefers-reduced-motion: no-preference)", () => {
  root.classList.add("fx-on");
  const cleanups = [() => root.classList.remove("fx-on")];

  const h1 = $(".read-head h1"), ws = h1 ? words(h1) : [];
  gsap.timeline({ defaults: { ease: "expo.out" } })
    .from(".read-head .eyebrow", { autoAlpha: 0, y: 12, duration: 0.6 })
    .from(ws, { yPercent: 115, duration: 0.9, stagger: 0.045 }, "<0.08")
    .from(".standfirst, .byline", { autoAlpha: 0, y: 16, duration: 0.7, stagger: 0.1 }, "-=0.55")
    .from(".toc", { autoAlpha: 0, x: -12, duration: 0.6 }, "<0.1");
  figure();

  const s = canvas && makeScene(canvas);
  if (s) {
    const { state } = s, merge = gsap.quickTo(state, "merge", { duration: 0.9, ease: "power3.out" });
    const rx = gsap.quickTo(s.group.rotation, "x", { duration: 1.2, ease: "power3.out" }), ry = gsap.quickTo(s.group.rotation, "y", { duration: 1.2, ease: "power3.out" });
    const scroll = () => { const h = root.scrollHeight - innerHeight; merge(h > 0 ? Math.min(1, scrollY / h) : 0); };
    const move = (e) => { if (e.pointerType === "touch") return; ry((e.clientX / innerWidth - 0.5) * 0.35); rx((e.clientY / innerHeight - 0.5) * 0.25); };
    const pulse = () => gsap.fromTo(state, { pulse: 1 }, { pulse: 0, duration: 1.4, ease: "power3.out", overwrite: true });
    const tap = (e) => { if (!e.target.closest("a, button, input, summary")) pulse(); };
    const tick = (t) => { if (!document.hidden) s.draw(t); };
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) pulse(); }), { rootMargin: "0px 0px -60% 0px" });
    $$(".prose h2").forEach((h) => io.observe(h));
    addEventListener("scroll", scroll, { passive: true }); addEventListener("pointermove", move, { passive: true }); addEventListener("pointerdown", tap);
    gsap.ticker.add(tick); scroll();
    gsap.from(state, { pulse: 1, duration: 1.8, ease: "power3.out", delay: 0.2 });      // the aperture opens as the headline lands
    gsap.fromTo(canvas, { autoAlpha: 0 }, { autoAlpha: 1, duration: 1.2, ease: "power2.out" });
    cleanups.push(() => { removeEventListener("scroll", scroll); removeEventListener("pointermove", move); removeEventListener("pointerdown", tap); gsap.ticker.remove(tick); io.disconnect(); s.dispose(); });
  }
  return () => cleanups.forEach((f) => f());
});

mm.add("(prefers-reduced-motion: reduce)", () => {     // one still frame, redrawn only when the window changes
  const s = canvas && makeScene(canvas); if (!s) return;
  s.state.merge = 0.4; const redraw = () => { s.size(); s.draw(4); };
  redraw(); addEventListener("resize", redraw);
  return () => { removeEventListener("resize", redraw); s.dispose(); };
});
