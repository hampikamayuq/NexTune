'use strict';

// Quarentena: lista (quarentena/listar), restaurar, apagar agora (confirmação dupla) e apagar vencidas.
// O contador do menu (#quarentena-n) é atualizado depois de toda mudança.

function quarentenaVencida(e) {
  const v = e.venceEm ? new Date(e.venceEm).getTime() : NaN;
  return !Number.isNaN(v) && v < Date.now();
}

function quarentenaVencidas() {
  return (S.quarentena.entradas || []).filter(quarentenaVencida);
}

// Contador no menu: vazio quando a quarentena está vazia ou ainda não foi lida.
function atualizarContadorQuarentena() {
  const el = document.getElementById('quarentena-n');
  if (!el) return;
  const n = (S.quarentena.entradas || []).length;
  el.textContent = n > 0 ? t('nav.quarentenaN', { n }) : '';
}

function quarentenaDias() {
  const d = S.ajustes && Number(S.ajustes.diasQuarentena);
  return Number.isInteger(d) && d >= 1 && d <= 90 ? d : null;
}

// Passa `dias` das opções para que `venceEm` siga o mesmo prazo que `purgarVencidos` usa.
async function carregarQuarentena() {
  const Q = S.quarentena;
  if (S.ocupado) return;
  Q.carregando = true; Q.erro = null;
  if (S.vista === 'quarentena') renderAtual();
  try {
    const dias = quarentenaDias();
    const r = await api.executar('quarentena', 'listar', dias ? { dias } : {}, null);
    Q.entradas = r.entradas || [];
    const ids = new Set(Q.entradas.map((e) => e.id));
    Q.sel = new Set([...Q.sel].filter((id) => ids.has(id)));
  } catch (e) {
    Q.erro = e.message || String(e);
  }
  Q.carregando = false;
  atualizarContadorQuarentena();
  if (S.vista === 'quarentena') renderAtual();
}

// O Rust aceita no máximo MAX_IDS por chamada; o que passar fica para a próxima ação.
const QUARENTENA_MAX_IDS = 200;

function quarentenaLimitar(sel) {
  if (sel.length <= QUARENTENA_MAX_IDS) return sel;
  toast(t('quarentena.limiteIds', { max: QUARENTENA_MAX_IDS }), 'aviso');
  return sel.slice(0, QUARENTENA_MAX_IDS);
}

function quarentenaSelecionadas() {
  const Q = S.quarentena;
  return (Q.entradas || []).filter((e) => Q.sel.has(e.id));
}

function quarentenaModulo(m) {
  const chave = 'nav.' + m;
  return textos[chave] !== undefined ? t(chave) : String(m || '');
}

async function restaurarQuarentena() {
  const Q = S.quarentena;
  const sel = quarentenaLimitar(quarentenaSelecionadas());
  if (!sel.length || S.ocupado) return;
  const ok = await perguntar({
    titulo: sel.length === 1 ? t('quarentena.restaurarTituloUm') : t('quarentena.restaurarTitulo', { n: sel.length }),
    corpo: [h('p', { text: t('quarentena.restaurarTexto') })],
    ok: t('quarentena.restaurar'),
  });
  if (!ok) return;
  // Restaurar reimporta chaves no registro: é escrita no sistema, merece o ponto de restauração.
  if (!(await garantirPonto())) return;
  try {
    const r = await api.executar('quarentena', 'restaurar', { ids: sel.map((e) => e.id) }, null);
    const n = (r.restauradas || []).length;
    toast(n === 0 ? t('quarentena.nadaRestaurado') : (n === 1 ? t('quarentena.restauradaUma') : t('quarentena.restauradas', { n })), n ? 'ok' : 'aviso');
    Q.ultimo = ((r.conflitos || []).length || (r.falhas || []).length) ? r : null;
    Q.sel.clear();
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarQuarentena();
}

async function purgarQuarentena() {
  const Q = S.quarentena;
  const sel = quarentenaLimitar(quarentenaSelecionadas());
  if (!sel.length || S.ocupado) return;
  const tamanho = fmtBytes(sel.reduce((s, e) => s + Math.max(e.tamanhoBytes || 0, 0), 0));
  const ok = await perguntar({
    titulo: t('quarentena.apagarTitulo'),
    corpo: [h('p', { class: 'aviso', text: sel.length === 1 ? t('quarentena.apagarTextoUm', { tamanho }) : t('quarentena.apagarTexto', { n: sel.length, tamanho }) })],
    exigeCheck: t('limpeza.entendi'),
    ok: t('quarentena.apagar'),
    okClasse: 'perigo',
  });
  if (!ok) return;
  try {
    const r = await api.executar('quarentena', 'purgar', { ids: sel.map((e) => e.id), confirmado: true }, null);
    const n = (r.removidas || []).length;
    toast(n === 1 ? t('quarentena.apagadaUma') : t('quarentena.apagadas', { n }), 'ok');
    Q.ultimo = (r.falhas || []).length ? { restauradas: [], conflitos: [], falhas: r.falhas } : null;
    Q.sel.clear();
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarQuarentena();
}

async function purgarVencidasQuarentena() {
  const vencidas = quarentenaVencidas();
  const dias = quarentenaDias();
  if (!vencidas.length || !dias || S.ocupado) return;
  const ok = await perguntar({
    titulo: t('quarentena.apagarVencidasTitulo'),
    corpo: [h('p', { text: vencidas.length === 1 ? t('quarentena.apagarVencidasTextoUm', { dias }) : t('quarentena.apagarVencidasTexto', { n: vencidas.length, dias }) })],
    ok: t('quarentena.apagarVencidas'),
    okClasse: 'perigo',
  });
  if (!ok) return;
  try {
    const r = await api.executar('quarentena', 'purgarVencidos', { dias }, null);
    const n = (r.removidas || []).length;
    toast(n === 0 ? t('quarentena.nenhumaVencida') : (n === 1 ? t('quarentena.vencidaApagada') : t('quarentena.vencidasApagadas', { n })), 'ok');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarQuarentena();
}

function cartaoResultadoQuarentena(r) {
  const Q = S.quarentena;
  const cartao = h('div', { class: 'cartao resultado atencao' });
  if ((r.conflitos || []).length) {
    cartao.append(h('h4', { text: t('quarentena.conflitosTitulo') }),
      ...r.conflitos.map((c) => h('p', { class: 'pequeno', text: t('quarentena.conflito', { item: c.item, motivo: c.motivo }) })));
  }
  if ((r.falhas || []).length) {
    cartao.append(h('h4', { text: t('quarentena.falhasTitulo') }),
      ...r.falhas.map((f) => h('p', { class: 'pequeno', text: t('quarentena.falha', { id: f.id, erro: f.erro }) })));
  }
  cartao.append(h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn sec', text: t('comum.fechar'), onclick: () => { Q.ultimo = null; renderAtual(); } })));
  return cartao;
}

VISTAS.quarentena = {
  render(main) {
    const Q = S.quarentena;
    const dias = quarentenaDias();
    const v = h('section', { class: 'vista' }, h('h1', { text: t('quarentena.titulo') }));
    main.append(v);
    v.append(h('p', { class: 'suave', text: t('quarentena.intro', { dias: dias == null ? '—' : dias }) }));

    if (!Q.entradas && !Q.carregando && !Q.erro && !S.ocupado) setTimeout(() => carregarQuarentena(), 0);

    if (Q.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('quarentena.erro', { erro: Q.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarQuarentena() })));
    }
    if (Q.ultimo) v.append(cartaoResultadoQuarentena(Q.ultimo));
    if (!Q.entradas) {
      if (!Q.erro) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('quarentena.carregando') })));
      return;
    }
    if (!Q.entradas.length) {
      v.append(h('div', { class: 'cartao' }, h('p', { class: 'suave', text: t('quarentena.vazia') }),
        h('button', { type: 'button', class: 'btn sec acao', text: t('quarentena.atualizar'), onclick: () => carregarQuarentena() })));
      return;
    }

    const vencidas = quarentenaVencidas();
    if (vencidas.length) {
      v.append(h('p', { class: 'aviso', text: vencidas.length === 1 ? t('quarentena.vencidaUma') : t('quarentena.vencidas', { n: vencidas.length }) }));
    }

    const btnRestaurar = h('button', { type: 'button', class: 'btn acao escrita', text: t('quarentena.restaurar'), onclick: () => restaurarQuarentena() });
    const btnApagar = h('button', { type: 'button', class: 'btn perigo acao escrita', text: t('quarentena.apagar'), onclick: () => purgarQuarentena() });
    const btnVencidas = h('button', { type: 'button', class: 'btn sec acao escrita', text: t('quarentena.apagarVencidas'), 'data-bloq': (vencidas.length && dias) ? null : '', onclick: () => purgarVencidasQuarentena() });
    const contagem = h('span', { class: 'contagem' });
    const todas = h('input', { type: 'checkbox', id: 'q-todas', class: 'acao' });
    const caixas = [];
    const atualizar = () => {
      const n = Q.sel.size;
      contagem.textContent = n === 0 ? t('quarentena.nenhumaSelecionada') : (n === 1 ? t('quarentena.selecionadaUma') : t('quarentena.selecionadas', { n }));
      [btnRestaurar, btnApagar].forEach((b) => { if (n === 0) b.setAttribute('data-bloq', ''); else b.removeAttribute('data-bloq'); });
      todas.checked = n > 0 && n === Q.entradas.length;
      todas.indeterminate = n > 0 && n < Q.entradas.length;
      aplicarOcupado();
    };
    todas.addEventListener('change', (e) => {
      Q.sel = e.target.checked ? new Set(Q.entradas.map((x) => x.id)) : new Set();
      caixas.forEach((c) => { c.checked = e.target.checked; });
      atualizar();
    });

    v.append(h('div', { class: 'barra-q' },
      h('label', { class: 'opcao', for: 'q-todas' }, todas, h('span', { text: t('quarentena.selecionarTodas') })),
      contagem,
      h('div', { class: 'acoes-q' }, btnVencidas, btnRestaurar, btnApagar)));

    const lista = h('div', { class: 'lista-q' });
    for (const e of Q.entradas) {
      const vencida = quarentenaVencida(e);
      const id = 'q-' + e.id;
      const caixa = h('input', { type: 'checkbox', id, class: 'acao', checked: Q.sel.has(e.id),
        onchange: (ev) => { if (ev.target.checked) Q.sel.add(e.id); else Q.sel.delete(e.id); atualizar(); } });
      caixas.push(caixa);
      lista.append(h('label', { class: 'qent' + (vencida ? ' vencida' : ''), for: id },
        caixa,
        h('span', { class: 'q-data', text: fmtData(e.data) }),
        h('span', { class: 'q-info' },
          h('span', { class: 'q-desc' }, h('span', { class: 'selo', text: quarentenaModulo(e.modulo) }), h('span', { text: e.descricao || t('quarentena.ilegivel') })),
          h('span', { class: 'suave pequeno', text: (e.itens === 1 ? t('quarentena.itemUm') : t('quarentena.itens', { n: e.itens })) + ' · ' + fmtBytes(e.tamanhoBytes) })),
        h('span', { class: 'q-vence' + (vencida ? ' aviso-texto' : ''), text: vencida ? t('quarentena.vencida') : t('quarentena.venceEm', { data: fmtData(e.venceEm) }) })));
    }
    v.append(lista);
    v.append(h('p', {}, h('button', { type: 'button', class: 'btn sec acao', text: t('quarentena.atualizar'), onclick: () => carregarQuarentena() })));
    atualizar();
  },
};
