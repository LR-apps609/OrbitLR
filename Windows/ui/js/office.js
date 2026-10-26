// LibreOffice: il componente facoltativo per Word, Excel e PowerPoint. Si installa con un clic
// (winget, il gestore di app di Windows); se non c'è, si apre la pagina ufficiale per scaricarlo.

import { invoke, openUrl } from "./api.js";
import { modal, toast } from "./util.js";
import { t } from "./i18n.js";

let installing = null;

/** true se LibreOffice c'è (ricontrollato, così vale anche appena installato). */
export async function officeReady(app) {
  if (app.engine?.office) return true;
  const ok = await invoke("office_ready").catch(() => false);
  if (ok && app.engine) app.engine.office = true;
  return ok;
}

/** Chiede se installarlo; restituisce true quando è pronto. */
export async function askOffice(app) {
  if (await officeReady(app)) return true;
  if (installing) {
    toast(t("Sto già installando LibreOffice: ancora qualche minuto"));
    return installing;
  }
  const go = await modal(t("Serve LibreOffice"),
    t("Per convertire Word, Excel e PowerPoint OrbitLR usa LibreOffice: gratuito, sicuro, circa 350 MB. Si installa una volta sola; Windows ti chiederà il permesso. OrbitLR lo usa in silenzio, senza aprire finestre."),
    [{ label: t("Non ora"), value: false }, { label: t("Installa LibreOffice"), value: true, primary: true }]);
  if (!go) return false;
  return install(app);
}

export function install(app) {
  if (installing) return installing;
  toast(t("Installo LibreOffice… ci vogliono alcuni minuti"));
  installing = invoke("office_install")
    .then((ok) => {
      if (ok) {
        if (app.engine) app.engine.office = true;
        toast(t("LibreOffice è pronto"));
        return true;
      }
      fallback();
      return false;
    })
    .catch(() => {
      fallback();
      return false;
    })
    .finally(() => {
      installing = null;
    });
  return installing;
}

export const isInstalling = () => !!installing;

function fallback() {
  openUrl("https://www.libreoffice.org/download/download-libreoffice/");
  toast(t("Scaricalo dalla pagina ufficiale che si è aperta, installalo e poi riprova"));
}
