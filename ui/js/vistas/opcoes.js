'use strict';

async function gravarAjuste(parcial, anular) {
  try {
    S.ajustes = await api.ajustes.gravar(parcial);
    toast(t('opcoes.salvo'), 'ok');
    if ('modoLeve' in parcial) {
      S.info = await api.info();
      aplicarLeve();
    }
  } catch (e) {
    mostrarErro(e);
    if (anular) anular();
  }
}

// "Abrir com o Windows": estado lido do sistema ao renderizar (assíncrono) e botão Ligar/Desligar.
function linhaAutostart() {
  const estado = h('span', { class: 'suave', text: '…' });
  const botao = h('button', { type: 'button', class: 'btn sec acao escrita', 'data-bloq': true, text: t('opcoes.autostartLigar') });
  let atual = false;
  const mostrar = (ligado) => {
    atual = ligado;
    estado.textContent = t('opcoes.autostart') + ': ' + t(ligado ? 'opcoes.autostartLigado' : 'opcoes.autostartDesligado');
    botao.textContent = t(ligado ? 'opcoes.autostartDesligar' : 'opcoes.autostartLigar');
    botao.removeAttribute('data-bloq');
    aplicarOcupado();
  };
  botao.addEventListener('click', async () => {
    try { mostrar(await api.autostart(!atual)); } catch (e) { toast(t('opcoes.autostartErro', { erro: e.message || String(e) }), 'erro'); }
  });
  api.autostartEstado().then(mostrar).catch((e) => toast(t('opcoes.autostartErro', { erro: e.message || String(e) }), 'erro'));
  return h('div', { class: 'campo' }, estado, botao);
}

// Cartão da versão nova (versão + notas em texto + botão que baixa e instala).
function cartaoNovaVersao(r) {
  return h('div', { class: 'resultado' },
    h('p', { class: 'destaque', text: t('opcoes.atualizacaoDisponivel', { v: r.versao }) }),
    r.notas ? h('p', { class: 'suave pequeno notas-atu', text: r.notas }) : null,
    h('button', { type: 'button', class: 'btn acao escrita', text: t('opcoes.instalarAtualizacao'), onclick: async () => {
      const ok = await perguntar({ titulo: t('opcoes.instalarTitulo', { v: r.versao }), corpo: [h('p', { text: t('opcoes.instalarTexto') })], ok: t('opcoes.instalarAtualizacao') });
      if (!ok) return;
      try { await api.atualizacao.instalar(); } catch (e) { toast(t('opcoes.atualizacaoErro', { erro: e.message || String(e) }), 'erro'); }
    } }));
}

function cartaoAtualizacao() {
  const saida = h('div', {});
  const procurar = h('button', { type: 'button', class: 'btn sec acao', text: t('opcoes.procurarAtualizacao'), onclick: async () => {
    saida.textContent = '';
    try {
      const r = await api.atualizacao.verificar();
      if (!r) toast(t('opcoes.semAtualizacao'), 'ok');
      else saida.append(cartaoNovaVersao(r));
    } catch (e) {
      toast(t('opcoes.atualizacaoErro', { erro: e.message || String(e) }), 'erro');
    }
  } });
  return h('div', { class: 'cartao' }, h('h3', { text: t('opcoes.atualizacaoTitulo') }),
    h('p', { text: t('opcoes.versaoAtual', { v: S.info.versao }) }), procurar, saida);
}

VISTAS.opcoes = {
  render(main) {
    const A = S.ajustes;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('opcoes.titulo') }));
    main.append(v);
    const opcoes = (prefixo, chaves) => chaves.map((k) => h('option', { value: k, text: t(prefixo + k), selected: false }));

    const selLeve = h('select', { id: 'op-leve', class: 'acao', onchange: (e) => gravarAjuste({ modoLeve: e.target.value }, () => { e.target.value = A.modoLeve; }) },
      opcoes('opcoes.modoLeve.', ['auto', 'on', 'off']));
    selLeve.value = A.modoLeve;

    const chkAv = h('input', { type: 'checkbox', id: 'op-av', checked: !!A.modoAvancado,
      onchange: (e) => gravarAjuste({ modoAvancado: e.target.checked }, () => { e.target.checked = !!A.modoAvancado; }) });

    const selPonto = h('select', { id: 'op-ponto', onchange: (e) => gravarAjuste({ pontoRestauracao: e.target.value }, () => { e.target.value = A.pontoRestauracao; }) },
      opcoes('opcoes.pontoRestauracao.', ['perguntar', 'ligar', 'pular']));
    selPonto.value = A.pontoRestauracao;

    const numDias = h('input', { type: 'number', id: 'op-dias', min: 1, max: 90, step: 1, value: A.diasQuarentena,
      onchange: (e) => {
        const n = Number(e.target.value);
        if (!Number.isInteger(n) || n < 1 || n > 90) { e.target.value = A.diasQuarentena; toast(t('opcoes.diasQuarentenaAjuda'), 'erro'); return; }
        gravarAjuste({ diasQuarentena: n }, () => { e.target.value = A.diasQuarentena; });
      } });

    const campo = (id, rotulo, ajuda, controle) => h('div', { class: 'campo' },
      h('label', { class: 'rotulo', for: id, text: rotulo }), controle, h('p', { class: 'ajuda', text: ajuda }));

    v.append(h('div', { class: 'cartao' },
      campo('op-leve', t('opcoes.modoLeve'), t('opcoes.modoLeveAjuda'), selLeve),
      campo('op-av', t('opcoes.modoAvancado'), t('opcoes.modoAvancadoAjuda'), chkAv),
      campo('op-ponto', t('opcoes.pontoRestauracao'), '', selPonto),
      campo('op-dias', t('opcoes.diasQuarentena'), t('opcoes.diasQuarentenaAjuda'), numDias)));
    const chkLemb = h('input', { type: 'checkbox', id: 'op-lemb', checked: !!A.lembretes,
      onchange: (e) => gravarAjuste({ lembretes: e.target.checked }, () => { e.target.checked = !!A.lembretes; }) });
    const numLemb = h('input', { type: 'number', id: 'op-lemb-dias', min: 1, max: 30, step: 1, value: A.lembretesDias,
      onchange: (e) => {
        const n = Number(e.target.value);
        if (!Number.isInteger(n) || n < 1 || n > 30) { e.target.value = A.lembretesDias; toast(t('opcoes.lembretesDiasAjuda'), 'erro'); return; }
        gravarAjuste({ lembretesDias: n }, () => { e.target.value = A.lembretesDias; });
      } });
    const chkBandeja = h('input', { type: 'checkbox', id: 'op-bandeja', checked: !!A.bandeja,
      onchange: (e) => gravarAjuste({ bandeja: e.target.checked }, () => { e.target.checked = !!A.bandeja; }) });
    v.append(h('div', { class: 'cartao' }, h('h3', { text: t('opcoes.bandejaTitulo') }),
      campo('op-lemb', t('opcoes.lembretes'), t('opcoes.lembretesAjuda'), chkLemb),
      campo('op-lemb-dias', t('opcoes.lembretesDias'), t('opcoes.lembretesDiasAjuda'), numLemb),
      campo('op-bandeja', t('opcoes.bandeja'), t('opcoes.bandejaAjuda'), chkBandeja),
      linhaAutostart()));
    v.append(cartaoAtualizacao());
    if (S.ocupado) v.append(h('p', { class: 'suave pequeno', text: t('opcoes.ocupado') }));
  },
};
