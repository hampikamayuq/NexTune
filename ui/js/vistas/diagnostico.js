'use strict';

const TRACO = '—';

function val(v, fmt) {
  if (v == null || v === '') return TRACO;
  return fmt ? fmt(v) : String(v);
}

function cartaoInfo(titulo, linhas) {
  const dl = h('dl', { class: 'linhas' });
  for (const [rotulo, valor] of linhas) {
    if (valor === undefined) continue;
    dl.append(h('dt', { text: rotulo }), h('dd', {}, valor));
  }
  return h('div', { class: 'cartao' }, h('h3', { text: titulo }), dl);
}

async function recoletar(params) {
  const r = await api.executar('diagnostico', 'coletar', params || {}, null);
  S.diag = r;
  S.info.perfil = r.perfil;
  return r;
}

// Modal para trocar o perfil manualmente (3 tipos de PC x 2 tipos de disco).
async function trocarPerfil() {
  if (S.ocupado) return;
  const atual = (S.diag && S.diag.perfil) || S.info.perfil;
  const radios = { classe: [], disco: [] };
  const grupo = (nome, legenda, chaves, prefixo, escolhido) => h('fieldset', {},
    h('legend', { text: legenda }),
    chaves.map((k) => {
      const r = h('input', { type: 'radio', name: 'perfil-' + nome, value: k, checked: k === escolhido });
      radios[nome].push(r);
      return h('label', { class: 'opcao' }, r, h('span', { text: t(prefixo + k) }));
    }));
  const corpo = [
    h('p', { class: 'suave', text: t('diagnostico.trocarAjuda') }),
    grupo('classe', t('diagnostico.classe'), ['basico', 'medio', 'gamer'], 'inicio.perfil.', atual.classe),
    grupo('disco', t('diagnostico.disco'), ['hdd', 'ssd'], 'inicio.disco.', atual.disco),
  ];
  // Perfil definido à mão: oferece voltar à detecção automática.
  const extra = atual.manual ? t('diagnostico.voltarAuto') : undefined;
  const ok = await perguntar({ titulo: t('diagnostico.trocarTitulo'), corpo, ok: t('diagnostico.salvar'), extra });
  if (!ok) return;
  if (ok === 'extra') { await voltarPerfilAutomatico(); return; }
  const lido = (lista, padrao) => { const r = lista.find((x) => x.checked); return r ? r.value : padrao; };
  await aplicarPerfil(lido(radios.classe, atual.classe), lido(radios.disco, atual.disco));
}

async function voltarPerfilAutomatico() {
  try {
    await recoletar({ resetarPerfil: true });
    renderAtual();
    toast(t('diagnostico.perfilAuto'), 'ok');
  } catch (e) { mostrarErro(e); }
}

async function aplicarPerfil(classe, disco) {
  try {
    await recoletar({ forcarPerfil: { classe, disco } });
    renderAtual();
    toast(t('diagnostico.perfilSalvo'), 'ok');
  } catch (e) { mostrarErro(e); }
}

VISTAS.diagnostico = {
  render(main) {
    const v = h('section', { class: 'vista' }, h('h1', { text: t('diagnostico.titulo') }));
    main.append(v);
    if (S.base === 'carregando' || !S.diag) {
      v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('diagnostico.aguarde') })));
      if (S.base === 'erro') {
        v.textContent = '';
        v.append(h('h1', { text: t('diagnostico.titulo') }), h('p', { text: t('inicio.erro', { erro: S.baseErro }) }));
      }
      return;
    }
    const d = S.diag;
    const p = d.perfil;
    const pt = perfilTexto(p);

    v.append(h('div', { class: 'cartao perfil-banner' },
      h('div', {},
        h('p', { class: 'grande', text: t('inicio.perfilLinha', pt) }),
        h('p', { class: 'suave pequeno', text: p.manual ? t('diagnostico.manual') : t('diagnostico.automatico') })),
      h('button', { type: 'button', class: 'btn sec acao', text: t('diagnostico.trocar'), onclick: () => trocarPerfil() })));

    v.append(h('p', { class: 'suave pequeno', text: t('diagnostico.admin', { valor: simNao(S.info.esAdmin) }) }));

    const grade = h('div', { class: 'grade' });
    v.append(grade);

    grade.append(cartaoInfo(t('diagnostico.equipo'), [
      [t('diagnostico.fabricante'), val(d.equipo.fabricante)],
      [t('diagnostico.modelo'), val(d.equipo.modelo)],
      [t('diagnostico.nome'), val(d.equipo.nome)],
    ]));

    const s = d.sistema;
    grade.append(cartaoInfo(t('diagnostico.sistema'), [
      [t('diagnostico.edicao'), val(s.nome)],
      [t('diagnostico.versao'), val(s.versao)],
      [t('diagnostico.build'), val(s.build)],
      [t('diagnostico.arquitetura'), val(s.arquitetura)],
      [t('diagnostico.diasLigado'), s.diasLigado == null ? TRACO : (Math.floor(s.diasLigado) === 1 ? t('diagnostico.dia') : t('diagnostico.dias', { n: Math.floor(s.diasLigado) }))],
      [t('diagnostico.inicioRapido'), simNao(s.inicioRapido)],
    ]));

    const c = d.cpu;
    grade.append(cartaoInfo(t('diagnostico.cpu'), [
      [t('diagnostico.produto'), val(c.nome)],
      [t('diagnostico.nucleos'), val(c.nucleos) + ' / ' + val(c.hilos)],
      [t('diagnostico.frequencia'), val(c.mhz, (x) => (x / 1000).toLocaleString('pt-BR', { maximumFractionDigits: 2 }) + ' GHz')],
      [t('diagnostico.temperatura'), val(c.temp, (x) => x + ' °C')],
    ]));

    const r = d.ram;
    grade.append(cartaoInfo(t('diagnostico.ram'), [
      [t('diagnostico.ramTotal'), val(r.totalBytes, fmtGb)],
      [t('diagnostico.ramLivre'), val(r.livreBytes, fmtGb)],
      [t('diagnostico.ramModulos'), val(r.modulos)],
    ]));

    for (const g of d.gpus || []) {
      grade.append(cartaoInfo(t('diagnostico.gpu'), [
        [t('diagnostico.produto'), val(g.nome)],
        [t('diagnostico.fabricante'), val(g.fabricante)],
        [t('diagnostico.gpuTipo'), g.dedicada ? t('diagnostico.gpuDedicada') : t('diagnostico.gpuIntegrada')],
        [t('diagnostico.driver'), val(g.driver)],
        [t('diagnostico.vram'), g.vram ? fmtBytes(g.vram) : TRACO],
      ]));
    }

    if (d.bateria) {
      grade.append(cartaoInfo(t('diagnostico.bateria'), [
        [t('diagnostico.carga'), val(d.bateria.carga, (x) => x + '%')],
        [t('diagnostico.saudeBateria'), val(d.bateria.saude, (x) => x + '%')],
      ]));
    }

    grade.append(cartaoInfo(t('diagnostico.servicos'), [
      [t('diagnostico.sysmain'), val(d.servicos.sysmain)],
      [t('diagnostico.wsearch'), val(d.servicos.wsearch)],
    ]));

    // Discos e unidades ocupam a largura toda.
    const discos = h('div', { class: 'cartao' }, h('h3', { text: t('diagnostico.discos') }));
    for (const dk of d.discos || []) {
      const dl = h('dl', { class: 'linhas' });
      const add = (rot, valor) => { if (valor != null) dl.append(h('dt', { text: rot }), h('dd', { text: String(valor) })); };
      add(t('diagnostico.saude'), dk.saude);
      add(t('diagnostico.desgaste'), dk.desgaste == null ? null : dk.desgaste + '%');
      add(t('diagnostico.temperatura'), dk.temperatura == null ? null : dk.temperatura + ' °C');
      add(t('diagnostico.horas'), dk.horas == null ? null : dk.horas.toLocaleString('pt-BR') + ' h');
      add(t('diagnostico.erros'), dk.erros);
      discos.append(h('div', { class: 'item-disco' },
        h('div', { class: 'nome-item' },
          h('span', { text: dk.nome }),
          h('span', { class: 'selo', text: [dk.tipo, dk.bus].filter(Boolean).join(' · ') + ' · ' + fmtBytes(dk.tamanho) }),
          dk.sistema ? h('span', { class: 'selo destaque', text: t('diagnostico.discoSistema') }) : null),
        dl));
    }
    const unidades = h('div', { class: 'cartao' }, h('h3', { text: t('diagnostico.unidades') }));
    for (const u of d.unidades || []) {
      const usado = u.total > 0 ? Math.round(((u.total - u.livre) / u.total) * 100) : 0;
      unidades.append(h('div', { class: 'item-disco' },
        h('div', { class: 'nome-item' }, h('span', { text: u.letra + (u.rotulo ? ' ' + u.rotulo : '') })),
        h('div', { class: 'uso' + (usado >= 90 ? ' cheio' : ''), vars: { '--pct': usado } }, h('i')),
        h('div', { class: 'suave pequeno', text: t('diagnostico.livreDe', { livre: fmtBytes(u.livre), total: fmtBytes(u.total) }) })));
    }
    v.append(h('div', { class: 'grade' }, discos, unidades));

    v.append(h('p', {}, h('button', { type: 'button', class: 'btn sec acao', text: t('diagnostico.atualizar'), onclick: async () => {
      try { await recoletar({}); renderAtual(); } catch (e) { mostrarErro(e); }
    } })));
  },
};
