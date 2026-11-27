'use strict';

// Espaço (módulo espaco, só leitura): onde está o espaço ocupado numa unidade. Mostra as 20 maiores pastas
// do nível aberto (barras proporcionais à maior) e os 20 maiores arquivos; clicar numa pasta analisa um
// nível abaixo. Cada resultado fica guardado por raiz em S.espaco.cache: voltar pela trilha não analisa de
// novo. Links e junções nunca são seguidos nem somados; "sem acesso" e "não medido" nunca viram zero.
// Apagar continua sendo pela Limpeza ou pela desinstalação (quarentena).

// Unidades fixas do diagnóstico ('C:', 'D:'...); a do sistema primeiro, se o Disco já disse qual é.
function espacoUnidades() {
  const lista = ((S.diag && S.diag.unidades) || []).map((u) => u.letra).filter((l) => /^[A-Za-z]:$/.test(l || ''));
  return lista.length ? lista : ['C:'];
}

function espacoLetraPadrao() {
  const unidades = espacoUnidades();
  const sis = typeof discoSistema === 'function' ? discoSistema() : null;
  if (sis && unidades.includes(sis.letra)) return sis.letra;
  return unidades.includes('C:') ? 'C:' : unidades[0];
}

function espacoRaizDaUnidade(letra) {
  return letra + '\\';
}

function espacoAtual() {
  const E = S.espaco;
  const raiz = E.trilha[E.trilha.length - 1];
  return raiz ? { raiz, r: E.cache[raiz] } : null;
}

// Nome curto para a trilha: 'C:' na raiz da unidade, senão o último pedaço do caminho.
function espacoRotulo(raiz) {
  if (/^[A-Za-z]:\\$/.test(raiz)) return raiz.slice(0, 2);
  const s = raiz.replace(/\\+$/, '');
  return s.slice(s.lastIndexOf('\\') + 1) || s;
}

// Pasta onde dá para entrar: nem link (não é seguido) nem sem acesso (não dá para listar).
function espacoNavegavel(p) {
  return !p.link && !p.semAcesso;
}

function espacoTamanho(p) {
  if (p.link) return t('espaco.link');
  if (p.semAcesso) return t('espaco.semAcesso');
  if (p.bytes == null || p.bytes < 0) return t('espaco.naoMedido');
  if (p.parcial) return t('espaco.peloMenos', { tamanho: fmtBytes(p.bytes) });
  return fmtBytes(p.bytes);
}

function espacoTitulo(p) {
  if (p.link) return t('espaco.linkDica');
  if (p.semAcesso) return t('espaco.semAcessoDica');
  if (p.bytes == null || p.bytes < 0) return t('espaco.naoMedidoDica');
  if (p.parcial) return t('espaco.parcialDica');
  return null;
}

// Analisa `raiz`. modo: 'unidade' (recomeça a trilha), 'entrar' (um nível abaixo) ou 'denovo' (o nível atual).
async function analisarEspaco(raiz, modo) {
  const E = S.espaco;
  if (S.ocupado) return;
  if (modo === 'entrar' && E.cache[raiz]) { espacoEntrar(raiz, modo); renderAtual(); return; }
  E.erro = null;
  E.prog = { pct: 0, msg: t('espaco.analisando', { pasta: raiz }) };
  renderAtual();
  try {
    const r = await api.executar('espaco', 'analisar', { raiz }, progressoInline(E, 'es-barra', 'es-msg'));
    // Analisar de novo deixa velhos os níveis guardados abaixo deste.
    const prefixo = raiz.replace(/\\+$/, '').toLowerCase() + '\\';
    Object.keys(E.cache).forEach((k) => { if (k.toLowerCase().startsWith(prefixo)) delete E.cache[k]; });
    E.cache[raiz] = r;
    espacoEntrar(raiz, modo);
    if (r.incompleto) toast(t('espaco.incompletoToast'), 'aviso');
  } catch (e) {
    E.erro = { raiz, msg: e.message || String(e) };
  }
  E.prog = null;
  if (S.vista === 'espaco') renderAtual();
}

function espacoEntrar(raiz, modo) {
  const E = S.espaco;
  if (modo === 'unidade') { E.trilha = [raiz]; return; }
  const i = E.trilha.indexOf(raiz);
  if (i >= 0) E.trilha = E.trilha.slice(0, i + 1);
  else if (modo === 'entrar') E.trilha.push(raiz);
  else E.trilha = [raiz];
}

function espacoVoltarPara(i) {
  const E = S.espaco;
  if (S.ocupado || i < 0 || i >= E.trilha.length - 1) return;
  E.trilha = E.trilha.slice(0, i + 1);
  E.erro = null;
  renderAtual();
}

function espacoTrocarUnidade(letra) {
  const E = S.espaco;
  E.letra = letra;
  E.erro = null;
  const raiz = espacoRaizDaUnidade(letra);
  E.trilha = E.cache[raiz] ? [raiz] : [];
  renderAtual();
}

function espacoTrilha() {
  const E = S.espaco;
  const itens = [];
  E.trilha.forEach((raiz, i) => {
    if (i > 0) itens.push(h('span', { class: 'sep', 'aria-hidden': 'true', text: '›' }));
    const ultimo = i === E.trilha.length - 1;
    itens.push(ultimo
      ? h('span', { class: 'atual', 'aria-current': 'location', title: raiz, text: espacoRotulo(raiz) })
      : h('button', { type: 'button', class: 'link acao', title: raiz, text: espacoRotulo(raiz), onclick: () => espacoVoltarPara(i) }));
  });
  return h('nav', { class: 'trilha-esp', 'aria-label': t('espaco.trilha') }, itens);
}

function linhaPastaEspaco(p, maior) {
  const pct = p.bytes > 0 && maior > 0 ? Math.max(0.5, (p.bytes / maior) * 100) : 0;
  const nav = espacoNavegavel(p);
  const dica = espacoTitulo(p);
  const nome = nav
    ? h('button', { type: 'button', class: 'nome-esp link acao', title: t('espaco.entrarDica', { pasta: p.caminho }), text: p.nome, onclick: () => analisarEspaco(p.caminho, 'entrar') })
    : h('span', { class: 'nome-esp', title: p.caminho, text: p.nome });
  const selos = [];
  if (p.link) selos.push(h('span', { class: 'selo', text: t('espaco.seloLink') }));
  if (p.semAcesso) selos.push(h('span', { class: 'selo', text: t('espaco.seloSemAcesso') }));
  const desconhecido = p.link || p.semAcesso || p.bytes == null || p.bytes < 0;
  return h('div', { class: 'pasta-esp' + (nav ? '' : ' fixa') },
    h('div', { class: 'cab-esp' }, nome, selos),
    h('span', { class: 'tam-esp' + (desconhecido ? ' desc-tam' : ''), title: dica, text: espacoTamanho(p) }),
    p.link ? h('span') : h('button', { type: 'button', class: 'btn sec mini', title: p.caminho, text: t('espaco.abrirExplorer'), onclick: () => abrirPastaExplorer(p.caminho) }),
    h('div', { class: 'barra-esp' + (p.parcial ? ' parcial' : ''), 'aria-hidden': 'true', vars: { '--pct': pct.toFixed(2) } }, h('i')));
}

function linhaArquivoEspaco(a) {
  const pasta = pastaDoArquivo(a.caminho);
  return h('div', { class: 'arq-esp' },
    h('div', { class: 'arq-info' },
      h('span', { class: 'arq-nome', text: a.nome }),
      h('span', { class: 'caminho suave pequeno', text: pasta })),
    h('span', { class: 'tam-esp', text: fmtBytes(a.bytes) }),
    h('button', { type: 'button', class: 'btn sec mini', title: pasta, text: t('espaco.abrirPasta'), onclick: () => abrirPastaExplorer(pasta) }));
}

function espacoResultado(raiz, r) {
  const pastas = r.pastas || [];
  const arquivos = r.arquivos || [];
  const maior = pastas.reduce((m, p) => (!p.link && p.bytes > m ? p.bytes : m), 0);
  const algoFaltou = r.incompleto || pastas.some((p) => p.parcial || p.semAcesso || (!p.link && p.bytes < 0));
  const total = algoFaltou ? t('espaco.peloMenos', { tamanho: fmtBytes(r.totalBytes) }) : fmtBytes(r.totalBytes);
  const partes = [];

  partes.push(h('div', { class: 'cartao resumo-esp' },
    h('div', { class: 'linha-total' },
      h('span', { class: 'suave', text: t('espaco.totalEm', { pasta: raiz }) }),
      h('span', { class: 'grande', text: total })),
    r.incompleto ? h('p', { class: 'aviso pequeno', text: t('espaco.incompleto') }) : null));

  partes.push(h('h2', { text: t('espaco.pastasTitulo') }));
  if (!pastas.length) {
    partes.push(h('p', { class: 'suave', text: t('espaco.semPastas') }));
  } else {
    partes.push(h('p', { class: 'suave pequeno', text: t('espaco.pastasDica') }));
    partes.push(h('div', { class: 'lista-esp' }, pastas.map((p) => linhaPastaEspaco(p, maior))));
  }

  partes.push(h('h2', { text: t('espaco.arquivosTitulo') }));
  if (!arquivos.length) partes.push(h('p', { class: 'suave', text: t('espaco.semArquivos') }));
  else partes.push(h('div', { class: 'lista-esp' }, arquivos.map(linhaArquivoEspaco)));

  partes.push(h('div', { class: 'nota-esp suave pequeno' },
    h('p', {}, t('espaco.soLeitura'), ' ',
      h('button', { type: 'button', class: 'link', text: t('espaco.irLimpeza'), onclick: () => irPara('limpeza') }), ' · ',
      h('button', { type: 'button', class: 'link', text: t('espaco.irProgramas'), onclick: () => irPara('programas') })),
    h('p', { text: t('espaco.hardLinks') })));
  return partes;
}

VISTAS.espaco = {
  render(main) {
    const E = S.espaco;
    if (!E.letra) E.letra = espacoLetraPadrao();
    const v = h('section', { class: 'vista' }, h('h1', { text: t('espaco.titulo') }), h('p', { class: 'suave', text: t('espaco.intro') }));
    main.append(v);

    const unidades = espacoUnidades();
    if (!unidades.includes(E.letra)) unidades.push(E.letra);
    const sel = h('select', { id: 'es-unidade', class: 'acao', 'aria-label': t('espaco.unidade'), onchange: (e) => espacoTrocarUnidade(e.target.value) },
      unidades.map((l) => h('option', { value: l, text: l })));
    sel.value = E.letra;
    const atual = espacoAtual();
    const raizUnidade = espacoRaizDaUnidade(E.letra);
    const info = ((S.diag && S.diag.unidades) || []).find((u) => u.letra === E.letra);
    v.append(h('div', { class: 'barra-prog' },
      h('label', { class: 'ordem', for: 'es-unidade' }, h('span', { class: 'suave pequeno', text: t('espaco.unidade') }), sel),
      h('button', { type: 'button', class: 'btn acao', text: t(E.cache[raizUnidade] ? 'espaco.analisarDeNovo' : 'espaco.analisar'),
        onclick: () => analisarEspaco(raizUnidade, 'unidade') }),
      atual && atual.raiz !== raizUnidade
        ? h('button', { type: 'button', class: 'btn sec acao', text: t('espaco.analisarPastaDeNovo'), onclick: () => analisarEspaco(atual.raiz, 'denovo') })
        : null,
      info ? h('span', { class: 'suave pequeno', text: t('espaco.livreDe', { livre: fmtBytes(info.livre), total: fmtBytes(info.total) }) }) : null));

    if (E.prog) v.append(cartaoProgresso(E.prog, 'es-barra', 'es-msg'));
    if (E.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('espaco.erro', { pasta: E.erro.raiz, erro: E.erro.msg }) }),
        h('button', { type: 'button', class: 'btn sec acao', text: t('comum.tentarDeNovo'),
          onclick: () => analisarEspaco(E.erro.raiz, E.trilha.length ? 'entrar' : 'unidade') })));
    }
    if (!atual || !atual.r) {
      if (!E.prog) v.append(h('p', { class: 'suave pequeno', text: t('espaco.comoComecar') }));
      aplicarOcupado();
      return;
    }
    v.append(espacoTrilha());
    v.append(...espacoResultado(atual.raiz, atual.r));
    aplicarOcupado();
  },
};
