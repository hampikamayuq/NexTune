'use strict';

// Dispositivos (módulo drivers): os aparelhos com ponto de exclamação no Gerenciador de Dispositivos, com o
// código explicado em português; reparo escalonado (desligar e ligar, reinstalar o driver que já está no
// Windows, procurar hardware), parando no primeiro passo que resolve; dispositivo essencial só procura
// hardware. Backup dos drivers com pnputil numa pasta do NexTune (não muda nada no sistema).

const DRIVERS_PASSOS = ['reiniciar', 'reinstalar', 'procurar'];
// Mesmo padrão do validador do Rust (re_id_dispositivo em acoes.rs): id fora dele seria recusado lá.
const DRIVERS_ID_VALIDO = /^[A-Za-z0-9_&\\.#{}?-]{1,400}$/;

async function carregarDrivers() {
  const D = S.drivers;
  if (S.ocupado) return;
  D.carregando = true; D.erro = null;
  if (S.vista === 'drivers') renderAtual();
  try {
    const r = await api.executar('drivers', 'listar', {}, null);
    D.lista = r.dispositivos || [];
  } catch (e) {
    D.erro = e.message || String(e);
  }
  D.carregando = false;
  if (S.vista === 'drivers') renderAtual();
}

function driversPassosPrevistos(d) {
  return d.critico ? ['procurar'] : DRIVERS_PASSOS;
}

async function repararDriver(d) {
  const D = S.drivers;
  if (S.ocupado || !DRIVERS_ID_VALIDO.test(d.id || '')) return;
  const corpo = [
    h('p', { text: t('drivers.repararTexto', { nome: d.nome }) }),
    h('ol', { class: 'passos-modal' }, driversPassosPrevistos(d).map((p) => h('li', {}, h('strong', { text: t('drivers.passo.' + p) }), ' — ', t('drivers.passoExplica.' + p)))),
  ];
  if (d.critico) corpo.push(h('p', { class: 'aviso pequeno', text: t('drivers.criticoAviso') }));
  corpo.push(h('p', { class: 'suave pequeno', text: t('drivers.repararDesfazer') }));
  const ok = await perguntar({ titulo: t('drivers.repararTitulo', { nome: d.nome }), corpo, ok: t('drivers.reparar') });
  if (!ok) return;
  if (!(await garantirPonto())) return;

  D.reparo = null;
  D.prog = { pct: 0, msg: t('drivers.reparando', { nome: d.nome }) };
  renderAtual();
  document.getElementById('principal').scrollTop = 0;
  // Cancelar no meio mataria o pnputil e poderia deixar o dispositivo desligado: sem o botão Cancelar.
  S.semCancelar = true;
  try {
    const r = await api.executar('drivers', 'reparar', { id: d.id, confirmado: true }, progressoInline(D, 'dr-barra', 'dr-msg'));
    D.reparo = { disp: d, r };
    if (r.resolvido) toast(t('drivers.resolvidoToast', { nome: d.nome }), 'ok');
    else toast(r.precisaReiniciar ? t('drivers.reiniciarToast') : t('drivers.naoResolvidoToast', { nome: d.nome }), 'aviso');
  } catch (e) {
    mostrarErroEscrita(e);
  } finally {
    S.semCancelar = false;
  }
  D.prog = null;
  await carregarDrivers();
  document.getElementById('principal').scrollTop = 0;
}

// Só copia os drivers para uma pasta do NexTune: não muda nada no Windows, então sem ponto de restauração.
async function backupDrivers() {
  const D = S.drivers;
  if (S.ocupado) return;
  const ok = await perguntar({
    titulo: t('drivers.backupTitulo'),
    corpo: [
      h('p', { text: t('drivers.backupTexto') }),
      h('p', { text: t('drivers.backupOnde') }),
      h('p', { class: 'suave pequeno', text: t('drivers.backupTamanho') }),
    ],
    ok: t('drivers.backup'),
  });
  if (!ok) return;
  D.backup = null;
  D.prog = { pct: 0, msg: t('drivers.backupProgresso') };
  renderAtual();
  try {
    D.backup = await api.executar('drivers', 'backup', { confirmado: true }, progressoInline(D, 'dr-barra', 'dr-msg'));
    toast(D.backup.quantidade > 0 ? t('drivers.backupFeito') : t('drivers.backupNada'), D.backup.quantidade > 0 ? 'ok' : 'aviso');
  } catch (e) {
    mostrarErroEscrita(e);
  }
  D.prog = null;
  if (S.vista === 'drivers') renderAtual();
}

function textoCodigoDepois(c) {
  return c === 0 ? t('drivers.funcionando') : t('drivers.codigo', { codigo: c });
}

function cartaoReparoDriver() {
  const D = S.drivers;
  const { disp, r } = D.reparo;
  const passos = r.passos || [];
  const fechar = h('button', { type: 'button', class: 'btn sec', text: t('comum.fechar'), onclick: () => { D.reparo = null; renderAtual(); } });
  const lista = passos.length
    ? h('ul', { class: 'passos-res' }, passos.map((p) => h('li', { class: p.ok ? 'ok' : 'falhou' },
      h('span', { class: 'marca-passo', 'aria-hidden': 'true', text: p.ok ? '✓' : '!' }),
      h('span', { text: t('drivers.passo.' + p.passo) }),
      h('span', { class: 'suave pequeno', text: (p.ok ? t('drivers.passoOk') : t('drivers.passoFalhou')) + ' · ' + textoCodigoDepois(p.codigoDepois) }))))
    : h('p', { class: 'suave', text: t('drivers.semPassos') });
  let titulo;
  if (r.resolvido) titulo = t('drivers.resolvido', { nome: disp.nome });
  else if (r.precisaReiniciar) titulo = t('drivers.precisaReiniciarTitulo', { nome: disp.nome });
  else titulo = t('drivers.naoResolvido', { nome: disp.nome });
  return h('div', { class: 'cartao resultado' + (r.resolvido ? '' : ' atencao') },
    h('p', { class: 'grande' + (r.resolvido ? '' : ' aviso-texto'), text: titulo }),
    lista,
    r.precisaReiniciar ? h('p', { class: 'aviso pequeno', text: t('drivers.precisaReiniciar') }) : null,
    !r.resolvido && !r.precisaReiniciar ? h('p', { class: 'suave pequeno', text: t('drivers.naoResolvidoDica') }) : null,
    h('div', { class: 'acoes' }, fechar));
}

function cartaoBackupDriver() {
  const D = S.drivers;
  const b = D.backup;
  const fechar = h('button', { type: 'button', class: 'btn sec', text: t('comum.fechar'), onclick: () => { D.backup = null; renderAtual(); } });
  if (!b.quantidade) {
    return h('div', { class: 'cartao resultado atencao' },
      h('p', { text: t('drivers.backupNada') }),
      b.codigo ? h('p', { class: 'suave pequeno', text: t('drivers.backupCodigo', { codigo: b.codigo }) }) : null,
      h('div', { class: 'acoes' }, fechar));
  }
  return h('div', { class: 'cartao resultado' },
    h('p', { class: 'grande', text: b.quantidade === 1 ? t('drivers.backupQuantidadeUm') : t('drivers.backupQuantidade', { n: b.quantidade }) }),
    h('p', { class: 'caminho pequeno', text: b.pasta }),
    b.codigo ? h('p', { class: 'suave pequeno', text: t('drivers.backupCodigo', { codigo: b.codigo }) }) : null,
    h('p', { class: 'suave pequeno', text: t('drivers.backupComoUsar') }),
    h('div', { class: 'acoes' },
      h('button', { type: 'button', class: 'btn sec', text: t('drivers.abrirPasta'), onclick: () => abrirPastaExplorer(b.pasta) }), fechar));
}

function linhaDriver(d) {
  const valido = DRIVERS_ID_VALIDO.test(d.id || '');
  return h('div', { class: 'prog disp' },
    h('span', { class: 'ponto ' + (d.critico ? 'vermelho' : 'amarelo'), 'aria-hidden': 'true' }),
    h('div', { class: 'prog-info' },
      h('div', { class: 'prog-nome' }, h('span', { text: d.nome || d.id }),
        h('span', { class: 'selo', text: d.classe || t('drivers.classeDesconhecida') }),
        d.critico ? h('span', { class: 'selo destaque', title: t('drivers.essencialDica'), text: t('drivers.essencial') }) : null),
      h('div', { class: 'pequeno', text: d.explicacao }),
      h('div', { class: 'suave pequeno', text: t('drivers.codigo', { codigo: d.codigo }) }),
      valido ? null : h('div', { class: 'motivo pequeno', text: t('drivers.idInvalido') })),
    h('div', { class: 'prog-lado' },
      valido ? h('button', { type: 'button', class: 'btn sec acao escrita', text: t('drivers.reparar'), onclick: () => repararDriver(d) }) : null));
}

VISTAS.drivers = {
  render(main) {
    const D = S.drivers;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('drivers.titulo') }), h('p', { class: 'suave', text: t('drivers.intro') }));
    main.append(v);

    if (!D.lista && !D.carregando && !D.erro && !S.ocupado) setTimeout(() => carregarDrivers(), 0);

    if (D.prog) v.append(cartaoProgresso(D.prog, 'dr-barra', 'dr-msg'));
    if (D.reparo) v.append(cartaoReparoDriver());

    v.append(h('h2', { text: t('drivers.problemasTitulo') }));
    v.append(h('div', { class: 'barra-prog' },
      h('button', { type: 'button', class: 'btn sec acao', text: t(D.lista ? 'drivers.verificarDeNovo' : 'drivers.verificar'), onclick: () => carregarDrivers() })));
    if (D.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('drivers.erro', { erro: D.erro }) }),
        h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => carregarDrivers() })));
    }
    if (D.carregando) {
      v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('drivers.carregando') })));
    } else if (D.lista) {
      if (!D.lista.length) v.append(h('p', { class: 'cartao', text: t('drivers.nenhum') }));
      else {
        v.append(h('p', { class: 'resumo', text: D.lista.length === 1 ? t('drivers.achadoUm') : t('drivers.achados', { n: D.lista.length }) }));
        D.lista.forEach((d) => v.append(linhaDriver(d)));
      }
    }

    v.append(h('h2', { text: t('drivers.backupSecao') }));
    v.append(h('p', { class: 'suave pequeno', text: t('drivers.backupIntro') }));
    if (D.backup) v.append(cartaoBackupDriver());
    v.append(h('div', { class: 'barra-prog' },
      h('button', { type: 'button', class: 'btn sec acao escrita', text: t('drivers.backup'), onclick: () => backupDrivers() })));
    aplicarOcupado();
  },
};
