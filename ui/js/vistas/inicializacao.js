'use strict';

// Inicialização: o que abre com o Windows (inicializacao/listar) e o botão Ligado/Desligado, que usa o
// mesmo mecanismo do Gerenciador de Tarefas e é reversível aqui ou lá. Cores: verde = pode desligar,
// amarelo = decide você, vermelho = protegido (sem botão), null = sem classificação.

const INICIO_FILTROS = ['todos', 'recomendados', 'desligados'];

async function carregarInicializacao() {
  const I = S.inicio;
  if (S.ocupado) return;
  I.carregando = true; I.erro = null; I.avancadoListado = !!S.ajustes.modoAvancado;
  if (S.vista === 'inicializacao') renderAtual();
  try {
    const r = await api.executar('inicializacao', 'listar', S.ajustes.modoAvancado ? { avancado: true } : {}, null);
    I.itens = r.itens || [];
  } catch (e) {
    I.erro = e.message || String(e);
  }
  I.carregando = false;
  if (S.vista === 'inicializacao' || S.vista === 'inicio') renderAtual();
}

// Itens verdes ainda ligados: o que a tela Início recomenda desligar.
function inicioRecomendados() {
  return (S.inicio.itens || []).filter((i) => i.cor === 'verde' && i.ativo && !i.protegido);
}

function inicializacaoFiltrados() {
  const I = S.inicio;
  const lista = I.itens || [];
  if (I.filtro === 'recomendados') return lista.filter((i) => i.cor === 'verde' && !i.protegido);
  if (I.filtro === 'desligados') return lista.filter((i) => !i.ativo);
  return lista;
}

async function alternarInicio(item) {
  if (S.ocupado || item.protegido) return;
  const ativar = !item.ativo;
  const nome = item.nome;
  const ok = await perguntar({
    titulo: t(ativar ? 'inicializacao.ligarTitulo' : 'inicializacao.desligarTitulo', { nome }),
    corpo: [h('p', { text: t(ativar ? 'inicializacao.ligarTexto' : 'inicializacao.desligarTexto', { nome }) })],
    ok: t(ativar ? 'inicializacao.ligar' : 'inicializacao.desligar'),
  });
  if (!ok) return;
  if (!(await garantirPonto())) return;
  const params = { id: item.id, ativar, confirmado: true };
  if (S.ajustes.modoAvancado) params.avancado = true;
  try {
    const r = await api.executar('inicializacao', 'alternar', params, null);
    S.inicio.itens = (S.inicio.itens || []).map((x) => (x.id === item.id ? Object.assign({}, x, { ativo: !!r.ativo }) : x));
    toast(t(r.ativo ? 'inicializacao.feitoLigado' : 'inicializacao.feitoDesligado', { nome }), 'ok');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  renderAtual();
}

function linhaInicio(i) {
  const selos = [];
  if (i.rodando) selos.push(h('span', { class: 'selo', text: t('inicializacao.selo.rodando', { ram: fmtBytes(i.ramBytes) }) }));
  if (i.protegido) selos.push(h('span', { class: 'selo destaque', title: i.motivoProtegido || '', text: t('inicializacao.selo.protegido') }));
  if (i.origem === 'tarefa') selos.push(h('span', { class: 'selo', text: t('inicializacao.selo.tarefa') }));
  if (i.escopo === 'todos') selos.push(h('span', { class: 'selo', text: t('inicializacao.selo.todos') }));

  const cor = i.cor || 'nenhuma';
  const lado = h('div', { class: 'prog-lado' });
  if (!i.protegido) {
    lado.append(h('button', {
      type: 'button', class: 'btn sec toggle acao escrita', 'aria-pressed': i.ativo ? 'true' : 'false',
      text: t(i.ativo ? 'inicializacao.ligado' : 'inicializacao.desligado'), onclick: () => alternarInicio(i),
    }));
  } else {
    lado.append(h('span', { class: 'suave pequeno', text: t(i.ativo ? 'inicializacao.ligado' : 'inicializacao.desligado') }));
  }
  return h('div', { class: 'prog' + (i.protegido ? ' protegido' : '') + (i.ativo ? '' : ' inativo') },
    h('span', { class: 'ponto ' + (i.cor || 'neutro'), role: 'img', title: t('inicializacao.cor.' + cor), 'aria-label': t('inicializacao.cor.' + cor) }),
    h('div', { class: 'prog-info' },
      h('div', { class: 'prog-nome' }, h('span', { text: i.nome }), selos),
      h('div', { class: 'suave pequeno', text: i.editor || t('inicializacao.editorDesconhecido') }),
      h('div', { class: 'suave pequeno comando', text: i.comando || t('inicializacao.comandoDesconhecido') }),
      i.motivoCor ? h('div', { class: 'suave pequeno motivo-cor', text: i.motivoCor }) : null),
    lado);
}

VISTAS.inicializacao = {
  render(main) {
    const I = S.inicio;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('inicializacao.titulo') }));
    main.append(v);

    const precisa = !I.carregando && !S.ocupado && !I.erro && (!I.itens || I.avancadoListado !== !!S.ajustes.modoAvancado);
    if (precisa) setTimeout(() => carregarInicializacao(), 0);

    if (I.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('inicializacao.erro', { erro: I.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarInicializacao() })));
    }
    if (!I.itens) {
      if (!I.erro) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('inicializacao.carregando') })));
      return;
    }

    v.append(h('p', { class: 'suave', text: t('inicializacao.intro') }));
    const ativos = I.itens.filter((i) => i.ativo).length;
    const rec = inicioRecomendados().length;
    v.append(h('p', { class: 'resumo', 'aria-live': 'polite', text: t('inicializacao.resumo', { n: ativos, m: rec }) }));

    const listaEl = h('div', { class: 'lista-prog' });
    const chips = [];
    const renderLista = () => {
      const itens = inicializacaoFiltrados();
      listaEl.textContent = '';
      if (!itens.length) listaEl.append(h('p', { class: 'suave', text: t('inicializacao.vazio') }));
      itens.forEach((i) => listaEl.append(linhaInicio(i)));
      chips.forEach((c) => { c.classList.toggle('ativo', c.dataset.filtro === I.filtro); c.setAttribute('aria-pressed', c.dataset.filtro === I.filtro ? 'true' : 'false'); });
      aplicarOcupado();
    };
    INICIO_FILTROS.forEach((f) => {
      chips.push(h('button', { type: 'button', class: 'chip' + (f === 'recomendados' ? ' verde' : ''), 'data-filtro': f, text: t('inicializacao.filtro.' + f),
        onclick: () => { I.filtro = f; renderLista(); } }));
    });
    v.append(h('div', { class: 'barra-prog' },
      h('div', { class: 'chips', role: 'group', 'aria-label': t('inicializacao.filtros') }, chips),
      h('button', { type: 'button', class: 'btn sec acao', text: t('inicializacao.atualizar'), onclick: () => carregarInicializacao() })),
      listaEl);
    renderLista();
  },
};
