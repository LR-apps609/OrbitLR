// 2.0.1 · Le scelte di base per chi installa adesso, senza cambiare niente a chi usa già OrbitLR.
// Niente DOM qui: si prova con node (Tools/prova-avvio-windows.mjs).

/** Quanti giorni dopo l'installazione si vede «Lo sapevi?» all'avvio. */
export const TIP_DAYS = 3;
const DAY = 86400e3;

/**
 * Da chiamare all'avvio, prima di tutto il resto. `store`: { get(k, d), set(k, v) }.
 * `existing`: OrbitLR era già stata usata (cronologia, controllo degli aggiornamenti, benvenuto visto).
 * - «installedAt»: il giorno dell'installazione (0 = prima della 2.0.1, data sconosciuta).
 * - «shelf»: la linguetta è spenta per chi installa adesso; chi la aveva (anche senza averla mai toccata) la tiene.
 */
export function firstRunDefaults(store, existing, now = Date.now()) {
  if (store.get("installedAt", null) != null) return false;
  store.set("installedAt", existing ? 0 : now);
  if (store.get("shelf", null) == null) store.set("shelf", !!existing);
  return !existing;
}

/** «Lo sapevi?» solo nei primi 3 giorni dall'installazione, mai dopo (né per chi c'era già prima della 2.0.1). */
export function tipAllowed(store, now = Date.now()) {
  const at = Number(store.get("installedAt", 0)) || 0;
  return at > 0 && now - at >= 0 && now - at < TIP_DAYS * DAY;
}

/** La linguetta: spenta se non è stata accesa (anche per chi apre la linguetta prima della finestra). */
export function shelfOn(store) {
  return store.get("shelf", false) === true;
}
