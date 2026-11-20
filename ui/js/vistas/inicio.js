'use strict';

function perfilTexto(p) {
  return {
    classe: t('inicio.perfil.' + p.classe),
    disco: t('inicio.disco.' + p.disco),
  };
}

// Soma dos itens verdes disponíveis com tamanho conhecido.
function lixoVerdeBytes() {
  if (!S.analise) return 0;
  return S.analise.categorias
    .filter((c) => c.cor === 'verde' && c.disponivel && c.tamanhoBytes > 0)
    .reduce((s, c) => s + c.tamanhoBytes, 0);
}

VISTAS.inicio = {
  render(main) {
    const v = h('section', { class: 'vista' }, h('h1', { text: t('inicio.titulo') }));
    main.append(v);

    if (S.base === 'carregando') {
      v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('inicio.analisando') })));
      return;
    }
    if (S.base === 'erro') {
      v.append(
        h('div', { class: 'cartao' },
          h('p', { text: t('inicio.erro', { erro: S.baseErro }) }),
          h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarBase() })));
      return;
    }

    const d = S.diag;
    const p = d.perfil;
    const pt = perfilTexto(p);
    v.append(
      h('p', { class: 'seu-pc', text: t('inicio.seuPc', {
        nome: (d.equipo.fabricante + ' ' + d.equipo.modelo).trim(),
        disco: t('inicio.discoCurto.' + p.disco),
        ram: fmtGb(d.ram.totalBytes),
      }) }),
      h('p', { class: 'perfil-linha' },
        t('inicio.perfilLinha', pt) + ' ',
        h('button', { type: 'button', class: 'link acao', text: t('inicio.trocar'), onclick: () => trocarPerfil() })));

    v.append(h('h2', { text: t('inicio.recomendado') }));
    const lixo = lixoVerdeBytes();
    const limiar = ((S.perfis && S.perfis.limites && S.perfis.limites.lixoNotificarMB) || 500) * 1048576;
    if (lixo > limiar) {
      v.append(h('div', { class: 'cartao recomendado' },
        h('div', {},
          h('div', { class: 'tamanho', text: fmtBytes(lixo) }),
          h('div', { class: 'texto', text: t('inicio.lixo') })),
        h('button', { type: 'button', class: 'btn acao', text: t('inicio.limpar'), onclick: () => { limpezaMarcarVerdes(); irPara('limpeza'); } })));
    } else if (!inicioRecomendados().length) {
      v.append(h('p', { class: 'suave', text: t('inicio.nadaAgora') }));
    }

    const nInicio = inicioRecomendados().length;
    if (nInicio) {
      v.append(h('div', { class: 'cartao recomendado card-inicio' },
        h('div', {},
          h('div', { class: 'titulo-card', text: t(nInicio === 1 ? 'inicio.inicializacaoUm' : 'inicio.inicializacao', { n: nInicio }) }),
          h('div', { class: 'texto', text: t('inicio.inicializacaoTexto') })),
        h('button', { type: 'button', class: 'btn acao', text: t('inicio.ver'), onclick: () => irPara('inicializacao') })));
    }

    v.append(
      h('p', { class: 'frase', text: t('inicio.frase') }),
      h('div', { class: 'atalhos' },
        h('button', { type: 'button', class: 'link', text: t('inicio.irDiagnostico'), onclick: () => irPara('diagnostico') }),
        h('button', { type: 'button', class: 'link', text: t('inicio.irLimpeza'), onclick: () => irPara('limpeza') })));
  },
};
