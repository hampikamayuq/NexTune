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
    if (S.ocupado) v.append(h('p', { class: 'suave pequeno', text: t('opcoes.ocupado') }));
  },
};
