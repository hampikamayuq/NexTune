'use strict';

// Rede (módulo rede): adaptadores físicos ativos e os servidores de DNS de cada um; limpar o cache de DNS
// (um clique, sem ponto de restauração); redefinir Winsock e TCP/IP (precisa reiniciar); e DNS seguro (DoH)
// com Cloudflare, Google ou Quad9, só no Windows 11. Antes da primeira troca o script guarda os servidores de
// cada adaptador; "Automático" devolve exatamente esses servidores (ou o DHCP, sem backup).

const REDE_PROVEDORES = ['cloudflare', 'google', 'quad9', 'automatico'];

async function carregarRede() {
  const R = S.rede;
  if (S.ocupado) return;
  R.carregando = true; R.erro = null;
  if (S.vista === 'rede') renderAtual();
  try {
    R.estado = await api.executar('rede', 'estado', {}, null);
    if (!REDE_PROVEDORES.includes(R.escolha)) R.escolha = REDE_PROVEDORES.includes(R.estado.provedor) ? R.estado.provedor : null;
  } catch (e) {
    R.erro = e.message || String(e);
  }
  R.carregando = false;
  if (S.vista === 'rede') renderAtual();
}

// Os três provedores precisam do Windows 11 e de nenhuma política (DoHPolicy) proibindo; Automático sempre vale.
function redeProvedorDisponivel(p) {
  const E = S.rede.estado;
  return p === 'automatico' || !!(E && E.dohDisponivel && !E.bloqueadoPorPolitica);
}

// Adaptador que o script voltou ao DNS anterior porque os nomes pararam de resolver com o DNS seguro.
function redeRevertido(a) {
  return !a.ok && /voltamos ao anterior|voltou ao anterior/i.test(a.erro || '');
}

// Algo a aplicar: escolha diferente da atual, ou "Automático" com backup ainda guardado (restauração pendente).
function redePodeAplicar() {
  const R = S.rede;
  if (!R.estado || !R.escolha || !redeProvedorDisponivel(R.escolha)) return false;
  return R.escolha !== R.estado.provedor || (R.escolha === 'automatico' && R.estado.temBackup);
}

async function limparDnsRede() {
  if (S.ocupado) return;
  try {
    const r = await api.executar('rede', 'limparDns', {}, null);
    toast(r.ok ? t('rede.limparFeito') : t('rede.limparFalhou'), r.ok ? 'ok' : 'aviso');
  } catch (e) {
    mostrarErroEscrita(e);
  }
}

async function redefinirRede() {
  const R = S.rede;
  if (S.ocupado) return;
  const ok = await perguntar({
    titulo: t('rede.redefinirTitulo'),
    corpo: [
      h('p', { text: t('rede.redefinirTexto') }),
      h('p', { class: 'aviso pequeno', text: t('rede.redefinirAviso') }),
      h('p', { class: 'suave pequeno', text: t('rede.redefinirDesfazer') }),
    ],
    exigeCheck: t('rede.redefinirCheck'),
    ok: t('rede.redefinir'),
    okClasse: 'perigo',
  });
  if (!ok) return;
  if (!(await garantirPonto())) return;
  R.redefinido = null;
  R.prog = { pct: 0, msg: t('rede.redefinindo') };
  renderAtual();
  try {
    R.redefinido = await api.executar('rede', 'redefinir', { confirmado: true }, progressoInline(R, 're-barra', 're-msg'));
    toast(t('rede.redefinirFeito'), 'aviso');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  R.prog = null;
  if (S.vista === 'rede') renderAtual();
  document.getElementById('principal').scrollTop = 0;
}

async function aplicarDnsRede() {
  const R = S.rede;
  if (S.ocupado || !redePodeAplicar()) return;
  const provedor = R.escolha;
  const nome = t('rede.prov.' + provedor);
  const adaptadores = (R.estado.adaptadores || []).map((a) => a.nome).join(', ') || t('rede.nenhumAdaptadorCurto');
  const corpo = provedor === 'automatico'
    ? [h('p', { text: t(R.estado.temBackup ? 'rede.automaticoTexto' : 'rede.automaticoSemBackup', { adaptadores }) })]
    : [
      h('p', { text: t('rede.dnsTexto', { provedor: nome, adaptadores }) }),
      h('p', { class: 'suave pequeno', text: t('rede.ipv6') }),
      h('p', { class: 'suave pequeno', text: t('rede.dnsDesfazer') }),
    ];
  const ok = await perguntar({
    titulo: provedor === 'automatico' ? t('rede.automaticoTitulo') : t('rede.dnsTitulo', { provedor: nome }),
    corpo,
    ok: t('rede.aplicar'),
  });
  if (!ok) return;
  if (!(await garantirPonto())) return;
  R.dns = null;
  R.prog = { pct: 0, msg: t('rede.aplicando', { provedor: nome }) };
  renderAtual();
  try {
    const r = await api.executar('rede', 'dnsSeguro', { provedor, confirmado: true }, progressoInline(R, 're-barra', 're-msg'));
    R.dns = r;
    const lista = r.adaptadores || [];
    const revertidos = lista.filter(redeRevertido).length;
    const falhas = lista.filter((a) => !a.ok && !redeRevertido(a)).length;
    if (revertidos) toast(revertidos === 1 ? t('rede.revertidoUm') : t('rede.revertidos', { n: revertidos }), 'aviso');
    if (r.aviso) toast(r.aviso, 'aviso');
    if (!revertidos || falhas) toast(falhas ? (falhas === 1 ? t('rede.dnsFalhaUm') : t('rede.dnsFalhas', { n: falhas })) : t('rede.dnsFeito', { provedor: t('rede.prov.' + r.provedor) }), falhas ? 'aviso' : 'ok');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  R.prog = null;
  R.escolha = null; // volta a marcar o que o Windows informar agora
  await carregarRede();
  document.getElementById('principal').scrollTop = 0; // o cartão do resultado fica no topo
}

function cartaoAdaptadores() {
  const R = S.rede;
  const lista = R.estado.adaptadores || [];
  const atual = R.estado.provedor;
  const c = h('div', { class: 'cartao' },
    h('h3', { text: t('rede.adaptadores') }),
    h('p', { class: 'pequeno', text: t('rede.provedorAtual', { provedor: t('rede.prov.' + (REDE_PROVEDORES.includes(atual) || atual === 'outro' ? atual : 'outro')) }) }));
  if (!lista.length) c.append(h('p', { class: 'suave', text: t('rede.nenhumAdaptador') }));
  lista.forEach((a) => {
    c.append(h('div', { class: 'adaptador' },
      h('div', { class: 'nome-item' }, h('span', { text: a.nome }), a.automatico ? h('span', { class: 'selo destaque', title: t('rede.automaticoDica'), text: t('rede.automatico') }) : null),
      h('div', { class: 'suave pequeno', text: a.descricao }),
      h('div', { class: 'pequeno dns-lista', text: (a.dns || []).length ? t('rede.servidores', { lista: a.dns.join(', ') }) : t('rede.semServidores') })));
  });
  return c;
}

function cartaoDnsSeguro() {
  const R = S.rede;
  const E = R.estado;
  const opcoes = REDE_PROVEDORES.map((p) => {
    const disp = redeProvedorDisponivel(p);
    const id = 'dns-' + p;
    return h('label', { class: 'preset' + (disp ? '' : ' indisp'), for: id },
      h('input', { type: 'radio', name: 'dns', id, value: p, class: 'acao', 'data-bloq': disp ? null : '', checked: R.escolha === p,
        onchange: () => { R.escolha = p; renderAtual(); } }),
      h('span', {},
        h('strong', { text: t('rede.prov.' + p) }), p === E.provedor ? h('span', { class: 'selo destaque', text: t('rede.emUso') }) : null,
        h('span', { class: 'suave pequeno', text: t('rede.provDesc.' + p) })));
  });
  const pode = redePodeAplicar();
  return h('fieldset', { class: 'cartao' },
    h('legend', { text: t('rede.dnsSeguro') }),
    h('p', { class: 'suave pequeno', text: t('rede.dnsIntro') }),
    E.dohDisponivel ? null : h('p', { class: 'aviso pequeno', text: t('rede.semDoh') }),
    E.dohDisponivel && E.bloqueadoPorPolitica ? h('p', { class: 'aviso pequeno', text: t('rede.politica') }) : null,
    opcoes,
    h('p', { class: 'suave pequeno', text: t('rede.ipv6') }),
    h('div', { class: 'acoes' },
      h('button', { type: 'button', class: 'btn acao escrita', 'data-bloq': pode ? null : '', text: t('rede.aplicar'), onclick: () => aplicarDnsRede() })));
}

function cartaoResultadoDns() {
  const R = S.rede;
  const r = R.dns;
  const itens = r.adaptadores || [];
  const atencao = itens.some((a) => !a.ok) || !!r.aviso;
  const linha = (a) => {
    let classe = 'ok'; let marca = '✓'; let texto = t('rede.adaptadorOk');
    if (a.mantido) { classe = 'mantido'; marca = '–'; texto = t('rede.adaptadorMantido'); }
    else if (redeRevertido(a)) { classe = 'falhou'; marca = '↺'; texto = t('rede.adaptadorRevertido', { erro: a.erro }); }
    else if (!a.ok) { classe = 'falhou'; marca = '!'; texto = t('rede.adaptadorErro', { erro: a.erro || '' }); }
    return h('li', { class: classe },
      h('span', { class: 'marca-passo', 'aria-hidden': 'true', text: marca }),
      h('span', { text: a.nome }),
      h('span', { class: 'suave pequeno', text: texto }));
  };
  return h('div', { class: 'cartao resultado' + (atencao ? ' atencao' : '') },
    h('p', { class: 'grande' + (atencao ? ' aviso-texto' : ''), text: t('rede.dnsResultado', { provedor: t('rede.prov.' + r.provedor) }) }),
    r.aviso ? h('p', { class: 'aviso pequeno', text: r.aviso }) : null,
    itens.length ? h('ul', { class: 'passos-res' }, itens.map(linha)) : h('p', { class: 'suave', text: t('rede.nenhumAdaptador') }),
    h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn sec', text: t('comum.fechar'), onclick: () => { R.dns = null; renderAtual(); } })));
}

function cartaoRedefinido() {
  const R = S.rede;
  return h('div', { class: 'cartao resultado atencao' },
    h('p', { class: 'grande aviso-texto', text: t('rede.redefinidoTitulo') }),
    h('p', { text: R.redefinido.detalhe }),
    R.redefinido.precisaReiniciar ? h('p', { class: 'aviso pequeno', text: t('rede.reinicieAviso') }) : null,
    h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn sec', text: t('comum.fechar'), onclick: () => { R.redefinido = null; renderAtual(); } })));
}

VISTAS.rede = {
  render(main) {
    const R = S.rede;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('rede.titulo') }), h('p', { class: 'suave', text: t('rede.intro') }));
    main.append(v);

    if (!R.estado && !R.carregando && !R.erro && !S.ocupado) setTimeout(() => carregarRede(), 0);

    if (R.prog) v.append(cartaoProgresso(R.prog, 're-barra', 're-msg'));
    if (R.redefinido) v.append(cartaoRedefinido());
    if (R.dns) v.append(cartaoResultadoDns());
    if (R.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('rede.erro', { erro: R.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarRede() })));
    }
    if (!R.estado) {
      if (!R.erro) v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('rede.carregando') })));
      return;
    }

    v.append(h('div', { class: 'barra-prog' },
      h('button', { type: 'button', class: 'btn sec acao', text: t('rede.atualizar'), onclick: () => carregarRede() })));
    v.append(cartaoAdaptadores());
    v.append(h('h2', { text: t('rede.ferramentas') }));
    v.append(h('div', { class: 'cartao ferramenta' },
      h('div', {}, h('strong', { text: t('rede.limpar') }), h('p', { class: 'suave pequeno', text: t('rede.limparExplica') })),
      h('button', { type: 'button', class: 'btn sec acao escrita', text: t('rede.limpar'), onclick: () => limparDnsRede() })));
    v.append(h('div', { class: 'cartao ferramenta' },
      h('div', {}, h('strong', { text: t('rede.redefinir') }), h('p', { class: 'suave pequeno', text: t('rede.redefinirExplica') })),
      h('button', { type: 'button', class: 'btn sec acao escrita', text: t('rede.redefinir'), onclick: () => redefinirRede() })));
    v.append(cartaoDnsSeguro());
    aplicarOcupado();
  },
};
