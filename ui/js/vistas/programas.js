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

// ---- restos de programas antigos (programas/restosAntigos, só leitura; mover usa limparRestos) ----

async function procurarRestosAntigos() {
  const A = S.programas.antigos;
  if (S.ocupado) return;
  A.erro = null;
  A.prog = { pct: 0, msg: t('programas.antigos.procurando') };
  renderAtual();
  try {
    const r = await api.executar('programas', 'restosAntigos', {}, progressoInline(A, 'pra-barra', 'pra-msg'));
    A.itens = r.itens || [];
    // Só os seguros vêm marcados; quem decide os outros é o usuário.
    A.sel = new Set(A.itens.filter((i) => i.seguro).map((i) => i.caminho));
  } catch (e) {
    A.erro = e.message || String(e);
  }
  A.prog = null;
  if (S.vista === 'programas') renderAtual();
}

async function moverRestosAntigos() {
  const A = S.programas.antigos;
  if (S.ocupado || !A.itens) return;
  const sel = A.itens.filter((i) => A.sel.has(i.caminho));
  if (!sel.length) return;
  const dias = S.ajustes.diasQuarentena;
  const tamanho = fmtBytes(sel.reduce((s, i) => s + Math.max(i.bytes || 0, 0), 0));
  const ok = await perguntar({
    titulo: sel.length === 1 ? t('programas.moverTituloUm') : t('programas.moverTitulo', { n: sel.length }),
    corpo: [
      h('p', { text: sel.length === 1 ? t('programas.moverTextoUm', { tamanho, dias }) : t('programas.moverTexto', { n: sel.length, tamanho, dias }) }),
      sel.some((i) => !i.seguro) ? h('p', { class: 'aviso pequeno', text: t('programas.antigos.naoSegurosAviso') }) : null,
    ],
    ok: t('programas.moverQuarentena'),
  });
  if (!ok) return;
  A.falhas = [];
  try {
    const r = await api.executar('programas', 'limparRestos', {
      itens: sel.map((i) => ({ tipo: i.tipo, caminho: i.caminho })), confirmado: true, nome: t('programas.antigos.nomeQuarentena'),
    }, null);
    A.falhas = r.falhas || [];
    const falhas = A.falhas.length;
    toast(falhas ? t('programas.movidosFalhas', { n: r.movidos, f: falhas }) : (r.movidos === 1 ? t('programas.movidoUm') : t('programas.movidos', { n: r.movidos })), falhas ? 'aviso' : 'ok');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  // Uma chamada por vez: primeiro o contador da Quarentena, depois a busca de novo.
  try { await carregarQuarentena(); } catch (e) { mostrarErro(e); }
  const falhas = A.falhas;
  await procurarRestosAntigos();
  A.falhas = falhas;
  if (S.vista === 'programas') renderAtual();
}

function linhaRestoAntigo(i, idx) {
  const A = S.programas.antigos;
  const id = 'antigo-' + idx;
  return h('label', { class: 'resto', for: id },
    h('input', { type: 'checkbox', id, class: 'acao', checked: A.sel.has(i.caminho),
      onchange: (e) => { if (e.target.checked) A.sel.add(i.caminho); else A.sel.delete(i.caminho); renderAtual(); } }),
    h('span', { class: 'linha-resto' },
      h('span', { class: 'selo', text: t('programas.resto.' + i.tipo) }),
      h('strong', { text: i.nome }),
      h('span', { class: 'tam', text: fmtBytes(i.bytes) })),
    h('span', { class: 'motivo-resto caminho pequeno suave', text: i.caminho }),
    i.seguro
      ? h('span', { class: 'suave pequeno motivo-resto', text: i.motivo || '' })
      : h('span', { class: 'aviso pequeno motivo-resto', text: i.motivo || t('programas.antigos.naoSeguro') }));
}

function secaoRestosAntigos() {
  const A = S.programas.antigos;
  const cab = h('button', { type: 'button', class: 'secao-abrir', 'aria-expanded': A.aberto ? 'true' : 'false', 'aria-controls': 'pr-antigos',
    onclick: () => { A.aberto = !A.aberto; renderAtual(); } },
  h('span', { class: 'seta', 'aria-hidden': 'true', text: A.aberto ? '▾' : '▸' }),
  h('span', { text: t('programas.antigos.titulo') }),
  A.itens && A.itens.length ? h('span', { class: 'selo', text: String(A.itens.length) }) : null);
  const caixa = h('div', { class: 'cartao secao-antigos' }, cab);
  if (!A.aberto) return caixa;
  const corpo = h('div', { id: 'pr-antigos' },
    h('p', { class: 'suave pequeno', text: t('programas.antigos.intro', { dias: S.ajustes.diasQuarentena }) }),
    h('div', { class: 'barra-prog' },
      h('button', { type: 'button', class: 'btn sec acao', text: t(A.itens ? 'programas.antigos.procurarDeNovo' : 'programas.antigos.procurar'), onclick: () => procurarRestosAntigos() })));
  caixa.append(corpo);
  if (A.prog) corpo.append(cartaoProgresso(A.prog, 'pra-barra', 'pra-msg'));
  if (A.erro) corpo.append(h('p', { class: 'aviso pequeno', text: t('programas.antigos.erro', { erro: A.erro }) }));
  A.falhas.forEach((f) => corpo.append(h('p', { class: 'aviso pequeno', text: t('programas.falhaResto', { caminho: f.caminho, erro: f.erro }) })));
  if (!A.itens || A.prog) return caixa;
  if (!A.itens.length) {
    corpo.append(h('p', { class: 'suave', text: t('programas.antigos.nenhum') }));
    return caixa;
  }
  const seguros = A.itens.filter((i) => i.seguro).length;
  corpo.append(h('p', { class: 'pequeno', text: t(A.itens.length === 1 ? 'programas.antigos.achadoUm' : 'programas.antigos.achados', { n: A.itens.length, s: seguros }) }));
  A.itens.forEach((i, idx) => corpo.append(linhaRestoAntigo(i, idx)));
  const selecionados = A.itens.filter((i) => A.sel.has(i.caminho));
  const tamanho = fmtBytes(selecionados.reduce((s, i) => s + Math.max(i.bytes || 0, 0), 0));
  corpo.append(h('div', { class: 'acoes' },
    h('span', { class: 'suave pequeno', text: selecionados.length === 1 ? t('programas.antigos.marcadoUm', { tamanho }) : t('programas.antigos.marcados', { n: selecionados.length, tamanho }) }),
    h('button', { type: 'button', class: 'btn acao escrita', 'data-bloq': selecionados.length ? null : '', text: t('programas.moverQuarentena'), onclick: () => moverRestosAntigos() })));
  return caixa;
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

VISTAS.programas = {
  render(main) {
    const P = S.programas;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('programas.titulo') }));
    main.append(v);

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
    v.append(secaoRestosAntigos());

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
