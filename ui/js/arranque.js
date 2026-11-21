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
  try { await carregarInicializacao(); } catch (e) { mostrarErro(e); }
  try { await carregarDisco(); } catch (e) { mostrarErro(e); }
  renderAtual();
  await carregarSessaoEQuarentena();
  // A vista aberta durante o arranque pode ter pulado a carga automática (S.ocupado): re-renderiza.
  renderAtual();
}

// Depois da base: confere a sessão (usuário elevado = usuário do console), lê a quarentena para o
// contador e apaga o que já venceu. Erros viram toast e nunca travam o arranque.
async function carregarSessaoEQuarentena() {
  if (S.info && typeof S.info.sessaoOk === 'boolean') S.sessaoOk = S.info.sessaoOk;
  try {
    const s = await api.executar('sistema', 'sessao', {}, null);
    S.sessaoOk = s.mesmo !== false;
  } catch (e) {
    toast(t('sessao.erro', { erro: e && e.message ? e.message : String(e) }), 'aviso');
  }
  aplicarSessao();
  await carregarQuarentena();
  if (S.quarentena.erro) { toast(t('quarentena.erro', { erro: S.quarentena.erro }), 'aviso'); return; }
  const dias = quarentenaDias();
  if (S.sessaoOk === false || !dias || !quarentenaVencidas().length) return;
  try {
    const r = await api.executar('quarentena', 'purgarVencidos', { dias }, null);
    const n = (r.removidas || []).length;
    if (n) toast(n === 1 ? t('quarentena.vencidaApagada') : t('quarentena.vencidasApagadas', { n }), 'ok');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarQuarentena();
  if (S.quarentena.erro) toast(t('quarentena.erro', { erro: S.quarentena.erro }), 'aviso');
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
  if (typeof S.info.sessaoOk === 'boolean') S.sessaoOk = S.info.sessaoOk;
  aplicarSessao();

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
