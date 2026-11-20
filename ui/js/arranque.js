'use strict';

// Primeiro o diagnóstico, depois qualquer outra ação: o Rust pode trocar o host PowerShell depois dele.
async function carregarBase() {
  S.base = 'carregando';
  S.baseErro = '';
  if (S.vista === 'inicio' || S.vista === 'diagnostico') renderAtual();
  try {
    S.diag = await api.executar('diagnostico', 'coletar', {}, null);
    S.info.perfil = S.diag.perfil;
  } catch (e) {
    S.base = 'erro';
    S.baseErro = e.message || String(e);
    renderAtual();
    return;
  }
  S.base = 'pronto';
  try { await analisarLimpeza(); } catch (e) { mostrarErro(e); }
  renderAtual();
}

function ligarJanela() {
  if (!TAURI) return;
  const w = TAURI.window.getCurrentWindow();
  document.getElementById('jan-min').addEventListener('click', () => w.minimize());
  document.getElementById('jan-max').addEventListener('click', () => w.toggleMaximize());
  document.getElementById('jan-fechar').addEventListener('click', () => w.close());
  // Fechar no meio de uma ação mata o host antes de ele religar serviços: pede confirmação.
  let perguntando = false;
  w.onCloseRequested(async (e) => {
    if (!S.ocupado) return;
    if (perguntando) { e.preventDefault(); return; }
    perguntando = true;
    try {
      const fechar = await perguntar({
        titulo: t('janela.fecharOcupadoTitulo'),
        corpo: [h('p', { class: 'aviso', text: t('janela.fecharOcupado') })],
        ok: t('janela.fecharMesmoAssim'),
        okClasse: 'perigo',
      });
      if (!fechar) e.preventDefault();
    } finally {
      perguntando = false;
    }
  });
}

async function arranque() {
  aplicarZoom();
  window.addEventListener('resize', aplicarZoom);
  await carregarI18n();
  aplicarI18n();
  ligarJanela();
  document.querySelectorAll('#menu .item').forEach((b) => b.addEventListener('click', () => irPara(b.dataset.vista)));
  document.getElementById('btn-cancelar').addEventListener('click', () => api.cancelar().catch(mostrarErro));

  await api.iniciar();
  S.info = await api.info();
  S.ajustes = await api.ajustes.ler();
  S.perfis = await api.dados('perfis');
  aplicarLeve();
  document.getElementById('versao').textContent = t('app.versao', { v: S.info.versao });
  document.getElementById('faixa-demo').hidden = !S.info.demo;

  irPara('inicio');
  await carregarBase();
  // Atalho de revisão do modo demonstração: index.html?vista=limpeza
  const pedida = new URLSearchParams(window.location.search).get('vista');
  if (S.info.demo && pedida) irPara(pedida);
}

arranque().catch((e) => {
  const main = document.getElementById('principal');
  main.textContent = '';
  main.append(h('p', { text: (textos['comum.erro'] ? t('comum.erro', { erro: e && e.message ? e.message : String(e) }) : String(e)) }));
});
