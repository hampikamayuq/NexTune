'use strict';

// Modo Jogo (módulo modojogo): presets, programas a fechar ao ativar e "Meus jogos" (automático).
// Não cria ponto de restauração: o Modo Jogo se desfaz sozinho em "Desativar".

const PRESETS = ['suave', 'equilibrado', 'a_fundo'];
// Igual à validação do Rust (ajustes): nome de executável, sem caminho.
const RE_EXE = /^[^\\/:*?"<>|\x00-\x1f]{1,120}\.exe$/i;

async function carregarModoJogo() {
  const M = S.modoJogo;
  if (S.ocupado) return;
  M.carregando = true; M.erro = null;
  if (S.vista === 'modojogo') renderAtual();
  try {
    M.estado = await api.executar('modojogo', 'estado', {}, null);
    M.processos = (await api.executar('modojogo', 'processos', {}, null)).processos || [];
    const vivos = new Set(M.processos.filter((p) => !p.protegido).map((p) => p.exe));
    M.sel = new Set([...M.sel].filter((x) => vivos.has(x)));
  } catch (e) {
    M.erro = e.message || String(e);
  }
  M.carregando = false;
  if (S.vista === 'modojogo') renderAtual();
}

function presetsVisiveis() {
  const perfil = (S.info && S.info.perfil) || {};
  const fraco = perfil.classe === 'basico' || perfil.disco === 'hdd';
  return PRESETS.filter((p) => p !== 'a_fundo' || !fraco || S.ajustes.modoAvancado);
}

function presetAtual() {
  const p = S.modoJogo.preset || S.ajustes.modoJogoPreset;
  return presetsVisiveis().includes(p) ? p : 'suave';
}

function nomePreset(p) { return t('modojogo.preset.' + p + '.nome'); }

async function ativarModoJogo() {
  const M = S.modoJogo;
  if (S.ocupado) return;
  const preset = presetAtual();
  const fechar = [...M.sel];
  const ok = await perguntar({
    titulo: t('modojogo.ativarTitulo', { preset: nomePreset(preset) }),
    corpo: [
      h('p', { text: fechar.length > 1 ? t('modojogo.ativarTexto', { n: fechar.length, preset: nomePreset(preset) }) : t(fechar.length ? 'modojogo.ativarTextoUm' : 'modojogo.ativarTextoSem', { preset: nomePreset(preset) }) }),
      h('p', { class: 'suave pequeno', text: t('modojogo.desfazer') }),
    ],
    ok: t('modojogo.ativar'),
  });
  if (!ok) return;
  const params = { preset, fechar, confirmado: true };
  if (S.ajustes.modoAvancado) params.avancado = true;
  try {
    const r = await api.executar('modojogo', 'ativar', params, null);
    toast(t('modojogo.ativado', { fechados: (r.fechados || []).length, servicos: (r.servicosPausados || []).length }), 'ok');
    (r.naoFechados || []).forEach((n) => toast(t('modojogo.naoFechou', { exe: n.exe, motivo: n.motivo }), 'aviso'));
    (r.avisos || []).forEach((a) => toast(t('modojogo.aviso', { item: a.item, erro: a.erro }), 'aviso'));
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarModoJogo();
}

async function desativarModoJogo() {
  if (S.ocupado) return;
  const ok = await perguntar({
    titulo: t('modojogo.desativarTitulo'),
    corpo: [h('p', { text: t('modojogo.desativarTexto') })],
    ok: t('modojogo.desativar'),
  });
  if (!ok) return;
  try {
    const r = await api.executar('modojogo', 'desativar', { confirmado: true }, null);
    toast(t('modojogo.desativado', { reabertos: (r.reabertos || []).length, religados: (r.religados || []).length }), 'ok');
    (r.falhas || []).forEach((f) => toast(t('modojogo.falha', { item: f.item, erro: f.erro }), 'erro'));
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarModoJogo();
}

// Liga/desliga o automático. Ligar também liga o início com o Windows (sem ele o vigia não roda).
async function mudarAuto(caixa) {
  if (caixa.checked) {
    const ok = await perguntar({ titulo: t('modojogo.autoTitulo'), corpo: [h('p', { text: t('modojogo.autoTexto') })] });
    if (!ok) { caixa.checked = false; return; }
    try {
      S.ajustes = await api.ajustes.gravar({ modoJogoAuto: true, modoJogoPreset: presetAtual(), jogos: S.ajustes.jogos || [] });
    } catch (e) { mostrarErro(e); caixa.checked = false; return; }
    try { await api.autostart(true); } catch (e) { toast(t('modojogo.autostartFalhou', { erro: e.message || String(e) }), 'aviso'); }
    toast(t('modojogo.autoLigado'), 'ok');
  } else {
    try {
      S.ajustes = await api.ajustes.gravar({ modoJogoAuto: false });
      toast(t('modojogo.autoDesligado'), 'ok');
    } catch (e) { mostrarErro(e); caixa.checked = true; }
  }
}

async function gravarJogos(jogos) {
  await gravarAjuste({ jogos });
  renderAtual();
}

function adicionarJogo(entrada) {
  const exe = entrada.value.trim();
  if (!RE_EXE.test(exe)) { toast(t('modojogo.exeInvalido'), 'erro'); return; }
  const jogos = S.ajustes.jogos || [];
  if (jogos.some((j) => j.toLowerCase() === exe.toLowerCase())) { toast(t('modojogo.jogoRepetido'), 'aviso'); return; }
  gravarJogos([...jogos, exe]);
}

function linhaProcesso(p) {
  const M = S.modoJogo;
  const info = h('div', { class: 'prog-info' },
    h('div', { class: 'prog-nome' }, h('span', { text: p.nome || p.exe }), h('span', { class: 'suave pequeno', text: p.exe }),
      p.protegido ? h('span', { class: 'selo', title: p.motivoProtegido || '', text: t('modojogo.selo.protegido') }) : null),
    p.protegido && p.motivoProtegido ? h('div', { class: 'suave pequeno', text: p.motivoProtegido }) : null);
  const ram = h('span', { class: 'tam', text: t('modojogo.ram', { ram: fmtBytes(p.ramBytes) }) });
  if (p.protegido) return h('div', { class: 'proc-jogo protegido' }, h('span', { class: 'sem-caixa' }), info, ram);
  const id = 'mj-p-' + p.exe;
  return h('label', { class: 'proc-jogo', for: id },
    h('input', { type: 'checkbox', class: 'acao', id, checked: M.sel.has(p.exe),
      onchange: (e) => { if (e.target.checked) M.sel.add(p.exe); else M.sel.delete(p.exe); } }),
    info, ram);
}

function cartaoAtivo(E) {
  const hora = new Date(E.desde).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  const titulo = t('modojogo.ativoTitulo', { preset: nomePreset(E.preset), hora }) + (E.jogo ? t('modojogo.ativoJogo', { jogo: E.jogo }) : '');
  const lista = (rotulo, itens) => (itens.length ? h('p', { class: 'suave', text: t(rotulo, { lista: itens.join(', ') }) }) : null);
  const naoFechados = E.naoFechados || [];
  return [
    h('div', { class: 'cartao recomendado' },
      h('div', { class: 'titulo-card', text: titulo }),
      h('button', { type: 'button', class: 'btn acao escrita', text: t('modojogo.desativar'), onclick: desativarModoJogo })),
    h('div', { class: 'cartao' },
      lista('modojogo.fechados', (E.fechados || []).map((f) => f.exe)),
      lista('modojogo.servicos', E.servicosPausados || []),
      naoFechados.length ? h('div', {}, h('h3', { text: t('modojogo.naoFechados') }),
        h('ul', { class: 'jogos-lista' }, naoFechados.map((n) => h('li', { text: t('modojogo.naoFechou', { exe: n.exe, motivo: n.motivo }) })))) : null),
  ];
}

function cartaoPresets() {
  const atual = presetAtual();
  return h('fieldset', { class: 'cartao' }, h('legend', { text: t('modojogo.presets') }),
    presetsVisiveis().map((p) => {
      const id = 'mj-preset-' + p;
      return h('label', { class: 'preset', for: id },
        h('input', { type: 'radio', name: 'mj-preset', id, value: p, checked: p === atual,
          onchange: () => { S.modoJogo.preset = p; if (S.ajustes.modoJogoAuto) gravarAjuste({ modoJogoPreset: p }); } }),
        h('span', {}, h('strong', { text: nomePreset(p) }), h('span', { class: 'suave pequeno', text: t('modojogo.preset.' + p + '.desc') })));
    }));
}

function cartaoJogos() {
  const jogos = S.ajustes.jogos || [];
  const entrada = h('input', { type: 'text', id: 'mj-exe', maxlength: 120, placeholder: 'eldenring.exe',
    onkeydown: (e) => { if (e.key === 'Enter') adicionarJogo(entrada); } });
  const auto = h('input', { type: 'checkbox', id: 'mj-auto', class: 'acao', checked: !!S.ajustes.modoJogoAuto, onchange: (e) => mudarAuto(e.target) });
  return h('div', { class: 'cartao' }, h('h3', { text: t('modojogo.jogos') }),
    h('p', { class: 'suave pequeno', text: t('modojogo.jogosAjuda') }),
    h('label', { class: 'rotulo-link', for: 'mj-exe', text: t('modojogo.jogosCampo') }),
    h('div', { class: 'linha-link' }, entrada,
      h('button', { type: 'button', class: 'btn sec acao', text: t('modojogo.adicionar'), onclick: () => adicionarJogo(entrada) })),
    h('ul', { class: 'jogos-lista' }, jogos.map((j) => h('li', {}, h('span', { text: j }),
      h('button', { type: 'button', class: 'btn sec acao', text: t('modojogo.remover'), 'aria-label': t('modojogo.remover') + ' ' + j,
        onclick: () => gravarJogos(jogos.filter((x) => x !== j)) })))),
    h('label', { class: 'opcao', for: 'mj-auto' }, auto, h('span', { text: t('modojogo.auto') })));
}

VISTAS.modojogo = {
  render(main) {
    const M = S.modoJogo;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('modojogo.titulo') }));
    main.append(v);

    const precisa = !M.carregando && !S.ocupado && !M.erro && !M.estado;
    if (precisa) setTimeout(() => carregarModoJogo(), 0);

    if (M.erro) {
      v.append(h('div', { class: 'cartao' }, h('p', { text: t('modojogo.erro', { erro: M.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarModoJogo() })));
    }
    if (!M.estado) {
      if (!M.erro) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('modojogo.carregando') })));
      return;
    }

    v.append(h('p', { class: 'suave', text: t('modojogo.intro') }));
    if (M.estado.ativo) {
      v.append(...cartaoAtivo(M.estado));
      return;
    }

    v.append(cartaoPresets());
    const procs = M.processos || [];
    v.append(h('div', { class: 'cartao' }, h('h3', { text: t('modojogo.fechar') }),
      procs.length ? h('div', { class: 'lista-atu' }, procs.map(linhaProcesso)) : h('p', { class: 'suave', text: t('modojogo.semProcessos') })));
    v.append(cartaoJogos());
    v.append(h('div', { class: 'cartao' }, h('div', { class: 'acoes' },
      h('button', { type: 'button', class: 'btn acao escrita', text: t('modojogo.ativar'), onclick: ativarModoJogo }))));
  },
};
