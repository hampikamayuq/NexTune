'use strict';

// Ponte com o Rust. Sem window.__TAURI__ (ex.: abrir o HTML num navegador) cai no modo demonstração.
const TAURI = window.__TAURI__ || null;
const _progresso = {}; // modulo -> callback do evento 'progresso'

const AJUSTES_PADRAO = {
  idioma: 'pt-BR', modoAvancado: false, pontoRestauracao: 'perguntar', diasQuarentena: 7,
  modoLeve: 'auto', tourVisto: false, ultimaVersao: '',
  jogos: [], modoJogoAuto: false, modoJogoPreset: 'suave', lembretes: false, lembretesDias: 3, bandeja: false,
};
const PERFIS_PADRAO = {
  classes: { basico: { ramGbMax: 4.5, nucleosMax: 2 }, gamer: { gpuDedicada: true, ramGbMin: 16 }, padrao: 'medio' },
  limites: { lixoNotificarMB: 500, diasSemVerificarDisco: 90 },
};

function _invoke(cmd, args) {
  return TAURI.core.invoke(cmd, args).catch((e) => { throw new Error(typeof e === 'string' ? e : (e && e.message) || String(e)); });
}

const api = {
  async iniciar() {
    if (!TAURI) return;
    await TAURI.event.listen('progresso', (e) => {
      const p = e.payload;
      const f = p && _progresso[p.modulo];
      if (f) f(p);
    });
  },

  async info() {
    if (!TAURI) return { versao: '0.1.0', demo: true, esAdmin: true, perfil: { classe: 'basico', disco: 'hdd', manual: false }, modoLeve: false, equipo: 'Demonstração', sessaoOk: true };
    return _invoke('info');
  },

  // true se `sistema/criarPonto` já devolveu `criado:true` neste processo (um ponto por sessão).
  async pontoSessao() {
    if (!TAURI) return !!demo._ponto;
    return _invoke('ponto_sessao');
  },

  ajustes: {
    async ler() {
      if (!TAURI) return { ...AJUSTES_PADRAO };
      return _invoke('ajustes_ler');
    },
    // Recebe só o que mudou; manda o objeto completo (argumento `a`).
    async gravar(parcial) {
      const completo = { ...S.ajustes, ...parcial };
      if (!TAURI) return completo;
      return _invoke('ajustes_gravar', { a: completo });
    },
  },

  async abrirUrl(url) {
    if (!TAURI) return null;
    return _invoke('abrir_url', { url });
  },

  async abrirPasta(caminho) {
    if (!TAURI) return null;
    return _invoke('abrir_pasta', { caminho });
  },

  async autostart(ligar) {
    if (!TAURI) return demo.autostart(ligar);
    return _invoke('autostart', { ligar });
  },

  async autostartEstado() {
    if (!TAURI) return demo._autostart;
    return _invoke('autostart_estado');
  },

  atualizacao: {
    async verificar() {
      if (!TAURI) return null;
      return _invoke('atualizacao_verificar');
    },
    async instalar() {
      if (!TAURI) throw new Error('demo');
      return _invoke('atualizacao_instalar');
    },
  },

  async dados(nome) {
    if (!TAURI) return PERFIS_PADRAO;
    return _invoke('dados', { nome });
  },

  async cancelar() {
    if (S.info && S.info.demo) demo.cancelar();
    if (TAURI) return _invoke('cancelar');
    return null;
  },

  // Uma ação por vez: enquanto S.ocupado a interface desabilita os botões.
  async executar(modulo, acao, params, onProgresso) {
    if (S.ocupado) throw new Error(t('comum.erro', { erro: 'ocupado' }));
    setOcupado(true);
    const ouvir = (p) => { atualizarOcupado(p); if (onProgresso) onProgresso(p); };
    _progresso[modulo] = ouvir;
    try {
      if (S.info && S.info.demo) return await demo.executar(modulo, acao, params || {}, ouvir);
      return await _invoke('executar', { modulo, acao, params: params || {} });
    } finally {
      delete _progresso[modulo];
      setOcupado(false);
    }
  },
};
