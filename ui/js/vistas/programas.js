'use strict';

// Programas: lista (programas/listar), filtros, desinstalação com ponto de restauração antes e
// restos para a quarentena depois. Cores: verde = pode remover, amarelo = decide você,
// vermelho = protegido (sem botão Desinstalar), null = sem classificação.

const PROGRAMAS_ABAS = ['todos', 'recomendados', 'loja', 'classicos'];
const PROGRAMAS_ORDENS = ['nome', 'tamanho', 'data'];

// Comparação sem acento e sem diferenciar caixa.
function normalizarTexto(s) {
  return String(s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
}

function programasProgresso(p) {
  const P = S.programas;
  if (!P.prog) return;
  if (p.tipo === 'progresso') {
    if (typeof p.pct === 'number') P.prog.pct = p.pct;
    if (p.msg) P.prog.msg = p.msg;
  }
  const barra = document.getElementById('pr-barra');
  if (barra) barra.style.setProperty('--pct', P.prog.pct);
  const msg = document.getElementById('pr-msg');
  if (msg) msg.textContent = P.prog.msg;
}

async function carregarProgramas() {
  const P = S.programas;
  if (S.ocupado) return;
  P.carregando = true; P.erro = null; P.prog = { pct: 0, msg: t('programas.carregando') };
  renderAtual();
  try {
    const r = await api.executar('programas', 'listar', {}, programasProgresso);
    P.lista = r.programas || [];
  } catch (e) {
    P.erro = e.message || String(e);
  }
  P.carregando = false; P.prog = null;
  renderAtual();
}

function programasFiltrados() {
  const P = S.programas;
  const q = normalizarTexto(P.filtro.trim());
  let lista = (P.lista || []).filter((p) => {
    if (P.aba === 'recomendados' && p.cor !== 'verde') return false;
    if (P.aba === 'loja' && p.tipo !== 'store') return false;
    if (P.aba === 'classicos' && p.tipo !== 'classico') return false;
    if (!q) return true;
    return normalizarTexto(p.nome).includes(q) || normalizarTexto(p.editor).includes(q);
  });
  const porNome = (a, b) => String(a.nome).localeCompare(String(b.nome), 'pt-BR', { sensitivity: 'base' });
  if (P.ordem === 'tamanho') {
    lista.sort((a, b) => (Math.max(b.tamanhoBytes, -1) - Math.max(a.tamanhoBytes, -1)) || porNome(a, b));
  } else if (P.ordem === 'data') {
    const ms = (p) => (p.instaladoEm ? new Date(p.instaladoEm).getTime() || 0 : 0);
    lista.sort((a, b) => (ms(b) - ms(a)) || porNome(a, b));
  } else {
    lista.sort(porNome);
  }
  return lista;
}

function linkStore(p) {
  return 'ms-windows-store://pdp/?ProductId=' + p.productId;
}

// Texto "para desfazer" da confirmação: Store com ProductId → link; clássico → site do fabricante.
function programasDesfazer(p) {
  if (p.tipo === 'store' && p.productId) return t('programas.desfazerStore');
  if (p.tipo === 'store') return t('programas.desfazerStoreSemLink');
  if (p.siteReinstalar) return t('programas.desfazerSite', { site: p.siteReinstalar });
  return t('programas.desfazerGenerico');
}

async function abrirLinkStore(url) {
  try {
    await api.abrirUrl(url);
    if (S.info.demo) toast(t('programas.linkDemo'), 'aviso');
  } catch (e) {
    mostrarErro(e);
  }
}

async function desinstalarPrograma(p) {
  if (S.ocupado || p.protegido) return;

  const editor = p.editor || t('programas.editorDesconhecido');
  const corpo = [h('p', { text: t('programas.confirmarTexto', { nome: p.nome, editor, tamanho: fmtBytes(p.tamanhoBytes), z: programasDesfazer(p) }) })];
  if (p.tipo === 'store' && p.productId) {
    corpo.push(h('label', { class: 'rotulo-link', for: 'pr-link', text: t('programas.linkStore') }),
      h('div', { class: 'linha-link' },
        h('input', { type: 'text', id: 'pr-link', class: 'link-store', readonly: true, value: linkStore(p), onfocus: (e) => e.target.select() }),
        h('button', { type: 'button', class: 'btn sec acao', text: t('programas.abrirLink'), onclick: () => abrirLinkStore(linkStore(p)) })));
  }
  let chkDesprov = null;
  if (p.tipo === 'store' && S.ajustes.modoAvancado) {
    chkDesprov = h('input', { type: 'checkbox', id: 'pr-desprov' });
    corpo.push(h('label', { class: 'opcao', for: 'pr-desprov' }, chkDesprov, h('span', { text: t('programas.desprovisionar') })),
      h('p', { class: 'aviso pequeno', text: t('programas.desprovisionarAviso') }));
  }
  const ok = await perguntar({ titulo: t('programas.confirmarTitulo', { nome: p.nome }), corpo, ok: t('programas.desinstalar') });
  if (!ok) return;
  if (!(await garantirPonto())) return;

  const params = { id: p.id, confirmado: true };
  if (S.ajustes.modoAvancado) params.avancado = true;
  if (chkDesprov && chkDesprov.checked) params.desprovisionar = true;

  const P = S.programas;
  P.ultimo = null;
  P.prog = { pct: 0, msg: t('programas.progresso', { nome: p.nome }) };
  renderAtual();
  document.getElementById('principal').scrollTop = 0; // progresso e cartão de resultado ficam no topo
  try {
    const r = await api.executar('programas', 'desinstalar', params, programasProgresso);
    // Contrato: `restos` já é a lista de candidatos (mesmo formato de restos.candidatos).
    const cand = Array.isArray(r.restos) ? r.restos : ((r.restos && r.restos.candidatos) || []);
    P.ultimo = { programa: p, resultado: r, candidatos: cand, sel: new Set(cand.map((c, i) => i)), movidos: null };
  } catch (e) {
    mostrarErroEscrita(e);
  }
  P.prog = null;
  await carregarProgramas();
  document.getElementById('principal').scrollTop = 0;
}

async function moverRestos() {
  const P = S.programas;
  const u = P.ultimo;
  if (!u || S.ocupado) return;
  const sel = u.candidatos.filter((c, i) => u.sel.has(i));
  if (!sel.length) return;
  const dias = S.ajustes.diasQuarentena;
  const tamanho = fmtBytes(sel.reduce((s, c) => s + Math.max(c.tamanhoBytes || 0, 0), 0));
  const ok = await perguntar({
    titulo: sel.length === 1 ? t('programas.moverTituloUm') : t('programas.moverTitulo', { n: sel.length }),
    corpo: [h('p', { text: sel.length === 1 ? t('programas.moverTextoUm', { tamanho, dias }) : t('programas.moverTexto', { n: sel.length, tamanho, dias }) })],
    ok: t('programas.moverQuarentena'),
  });
  if (!ok) return;
  try {
    const r = await api.executar('programas', 'limparRestos', {
      itens: sel.map((c) => ({ tipo: c.tipo, caminho: c.caminho })), confirmado: true, nome: u.programa.nome,
    }, null);
    u.movidos = r;
    const falhas = (r.falhas || []).length;
    toast(falhas ? t('programas.movidosFalhas', { n: r.movidos, f: falhas }) : (r.movidos === 1 ? t('programas.movidoUm') : t('programas.movidos', { n: r.movidos })), 'ok');
    renderAtual();
    try { await carregarQuarentena(); } catch (e) { mostrarErro(e); }
  } catch (e) {
    mostrarErroEscrita(e);
  }
}

function cartaoResultadoProgramas() {
  const P = S.programas;
  const u = P.ultimo;
  const r = u.resultado;
  const detalhes = [t('programas.modo.' + r.modo)];
  if (typeof r.codigo === 'number') detalhes.push(t('programas.codigo', { codigo: r.codigo }));
  else if (r.modo === 'assistente') detalhes.push(t('programas.assistenteAberto'));
  const fechar = h('button', { type: 'button', class: 'btn sec', text: u.movidos ? t('comum.fechar') : t('programas.deixar'), onclick: () => { P.ultimo = null; renderAtual(); } });
  const cartao = h('div', { class: 'cartao resultado' },
    h('p', { class: 'grande', text: t('programas.resultadoTitulo', { nome: u.programa.nome }) }),
    h('p', { class: 'suave pequeno', text: detalhes.join(' · ') }));

  if (u.movidos) {
    const m = u.movidos;
    const falhas = m.falhas || [];
    cartao.append(
      h('p', { text: falhas.length ? t('programas.movidosFalhas', { n: m.movidos, f: falhas.length }) : (m.movidos === 1 ? t('programas.movidoUm') : t('programas.movidos', { n: m.movidos })) }),
      ...falhas.map((f) => h('p', { class: 'aviso pequeno', text: t('programas.falhaResto', { caminho: f.caminho, erro: f.erro }) })),
      h('div', { class: 'acoes' },
        h('button', { type: 'button', class: 'btn sec', text: t('programas.verQuarentena'), onclick: () => irPara('quarentena') }), fechar));
    return cartao;
  }

  if (!u.candidatos.length) {
    cartao.append(h('p', { class: 'suave', text: t('programas.restosNenhum') }), h('div', { class: 'acoes' }, fechar));
    return cartao;
  }

  const btnMover = h('button', { type: 'button', class: 'btn acao escrita', text: t('programas.moverQuarentena'), onclick: () => moverRestos() });
  const atualizarBotao = () => { if (u.sel.size === 0) btnMover.setAttribute('data-bloq', ''); else btnMover.removeAttribute('data-bloq'); aplicarOcupado(); };
  cartao.append(
    h('h4', { text: t('programas.restosTitulo') }),
    h('p', { class: 'suave pequeno', text: t('programas.restosIntro', { dias: S.ajustes.diasQuarentena }) }));
  u.candidatos.forEach((c, i) => {
    const id = 'resto-' + i;
    cartao.append(h('label', { class: 'resto', for: id },
      h('input', { type: 'checkbox', id, class: 'acao', checked: u.sel.has(i), onchange: (e) => { if (e.target.checked) u.sel.add(i); else u.sel.delete(i); atualizarBotao(); } }),
      h('span', { class: 'linha-resto' },
        h('span', { class: 'selo', text: t('programas.resto.' + c.tipo) }),
        h('span', { class: 'caminho', text: c.caminho }),
        h('span', { class: 'tam', text: fmtBytes(c.tamanhoBytes) })),
      h('span', { class: 'suave pequeno motivo-resto', text: c.motivo || '' })));
  });
  cartao.append(h('div', { class: 'acoes' }, fechar, btnMover));
  setTimeout(atualizarBotao, 0);
  return cartao;
}

function linhaPrograma(p) {
  const selos = [];
  if (p.tipo === 'store') selos.push(h('span', { class: 'selo', text: t('programas.selo.store') }));
  if (p.protegido) selos.push(h('span', { class: 'selo destaque', title: p.motivoProtegido || '', text: t('programas.selo.protegido') }));
  const ns = (p.servicos || []).length;
  if (ns > 0) selos.push(h('span', { class: 'selo', title: p.servicos.join(', '), text: ns === 1 ? t('programas.selo.servicoUm') : t('programas.selo.servicos', { n: ns }) }));
  if (p.ramBytes > 0) selos.push(h('span', { class: 'selo', text: t('programas.selo.ram', { ram: fmtBytes(p.ramBytes) }) }));

  const meta = [p.editor || t('programas.editorDesconhecido')];
  if (p.versao) meta.push(t('programas.versao', { v: p.versao }));
  if (p.instaladoEm) meta.push(t('programas.instaladoEm', { data: fmtData(p.instaladoEm) }));

  return h('div', { class: 'prog' + (p.protegido ? ' protegido' : '') },
    h('span', { class: 'ponto ' + (p.cor || 'neutro'), role: 'img', title: t('programas.cor.' + (p.cor || 'nenhuma')), 'aria-label': t('programas.cor.' + (p.cor || 'nenhuma')) }),
    h('div', { class: 'prog-info' },
      h('div', { class: 'prog-nome' }, h('span', { text: p.nome }), selos),
      h('div', { class: 'suave pequeno', text: meta.join(' · ') }),
      p.motivoCor ? h('div', { class: 'suave pequeno motivo-cor', text: p.motivoCor }) : null),
    h('div', { class: 'prog-lado' },
      h('span', { class: 'tam' + (p.tamanhoBytes < 0 ? ' desc-tam' : ''), text: fmtBytes(p.tamanhoBytes) }),
      p.protegido ? null : h('button', { type: 'button', class: 'btn sec acao escrita', text: t('programas.desinstalar'), onclick: () => desinstalarPrograma(p) })));
}

// ---- restos de programas já desinstalados (programas/restosAntigos) ----
// Pastas sem programa instalado correspondente e atalhos quebrados do menu Iniciar. Os itens `seguro`
// vêm marcados; os parecidos com um programa ainda instalado só vão se o usuário marcar de propósito.

async function carregarRestosAntigos() {
  const R = S.restosAntigos;
  if (S.ocupado) return;
  R.carregando = true; R.erro = null;
  if (S.vista === 'programas') renderAtual();
  try {
    const r = await api.executar('programas', 'restosAntigos', {}, null);
    const lista = Array.isArray(r.itens) ? r.itens : [];
    // Quem já estava na lista mantém a marcação do usuário; os novos seguem o `seguro`.
    const antes = new Map((R.lista || []).map((i) => [i.caminho, R.sel.has(i.caminho)]));
    R.sel = new Set(lista.filter((i) => (antes.has(i.caminho) ? antes.get(i.caminho) : i.seguro === true)).map((i) => i.caminho));
    R.lista = lista;
  } catch (e) {
    R.erro = e.message || String(e);
  }
  R.carregando = false;
  if (S.vista === 'programas') renderAtual();
}

async function moverRestosAntigos() {
  const R = S.restosAntigos;
  if (S.ocupado || !R.lista) return;
  const sel = R.lista.filter((i) => R.sel.has(i.caminho));
  if (!sel.length) return;
  const dias = S.ajustes.diasQuarentena;
  const tamanho = fmtBytes(sel.reduce((s, i) => s + Math.max(i.bytes || 0, 0), 0));
  const corpo = [h('p', { text: sel.length === 1 ? t('programas.moverTextoUm', { tamanho, dias }) : t('programas.moverTexto', { n: sel.length, tamanho, dias }) })];
  const parecidos = sel.filter((i) => i.seguro !== true);
  if (parecidos.length) {
    corpo.push(h('div', { class: 'aviso pequeno' },
      h('p', { text: parecidos.length === 1 ? t('programas.antigos.moverParecidoUm') : t('programas.antigos.moverParecidos', { n: parecidos.length }) }),
      h('ul', {}, ...parecidos.map((i) => h('li', { text: i.parecido ? t('programas.antigos.itemParecido', { nome: i.nome || i.caminho, parecido: i.parecido }) : (i.nome || i.caminho) })))));
  }
  const ok = await perguntar({
    titulo: sel.length === 1 ? t('programas.moverTituloUm') : t('programas.moverTitulo', { n: sel.length }),
    corpo,
    ok: t('programas.moverQuarentena'),
  });
  if (!ok) return;
  if (!(await garantirPonto())) return;
  try {
    // O script descreve a entrada como 'Restos de ' + nome: fica "Restos de programas já desinstalados".
    const r = await api.executar('programas', 'limparRestos', {
      itens: sel.map((i) => ({ tipo: i.tipo, caminho: i.caminho })), confirmado: true, nome: t('programas.antigos.nomeQuarentena'),
    }, null);
    const falhas = r.falhas || [];
    if (r.movidos > 0 || !falhas.length) {
      toast(falhas.length ? t('programas.movidosFalhas', { n: r.movidos, f: falhas.length }) : (r.movidos === 1 ? t('programas.movidoUm') : t('programas.movidos', { n: r.movidos })), 'ok');
    }
    falhas.forEach((f) => toast(t('programas.falhaResto', { caminho: f.caminho, erro: f.erro }), 'erro'));
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarRestosAntigos();
  // Depois da lista: cada chamada deixa a interface ocupada e a seguinte seria ignorada. O contador da
  // Quarentena no menu passa a incluir a entrada recém-criada.
  if (typeof carregarQuarentena === 'function') await carregarQuarentena();
}

function linhaRestoAntigo(i, idx, aoMudar) {
  const R = S.restosAntigos;
  const id = 'ra-' + idx;
  const aviso = i.seguro === true ? null
    : h('div', { class: 'aviso pequeno', text: i.parecido ? t('programas.antigos.parecido', { parecido: i.parecido }) : t('programas.antigos.parecidoSemNome') });
  return h('label', { class: 'atu resto-antigo', for: id },
    h('input', {
      type: 'checkbox', class: 'acao', id, checked: R.sel.has(i.caminho),
      onchange: (e) => { if (e.target.checked) R.sel.add(i.caminho); else R.sel.delete(i.caminho); aoMudar(); },
    }),
    h('div', { class: 'atu-info' },
      h('div', { class: 'atu-nome' }, h('span', { text: i.nome || i.caminho }), h('span', { class: 'selo', text: t('programas.resto.' + i.tipo) })),
      h('div', { class: 'suave pequeno caminho', text: i.caminho }),
      i.motivo ? h('div', { class: 'suave pequeno', text: i.motivo }) : null,
      aviso),
    h('span', { class: 'tam' + (i.bytes < 0 ? ' desc-tam' : ''), text: fmtBytes(i.bytes) }));
}

function renderRestosAntigos(v) {
  const R = S.restosAntigos;
  v.append(h('p', { class: 'suave', text: t('programas.antigos.intro', { dias: S.ajustes.diasQuarentena }) }));
  v.append(h('div', { class: 'barra-prog' },
    h('button', { type: 'button', class: 'btn sec acao', text: t(R.lista ? 'programas.antigos.procurarDeNovo' : 'programas.antigos.procurar'), onclick: () => carregarRestosAntigos() })));

  if (R.erro) {
    v.append(h('div', { class: 'cartao' },
      h('p', { text: t('programas.antigos.erro', { erro: R.erro }) }),
      h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarRestosAntigos() })));
  }
  if (R.carregando) {
    v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('programas.antigos.procurando') })));
    return;
  }
  if (!R.lista) return;
  if (!R.lista.length) {
    v.append(h('p', { class: 'suave', text: t('programas.antigos.nada') }));
    return;
  }

  const conhecidos = R.lista.filter((i) => i.bytes >= 0);
  const total = fmtBytes(conhecidos.length ? conhecidos.reduce((s, i) => s + i.bytes, 0) : -1);
  v.append(h('h2', { text: R.lista.length === 1 ? t('programas.antigos.achadosUm', { tamanho: total }) : t('programas.antigos.achados', { n: R.lista.length, tamanho: total }) }));

  const btnMover = h('button', { type: 'button', class: 'btn acao escrita', onclick: () => moverRestosAntigos() });
  const atualizarBotao = () => {
    const n = R.lista.filter((i) => R.sel.has(i.caminho)).length;
    btnMover.textContent = t('programas.antigos.mover', { n });
    if (n === 0) btnMover.setAttribute('data-bloq', ''); else btnMover.removeAttribute('data-bloq');
    aplicarOcupado();
  };
  const listaEl = h('div', { class: 'lista-antigos' });
  R.lista.forEach((i, idx) => listaEl.append(linhaRestoAntigo(i, idx, atualizarBotao)));
  v.append(listaEl, h('div', { class: 'barra-prog acoes-antigos' }, btnMover));
  atualizarBotao();
}

VISTAS.programas = {
  render(main) {
    const P = S.programas;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('programas.titulo') }));
    main.append(v);

    const secoes = h('div', { class: 'chips secoes-prog', role: 'group', 'aria-label': t('programas.secoes') },
      ['instalados', 'antigos'].map((s) => h('button', {
        type: 'button', class: 'chip' + (P.secao === s ? ' ativo' : ''), 'aria-pressed': P.secao === s ? 'true' : 'false',
        text: t('programas.secao.' + s), onclick: () => { if (P.secao !== s) { P.secao = s; renderAtual(); } },
      })));
    v.append(secoes);

    if (P.secao === 'antigos') {
      renderRestosAntigos(v);
      return;
    }

    if (!P.lista && !P.carregando && !P.erro && !S.ocupado) setTimeout(() => carregarProgramas(), 0);

    if (P.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('programas.erro', { erro: P.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarProgramas() })));
    }
    if (P.prog) {
      v.append(h('div', { class: 'progresso cartao' },
        h('div', { class: 'trilho' }, h('i', { id: 'pr-barra', vars: { '--pct': P.prog.pct } })),
        h('p', { class: 'pequeno suave', id: 'pr-msg', text: P.prog.msg })));
    }
    if (P.ultimo) v.append(cartaoResultadoProgramas());
    if (!P.lista) {
      if (!P.erro && !P.prog) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('programas.carregando') })));
      // Sempre dá para pedir a lista de novo (ex.: a visita aconteceu durante o arranque e a carga automática foi pulada).
      if (!P.prog) v.append(h('p', {}, h('button', { type: 'button', class: 'btn sec acao', text: t('programas.atualizar'), onclick: () => carregarProgramas() })));
      return;
    }

    v.append(h('p', { class: 'suave', text: t('programas.intro') }));

    const listaEl = h('div', { class: 'lista-prog' });
    const contagem = h('span', { class: 'suave pequeno contagem' });
    const chips = [];
    const renderLista = () => {
      const itens = programasFiltrados();
      listaEl.textContent = '';
      contagem.textContent = itens.length === 1 ? t('programas.contagemUm') : t('programas.contagem', { n: itens.length });
      if (!itens.length) listaEl.append(h('p', { class: 'suave', text: t('programas.vazio') }));
      itens.forEach((p) => listaEl.append(linhaPrograma(p)));
      chips.forEach((c) => { c.classList.toggle('ativo', c.dataset.aba === P.aba); c.setAttribute('aria-pressed', c.dataset.aba === P.aba ? 'true' : 'false'); });
      aplicarOcupado();
    };

    const busca = h('input', { type: 'search', id: 'pr-busca', placeholder: t('programas.buscar'), 'aria-label': t('programas.buscar'), value: P.filtro,
      oninput: (e) => { P.filtro = e.target.value; renderLista(); } });
    PROGRAMAS_ABAS.forEach((a) => {
      chips.push(h('button', { type: 'button', class: 'chip' + (a === 'recomendados' ? ' verde' : ''), 'data-aba': a, text: t('programas.aba.' + a),
        onclick: () => { P.aba = a; renderLista(); } }));
    });
    const ordem = h('select', { id: 'pr-ordem', 'aria-label': t('programas.ordem'), onchange: (e) => { P.ordem = e.target.value; renderLista(); } },
      PROGRAMAS_ORDENS.map((o) => h('option', { value: o, text: t('programas.ordem.' + o) })));
    ordem.value = P.ordem;

    v.append(h('div', { class: 'barra-prog' },
      busca,
      h('div', { class: 'chips', role: 'group', 'aria-label': t('programas.filtros') }, chips),
      h('label', { class: 'ordem' }, h('span', { class: 'suave pequeno', text: t('programas.ordem') }), ordem),
      h('button', { type: 'button', class: 'btn sec acao', text: t('programas.atualizar'), onclick: () => carregarProgramas() })),
      contagem, listaEl);
    renderLista();
  },
};
