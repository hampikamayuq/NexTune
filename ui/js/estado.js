'use strict';

// Estado global da interface.
const S = {
  info: null,
  ajustes: null,
  perfis: null,
  diag: null,          // resultado de diagnostico/coletar
  analise: null,       // resultado de limpeza/analisar ({categorias})
  base: 'carregando',  // carregando | pronto | erro
  baseErro: '',
  vista: 'inicio',
  ocupado: false,
  limpeza: { sel: new Set(), log: [], pct: 0, msg: '', rodando: false, resultado: null, avancadoAnalisado: null, falhou: null },
};

const VISTAS = {}; // inicio, diagnostico, limpeza, opcoes: cada uma com render(main)

const CATEGORIAS = [
  'temp_usuario', 'temp_windows', 'wu_cache', 'entrega', 'informes', 'miniaturas', 'launchers',
  'navegadores', 'minidumps', 'lixeira', 'shaders', 'dism_componentes', 'windows_old', 'pontos_antigos',
];

function fmtBytes(n) {
  if (n == null || n < 0) return t('limpeza.tamanhoDesconhecido');
  const un = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n, i = 0;
  while (v >= 1024 && i < un.length - 1) { v /= 1024; i++; }
  const casas = i === 0 ? 0 : (v >= 100 ? 0 : 1);
  return v.toLocaleString('pt-BR', { minimumFractionDigits: 0, maximumFractionDigits: casas }) + ' ' + un[i];
}

function fmtGb(bytes) {
  return (bytes / 1073741824).toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + ' GB';
}

function simNao(v) {
  if (typeof v === 'boolean') return v ? t('comum.sim') : t('comum.nao');
  return v == null ? '—' : String(v);
}

// ---- vistas e navegação ----
function renderAtual() {
  const main = document.getElementById('principal');
  main.textContent = '';
  const v = VISTAS[S.vista];
  if (v) v.render(main);
  document.querySelectorAll('#menu .item').forEach((b) => b.classList.toggle('ativo', b.dataset.vista === S.vista));
  aplicarOcupado();
}

function irPara(nome) {
  if (!VISTAS[nome]) return;
  S.vista = nome;
  renderAtual();
  document.getElementById('principal').scrollTop = 0;
}

// ---- estado ocupado ----
function aplicarOcupado() {
  document.querySelectorAll('.acao').forEach((el) => { el.disabled = S.ocupado || el.hasAttribute('data-bloq'); });
}

function setOcupado(b) {
  S.ocupado = b;
  const barra = document.getElementById('ocupado');
  barra.hidden = !b;
  document.getElementById('ocupado-barra').style.setProperty('--pct', 0);
  document.getElementById('ocupado-msg').textContent = t('ocupado.trabalhando');
  document.body.classList.toggle('ocupado', b);
  aplicarOcupado();
}

function atualizarOcupado(p) {
  if (p.tipo === 'progresso' && typeof p.pct === 'number') {
    document.getElementById('ocupado-barra').style.setProperty('--pct', Math.max(0, Math.min(100, p.pct)));
  }
  if (p.msg) document.getElementById('ocupado-msg').textContent = p.msg;
}

// ---- toasts ----
function toast(msg, tipo) {
  const raiz = document.getElementById('toasts');
  const el = h('div', { class: 'toast ' + (tipo || ''), text: msg });
  raiz.append(el);
  setTimeout(() => el.remove(), tipo === 'erro' ? 8000 : 4000);
}

function mostrarErro(e) {
  const msg = e && e.message ? e.message : String(e);
  toast(t('comum.erro', { erro: msg }), 'erro');
}

// ---- modal ----
// Devolve Promise<boolean>. `corpo` é um array de nós; `exigeCheck` é o texto do checkbox obrigatório.
function perguntar({ titulo, corpo, ok, okClasse, cancelar, exigeCheck }) {
  return new Promise((resolver) => {
    const raiz = document.getElementById('modal-raiz');
    const anterior = document.activeElement;
    let check = null;
    const btnOk = h('button', { type: 'button', class: 'btn ' + (okClasse || ''), text: ok || t('comum.confirmar') });
    const btnNao = h('button', { type: 'button', class: 'btn sec', text: cancelar || t('comum.cancelar') });
    const fim = (v) => {
      document.removeEventListener('keydown', teclas, true);
      raiz.textContent = '';
      if (anterior && anterior.focus) anterior.focus();
      resolver(v);
    };
    const teclas = (e) => { if (e.key === 'Escape') { e.preventDefault(); fim(false); } };
    btnOk.addEventListener('click', () => fim(true));
    btnNao.addEventListener('click', () => fim(false));
    const filhos = [h('h2', { text: titulo }), h('div', { class: 'corpo' }, corpo || [])];
    if (exigeCheck) {
      check = h('input', { type: 'checkbox', id: 'modal-check' });
      btnOk.disabled = true;
      check.addEventListener('change', () => { btnOk.disabled = !check.checked; });
      filhos.push(h('label', { class: 'opcao', for: 'modal-check' }, check, h('span', { text: exigeCheck })));
    }
    filhos.push(h('div', { class: 'acoes' }, btnNao, btnOk));
    const fundo = h('div', { class: 'fundo-modal' }, h('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' }, filhos));
    fundo.addEventListener('mousedown', (e) => { if (e.target === fundo) fim(false); });
    raiz.textContent = '';
    raiz.append(fundo);
    document.addEventListener('keydown', teclas, true);
    (exigeCheck ? check : btnNao).focus();
  });
}

// ---- modo leve e zoom ----
function aplicarLeve() {
  document.documentElement.classList.toggle('leve', !!(S.info && S.info.modoLeve));
}

function aplicarZoom() {
  const z = Math.min(1, Math.max(0.7, window.innerWidth / 1180));
  document.documentElement.style.setProperty('--zoom', String(z));
}
