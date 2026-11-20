'use strict';

const CATEGORIAS_DUPLA = ['windows_old', 'pontos_antigos'];

function categoriasVisiveis() {
  if (!S.analise) return [];
  return S.analise.categorias.filter((c) => !c.avancado || S.ajustes.modoAvancado);
}

// Verdes disponíveis ficam marcados; amarelos ficam por conta do usuário.
function limpezaMarcarVerdes() {
  S.limpeza.sel = new Set(categoriasVisiveis().filter((c) => c.cor === 'verde' && c.disponivel).map((c) => c.id));
}

async function analisarLimpeza() {
  const av = !!S.ajustes.modoAvancado;
  const r = await api.executar('limpeza', 'analisar', av ? { avancado: true } : {}, null);
  S.analise = r;
  S.limpeza.avancadoAnalisado = av;
  limpezaMarcarVerdes();
}

function limpezaSelecionadas() {
  return categoriasVisiveis().filter((c) => S.limpeza.sel.has(c.id) && c.disponivel);
}

function limpezaTotal() {
  const sel = limpezaSelecionadas();
  return {
    bytes: sel.reduce((s, c) => s + Math.max(c.tamanhoBytes, 0), 0),
    desconhecido: sel.some((c) => c.tamanhoBytes < 0),
    n: sel.length,
  };
}

function limpezaAtualizarTotal() {
  const el = document.getElementById('lp-total');
  const btn = document.getElementById('lp-limpar');
  if (!el || !btn) return;
  const tot = limpezaTotal();
  el.textContent = tot.n === 0 ? t('limpeza.nenhuma')
    : t(tot.desconhecido ? 'limpeza.totalMais' : 'limpeza.total', { tamanho: fmtBytes(tot.bytes) });
  if (tot.n === 0) btn.setAttribute('data-bloq', ''); else btn.removeAttribute('data-bloq');
  aplicarOcupado();
}

function limpezaProgresso(p) {
  const L = S.limpeza;
  if (p.tipo === 'progresso') {
    if (typeof p.pct === 'number') L.pct = p.pct;
    if (p.msg) L.msg = p.msg;
  } else if (p.tipo === 'log' && p.msg) {
    L.log.push(p.msg);
    L.log = L.log.slice(-5);
  }
  const barra = document.getElementById('lp-barra');
  if (barra) barra.style.setProperty('--pct', L.pct);
  const msg = document.getElementById('lp-msg');
  if (msg) msg.textContent = L.msg;
  const log = document.getElementById('lp-log');
  if (log) { log.textContent = ''; L.log.forEach((l) => log.append(h('li', { text: l }))); }
}

async function limpar() {
  const sel = limpezaSelecionadas();
  if (sel.length === 0 || S.ocupado) return;
  const tot = limpezaTotal();
  const nomes = sel.map((c) => t('cat.' + c.id + '.nome')).join(', ');
  const tamanho = tot.desconhecido ? t('limpeza.confirmarMais', { tamanho: fmtBytes(tot.bytes) }) : fmtBytes(tot.bytes);
  const x = sel.length === 1 ? t('limpeza.confirmarX1', { tamanho }) : t('limpeza.confirmarXn', { n: sel.length, tamanho });
  const ok1 = await perguntar({
    titulo: t('limpeza.confirmarTitulo'),
    corpo: [h('p', { text: t('limpeza.confirmarTexto', { x, y: nomes, z: t('limpeza.confirmarDesfazer') }) })],
    ok: t('limpeza.limpar'),
  });
  if (!ok1) return;

  const perigosas = sel.filter((c) => c.confirmacaoDupla || CATEGORIAS_DUPLA.includes(c.id));
  let confirmado = false;
  if (perigosas.length > 0) {
    const ok2 = await perguntar({
      titulo: t('limpeza.confirmarDuplaTitulo'),
      corpo: [
        h('p', { class: 'aviso', text: t('limpeza.confirmacaoDupla') }),
        h('p', { class: 'suave', text: t('limpeza.confirmacaoDuplaLista', { y: perigosas.map((c) => t('cat.' + c.id + '.nome')).join(', ') }) }),
      ],
      exigeCheck: t('limpeza.entendi'),
      ok: t('limpeza.apagar'),
      okClasse: 'perigo',
    });
    if (!ok2) return;
    confirmado = true;
  }

  const L = S.limpeza;
  L.rodando = true; L.log = []; L.pct = 0; L.msg = t('limpeza.progresso'); L.resultado = null;
  renderAtual();
  const params = { categorias: sel.map((c) => c.id) };
  if (confirmado) params.confirmado = true;
  if (S.ajustes.modoAvancado) params.avancado = true;
  try {
    L.resultado = await api.executar('limpeza', 'limpar', params, limpezaProgresso);
  } catch (e) {
    mostrarErro(e);
  }
  L.rodando = false;
  try { await analisarLimpeza(); } catch (e) { mostrarErro(e); }
  renderAtual();
}

VISTAS.limpeza = {
  render(main) {
    const L = S.limpeza;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('limpeza.titulo') }));
    main.append(v);

    const precisa = S.base !== 'carregando' && !L.rodando && !S.ocupado &&
      (!S.analise || L.avancadoAnalisado !== !!S.ajustes.modoAvancado);
    if (precisa) {
      setTimeout(async () => {
        try { await analisarLimpeza(); } catch (e) { mostrarErro(e); S.analise = S.analise || { categorias: [] }; }
        if (S.vista === 'limpeza') renderAtual();
      }, 0);
    }
    if (!S.analise) {
      v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('limpeza.analisando') })));
      return;
    }

    if (L.rodando) {
      v.append(h('div', { class: 'progresso cartao' },
        h('div', { class: 'trilho' }, h('i', { id: 'lp-barra', vars: { '--pct': L.pct } })),
        h('p', { class: 'pequeno suave', id: 'lp-msg', text: L.msg }),
        h('ul', { class: 'registro', id: 'lp-log' }, L.log.map((l) => h('li', { text: l })))));
    }
    if (L.resultado) {
      const r = L.resultado;
      v.append(h('div', { class: 'cartao resultado' },
        h('p', { class: 'grande', text: t(r.pulados === 1 ? 'limpeza.resultadoUm' : 'limpeza.resultado', { liberado: fmtBytes(r.liberadoBytes), pulados: r.pulados }) })));
    }
    v.append(h('p', { class: 'suave', text: t('limpeza.intro') }));
    for (const c of categoriasVisiveis()) {
      const indisp = !c.disponivel;
      const caixa = h('input', {
        type: 'checkbox', class: 'acao', id: 'cat-' + c.id, checked: !indisp && L.sel.has(c.id),
        'data-bloq': indisp ? '' : null,
        onchange: (e) => {
          if (e.target.checked) L.sel.add(c.id); else L.sel.delete(c.id);
          limpezaAtualizarTotal();
        },
      });
      v.append(h('label', { class: 'cat' + (indisp ? ' indisp' : ''), for: 'cat-' + c.id },
        caixa,
        h('span', { class: 'nome-cat' },
          h('span', { class: 'ponto ' + c.cor, title: t('limpeza.' + c.cor) }),
          h('span', { text: t('cat.' + c.id + '.nome') })),
        h('span', { class: 'tam' + (c.tamanhoBytes < 0 ? ' desc-tam' : ''), text: indisp ? '' : fmtBytes(c.tamanhoBytes) }),
        h('span', { class: 'desc', text: t('cat.' + c.id + '.desc') }),
        indisp ? h('span', { class: 'motivo', text: c.motivoIndisponivel }) : null));
    }

    v.append(h('div', { class: 'rodape-limpeza' },
      h('span', { class: 'total', id: 'lp-total' }),
      h('button', { type: 'button', class: 'btn acao', id: 'lp-limpar', text: t('limpeza.limpar'), onclick: () => limpar() })));
    limpezaAtualizarTotal();

  },
};
