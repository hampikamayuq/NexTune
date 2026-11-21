'use strict';

// Ajustes do Windows (módulo ajusteswin): cinco grupos; cada ajuste tem Aplicar ou Restaurar. O valor
// original fica guardado pelo script antes da escrita, então Restaurar devolve exatamente o que havia.
// Textos de cada ajuste: ajuste.<id>.nome / .desc em pt-BR.js (mesmo id de data/ajustes.json).

const AJUSTES_GRUPOS = ['anuncios', 'privacidade', 'copilot', 'explorador', 'desempenho'];

async function carregarAjustesWin() {
  const A = S.ajustesWin;
  if (S.ocupado) return;
  A.carregando = true; A.erro = null; A.avancadoListado = !!S.ajustes.modoAvancado;
  if (S.vista === 'ajustes') renderAtual();
  try {
    const r = await api.executar('ajusteswin', 'listar', S.ajustes.modoAvancado ? { avancado: true } : {}, null);
    A.lista = r.ajustes || [];
  } catch (e) {
    A.erro = e.message || String(e);
  }
  A.carregando = false;
  if (S.vista === 'ajustes') renderAtual();
}

function ajustesRecomendadosPendentes() {
  return (S.ajustesWin.lista || []).filter((a) => a.recomendado && a.disponivel && !a.aplicado);
}

function nomeAjuste(id) {
  return t('ajuste.' + id + '.nome');
}

// acao: 'aplicar' | 'restaurar'. Confirmação única com a lista de nomes e o caminho de volta.
async function executarAjustes(acao, ids) {
  if (S.ocupado || !ids.length) return;
  const n = ids.length;
  const nomes = ids.map(nomeAjuste).join(', ');
  const ok = await perguntar({
    titulo: n === 1 ? t('ajustes.' + acao + 'TituloUm') : t('ajustes.' + acao + 'Titulo', { n }),
    corpo: [h('p', { text: t('ajustes.' + acao + 'Texto', { lista: nomes }) }), acao === 'aplicar' ? h('p', { class: 'suave pequeno', text: t('ajustes.desfazer') }) : null],
    ok: t('ajustes.' + acao),
  });
  if (!ok) return;
  if (!(await garantirPonto())) return;
  const params = { ids, confirmado: true };
  if (acao === 'aplicar' && S.ajustes.modoAvancado) params.avancado = true;
  try {
    const r = await api.executar('ajusteswin', acao, params, null);
    const feitos = (acao === 'aplicar' ? r.aplicados : r.restaurados) || [];
    const falhas = r.falhas || [];
    if (feitos.length) toast(feitos.length === 1 ? t('ajustes.' + acao + 'FeitoUm') : t('ajustes.' + acao + 'Feitos', { n: feitos.length }), 'ok');
    else if (!falhas.length) toast(t('ajustes.nadaFeito'), 'aviso');
    falhas.forEach((f) => toast(t('ajustes.falha', { nome: nomeAjuste(f.id), erro: f.erro }), 'erro'));
    (r.avisos || []).forEach((w) => toast(w.aviso, 'aviso'));
    if (r.precisaReiniciar) toast(t('ajustes.reiniciar'), 'aviso');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarAjustesWin();
}

function linhaAjuste(a) {
  const selos = [];
  if (a.recomendado) selos.push(h('span', { class: 'selo destaque', text: t('ajustes.selo.recomendado') }));
  if (a.politica) selos.push(h('span', { class: 'selo', text: t('ajustes.selo.politica') }));
  if (a.reiniciarExplorer) selos.push(h('span', { class: 'selo', text: t('ajustes.selo.reiniciar') }));
  const lado = h('div', { class: 'ajuste-lado' });
  if (a.disponivel) {
    // Aplicado sem backup (já era assim antes do NexTune): não há o que restaurar, então só mostra o estado.
    const semBackup = a.aplicado && !a.temBackup;
    lado.append(h('span', { class: 'suave pequeno', text: t(semBackup ? 'ajustes.estado.aplicadoSemBackup' : (a.aplicado ? 'ajustes.estado.aplicado' : 'ajustes.estado.original')) }));
    if (!semBackup) {
      lado.append(h('button', { type: 'button', class: 'btn sec acao escrita', text: t(a.aplicado ? 'ajustes.restaurar' : 'ajustes.aplicar'),
        onclick: () => executarAjustes(a.aplicado ? 'restaurar' : 'aplicar', [a.id]) }));
    }
  }
  return h('div', { class: 'ajuste' + (a.disponivel ? '' : ' indisp') },
    h('div', { class: 'ajuste-info' },
      h('div', { class: 'ajuste-nome' }, h('span', { text: nomeAjuste(a.id) }), selos),
      h('div', { class: 'suave pequeno', text: t('ajuste.' + a.id + '.desc') }),
      a.disponivel ? null : h('div', { class: 'motivo', text: a.motivoIndisponivel || t('comum.indisponivel') })),
    lado);
}

VISTAS.ajustes = {
  render(main) {
    const A = S.ajustesWin;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('ajustes.titulo') }));
    main.append(v);

    const precisa = !A.carregando && !S.ocupado && !A.erro && (!A.lista || A.avancadoListado !== !!S.ajustes.modoAvancado);
    if (precisa) setTimeout(() => carregarAjustesWin(), 0);

    if (A.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('ajustes.erro', { erro: A.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarAjustesWin() })));
    }
    if (!A.lista) {
      if (!A.erro) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('ajustes.carregando') })));
      return;
    }

    v.append(h('p', { class: 'suave', text: t('ajustes.intro') }));
    const pend = ajustesRecomendadosPendentes();
    const btnRec = h('button', { type: 'button', class: 'btn acao escrita', 'data-bloq': pend.length ? null : '',
      text: t('ajustes.aplicarRecomendados', { n: pend.length }), onclick: () => executarAjustes('aplicar', pend.map((a) => a.id)) });
    v.append(h('div', { class: 'barra-prog' },
      btnRec,
      pend.length ? null : h('span', { class: 'suave pequeno', text: t('ajustes.nenhumRecomendado') }),
      h('button', { type: 'button', class: 'btn sec acao', text: t('ajustes.atualizar'), onclick: () => carregarAjustesWin() })));

    for (const g of AJUSTES_GRUPOS) {
      const itens = A.lista.filter((a) => a.grupo === g);
      if (!itens.length) continue;
      v.append(h('div', { class: 'cartao grupo-ajustes' }, h('h3', { text: t('ajustes.grupo.' + g) }), itens.map(linhaAjuste)));
    }
    aplicarOcupado();
  },
};
