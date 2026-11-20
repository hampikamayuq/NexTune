'use strict';

// Modo demonstração: dados de exemplo (um PC básico com HDD, parecido com o de muita gente) e
// progresso simulado. Nada aqui toca no sistema.
const GB = 1073741824;
const MB = 1048576;

const demo = {
  _cancelar: false,
  _perfil: { classe: 'basico', disco: 'hdd', manual: false },
  _cats: null,

  cancelar() { this._cancelar = true; },

  _dormir(ms) { return new Promise((r) => setTimeout(r, ms)); },

  async _simular(onProgresso, modulo, etapas) {
    this._cancelar = false;
    const total = 1200;
    const passo = total / etapas.length;
    for (let i = 0; i < etapas.length; i++) {
      await this._dormir(passo);
      if (this._cancelar) throw new Error('Ação cancelada.');
      onProgresso({ id: 'demo', modulo, tipo: 'progresso', pct: Math.round(((i + 1) / etapas.length) * 100), msg: etapas[i] });
      if (modulo === 'limpeza' && etapas[i].startsWith('Limpando')) {
        onProgresso({ id: 'demo', modulo, tipo: 'log', tipoLog: 'info', msg: etapas[i], ruta: '' });
      }
    }
  },

  _categoriasIniciais() {
    const c = (id, cor, tam, extra) => Object.assign({
      id, cor, tamanhoBytes: tam, disponivel: true, motivoIndisponivel: '', confirmacaoDupla: false, avancado: false,
    }, extra || {});
    return [
      c('temp_usuario', 'verde', 1.4 * GB),
      c('temp_windows', 'verde', 620 * MB),
      c('wu_cache', 'amarelo', 2.1 * GB),
      c('entrega', 'verde', 310 * MB),
      c('informes', 'verde', 85 * MB),
      c('miniaturas', 'verde', 240 * MB),
      c('launchers', 'amarelo', 0, { disponivel: false, motivoIndisponivel: 'Nenhuma loja de jogos encontrada neste PC.' }),
      c('navegadores', 'amarelo', 980 * MB),
      c('minidumps', 'verde', 46 * MB),
      c('lixeira', 'amarelo', 530 * MB),
      c('shaders', 'amarelo', 0, { disponivel: false, motivoIndisponivel: 'Este perfil de PC não usa cache de shaders.' }),
      c('dism_componentes', 'amarelo', -1, { avancado: true }),
      c('windows_old', 'amarelo', 14.2 * GB, { avancado: true, confirmacaoDupla: true }),
      c('pontos_antigos', 'amarelo', -1, { avancado: true, confirmacaoDupla: true }),
    ].map((x) => Object.assign(x, { tamanhoBytes: Math.round(x.tamanhoBytes) }));
  },

  _coletar(params) {
    if (params && params.forcarPerfil) {
      this._perfil = { classe: params.forcarPerfil.classe, disco: params.forcarPerfil.disco, manual: true };
    }
    return {
      equipo: { fabricante: 'Positivo', modelo: 'C6400', nome: 'PC-DA-SALA' },
      sistema: { nome: 'Windows 11 Pro', versao: '25H2', build: '26200', arquitetura: '64 bits', diasLigado: 3, inicioRapido: false },
      cpu: { nome: 'Intel Celeron J4125', nucleos: 4, hilos: 4, mhz: 2000, temp: null },
      ram: { totalBytes: 8 * GB, livreBytes: Math.round(3.1 * GB), modulos: 1 },
      gpus: [{ nome: 'Intel UHD Graphics 600', fabricante: 'Intel', dedicada: false, driver: '31.0.101.2111', vram: 128 * MB }],
      discos: [{ nome: 'Seagate BarraCuda 1 TB', tipo: 'HDD', bus: 'SATA', tamanho: 1000 * GB, saude: 'Saudável', desgaste: null, temperatura: 38, horas: 9120, erros: 0, sistema: true }],
      unidades: [{ letra: 'C:', rotulo: 'Windows', total: 930 * GB, livre: 412 * GB }],
      bateria: null,
      servicos: { sysmain: 'Desativado', wsearch: 'Em execução' },
      perfil: Object.assign({}, this._perfil),
    };
  },

  async executar(modulo, acao, params, onProgresso) {
    if (modulo === 'diagnostico' && acao === 'coletar') {
      await this._simular(onProgresso, modulo, ['Lendo o equipamento…', 'Lendo discos e memória…', 'Definindo o perfil…']);
      return this._coletar(params);
    }
    if (modulo === 'limpeza' && acao === 'analisar') {
      if (!this._cats) this._cats = this._categoriasIniciais();
      await this._simular(onProgresso, modulo, ['Medindo temporários…', 'Medindo caches…', 'Medindo o restante…']);
      return { categorias: this._cats.map((c) => Object.assign({}, c)) };
    }
    if (modulo === 'limpeza' && acao === 'limpar') {
      const ids = (params && params.categorias) || [];
      const dup = this._cats.filter((c) => ids.includes(c.id) && c.confirmacaoDupla);
      if (dup.length && params.confirmado !== true) throw new Error('É preciso confirmar esta limpeza.');
      await this._simular(onProgresso, modulo, ids.map((id) => 'Limpando ' + t('cat.' + id + '.nome') + '…'));
      let liberado = 0;
      const detalhes = [];
      for (const c of this._cats) {
        if (!ids.includes(c.id)) continue;
        const antes = Math.max(c.tamanhoBytes, 0);
        const sobra = Math.round(antes * 0.02);
        liberado += antes - sobra;
        detalhes.push({ id: c.id, antes, depois: sobra, pulados: sobra > 0 ? 1 : 0 });
        c.tamanhoBytes = c.tamanhoBytes < 0 ? 0 : sobra;
      }
      return { liberadoBytes: liberado, pulados: detalhes.reduce((s, d) => s + d.pulados, 0), detalhes };
    }
    throw new Error('Ação não disponível na demonstração: ' + modulo + '/' + acao);
  },
};
