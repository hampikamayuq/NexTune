'use strict';

// Atualizações (módulo atualizacoes): Windows Update (sem atualizações de versão; prévias só no modo
// avançado) e programas pelo winget. Carrega na primeira visita, não no arranque: usa rede e demora.

async function carregarAtualizacoes() {
  const A = S.atualiz;
  if (S.ocupado) return;
  A.carregando = true; A.erro = null; A.avancadoListado = !!S.ajustes.modoAvancado;
  if (S.vista === 'atualizacoes') renderAtual();
  try {
    const r = await api.executar('atualizacoes', 'listar', S.ajustes.modoAvancado ? { avancado: true } : {}, null);
    A.lista = r;
    A.selWin = new Set((r.windows || []).filter((w) => !w.excluido).map((w) => w.id));
    A.selProg = new Set((r.programas || []).map((p) => p.id));
  } catch (e) {
    A.erro = e.message || String(e);
  }
  A.carregando = false;
  if (S.vista === 'atualizacoes') renderAtual();
}

// acao: 'instalar' (Windows, ids GUID) | 'atualizar' (programas, ids do winget).
async function executarAtualizacoes(acao, ids, nomes) {
  if (S.ocupado || !ids.length) return;
  const n = ids.length;
  const ok = await perguntar({
    titulo: n === 1 ? t('atualizacoes.' + acao + 'TituloUm') : t('atualizacoes.' + acao + 'Titulo', { n }),
    corpo: [h('p', { text: t('atualizacoes.' + acao + 'Texto', { lista: nomes.join(', ') }) }), h('p', { class: 'suave pequeno', text: t('atualizacoes.' + acao + 'Desfazer') })],
    ok: t('atualizacoes.' + acao + 'Botao'),
  });
  if (!ok) return;
  if (!(await garantirPonto())) return;
  const params = { ids, confirmado: true };
  if (acao === 'instalar' && S.ajustes.modoAvancado) params.avancado = true;
  try {
    const r = await api.executar('atualizacoes', acao === 'instalar' ? 'instalar' : 'atualizarProgramas', params, null);
    const feitos = (acao === 'instalar' ? r.instalados : r.atualizados) || [];
    const falhas = r.falhas || [];
    if (feitos.length) toast(feitos.length === 1 ? t('atualizacoes.' + acao + 'FeitoUm') : t('atualizacoes.' + acao + 'Feitos', { n: feitos.length }), 'ok');
    else if (!falhas.length) toast(t('atualizacoes.nadaFeito'), 'aviso');
    falhas.forEach((f) => toast(t('atualizacoes.falha', { nome: f.id, erro: f.erro }), 'erro'));
    if (r.precisaReiniciar) toast(t('atualizacoes.reiniciar'), 'aviso');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarAtualizacoes();
}

// Só 'upgrade' fica travado; 'preview' só chega aqui no modo avançado e pode ser marcada (desmarcada por padrão).
function linhaWindows(w, aoMudar) {
  const A = S.atualiz;
  const travado = w.excluido === 'upgrade';
  const selos = [h('span', { class: 'selo' + (w.tipo === 'seguranca' ? ' destaque' : ''), text: t('atualizacoes.tipo.' + w.tipo) })];
  if (w.excluido === 'preview') selos.push(h('span', { class: 'selo', text: t('atualizacoes.selo.preview') }));
  if (w.kb) selos.push(h('span', { class: 'selo', text: w.kb }));
  if (w.exigeReinicio) selos.push(h('span', { class: 'selo', text: t('atualizacoes.reinicio') }));
  const id = 'atu-w-' + w.id;
  const caixa = travado ? h('span', { class: 'sem-caixa' }) : h('input', {
    type: 'checkbox', class: 'acao', id, checked: A.selWin.has(w.id),
    onchange: (e) => { if (e.target.checked) A.selWin.add(w.id); else A.selWin.delete(w.id); aoMudar(); },
  });
  return h(travado ? 'div' : 'label', { class: 'atu' + (travado ? ' indisp' : ''), for: travado ? null : id },
    caixa,
    h('div', { class: 'atu-info' },
      h('div', { class: 'atu-nome' }, h('span', { text: w.titulo }), selos),
      w.excluido ? h('div', { class: 'motivo', text: t('atualizacoes.excluido.' + w.excluido) }) : null),
    h('span', { class: 'tam', text: w.tamanhoBytes > 0 ? fmtBytes(w.tamanhoBytes) : '' }));
}

function linhaPrograma(p, aoMudar) {
  const A = S.atualiz;
  const id = 'atu-p-' + p.id;
  return h('label', { class: 'atu', for: id },
    h('input', {
      type: 'checkbox', class: 'acao', id, checked: A.selProg.has(p.id),
      onchange: (e) => { if (e.target.checked) A.selProg.add(p.id); else A.selProg.delete(p.id); aoMudar(); },
    }),
    h('div', { class: 'atu-info' },
      h('div', { class: 'atu-nome' }, h('span', { text: p.nome || p.id }), p.origem ? h('span', { class: 'selo', text: p.origem }) : null),
      h('div', { class: 'suave pequeno', text: t('atualizacoes.versao', { atual: p.versaoAtual || '—', nova: p.versaoNova || '—' }) })),
    h('span', { class: 'tam', text: p.id }));
}

VISTAS.atualizacoes = {
  render(main) {
    const A = S.atualiz;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('atualizacoes.titulo') }));
    main.append(v);

    const precisa = !A.carregando && !S.ocupado && !A.erro && (!A.lista || A.avancadoListado !== !!S.ajustes.modoAvancado);
    if (precisa) setTimeout(() => carregarAtualizacoes(), 0);

    if (A.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('atualizacoes.erro', { erro: A.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarAtualizacoes() })));
    }
    if (!A.lista) {
      if (!A.erro) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('atualizacoes.carregando') })));
      return;
    }

    v.append(h('p', { class: 'suave', text: t('atualizacoes.intro') }));
    v.append(h('div', { class: 'barra-prog' },
      h('button', { type: 'button', class: 'btn sec acao', text: t('atualizacoes.procurar'), onclick: () => carregarAtualizacoes() })));

    const windows = A.lista.windows || [];
    const programas = A.lista.programas || [];
    const btnWin = h('button', { type: 'button', class: 'btn acao escrita' });
    const btnProg = h('button', { type: 'button', class: 'btn acao escrita' });
    const atualizarBotoes = () => {
      const nw = A.selWin.size;
      btnWin.textContent = t('atualizacoes.instalarBotaoN', { n: nw });
      if (nw) btnWin.removeAttribute('data-bloq'); else btnWin.setAttribute('data-bloq', '');
      const np = A.selProg.size;
      btnProg.textContent = t('atualizacoes.atualizarBotaoN', { n: np });
      if (np) btnProg.removeAttribute('data-bloq'); else btnProg.setAttribute('data-bloq', '');
      aplicarOcupado();
    };
    btnWin.addEventListener('click', () => {
      const sel = windows.filter((w) => A.selWin.has(w.id));
      executarAtualizacoes('instalar', sel.map((w) => w.id), sel.map((w) => w.titulo));
    });
    btnProg.addEventListener('click', () => {
      const sel = programas.filter((p) => A.selProg.has(p.id));
      executarAtualizacoes('atualizar', sel.map((p) => p.id), sel.map((p) => p.nome || p.id));
    });

    const cw = h('div', { class: 'cartao' }, h('h3', { text: t('atualizacoes.windows') }));
    if (A.lista.windowsErro) cw.append(h('p', { class: 'aviso pequeno', text: t('atualizacoes.windowsErro', { erro: A.lista.windowsErro }) }));
    else if (!windows.length) cw.append(h('p', { class: 'suave', text: t('atualizacoes.nenhumaWindows') }));
    if (windows.length) {
      cw.append(h('div', { class: 'lista-atu' }, windows.map((w) => linhaWindows(w, atualizarBotoes))));
      cw.append(h('div', { class: 'acoes' }, btnWin));
    }
    v.append(cw);

    const cp = h('div', { class: 'cartao' }, h('h3', { text: t('atualizacoes.programas') }));
    const wg = A.lista.winget || {};
    if (wg.disponivel === false) cp.append(h('p', { class: 'aviso pequeno', text: t('atualizacoes.wingetAusente') }));
    else if (wg.erro) cp.append(h('p', { class: 'aviso pequeno', text: t('atualizacoes.wingetErro', { erro: wg.erro }) }));
    else if (!programas.length) cp.append(h('p', { class: 'suave', text: t('atualizacoes.nenhumPrograma') }));
    if (programas.length) {
      cp.append(h('div', { class: 'lista-atu' }, programas.map((p) => linhaPrograma(p, atualizarBotoes))));
      cp.append(h('div', { class: 'acoes' }, btnProg));
    }
    v.append(cp);
    atualizarBotoes();
  },
};
