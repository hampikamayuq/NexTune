'use strict';

// Reparo (módulo reparo): acha instalações do Windows Installer sem a cópia local do .msi e sem origem
// acessível (o Windows não consegue atualizar nem desinstalar e responde 1603/1612) e, com confirmação,
// remove só o REGISTRO delas, com backup na Quarentena. Nada vem marcado: quem escolhe é o usuário.

async function carregarReparo() {
  const R = S.reparo;
  if (S.ocupado) return;
  R.carregando = true; R.erro = null;
  if (S.vista === 'reparo') renderAtual();
  try {
    const r = await api.executar('reparo', 'diagnosticar', {}, null);
    R.lista = r.produtos || [];
    R.sel = new Set([...R.sel].filter((c) => R.lista.some((p) => p.codigo === c && p.reparavel)));
  } catch (e) {
    R.erro = e.message || String(e);
  }
  R.carregando = false;
  if (S.vista === 'reparo') renderAtual();
}

async function repararSelecionados() {
  const R = S.reparo;
  const ids = [...R.sel];
  if (S.ocupado || !ids.length) return;
  const ok = await perguntar({
    titulo: t('reparo.repararTitulo', { n: ids.length }),
    corpo: [
      h('p', { text: t('reparo.repararTexto') }),
      h('p', { class: 'aviso pequeno', text: t('reparo.repararAviso') }),
      h('ul', {}, ...ids.map((c) => {
        const p = (R.lista || []).find((x) => x.codigo === c);
        return h('li', { text: p ? p.nome + (p.versao ? ' ' + p.versao : '') : c });
      })),
    ],
    ok: t('reparo.reparar'),
  });
  if (!ok) return;
  if (!(await garantirPonto())) return;
  try {
    const r = await api.executar('reparo', 'reparar', { ids, confirmado: true }, null);
    const feitos = r.reparados || [];
    if (feitos.length) toast(feitos.length === 1 ? t('reparo.feitoUm') : t('reparo.feitos', { n: feitos.length }), 'ok');
    (r.falhas || []).forEach((f) => {
      const p = (R.lista || []).find((x) => x.codigo === f.id);
      toast(t('reparo.falha', { nome: p ? p.nome : f.id, erro: f.erro }), 'erro');
    });
    R.sel = new Set();
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarReparo();
  // Depois da lista: cada chamada deixa a interface ocupada e a seguinte seria ignorada. O contador da
  // Quarentena no menu passa a incluir o backup recém-criado.
  if (typeof carregarQuarentena === 'function') await carregarQuarentena();
}

function cartaoReparo(p) {
  const R = S.reparo;
  const id = 'rep-' + p.codigo;
  const caixa = p.reparavel
    ? h('input', {
      type: 'checkbox', class: 'acao escrita', id, checked: R.sel.has(p.codigo),
      onchange: (e) => { if (e.target.checked) R.sel.add(p.codigo); else R.sel.delete(p.codigo); renderAtual(); },
    })
    : h('span', { class: 'sem-caixa' });
  const origens = (p.origens || []).length ? t('reparo.origem', { origens: p.origens.join('; ') }) : t('reparo.semOrigem');
  return h(p.reparavel ? 'label' : 'div', { class: 'atu' + (p.reparavel ? '' : ' indisp'), for: p.reparavel ? id : null },
    caixa,
    h('div', { class: 'atu-info' },
      h('div', { class: 'atu-nome' }, h('span', { text: p.nome || p.codigo }), p.versao ? h('span', { class: 'selo', text: p.versao }) : null),
      h('div', { class: 'suave pequeno', text: origens }),
      p.reparavel ? null : h('div', { class: 'aviso pequeno', text: t('reparo.naoReparavel', { motivo: p.motivo || '' }) })));
}

VISTAS.reparo = {
  render(main) {
    const R = S.reparo;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('reparo.titulo') }), h('p', { class: 'suave', text: t('reparo.intro') }));
    main.append(v);

    v.append(h('div', { class: 'barra-prog' },
      h('button', { type: 'button', class: 'btn sec acao', text: t(R.lista ? 'reparo.procurarDeNovo' : 'reparo.procurar'), onclick: () => carregarReparo() })));

    if (R.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('reparo.erro', { erro: R.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarReparo() })));
    }
    if (R.carregando) {
      v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('reparo.procurando') })));
      return;
    }
    if (!R.lista) return;
    if (!R.lista.length) {
      v.append(h('p', { class: 'suave', text: t('reparo.nada') }));
      return;
    }
    v.append(h('h2', { text: t(R.lista.length === 1 ? 'reparo.achadosUm' : 'reparo.achados', { n: R.lista.length }) }));
    R.lista.forEach((p) => v.append(cartaoReparo(p)));
    v.append(h('div', { class: 'barra-prog' },
      h('button', {
        type: 'button', class: 'btn acao escrita', 'data-bloq': R.sel.size ? null : '',
        text: t('reparo.reparar') + (R.sel.size ? ' (' + R.sel.size + ')' : ''), onclick: () => repararSelecionados(),
      })));
    aplicarOcupado();
  },
};
