'use strict';

// Modo demonstração: dados de exemplo (um PC básico com HDD, parecido com o de muita gente) e
// progresso simulado. Nada aqui toca no sistema.
const GB = 1073741824;
const MB = 1048576;

const demo = {
  _cancelar: false,
  _perfil: { classe: 'basico', disco: 'hdd', manual: false },
  _cats: null,
  _programas: null,
  _quarentena: null,
  _protecao: false,   // Proteção do Sistema desligada até ligarProtecao (PC de fábrica com disco pequeno)
  _ponto: false,      // criarPonto ainda não rodou nesta sessão
  _seq: 0,

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

  _dia(n) { return new Date(Date.now() - n * 86400000).toISOString(); },

  _programasIniciais() {
    const p = (id, nome, editor, extra) => Object.assign({
      id, nome, editor, versao: '1.0', tipo: 'classico', tamanhoBytes: -1, instaladoEm: null, local: null,
      cor: null, motivoCor: null, protegido: false, motivoProtegido: null, instalador: 'desconhecido',
      servicos: [], ramBytes: 0, packageFamilyName: null, productId: null, siteReinstalar: null,
    }, extra || {});
    return [
      p('cl:hklm64:PositivoUtilities', 'Positivo Utilities', 'Positivo Tecnologia', {
        versao: '3.2.1', tamanhoBytes: 186 * MB, instaladoEm: this._dia(410), local: 'C:\\Program Files\\Positivo\\Utilities', instalador: 'inno',
        cor: 'verde', motivoCor: 'Utilitário de fábrica do Positivo: propaganda e atalhos; o Windows já faz tudo isso.',
        servicos: ['PositivoSvc'], ramBytes: 42 * MB }),
      p('cl:hklm32:MultilaserApp', 'Multilaser App', 'Multilaser', {
        versao: '2.0.8', tamanhoBytes: 97 * MB, instaladoEm: this._dia(410), local: 'C:\\Program Files (x86)\\Multilaser\\App', instalador: 'nsis',
        cor: 'verde', motivoCor: 'Utilitário de fábrica da Multilaser: propaganda e atalhos; o Windows já faz tudo isso.' }),
      p('cl:hklm64:LenovoVantage', 'Lenovo Vantage', 'Lenovo', {
        versao: '10.2401.29.0', tamanhoBytes: 312 * MB, instaladoEm: this._dia(380), local: 'C:\\Program Files\\Lenovo\\Vantage', instalador: 'msi',
        cor: 'amarelo', motivoCor: 'Lenovo Vantage: atualiza drivers e configura a bateria do notebook; só remova se não usa.',
        servicos: ['LenovoVantageService', 'ImControllerService'], ramBytes: 118 * MB, siteReinstalar: 'https://support.lenovo.com/br/pt/solutions/ht505081' }),
      p('cl:hklm64:Avast Antivirus', 'Avast Free Antivirus', 'Avast Software', {
        versao: '24.3.6108', tamanhoBytes: Math.round(1.9 * GB), instaladoEm: this._dia(200), local: 'C:\\Program Files\\Avast Software\\Avast', instalador: 'quiet',
        cor: 'amarelo', motivoCor: 'Antivírus: só remova se tiver outro; ao sair, o Windows Defender volta a proteger sozinho.',
        servicos: ['avast! Antivirus', 'aswbIDSAgent'], ramBytes: 260 * MB, siteReinstalar: 'https://www.avast.com/pt-br/' }),
      p('cl:hklm32:Microsoft EdgeWebView', 'Microsoft Edge WebView2 Runtime', 'Microsoft Corporation', {
        versao: '131.0.2903.70', tamanhoBytes: 620 * MB, instaladoEm: this._dia(12), local: 'C:\\Program Files (x86)\\Microsoft\\EdgeWebView', instalador: 'quiet',
        cor: 'vermelho', motivoCor: 'Mostra a tela do NexTune e de muitos outros programas: sem ele, eles não abrem.',
        protegido: true, motivoProtegido: 'Mostra a tela do NexTune e de muitos outros programas: sem ele, eles não abrem.', ramBytes: 95 * MB }),
      p('cl:hklm32:Microsoft Edge', 'Microsoft Edge', 'Microsoft Corporation', {
        versao: '131.0.2903.70', tamanhoBytes: 680 * MB, instaladoEm: this._dia(12), local: 'C:\\Program Files (x86)\\Microsoft\\Edge', instalador: 'quiet',
        cor: 'vermelho', motivoCor: 'Navegador que faz parte do Windows: o sistema e outros programas dependem dele.',
        protegido: true, motivoProtegido: 'Navegador que faz parte do Windows: o sistema e outros programas dependem dele.', servicos: ['edgeupdate'] }),
      p('cl:hklm64:Google Chrome', 'Google Chrome', 'Google LLC', {
        versao: '131.0.6778.86', tamanhoBytes: 710 * MB, instaladoEm: this._dia(300), local: 'C:\\Program Files\\Google\\Chrome', instalador: 'quiet',
        servicos: ['GoogleUpdaterService'], ramBytes: 540 * MB }),
      p('cl:hklm64:LibreOffice 24.8', 'LibreOffice 24.8', 'The Document Foundation', {
        versao: '24.8.3.2', tamanhoBytes: Math.round(1.1 * GB), instaladoEm: this._dia(90), local: 'C:\\Program Files\\LibreOffice', instalador: 'msi' }),
      p('st:Microsoft.BingNews_4.2.27001.0_x64__8wekyb3d8bbwe', 'Microsoft News', 'Microsoft Corporation', {
        versao: '4.2.27001.0', tipo: 'store', tamanhoBytes: 58 * MB, instaladoEm: this._dia(410), instalador: 'loja',
        cor: 'verde', motivoCor: 'Notícias da Microsoft: só mostra manchetes e anúncios; o navegador faz o mesmo.',
        packageFamilyName: 'Microsoft.BingNews_8wekyb3d8bbwe', productId: '9WZDNCRFHVFW' }),
      p('st:king.com.CandyCrushSaga_1.270.0.0_x86__kgqvnymyfvs32', 'Candy Crush Saga', 'king.com', {
        versao: '1.270.0.0', tipo: 'store', tamanhoBytes: 412 * MB, instaladoEm: this._dia(410), instalador: 'loja',
        cor: 'verde', motivoCor: 'Candy Crush pré-instalado: jogo com compras dentro do app; reinstale pela Store se quiser jogar.',
        packageFamilyName: 'king.com.CandyCrushSaga_kgqvnymyfvs32', productId: '9NBLGGH18846' }),
      p('st:Microsoft.ZuneMusic_11.2411.8.0_x64__8wekyb3d8bbwe', 'Media Player', 'Microsoft Corporation', {
        versao: '11.2411.8.0', tipo: 'store', tamanhoBytes: 74 * MB, instaladoEm: this._dia(12), instalador: 'loja',
        cor: 'amarelo', motivoCor: 'Media Player (antigo Groove): no Windows 11 é o tocador padrão de música; só remova se usa outro.',
        packageFamilyName: 'Microsoft.ZuneMusic_8wekyb3d8bbwe', productId: '9WZDNCRFJ3PT' }),
    ];
  },

  // Três entradas dentro do prazo (2, 5 e dias-1 dias atrás), para o arranque não purgar nada.
  // Para ver o estado "vencida" na demo: em Opções, baixe os dias na quarentena para menos que a
  // idade de uma entrada (ex.: 3 dias deixa a de 5 dias vencida) e volte à Quarentena.
  _quarentenaInicial() {
    const dias = (S.ajustes && S.ajustes.diasQuarentena) || 7;
    const e = (id, hDias, modulo, descricao, itens, tam) => ({ id, data: this._dia(hDias), modulo, descricao, itens, tamanhoBytes: tam });
    return [
      e('20251118-143012-a3f1', 2, 'programas', 'Restos de McAfee LiveSafe', 3, 48 * MB),
      e('20251115-091500-7c0e', 5, 'programas', 'Restos de Lenovo Now', 1, 12 * MB),
      e('20251114-201044-b2d9', Math.max(dias - 1, 1), 'ajustes', 'Backup de registro: anúncios e sugestões', 4, 24 * 1024),
    ];
  },

  _restos(prog) {
    const usuario = 'C:\\Users\\Maria';
    const base = (prog.editor ? prog.editor.split(' ')[0] : prog.nome) + '\\' + prog.nome;
    return [
      { tipo: 'pasta', caminho: usuario + '\\AppData\\Local\\' + base, tamanhoBytes: 36 * MB, motivo: 'Pasta de dados do programa em AppData, sem executáveis e sem mudanças há 30 dias.', confianca: 'media' },
      { tipo: 'atalho', caminho: usuario + '\\Desktop\\' + prog.nome + '.lnk', tamanhoBytes: 2048, motivo: 'Atalho da Área de Trabalho apontando para um programa que não existe mais.', confianca: 'media' },
    ];
  },

  _coletar(params) {
    if (params && params.forcarPerfil) {
      this._perfil = { classe: params.forcarPerfil.classe, disco: params.forcarPerfil.disco, manual: true };
    } else if (params && params.resetarPerfil === true) {
      this._perfil = { classe: 'basico', disco: 'hdd', manual: false };
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
        detalhes.push({ id: c.id, antes, depois: sobra, pulados: sobra > 0 ? 1 : 0, erro: null });
        c.tamanhoBytes = c.tamanhoBytes < 0 ? 0 : sobra;
      }
      return { liberadoBytes: liberado, pulados: detalhes.reduce((s, d) => s + d.pulados, 0), falhas: [], detalhes };
    }
    if (modulo === 'programas') return this._executarProgramas(acao, params, onProgresso);
    if (modulo === 'quarentena') return this._executarQuarentena(acao, params, onProgresso);
    if (modulo === 'sistema') return this._executarSistema(acao, params, onProgresso);
    throw new Error('Ação não disponível na demonstração: ' + modulo + '/' + acao);
  },

  async _executarProgramas(acao, params, onProgresso) {
    if (!this._programas) this._programas = this._programasIniciais();
    if (acao === 'listar') {
      await this._simular(onProgresso, 'programas', ['Lendo programas instalados…', 'Lendo apps da Store…', 'Medindo tamanhos, serviços e memória…']);
      return { programas: this._programas.map((p) => Object.assign({}, p, { servicos: p.servicos.slice() })) };
    }
    if (acao === 'desinstalar') {
      const prog = this._programas.find((p) => p.id === params.id);
      if (!prog) throw new Error('Programa não encontrado na lista: ' + params.id);
      if (prog.protegido) throw new Error('Programa protegido: ' + prog.motivoProtegido);
      if (params.confirmado !== true) throw new Error('É preciso confirmar a desinstalação.');
      if (params.desprovisionar === true && params.avancado !== true) throw new Error('desprovisionar exige o modo avançado.');
      await this._simular(onProgresso, 'programas', ['Preparando o desinstalador…', 'Desinstalando ' + prog.nome + '…', 'Procurando restos…']);
      this._programas = this._programas.filter((p) => p.id !== prog.id);
      const loja = prog.tipo === 'store';
      return { modo: loja ? 'loja' : (prog.instalador === 'desconhecido' ? 'assistente' : 'silencioso'), codigo: 0, restos: this._restos(prog) };
    }
    if (acao === 'restos') {
      const prog = this._programas.find((p) => p.id === params.id) || { nome: params.nome, editor: params.editor || '' };
      return { candidatos: this._restos(prog) };
    }
    if (acao === 'limparRestos') {
      if (params.confirmado !== true) throw new Error('É preciso confirmar.');
      const itens = params.itens || [];
      if (!itens.length) throw new Error('Nenhum item para mover.');
      if (!this._quarentena) this._quarentena = this._quarentenaInicial();
      await this._simular(onProgresso, 'programas', itens.map((i) => 'Movendo ' + i.caminho + '…'));
      this._seq++;
      const id = '20251120-1530' + String(this._seq).padStart(2, '0') + '-' + (0x1a00 + this._seq).toString(16);
      const agora = new Date();
      this._quarentena.unshift({
        id, data: agora.toISOString(), modulo: 'programas', descricao: 'Restos de ' + (params.nome || 'programa'),
        itens: itens.length, tamanhoBytes: itens.length * 18 * MB,
      });
      return { quarentenaId: id, movidos: itens.length, falhas: [] };
    }
    throw new Error('Ação não disponível na demonstração: programas/' + acao);
  },

  async _executarQuarentena(acao, params, onProgresso) {
    if (!this._quarentena) this._quarentena = this._quarentenaInicial();
    const ids = params.ids || [];
    if (acao === 'listar') {
      // Como o script real: venceEm = data + params.dias (padrão 7), calculado na hora da leitura.
      const dias = Number(params.dias) || 7;
      await this._dormir(150);
      return { entradas: this._quarentena.map((e) => Object.assign({}, e, { venceEm: new Date(new Date(e.data).getTime() + dias * 86400000).toISOString() })), diasPadrao: 7 };
    }
    if (acao === 'restaurar') {
      await this._simular(onProgresso, 'quarentena', ids.map((id) => 'Restaurando ' + id + '…'));
      const restauradas = [];
      const conflitos = [];
      for (const id of ids) {
        const e = this._quarentena.find((x) => x.id === id);
        if (!e) continue;
        // A entrada mais antiga simula origem que voltou a existir: fica na quarentena.
        if (e.modulo === 'ajustes') { conflitos.push({ id, item: 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager', motivo: 'já existe algo no lugar de origem' }); continue; }
        restauradas.push(id);
      }
      this._quarentena = this._quarentena.filter((e) => !restauradas.includes(e.id));
      return { restauradas, conflitos, falhas: [] };
    }
    if (acao === 'purgar') {
      if (params.confirmado !== true) throw new Error('É preciso confirmar.');
      await this._simular(onProgresso, 'quarentena', ids.map((id) => 'Apagando ' + id + '…'));
      const removidas = this._quarentena.filter((e) => ids.includes(e.id)).map((e) => e.id);
      this._quarentena = this._quarentena.filter((e) => !removidas.includes(e.id));
      return { removidas, falhas: [] };
    }
    if (acao === 'purgarVencidos') {
      const dias = Number(params.dias) || 7;
      const limite = Date.now() - dias * 86400000;
      await this._dormir(300);
      const removidas = this._quarentena.filter((e) => new Date(e.data).getTime() < limite).map((e) => e.id);
      this._quarentena = this._quarentena.filter((e) => !removidas.includes(e.id));
      return { removidas };
    }
    throw new Error('Ação não disponível na demonstração: quarentena/' + acao);
  },

  async _executarSistema(acao, params, onProgresso) {
    if (acao === 'protecaoEstado') {
      await this._dormir(200);
      return { ativa: this._protecao, ultimoPonto: this._ponto ? new Date().toISOString() : null, frequenciaMin: this._protecao ? 1440 : null, unidade: 'C:' };
    }
    if (acao === 'ligarProtecao') {
      await this._simular(onProgresso, 'sistema', ['Ligando a Proteção do Sistema…', 'Reservando 3 % do disco…']);
      this._protecao = true;
      return { ligada: true, mensagem: 'Proteção do Sistema ligada em C: com até 3 % do disco.' };
    }
    if (acao === 'criarPonto') {
      await this._simular(onProgresso, 'sistema', ['Criando um ponto de restauração…']);
      if (!this._protecao) return { criado: false, mensagem: 'A Proteção do Sistema está desligada.' };
      this._ponto = true;
      return { criado: true, mensagem: 'Ponto "NexTune" criado.' };
    }
    if (acao === 'sessao') {
      await this._dormir(100);
      return { usuarioProcesso: 'PC-DA-SALA\\Maria', usuarioConsole: 'PC-DA-SALA\\Maria', mesmo: true, desconhecido: false };
    }
    throw new Error('Ação não disponível na demonstração: sistema/' + acao);
  },
};
