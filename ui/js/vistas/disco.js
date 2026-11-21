'use strict';

// Disco (módulo disco): uma unidade fixa por cartão. Verificar é só leitura (Repair-Volume -Scan);
// Corrigir não mexe no volume agora, só agenda a correção para o próximo reinício (e a tela ensina a
// reiniciar em vez de desligar, por causa da Inicialização Rápida); Otimizar desfragmenta HDD ou faz
// TRIM em SSD, nunca o contrário, e só depois de uma verificação sem erros.

async function carregarDisco() {
  const D = S.disco;
  if (S.ocupado) return;
  D.carregando = true; D.erro = null;
  if (S.vista === 'disco') renderAtual();
  try {
    D.estado = await api.executar('disco', 'estado', {}, null);
  } catch (e) {
    D.erro = e.message || String(e);
  }
  D.carregando = false;
  if (S.vista === 'disco' || S.vista === 'inicio') renderAtual();
}

// Unidade do sistema (ou null): o Início recomenda a verificação dela.
function discoSistema() {
  const lista = (S.disco.estado && S.disco.estado.unidades) || [];
  return lista.find((u) => u.sistema) || null;
}

// Motivo para o botão Otimizar ficar travado (mesma regra de Test-PodeOtimizar no script) ou null.
function discoMotivoBloqueio(u) {
  if (u.sujo) return t('disco.otimizarBloqueadoSujo');
  if (u.tipoDisco !== 'hdd' && u.tipoDisco !== 'ssd') return t('disco.otimizarBloqueadoTipo');
  if (u.semErros !== true) return t('disco.otimizarBloqueadoVerifique');
  return null;
}

// 'desfragmentar' | 'trim' | 'otimizar' (tipo desconhecido: o botão fica travado com rótulo genérico).
function discoOperacao(u) {
  if (u.tipoDisco === 'ssd') return 'trim';
  if (u.tipoDisco === 'hdd') return 'desfragmentar';
  return 'otimizar';
}

async function verificarDisco(u) {
  if (S.ocupado) return;
  try {
    const r = await api.executar('disco', 'verificar', { letra: u.letra }, null);
    const chave = 'disco.resultado.' + r.resultado;
    const msg = textos[chave] ? t(chave, { letra: u.letra }) : t('disco.resultado.outro', { letra: u.letra, resultado: r.resultado });
    toast(msg, r.semErros ? 'ok' : 'aviso');
  } catch (e) {
    mostrarErro(e);
  }
  await carregarDisco();
}

// Nada muda até o reinício, então não cria ponto de restauração.
async function corrigirDisco(u) {
  if (S.ocupado) return;
  const ok = await perguntar({
    titulo: t('disco.corrigirTitulo', { letra: u.letra }),
    corpo: [h('p', { text: t('disco.corrigirTexto', { letra: u.letra }) }), h('p', { class: 'suave pequeno', text: t('disco.corrigirDesfazer') })],
    ok: t('disco.corrigir'),
  });
  if (!ok) return;
  try {
    await api.executar('disco', 'corrigir', { letra: u.letra, confirmado: true }, null);
    toast(t('disco.corrigirFeito', { letra: u.letra }), 'ok');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarDisco();
}

async function reiniciarPc() {
  if (S.ocupado) return;
  const ok = await perguntar({
    titulo: t('disco.reiniciarTitulo'),
    corpo: [h('p', { class: 'aviso', text: t('disco.reiniciarTexto') })],
    ok: t('disco.reiniciar'),
    okClasse: 'perigo',
  });
  if (!ok) return;
  try {
    await api.executar('disco', 'reiniciar', { confirmado: true }, null);
    toast(t('disco.reiniciarFeito'), 'aviso');
  } catch (e) {
    mostrarErroEscrita(e);
  }
}

// Desfragmentar/TRIM não alteram arquivos: sem ponto de restauração.
async function otimizarDisco(u) {
  if (S.ocupado || discoMotivoBloqueio(u)) return;
  const op = discoOperacao(u);
  const ok = await perguntar({
    titulo: t('disco.' + op + 'Titulo', { letra: u.letra }),
    corpo: [h('p', { text: t('disco.' + op + 'Texto') })],
    ok: t('disco.' + op),
  });
  if (!ok) return;
  try {
    const r = await api.executar('disco', 'otimizar', { letra: u.letra, confirmado: true }, null);
    toast(t('disco.otimizarFeito.' + r.operacao, { letra: u.letra }), 'ok');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  await carregarDisco();
}

function textoUltimaVerificacao(u) {
  if (!u.ultimaVerificacao) return t('disco.nunca');
  const data = fmtData(u.ultimaVerificacao);
  if (u.semErros === true) return t('disco.ultimaSemErros', { data });
  if (u.semErros === false) return t('disco.ultimaComErros', { data });
  return t('disco.ultimaSoData', { data });
}

function cartaoUnidade(u) {
  const usado = u.total > 0 ? Math.round(((u.total - u.livre) / u.total) * 100) : 0;
  const selos = [h('span', { class: 'selo', text: t('disco.tipo.' + (u.tipoDisco === 'hdd' || u.tipoDisco === 'ssd' ? u.tipoDisco : 'desconhecido')) })];
  if (u.sistema) selos.push(h('span', { class: 'selo destaque', text: t('disco.sistema') }));
  if (u.agendada) selos.push(h('span', { class: 'selo destaque', text: t('disco.agendada') }));
  const motivo = discoMotivoBloqueio(u);
  const op = discoOperacao(u);

  const extras = [];
  if (u.agendada) {
    const aviso = t('disco.reinicieAviso') + (S.disco.estado && S.disco.estado.inicioRapido ? ' ' + t('disco.inicioRapidoAviso') : '');
    extras.push(h('p', { class: 'aviso pequeno', text: aviso }));
    extras.push(h('p', { class: 'suave pequeno', text: t('disco.recuperacao', { letra: u.letra }) }));
  }
  const botoes = h('div', { class: 'acoes-disco' },
    h('button', { type: 'button', class: 'btn sec acao', text: t('disco.verificar'), onclick: () => verificarDisco(u) }),
    h('button', { type: 'button', class: 'btn sec acao escrita', text: t('disco.corrigir'), onclick: () => corrigirDisco(u) }),
    h('button', { type: 'button', class: 'btn sec acao escrita', 'data-bloq': motivo ? '' : null, title: motivo, text: t('disco.' + op), onclick: () => otimizarDisco(u) }),
    u.agendada ? h('button', { type: 'button', class: 'btn acao escrita', text: t('disco.reiniciar'), onclick: () => reiniciarPc() }) : null);

  return h('div', { class: 'cartao unidade' },
    h('div', { class: 'nome-item' }, h('span', { class: 'grande', text: u.letra + (u.rotulo ? ' ' + u.rotulo : '') }), selos),
    h('div', { class: 'uso' + (usado >= 90 ? ' cheio' : ''), vars: { '--pct': usado } }, h('i')),
    h('div', { class: 'suave pequeno', text: t('disco.livreDe', { livre: fmtBytes(u.livre), total: fmtBytes(u.total) }) }),
    h('p', { class: 'ultima' + (u.semErros === false ? ' aviso-texto' : ''), text: textoUltimaVerificacao(u) }),
    motivo ? h('p', { class: 'suave pequeno', text: motivo }) : null,
    extras,
    botoes);
}

VISTAS.disco = {
  render(main) {
    const D = S.disco;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('disco.titulo') }));
    main.append(v);

    const precisa = !D.carregando && !S.ocupado && !D.erro && !D.estado;
    if (precisa) setTimeout(() => carregarDisco(), 0);

    if (D.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('disco.erro', { erro: D.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarDisco() })));
    }
    if (!D.estado) {
      if (!D.erro) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('disco.carregando') })));
      return;
    }

    v.append(h('p', { class: 'suave', text: t('disco.intro') }));
    v.append(h('div', { class: 'barra-prog' },
      h('button', { type: 'button', class: 'btn sec acao', text: t('disco.atualizar'), onclick: () => carregarDisco() })));
    const unidades = D.estado.unidades || [];
    if (!unidades.length) v.append(h('p', { class: 'suave', text: t('disco.vazio') }));
    unidades.forEach((u) => v.append(cartaoUnidade(u)));
    aplicarOcupado();
  },
};
