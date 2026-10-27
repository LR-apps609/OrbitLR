// Suoni discreti in stile radio, come sul Mac: un clic passando da uno spicchio all'altro, uno scatto
// quando confermi, un piccolo «ding» a lavoro finito (solo con OrbitLR in primo piano), un suono quando
// lasci cadere dei file e uno se un lavoro non riesce. Si spengono nelle Opzioni → Aspetto.

import { store } from "./util.js";

const VOLUME = { tick: 0.22, select: 0.38, done: 0.45, fail: 0.35, drop: 0.3 };
const COPIES = { tick: 4, select: 2, done: 2, fail: 2, drop: 2 };
const pools = {};
const next = {};
let lastTick = 0;

export const soundsOn = () => store.get("sounds", true) !== false;
export const setSounds = (on) => store.set("sounds", !!on);

/** Carica i suoni una volta sola: così il primo clic non ha ritardi. */
export function prepareSounds() {
  for (const k of Object.keys(VOLUME)) {
    if (pools[k]) continue;
    pools[k] = Array.from({ length: COPIES[k] }, () => {
      const a = new Audio(`sounds/${k}.wav`);
      a.preload = "auto";
      a.volume = VOLUME[k];
      return a;
    });
    next[k] = 0;
  }
}

/** Suona un effetto: «tick», «select», «done», «fail», «drop». */
export function play(effect) {
  if (!soundsOn()) return;
  if (effect === "done" && !document.hasFocus()) return;
  if (effect === "tick") {
    // Muovendo il mouse in fretta non diventa un ronzio
    const now = performance.now();
    if (now - lastTick < 45) return;
    lastTick = now;
  }
  prepareSounds();
  const pool = pools[effect];
  if (!pool) return;
  const a = pool[next[effect] % pool.length];
  next[effect]++;
  try {
    a.currentTime = 0;
    const p = a.play();
    if (p && p.catch) p.catch(() => {});
  } catch {}
}
