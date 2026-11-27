'use strict';

// Espaço (módulo espaco): o que ocupa o disco. Só leitura: mostra as 20 maiores pastas do nível atual (clicar desce um
// nível) e os 20 maiores arquivos abaixo dele, e abre a pasta no Explorer. Apagar continua sendo pela Limpeza, por
// Programas ou pela Quarentena. Junction e link não entram na conta; pasta sem permissão aparece como "sem acesso", e a
// que estourou o tempo de medida aparece como "pelo menos" (o tamanho é um mínimo).

// Unidades fixas conhecidas (da tela Disco ou do Diagnóstico), com a do sistema primeiro.
function espacoUnidades() {
  const lista = (S.disco.estado && S.disco.estado.unidades) || (S.diag && S.diag.unidades) || [];
  const letras = lista.map((u) => u.letra).filter((l) => /^[A-Z]:$/.test(l || ''));
  const sis = discoSistema();
  if (sis && letras.includes(sis.letra)) {
    letras.splice(letras.indexOf(sis.letra), 1);
    letras.unshift(sis.letra);
  }
  return letras.length ? letras : ['C:'];
}

// Pasta de cima (null na raiz da unidade).
function espacoPai(caminho) {
  const c = (caminho || '').replace(/\\+$/, '');
  if (c.length <= 2) return null;
  const i = c.lastIndexOf('\\');
  if (i < 0) return null;
  return i <= 2 ? c.slice(0, 2) + '\\' : c.slice(0, i);
}

function espacoNome(caminho) {
  const c = (caminho || '').replace(/\\+$/, '');
  const i = c.lastIndexOf('\\');
  return i < 0 ? c + '\\' : c.slice(i + 1);
}

async function analisarEspaco(raiz) {
  const E = S.espaco;
  if (S.ocupado) return;
  E.carregando = true; E.erro = null; E.alvo = raiz;
  if (S.vista === 'espaco') renderAtual();
  try {
    E.resultado = await api.executar('espaco', 'analisar', { raiz }, null);
  } catch (e) {
    E.erro = e.message || String(e);
  }
  E.carregando = false;
  if (S.vista === 'espaco') renderAtual();
}

async function abrirPastaEspaco(caminho) {
  try {
    if (S.info && S.info.demo) { toast(t('espaco.abrirDemo'), 'aviso'); return; }
    await api.abrirPasta(caminho);
  } catch (e) {
    mostrarErro(e);
  }
}

function linhaPastaEspaco(p, maior) {
  const pct = p.bytes && maior > 0 ? Math.max(1, Math.round((p.bytes / maior) * 100)) : 0;
  const tam = p.semAcesso ? t('espaco.semAcesso') : (p.parcial ? t('espaco.peloMenos', { tam: fmtBytes(p.bytes) }) : fmtBytes(p.bytes));
  const nome = p.semAcesso
    ? h('span', { class: 'caminho', text: espacoNome(p.caminho) })
    : h('button', { type: 'button', class: 'link acao', text: espacoNome(p.caminho), title: t('espaco.entrar'), onclick: () => analisarEspaco(p.caminho) });
  return h('div', { class: 'item-disco' },
    h('div', { class: 'linha-resto' },
      nome,
      h('span', { class: 'tam' + (p.semAcesso ? ' suave' : ''), text: tam }),
      h('button', { type: 'button', class: 'btn sec pequeno', text: t('espaco.abrir'), onclick: () => abrirPastaEspaco(p.caminho) })),
    p.semAcesso ? null : h('div', { class: 'uso', vars: { '--pct': pct } }, h('i')));
}

function linhaArquivoEspaco(a) {
  const pasta = espacoPai(a.caminho);
  return h('div', { class: 'item-disco' },
    h('div', { class: 'linha-resto' },
      h('span', { class: 'caminho', text: a.caminho }),
      h('span', { class: 'tam', text: fmtBytes(a.bytes) }),
      pasta ? h('button', { type: 'button', class: 'btn sec pequeno', text: t('espaco.abrirPasta'), onclick: () => abrirPastaEspaco(pasta) }) : null));
}

VISTAS.espaco = {
  render(main) {
    const E = S.espaco;
    const v = h('section', { class: 'vista' }, h('h1', { text: t('espaco.titulo') }), h('p', { class: 'suave', text: t('espaco.intro') }));
    main.append(v);

    const r = E.resultado;
    const atual = r ? r.raiz : null;
    const unidades = espacoUnidades();
    v.append(h('div', { class: 'barra-prog' },
      h('div', { class: 'chips' }, ...unidades.map((l) => h('button', {
        type: 'button', class: 'chip acao' + (atual && atual.toUpperCase().startsWith(l) ? ' ativo' : ''),
        text: t('espaco.unidade', { letra: l }), onclick: () => analisarEspaco(l + '\\'),
      })))));

    if (E.erro) {
      v.append(h('div', { class: 'cartao' },
        h('p', { text: t('espaco.erro', { erro: E.erro }) }),
        E.alvo ? h('button', { type: 'button', class: 'btn acao', text: t('comum.tentarDeNovo'), onclick: () => analisarEspaco(E.alvo) }) : null));
    }
    if (E.carregando) {
      v.append(h('div', { class: 'carregando' }, h('span', { class: 'giro' }), h('span', { text: t('espaco.medindo', { pasta: E.alvo || '' }) })));
      return;
    }
    if (!r) {
      v.append(h('p', { class: 'suave', text: t('espaco.comecar') }));
      aplicarOcupado();
      return;
    }

    const pai = espacoPai(r.raiz);
    v.append(h('div', { class: 'barra-prog' },
      pai ? h('button', { type: 'button', class: 'btn sec acao', text: t('espaco.subir'), onclick: () => analisarEspaco(pai) }) : null,
      h('span', { class: 'caminho', text: r.raiz }),
      h('button', { type: 'button', class: 'btn sec', text: t('espaco.abrir'), onclick: () => abrirPastaEspaco(r.raiz) }),
      h('button', { type: 'button', class: 'btn sec acao', text: t('espaco.medirDeNovo'), onclick: () => analisarEspaco(r.raiz) })));

    v.append(h('p', {}, h('strong', { text: t(r.parcial ? 'espaco.totalParcial' : 'espaco.total', { tam: fmtBytes(r.totalBytes) }) })));
    if (r.parcial) v.append(h('p', { class: 'aviso pequeno', text: t('espaco.avisoParcial') }));

    const pastas = r.pastas || [];
    const maior = pastas.reduce((m, p) => Math.max(m, p.bytes || 0), 0);
    const cPastas = h('div', { class: 'cartao' }, h('h3', { text: t('espaco.pastas') }));
    if (!pastas.length) cPastas.append(h('p', { class: 'suave', text: t('espaco.semPastas') }));
    pastas.forEach((p) => cPastas.append(linhaPastaEspaco(p, maior)));
    if (r.soltosBytes > 0) cPastas.append(h('p', { class: 'suave pequeno', text: t('espaco.soltos', { tam: fmtBytes(r.soltosBytes) }) }));

    const arquivos = r.arquivos || [];
    const cArq = h('div', { class: 'cartao' }, h('h3', { text: t('espaco.arquivos') }));
    if (!arquivos.length) cArq.append(h('p', { class: 'suave', text: t('espaco.semArquivos') }));
    arquivos.forEach((a) => cArq.append(linhaArquivoEspaco(a)));

    v.append(cPastas, cArq);
    v.append(h('p', { class: 'suave pequeno', text: t('espaco.rodape') }));
    aplicarOcupado();
  },
};
