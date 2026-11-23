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
  _inicio: null,
  _ajustesWin: null,
  _disco: null,
  _atualiz: null,
  _modoJogo: null,
  _autostart: false,
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

  _reinicios() {
    const dia = 24 * 3600 * 1000;
    const quando = (dias, hora) => new Date(Date.now() - dias * dia + hora * 3600 * 1000).toISOString();
    return {
      eventos: [
        { data: quando(1, 0), tipo: 'reinicio', quem: 'Windows Update', motivo: 'O Windows reiniciou para instalar atualizações. É normal; para evitar que aconteça enquanto você usa o PC, defina as "horas ativas" em Configurações > Windows Update.' },
        { data: quando(4, -3), tipo: 'telaAzul', quem: 'Windows', motivo: 'A placa de vídeo parou de responder (driver de vídeo, ou placa forçada demais ou muito quente).', codigo: '0x00000116' },
        { data: quando(9, -5), tipo: 'queda', quem: 'Windows', motivo: 'O PC desligou de repente, sem aviso do Windows: falta de energia, botão de ligar mantido pressionado, fonte ou temperatura. Se acontecer jogando, vigie as temperaturas.' },
        { data: quando(15, -2), tipo: 'desligamento', quem: 'Você', motivo: 'Você desligou o PC pelo menu Iniciar ou por um programa que pediu.' },
      ],
    };
  },

  async executar(modulo, acao, params, onProgresso) {
    if (modulo === 'diagnostico' && acao === 'coletar') {
      await this._simular(onProgresso, modulo, ['Lendo o equipamento…', 'Lendo discos e memória…', 'Definindo o perfil…']);
      return this._coletar(params);
    }
    if (modulo === 'diagnostico' && acao === 'reinicios') {
      await this._simular(onProgresso, modulo, ['Lendo o histórico do Windows…']);
      return this._reinicios();
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
    if (modulo === 'inicializacao') return this._executarInicializacao(acao, params || {});
    if (modulo === 'ajusteswin') return this._executarAjustesWin(acao, params || {});
    if (modulo === 'disco') return this._executarDisco(acao, params || {}, onProgresso);
    if (modulo === 'atualizacoes') return this._executarAtualizacoes(acao, params || {}, onProgresso);
    if (modulo === 'modojogo') return this._executarModoJogo(acao, params || {});
    if (modulo === 'reparo') return this._executarReparo(acao, params || {});
    if (modulo === 'saude') return this._executarSaude(acao, params || {}, onProgresso);
    if (modulo === 'espaco') return this._executarEspaco(acao, params || {}, onProgresso);
    if (modulo === 'drivers') return this._executarDrivers(acao, params || {}, onProgresso);
    if (modulo === 'rede') return this._executarRede(acao, params || {}, onProgresso);
    if (modulo === 'quarentena') return this._executarQuarentena(acao, params, onProgresso);
    if (modulo === 'sistema') return this._executarSistema(acao, params, onProgresso);
    throw new Error('Ação não disponível na demonstração: ' + modulo + '/' + acao);
  },

  _inicioInicial() {
    const i = (id, nome, editor, comando, extra) => Object.assign({
      id, nome, editor, comando, exe: comando, origem: 'run', escopo: 'usuario', ativo: true, cor: null, motivoCor: null,
      protegido: false, motivoProtegido: null, tamanhoBytes: -1, ramBytes: 0, rodando: false, avancado: false,
    }, extra || {});
    return [
      i('run:hklm:PositivoUpdater', 'Positivo Updater', 'Positivo Tecnologia', 'C:\\Program Files\\Positivo\\Updater.exe', {
        escopo: 'todos', cor: 'verde', motivoCor: 'Atualizador de fábrica: só mostra avisos e propaganda.', tamanhoBytes: 24 * MB, rodando: true, ramBytes: 38 * MB }),
      i('run:hklm:MultilaserHelper', 'Multilaser', 'Multilaser', 'C:\\Program Files (x86)\\Multilaser\\Helper.exe', {
        escopo: 'todos', cor: 'verde', motivoCor: 'Atalhos e propaganda da fábrica.', tamanhoBytes: 12 * MB }),
      i('run:hkcu:Spotify', 'Spotify', 'Spotify AB', 'C:\\Users\\Maria\\AppData\\Roaming\\Spotify\\Spotify.exe --autostart', {
        cor: 'amarelo', motivoCor: 'Abre o tocador na partida; desligue se não usa todo dia.', tamanhoBytes: 98 * MB, rodando: true, ramBytes: 210 * MB }),
      i('run:hkcu:Discord', 'Discord', 'Discord Inc.', 'C:\\Users\\Maria\\AppData\\Local\\Discord\\Update.exe --processStart Discord.exe', {
        ativo: false, cor: 'amarelo', motivoCor: 'Abre o chat na partida; desligue se não usa todo dia.', tamanhoBytes: 2 * MB }),
      i('run:hkcu:OneDrive', 'Microsoft OneDrive', 'Microsoft Corporation', 'C:\\Users\\Maria\\AppData\\Local\\Microsoft\\OneDrive\\OneDrive.exe /background', {
        cor: 'amarelo', motivoCor: 'Sincroniza arquivos; desligue se não usa o OneDrive.', tamanhoBytes: 45 * MB, rodando: true, ramBytes: 95 * MB }),
      i('run:hklm:SecurityHealth', 'Segurança do Windows', 'Microsoft Corporation', 'C:\\Windows\\System32\\SecurityHealthSystray.exe', {
        escopo: 'todos', cor: 'vermelho', protegido: true, motivoProtegido: 'Ícone do Windows Defender: fica ligado.', rodando: true, ramBytes: 6 * MB }),
      i('run:hklm:RtkAudUService', 'Realtek HD Audio', 'Realtek Semiconductor', 'C:\\Windows\\System32\\RtkAudUService64.exe', {
        escopo: 'todos', cor: 'vermelho', protegido: true, motivoProtegido: 'Controla o som do PC: fica ligado.', rodando: true, ramBytes: 12 * MB }),
      i('tarefa:\\Positivo\\PositivoUpdate', 'PositivoUpdate', 'Positivo Tecnologia', 'C:\\Program Files\\Positivo\\Update.exe /check', {
        origem: 'tarefa', escopo: 'todos', cor: 'verde', motivoCor: 'Procura atualizações da fábrica ao ligar.', avancado: true }),
    ];
  },

  async _executarInicializacao(acao, params) {
    if (!this._inicio) this._inicio = this._inicioInicial();
    await this._dormir(200);
    if (acao === 'listar') {
      const av = params.avancado === true;
      return { itens: this._inicio.filter((x) => av || !x.avancado).map((x) => Object.assign({}, x)) };
    }
    if (acao === 'alternar') {
      const it = this._inicio.find((x) => x.id === params.id);
      if (!it) throw new Error('Item não encontrado: ' + params.id);
      if (it.protegido) throw new Error('Item protegido: ' + it.motivoProtegido);
      if (params.confirmado !== true) throw new Error('É preciso confirmar.');
      if (typeof params.ativar !== 'boolean') throw new Error('ativar deve ser verdadeiro ou falso.');
      if (it.origem === 'tarefa' && params.avancado !== true) throw new Error('Tarefas agendadas exigem o modo avançado.');
      it.ativo = params.ativar;
      return { id: it.id, ativo: it.ativo };
    }
    throw new Error('Ação não disponível na demonstração: inicializacao/' + acao);
  },

  // Demo simula Windows 11: tudo disponível. Só 'sugestoes_inicio' começa aplicado.
  _ajustesWinIniciais() {
    const a = (id, grupo, extra) => Object.assign({
      id, grupo, politica: false, avancado: false, recomendado: false, disponivel: true, motivoIndisponivel: null,
      aplicado: false, temBackup: false, reiniciarExplorer: false,
    }, extra || {});
    return [
      a('sugestoes_inicio', 'anuncios', { recomendado: true, aplicado: true, temBackup: true }),
      a('dicas_windows', 'anuncios', { recomendado: true }),
      a('sugestoes_configuracoes', 'anuncios', { recomendado: true }),
      a('apps_sugeridos', 'anuncios', { recomendado: true }),
      a('avisos_onedrive_explorador', 'anuncios', { recomendado: true }),
      a('id_publicidade', 'privacidade', { recomendado: true }),
      a('experiencias_personalizadas', 'privacidade', { recomendado: true }),
      a('telemetria_minima', 'privacidade', { recomendado: true }),
      a('digitacao_personalizada', 'privacidade', { recomendado: true }),
      a('historico_atividades', 'privacidade', { politica: true, avancado: true }),
      a('feedback_frequencia', 'privacidade', { recomendado: true }),
      a('idioma_sites', 'privacidade', { recomendado: true }),
      a('novidades_windows', 'privacidade', { recomendado: true }),
      a('sugestoes_pesquisa_web', 'privacidade', { politica: true, avancado: true }),
      a('servico_telemetria', 'privacidade', { recomendado: true }),
      a('relatorio_erros', 'privacidade'),
      a('tarefas_telemetria', 'privacidade', { recomendado: true }),
      a('widgets_barra', 'copilot', { recomendado: true }),
      a('copilot_barra', 'copilot', { recomendado: true }),
      a('chat_teams_barra', 'copilot', { recomendado: true }),
      a('destaques_pesquisa', 'copilot', { recomendado: true }),
      a('noticias_barra_win10', 'copilot'),
      a('copilot_desligar', 'copilot', { politica: true, avancado: true }),
      a('extensoes_visiveis', 'explorador', { reiniciarExplorer: true, aplicado: true }), // aplicado sem backup: sem botão Restaurar
      a('abrir_este_computador', 'explorador', { reiniciarExplorer: true }),
      a('recentes_inicio_rapido', 'explorador', { reiniciarExplorer: true }),
      a('efeitos_visuais', 'desempenho', { recomendado: true, reiniciarExplorer: true }),
      a('transparencia', 'desempenho', { recomendado: true }),
    ];
  },

  async _executarAjustesWin(acao, params) {
    if (!this._ajustesWin) this._ajustesWin = this._ajustesWinIniciais();
    await this._dormir(200);
    if (acao === 'listar') {
      const av = params.avancado === true;
      return { ajustes: this._ajustesWin.filter((x) => av || !x.avancado).map((x) => Object.assign({}, x)) };
    }
    if (acao !== 'aplicar' && acao !== 'restaurar') throw new Error('Ação não disponível na demonstração: ajusteswin/' + acao);
    if (params.confirmado !== true) throw new Error('É preciso confirmar.');
    const feitos = [];
    const falhas = [];
    let precisaReiniciar = false;
    for (const id of params.ids || []) {
      const x = this._ajustesWin.find((y) => y.id === id);
      if (!x) { falhas.push({ id, erro: 'ajuste desconhecido' }); continue; }
      if (acao === 'aplicar' && x.avancado && params.avancado !== true) { falhas.push({ id, erro: 'exige o modo avançado' }); continue; }
      if (acao === 'restaurar' && !x.temBackup) { falhas.push({ id, erro: 'sem backup para este ajuste' }); continue; }
      x.aplicado = acao === 'aplicar';
      x.temBackup = acao === 'aplicar';
      if (x.reiniciarExplorer) precisaReiniciar = true;
      feitos.push(id);
    }
    return acao === 'aplicar' ? { aplicados: feitos, falhas, avisos: [], precisaReiniciar } : { restaurados: feitos, falhas, avisos: [], precisaReiniciar };
  },

  // C: HDD do sistema nunca verificado (o Início recomenda verificar); D: SSD verificado há 10 dias.
  _discoInicial() {
    return {
      unidades: [
        { letra: 'C:', rotulo: 'Windows', total: 930 * GB, livre: 412 * GB, tipoDisco: 'hdd', sistema: true, sujo: false, agendada: false, ultimaVerificacao: null, semErros: null, diasSemVerificar: null },
        { letra: 'D:', rotulo: 'Jogos', total: 480 * GB, livre: 200 * GB, tipoDisco: 'ssd', sistema: false, sujo: false, agendada: false, ultimaVerificacao: this._dia(10), semErros: true, diasSemVerificar: 10 },
      ],
      inicioRapido: true,
    };
  },

  async _executarReparo(acao, params) {
    if (!this._reparo) {
      this._reparo = [
        { codigo: '{37B34C3A-D825-40AF-BB33-A4DA7A6E4782}', nome: 'Microsoft Visual C++ 2019 X64 Minimum Runtime', versao: '14.28.29213', editor: 'Microsoft Corporation', localPackage: 'C:\\Windows\\Installer\\1d34c.msi', origens: ['W:\\Data\\Programs\\Win7\\Redist\\VCpp\\AIO\\2019\\x64\\'], reparavel: true, motivo: null },
        { codigo: '{E5281CF4-57AC-41C9-8034-00F8428B8951}', nome: 'Microsoft Visual C++ 2019 X64 Additional Runtime', versao: '14.28.29213', editor: 'Microsoft Corporation', localPackage: 'C:\\Windows\\Installer\\1d359.msi', origens: ['W:\\Data\\Programs\\Win7\\Redist\\VCpp\\AIO\\2019\\x64\\'], reparavel: true, motivo: null },
        { codigo: '{5C7E2016-38FD-4855-A27C-3FDE9207319A}', nome: 'LibreOffice 26.8.0.3', versao: '26.8.0.3', editor: 'The Document Foundation', localPackage: '', origens: [], reparavel: true, motivo: null },
        { codigo: '{BB052C53-34CB-42DE-AF41-66FDFCEEC868}', nome: 'Microsoft Update Health Tools', versao: '5.72.0.0', editor: 'Microsoft Corporation', localPackage: '', origens: ['C:\\Windows\\TEMP\\F8807161\\'], reparavel: false, motivo: 'Componente do Windows Update: o Windows o reinstala sozinho.' },
      ];
    }
    if (acao === 'diagnosticar') { await this._dormir(300); return { produtos: this._reparo.map((p) => Object.assign({}, p)) }; }
    if (acao === 'reparar') {
      if (params.confirmado !== true) throw new Error('É preciso confirmar.');
      await this._dormir(400);
      const reparados = [];
      const falhas = [];
      (params.ids || []).forEach((id) => {
        const i = this._reparo.findIndex((p) => p.codigo === id);
        if (i < 0) falhas.push({ id, erro: 'já não está quebrado (ou não existe): nada a fazer' });
        else if (!this._reparo[i].reparavel) falhas.push({ id, erro: this._reparo[i].motivo });
        else { this._reparo.splice(i, 1); reparados.push(id); }
      });
      return { reparados, falhas, entrada: '20261121-120000-demo' };
    }
    throw new Error('Ação não disponível na demonstração: reparo/' + acao);
  },

  // Demonstração: a imagem começa reparável e fica íntegra depois de reparar.
  async _executarSaude(acao, params, onProgresso) {
    if (acao === 'verificar') {
      await this._simular(onProgresso, 'saude', ['Verificando a imagem do Windows…']);
      return this._saudeReparada
        ? { estado: 'ok', detalhe: 'Nenhuma corrupção registrada na imagem do Windows.' }
        : { estado: 'reparavel', detalhe: 'A imagem do Windows tem corrupção que dá para reparar.' };
    }
    if (acao === 'reparar') {
      if (params.confirmado !== true) throw new Error('É preciso confirmar.');
      await this._simular(onProgresso, 'saude', ['Reparando a imagem do Windows…', 'Reparando arquivos do sistema…', 'Lendo o resultado…']);
      this._saudeReparada = true;
      return {
        dism: { codigo: 0, estado: 'ok' },
        sfc: { codigo: 0, estado: 'reparado' },
        precisaReiniciar: true,
        detalhe: 'O DISM terminou sem erro: a imagem do Windows está íntegra. O SFC reparou arquivos do sistema corrompidos. Reinicie o PC para concluir.',
      };
    }
    throw new Error('Ação não disponível na demonstração: saude/' + acao);
  },

  async _executarDisco(acao, params, onProgresso) {
    if (!this._disco) this._disco = this._discoInicial();
    const D = this._disco;
    const copia = () => ({ unidades: D.unidades.map((u) => Object.assign({}, u)), inicioRapido: D.inicioRapido });
    if (acao === 'estado') { await this._dormir(200); return copia(); }
    if (acao === 'reiniciar') {
      if (params.confirmado !== true) throw new Error('É preciso confirmar.');
      await this._dormir(200);
      return { agendado: true };
    }
    const u = D.unidades.find((x) => x.letra === params.letra);
    if (!u) throw new Error('unidade não encontrada: ' + params.letra);
    if (acao === 'verificar') {
      await this._simular(onProgresso, 'disco', ['Verificando ' + u.letra + ' (pode levar alguns minutos)…', 'Lendo o resultado…']);
      u.ultimaVerificacao = new Date().toISOString(); u.semErros = true; u.diasSemVerificar = 0;
      return { letra: u.letra, resultado: 'NoErrorsFound', semErros: true, verificadoEm: u.ultimaVerificacao };
    }
    if (params.confirmado !== true) throw new Error('É preciso confirmar.');
    if (acao === 'corrigir') {
      await this._dormir(300);
      u.sujo = true; u.agendada = true;
      return { letra: u.letra, agendada: true, inicioRapido: D.inicioRapido };
    }
    if (acao === 'otimizar') {
      if (u.sujo) throw new Error('o volume está marcado para verificação; reinicie o PC antes de otimizar');
      if (u.semErros !== true) throw new Error('verifique a unidade antes de otimizar (a verificação precisa terminar sem erros)');
      const operacao = u.tipoDisco === 'ssd' ? 'trim' : 'desfragmentar';
      await this._simular(onProgresso, 'disco', [operacao === 'trim' ? 'Fazendo TRIM em ' + u.letra + '…' : 'Desfragmentando ' + u.letra + '…']);
      return { letra: u.letra, operacao };
    }
    throw new Error('Ação não disponível na demonstração: disco/' + acao);
  },

  _atualizIniciais() {
    const w = (id, titulo, kb, tam, tipo, extra) => Object.assign({ id, titulo, kb, tamanhoBytes: tam, categorias: [], tipo, exigeReinicio: false, excluido: null }, extra || {});
    return {
      windows: [
        w('a1b2c3d4-0001-4000-8000-000000000001', '2026-11 Atualização Cumulativa para Windows 11 Versão 25H2 (KB5048667)', 'KB5048667', 320 * MB, 'seguranca', { exigeReinicio: true }),
        w('a1b2c3d4-0002-4000-8000-000000000002', '2026-11 Atualização Cumulativa do .NET Framework 3.5 e 4.8.1 (KB5048163)', 'KB5048163', 60 * MB, 'qualidade'),
        w('a1b2c3d4-0003-4000-8000-000000000003', '2026-11 Cumulative Update Preview for Windows 11 (KB5050094)', 'KB5050094', 400 * MB, 'qualidade', { exigeReinicio: true, excluido: 'preview' }),
        w('a1b2c3d4-0004-4000-8000-000000000004', 'Windows 11, versão 26H1', null, 4 * GB, 'outro', { exigeReinicio: true, excluido: 'upgrade' }),
      ],
      programas: [
        { id: 'Google.Chrome', nome: 'Google Chrome', versaoAtual: '130.0.6723.117', versaoNova: '131.0.6778.86', origem: 'winget' },
        { id: 'VideoLAN.VLC', nome: 'VLC media player', versaoAtual: '3.0.20', versaoNova: '3.0.21', origem: 'winget' },
        { id: 'Spotify.Spotify', nome: 'Spotify', versaoAtual: '1.2.40', versaoNova: '1.2.50', origem: 'winget' },
      ],
    };
  },

  async _executarAtualizacoes(acao, params, onProgresso) {
    if (!this._atualiz) this._atualiz = this._atualizIniciais();
    const A = this._atualiz;
    if (acao === 'listar') {
      await this._simular(onProgresso, 'atualizacoes', ['Consultando o Windows Update…', 'Consultando o winget…']);
      const av = params.avancado === true;
      return {
        windows: A.windows.filter((w) => av || !w.excluido).map((w) => Object.assign({}, w)),
        windowsErro: null,
        programas: A.programas.map((p) => Object.assign({}, p)),
        winget: { disponivel: true, erro: null },
      };
    }
    if (params.confirmado !== true) throw new Error('É preciso confirmar.');
    const ids = params.ids || [];
    if (acao === 'instalar') {
      const feitos = []; const falhas = []; let precisaReiniciar = false;
      for (const id of ids) {
        const w = A.windows.find((x) => x.id === id);
        if (!w) { falhas.push({ id, erro: 'atualização não está mais disponível' }); continue; }
        if (w.excluido === 'upgrade') { falhas.push({ id, erro: 'atualização de versão do Windows fica fora do NexTune: use Configurações › Windows Update' }); continue; }
        if (w.excluido === 'preview' && params.avancado !== true) { falhas.push({ id, erro: 'atualização Preview só no modo avançado' }); continue; }
        feitos.push(id); if (w.exigeReinicio) precisaReiniciar = true;
      }
      await this._simular(onProgresso, 'atualizacoes', ['Baixando ' + feitos.length + ' atualizações…', 'Instalando…']);
      A.windows = A.windows.filter((w) => !feitos.includes(w.id));
      return { instalados: feitos, falhas, precisaReiniciar };
    }
    if (acao === 'atualizarProgramas') {
      await this._simular(onProgresso, 'atualizacoes', ids.map((id) => 'Atualizando ' + id + '…'));
      const feitos = ids.filter((id) => A.programas.some((p) => p.id === id));
      A.programas = A.programas.filter((p) => !feitos.includes(p.id));
      return { atualizados: feitos, falhas: ids.filter((id) => !feitos.includes(id)).map((id) => ({ id, erro: 'winget terminou com código -1978335189' })) };
    }
    throw new Error('Ação não disponível na demonstração: atualizacoes/' + acao);
  },

  autostart(ligar) { this._autostart = !!ligar; return this._autostart; },

  _modoJogoInicial() {
    const p = (exe, nome, mb, protegido) => Object.assign({ exe, nome, caminho: 'C:\\Program Files\\' + nome + '\\' + exe, ramBytes: mb * MB, protegido: !!protegido, motivoProtegido: null }, protegido ? { motivoProtegido: protegido } : {});
    return {
      estado: { ativo: false },
      processos: [
        p('chrome.exe', 'Google Chrome', 540),
        p('Spotify.exe', 'Spotify', 210),
        p('Discord.exe', 'Discord', 320, 'Chat de voz com os amigos.'),
        p('obs64.exe', 'OBS Studio', 260, 'Gravação/transmissão: fechar perde a live.'),
        p('soffice.exe', 'LibreOffice', 180),
      ],
    };
  },

  async _executarModoJogo(acao, params) {
    if (!this._modoJogo) this._modoJogo = this._modoJogoInicial();
    const M = this._modoJogo;
    await this._dormir(250);
    if (acao === 'estado') return JSON.parse(JSON.stringify(M.estado));
    if (acao === 'processos') return { processos: M.processos.map((x) => Object.assign({}, x)) };
    if (params.confirmado !== true) throw new Error('É preciso confirmar.');
    if (acao === 'ativar') {
      const marcados = M.processos.filter((x) => (params.fechar || []).includes(x.exe));
      const fechados = marcados.filter((x) => !x.protegido).map((x) => ({ exe: x.exe, caminho: x.caminho }));
      const naoFechados = marcados.filter((x) => x.protegido).map((x) => ({ exe: x.exe, motivo: x.motivoProtegido }));
      const servicosPausados = params.preset === 'suave' ? [] : (params.preset === 'a_fundo' ? ['wuauserv', 'BITS', 'WSearch', 'SysMain'] : ['wuauserv', 'BITS']);
      M.estado = { ativo: true, preset: params.preset, desde: new Date().toISOString(), automatico: false, jogo: params.jogo || null, fechados, naoFechados, servicosPausados, planoAnterior: '381b4222-f694-41f0-9685-ff5bb260df2e', notificacoesAnterior: null, windowsInstalando: false };
      M.processos = M.processos.filter((x) => !fechados.some((f) => f.exe === x.exe));
      return { ativo: true, preset: params.preset, fechados, naoFechados, servicosPausados, windowsInstalando: false, avisos: [] };
    }
    if (acao === 'desativar') {
      const r = { ativo: false, reabertos: (M.estado.fechados || []).map((f) => f.exe), religados: M.estado.servicosPausados || [], falhas: [] };
      this._modoJogo = null;
      return r;
    }
    throw new Error('Ação não disponível na demonstração: modojogo/' + acao);
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
    if (acao === 'restosAntigos') {
      if (!this._antigos) this._antigos = this._restosAntigosIniciais();
      await this._simular(onProgresso, 'programas', ['Lendo programas instalados…', 'Procurando restos em C:\\Program Files…', 'Procurando restos em AppData…', 'Procurando atalhos quebrados no Menu Iniciar…']);
      return { itens: this._antigos.map((x) => Object.assign({}, x)) };
    }
    if (acao === 'limparRestos') {
      if (params.confirmado !== true) throw new Error('É preciso confirmar.');
      const itens = params.itens || [];
      if (!itens.length) throw new Error('Nenhum item para mover.');
      if (!this._quarentena) this._quarentena = this._quarentenaInicial();
      await this._simular(onProgresso, 'programas', itens.map((i) => 'Movendo ' + i.caminho + '…'));
      // Restos antigos movidos somem da próxima busca e entram na quarentena com o tamanho de verdade.
      let tamAntigos = 0;
      if (this._antigos) {
        const movidos = new Set(itens.map((i) => i.caminho));
        this._antigos.forEach((x) => { if (movidos.has(x.caminho)) tamAntigos += x.bytes; });
        this._antigos = this._antigos.filter((x) => !movidos.has(x.caminho));
      }
      this._seq++;
      const id = '20251120-1530' + String(this._seq).padStart(2, '0') + '-' + (0x1a00 + this._seq).toString(16);
      const agora = new Date();
      this._quarentena.unshift({
        id, data: agora.toISOString(), modulo: 'programas', descricao: 'Restos de ' + (params.nome || 'programa'),
        itens: itens.length, tamanhoBytes: tamAntigos || itens.length * 18 * MB,
      });
      return { quarentenaId: id, movidos: itens.length, falhas: [] };
    }
    throw new Error('Ação não disponível na demonstração: programas/' + acao);
  },

  // Pastas e atalhos de programas já desinstalados; Lenovo e Avast continuam instalados (não seguros).
  _restosAntigosIniciais() {
    const u = 'C:\\Users\\Maria';
    const menu = 'C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs';
    const r = (tipo, caminho, nome, bytes, seguro, motivo) => ({ tipo, caminho, nome, bytes: Math.round(bytes), seguro, motivo });
    return [
      r('pasta', 'C:\\Program Files (x86)\\Nero', 'Nero', 412 * MB, true, 'Nenhum programa instalado tem este nome ou editor, e a pasta não muda há mais de 30 dias.'),
      r('pasta', 'C:\\ProgramData\\McAfee', 'McAfee', 186 * MB, true, 'Nenhum programa instalado tem este nome ou editor, e a pasta não muda há mais de 30 dias.'),
      r('pasta', u + '\\AppData\\Roaming\\Baidu', 'Baidu', 23 * MB, true, 'Nenhum programa instalado tem este nome ou editor, e a pasta não muda há mais de 30 dias.'),
      r('pasta', u + '\\AppData\\Local\\Lenovo', 'Lenovo', 64 * MB, false, 'Nome parecido com o editor de um programa instalado: Lenovo Vantage (Lenovo)'),
      r('pasta', 'C:\\ProgramData\\Avast Software\\Browser', 'Browser', 9 * MB, false, 'Fica na pasta de Avast Software, que ainda tem programa instalado: pode ser um componente compartilhado.'),
      r('atalho', menu + '\\WinRAR\\WinRAR.lnk', 'WinRAR', 1450, true, 'Atalho cujo destino não existe mais: C:\\Program Files\\WinRAR\\WinRAR.exe'),
      r('atalho', u + '\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Steam.lnk', 'Steam', 2100, false, 'O destino fica num disco que não está conectado agora (E:): o atalho pode voltar a funcionar.'),
    ];
  },

  // Árvore da unidade C: para o analisador de espaço. n = nome, b = bytes (só nas folhas sem filhos), k = filhos,
  // f = arquivos [[nome, bytes]], a = sem acesso, l = link, p = parcial. Pasta sem filhos e com b > 0 ganha filhos
  // genéricos na hora, para dar para descer em qualquer pasta.
  _arvoreEspaco() {
    const p = (n, b, extra) => Object.assign({ n, b }, extra || {});
    const k = (n, filhos, extra) => Object.assign({ n, k: filhos }, extra || {});
    return k('C:', [
      k('Users', [
        k('Maria', [
          k('Videos', [p('Viagem praia 2025', 22 * GB), p('Aniversário', 9 * GB)], { f: [['Casamento da Ana.mp4', 14.2 * GB], ['Formatura.mov', 8.4 * GB], ['Tela gravada.mp4', 3.1 * GB]] }),
          k('AppData', [
            k('Local', [p('Google', 6.8 * GB), p('Temp', 4.2 * GB), p('Spotify', 3.4 * GB), p('Microsoft', 9.6 * GB, { p: true }), p('Packages', 5.1 * GB), p('Discord', 0.9 * GB)]),
            k('Roaming', [p('Spotify', 1.6 * GB), p('Microsoft', 2.2 * GB), p('discord', 0.6 * GB), p('Zoom', 0.4 * GB)]),
            p('LocalLow', 1.1 * GB),
          ]),
          k('Downloads', [p('Instaladores', 6.2 * GB), p('Fotos do WhatsApp', 2.8 * GB)], { f: [['Windows11_25H2.iso', 6.7 * GB], ['GTA_V_Setup.exe', 3.9 * GB], ['backup-celular.zip', 4.4 * GB], ['curso-excel.zip', 1.2 * GB]] }),
          p('Pictures', 18.4 * GB),
          p('Documents', 7.3 * GB),
          p('OneDrive', 2.1 * GB),
          p('Desktop', 1.2 * GB),
          p('Music', 0.8 * GB),
          p('Meus Documentos', 0, { l: true }),
        ], { f: [['NTUSER.DAT', 18 * MB]] }),
        p('Public', 2.3 * GB),
        p('Default', 0.2 * GB),
        p('All Users', 0, { l: true }),
        p('Default User', 0, { l: true }),
      ]),
      k('Windows', [
        p('WinSxS', 11.4 * GB, { p: true }),
        p('System32', 6.9 * GB),
        p('SysWOW64', 1.8 * GB),
        p('Installer', 3.2 * GB),
        p('SoftwareDistribution', 1.4 * GB),
        p('assembly', 0.9 * GB),
        p('servicing', 0, { b: -1, p: true }),
        p('LiveKernelReports', 0, { b: -1, p: true }),
      ], { incompleto: true, f: [['MEMORY.DMP', 1.1 * GB], ['explorer.exe', 5 * MB], ['WindowsUpdate.log', 2 * MB]] }),
      p('Program Files', 38.6 * GB),
      p('Program Files (x86)', 12.4 * GB),
      p('ProgramData', 6.1 * GB, { p: true }),
      p('System Volume Information', 0, { a: true }),
      p('Recovery', 0.9 * GB),
      p('Documents and Settings', 0, { l: true }),
      p('$Recycle.Bin', 0.5 * GB),
    ], { f: [['pagefile.sys', 8 * GB], ['hiberfil.sys', 6.4 * GB], ['swapfile.sys', 256 * MB], ['DumpStack.log.tmp', 12 * 1024]] });
  },

  _noEspaco(raiz) {
    if (!this._espaco) this._espaco = this._arvoreEspaco();
    const partes = raiz.replace(/\\+$/, '').split('\\');
    if (partes[0].toUpperCase() !== 'C:') return null;
    let no = this._espaco;
    for (const nome of partes.slice(1)) {
      const filhos = this._filhosEspaco(no);
      no = filhos.find((x) => x.n.toLowerCase() === nome.toLowerCase());
      if (!no) return null;
    }
    return no;
  },

  _filhosEspaco(no) {
    if (no.k) return no.k;
    if (no.l || no.a || !(no.b > 0)) return [];
    const b = no.b;
    no.k = [
      { n: 'Dados', b: b * 0.46 }, { n: 'Cache', b: b * 0.27 }, { n: 'Atualizações', b: b * 0.12 }, { n: 'Logs', b: b * 0.03 },
    ];
    no.f = [['pacote-' + no.n.toLowerCase().replace(/[^a-z0-9]+/g, '-') + '.dat', b * 0.08], ['instalador.msi', b * 0.04]];
    return no.k;
  },

  _bytesEspaco(no) {
    if (no.l || no.a) return 0;
    if (no.b != null && no.b < 0) return -1;
    // Folha ainda sem filhos: o tamanho é o b dela (os filhos genéricos, quando criados, somam o mesmo b).
    if (!no.k) return Math.round(no.b || 0);
    const arquivos = (no.f || []).reduce((s, f) => s + f[1], 0);
    return Math.round(no.k.reduce((s, x) => s + Math.max(this._bytesEspaco(x), 0), 0) + arquivos);
  },

  _arquivosEspaco(no, caminho, saida) {
    (no.f || []).forEach((f) => saida.push({ caminho: caminho + '\\' + f[0], nome: f[0], bytes: Math.round(f[1]) }));
    if (no.l || no.a || !no.k) return;
    no.k.forEach((x) => this._arquivosEspaco(x, caminho + '\\' + x.n, saida));
  },

  async _executarEspaco(acao, params, onProgresso) {
    if (acao !== 'analisar') throw new Error('Ação não disponível na demonstração: espaco/' + acao);
    const raiz = String(params.raiz || '');
    if (!/^[A-Za-z]:\\/.test(raiz)) throw new Error('raiz deve ser um caminho absoluto de pasta (X:\\...)');
    const no = this._noEspaco(raiz);
    if (!no) throw new Error('a pasta não existe: ' + raiz);
    if (no.l) throw new Error('a pasta é um link ou junção, ou fica dentro de um: recusada');
    if (no.a) throw new Error('sem acesso à pasta ' + raiz);
    const base = raiz.replace(/\\+$/, '');
    const filhos = this._filhosEspaco(no);
    await this._simular(onProgresso, 'espaco', ['Analisando ' + raiz].concat(filhos.slice(0, 5).map((x) => 'Medindo ' + x.n)));
    const pastas = filhos.map((x) => {
      const bytes = x.l ? 0 : (x.a ? -1 : this._bytesEspaco(x));
      return { caminho: base + '\\' + x.n, nome: x.n, bytes, semAcesso: !!x.a, parcial: !!x.p || bytes < 0, link: !!x.l };
    }).sort((a, b) => (b.bytes - a.bytes) || a.nome.localeCompare(b.nome)).slice(0, 20);
    const arquivos = [];
    this._arquivosEspaco(no, base, arquivos);
    arquivos.sort((a, b) => b.bytes - a.bytes);
    const soltos = (no.f || []).reduce((s, f) => s + Math.round(f[1]), 0);
    const total = pastas.reduce((s, x) => s + Math.max(x.bytes, 0), 0) + soltos;
    return { raiz: raiz.length === 3 ? raiz : base, totalBytes: total, incompleto: !!no.incompleto, pastas, arquivos: arquivos.slice(0, 20) };
  },

  // Três dispositivos: a placa de rede resolve no 2º passo, a câmera não resolve, o vídeo é essencial.
  _driversIniciais() {
    return [
      { id: 'PCI\\VEN_10EC&DEV_8168&SUBSYS_86771043&REV_15\\4&2A1B3C4D&0&00E4', nome: 'Realtek PCIe GbE Family Controller', classe: 'Net', codigo: 10,
        explicacao: 'O dispositivo não consegue iniciar. Tente o reparo; se continuar, instale o driver mais novo do site do fabricante.', critico: false, _resolveNo: 'reinstalar' },
      { id: 'USB\\VID_0BDA&PID_58C2&MI_00\\6&1F2E3D4C&0&0000', nome: 'Câmera HD integrada', classe: 'Camera', codigo: 28,
        explicacao: 'O driver deste dispositivo não está instalado. Instale o driver do site do fabricante ou pelo Windows Update.', critico: false, _resolveNo: null },
      { id: 'PCI\\VEN_8086&DEV_3185&SUBSYS_00000000&REV_06\\3&11583659&0&10', nome: 'Intel UHD Graphics 600', classe: 'Display', codigo: 43,
        explicacao: 'O Windows parou o dispositivo porque ele informou problemas. Tente o reparo; se continuar, troque de porta ou atualize o driver.', critico: true, _resolveNo: null },
    ];
  },

  async _executarDrivers(acao, params, onProgresso) {
    if (!this._drivers) this._drivers = this._driversIniciais();
    const publico = (d) => ({ id: d.id, nome: d.nome, classe: d.classe, codigo: d.codigo, explicacao: d.explicacao, critico: d.critico });
    if (acao === 'listar') {
      await this._simular(onProgresso, 'drivers', ['Procurando dispositivos com problema…']);
      return { dispositivos: this._drivers.filter((d) => d.codigo !== 0).map(publico) };
    }
    if (params.confirmado !== true) throw new Error('ação exige confirmação');
    if (acao === 'backup') {
      await this._simular(onProgresso, 'drivers', ['Copiando os drivers instalados (pode levar alguns minutos)…', 'Contando os drivers copiados…']);
      const d = new Date();
      const dois = (n) => String(n).padStart(2, '0');
      const pasta = 'C:\\ProgramData\\NexTune\\Drivers\\' + d.getFullYear() + dois(d.getMonth() + 1) + dois(d.getDate()) + '-' + dois(d.getHours()) + dois(d.getMinutes()) + dois(d.getSeconds());
      return { pasta, quantidade: 37, codigo: 0 };
    }
    if (acao === 'reparar') {
      const d = this._drivers.find((x) => x.id === params.id && x.codigo !== 0);
      if (!d) throw new Error('dispositivo não encontrado ou já sem problema');
      const passos = [];
      for (const passo of ['reiniciar', 'reinstalar', 'procurar']) {
        if (d.critico && passo !== 'procurar') continue;
        const msg = { reiniciar: 'Desligando e ligando ', reinstalar: 'Reinstalando o driver de ', procurar: 'Procurando alterações de hardware' }[passo];
        await this._simular(onProgresso, 'drivers', [passo === 'procurar' ? msg : msg + d.nome]);
        if (d._resolveNo === passo) d.codigo = 0;
        passos.push({ passo, ok: true, codigoDepois: d.codigo });
        if (d.codigo === 0) break;
      }
      return { resolvido: d.codigo === 0, passos, precisaReiniciar: false };
    }
    throw new Error('Ação não disponível na demonstração: drivers/' + acao);
  },

  // Windows 11 com Wi-Fi (DNS do roteador, IPv4 e IPv6) e cabo com um DNS digitado à mão (OpenDNS): o
  // provedor atual é "outro"; Automático sem backup mantém o do cabo (mantido:true).
  _redeInicial() {
    return {
      adaptadores: [
        { indice: 12, nome: 'Wi-Fi', descricao: 'Intel(R) Wi-Fi 6 AX201 160MHz', ipv4: ['192.168.0.1'], ipv6: ['2804:14d:1:0:181:213:132:2'], ipv4Automatico: true, ipv6Automatico: true },
        { indice: 7, nome: 'Ethernet', descricao: 'Realtek PCIe GbE Family Controller', ipv4: ['208.67.222.222', '208.67.220.220'], ipv6: [], ipv4Automatico: false, ipv6Automatico: true },
      ],
      backup: null,
      build: 26200,
      bloqueadoPorPolitica: false,
    };
  },

  async _executarRede(acao, params, onProgresso) {
    if (!this._rede) this._rede = this._redeInicial();
    const R = this._rede;
    const servidores = { cloudflare: ['1.1.1.1', '1.0.0.1'], google: ['8.8.8.8', '8.8.4.4'], quad9: ['9.9.9.9', '149.112.112.112'] };
    const servidores6 = { cloudflare: ['2606:4700:4700::1111', '2606:4700:4700::1001'], google: ['2001:4860:4860::8888', '2001:4860:4860::8844'], quad9: ['2620:fe::fe', '2620:fe::9'] };
    const deProvedor = (a) => !a.ipv4Automatico && Object.values(servidores).some((ips) => ips.join(',') === a.ipv4.join(','));
    if (acao === 'estado') {
      await this._simular(onProgresso, 'rede', ['Lendo os adaptadores de rede…']);
      let provedor = 'outro';
      if (R.adaptadores.every((a) => a.ipv4Automatico && a.ipv6Automatico)) provedor = 'automatico';
      for (const [nome, ips] of Object.entries(servidores)) {
        if (R.adaptadores.every((a) => !a.ipv4Automatico && a.ipv4.join(',') === ips.join(','))) provedor = nome;
      }
      return {
        adaptadores: R.adaptadores.map((a) => ({ indice: a.indice, nome: a.nome, descricao: a.descricao, dns: a.ipv4.concat(a.ipv6), automatico: a.ipv4Automatico && a.ipv6Automatico })),
        provedor, dohDisponivel: R.build >= 22000, bloqueadoPorPolitica: R.bloqueadoPorPolitica, temBackup: !!R.backup,
      };
    }
    if (acao === 'limparDns') {
      await this._simular(onProgresso, 'rede', ['Limpando o cache de DNS…']);
      return { ok: true };
    }
    if (params.confirmado !== true) throw new Error('ação exige confirmação');
    if (acao === 'redefinir') {
      await this._simular(onProgresso, 'rede', ['Redefinindo o Winsock…', 'Redefinindo o TCP/IP…']);
      return { precisaReiniciar: true, detalhe: 'O Winsock e o TCP/IP voltaram ao padrão do Windows. Reinicie o PC para concluir.' };
    }
    if (acao === 'dnsSeguro') {
      const provedor = params.provedor;
      if (!['cloudflare', 'google', 'quad9', 'automatico'].includes(provedor)) throw new Error('provedor de DNS inválido');
      if (provedor !== 'automatico' && R.build < 22000) throw new Error('DNS seguro precisa do Windows 11');
      if (provedor !== 'automatico' && R.bloqueadoPorPolitica) throw new Error('uma política do Windows proíbe o DNS seguro neste PC');
      await this._simular(onProgresso, 'rede', R.adaptadores.map((a) => 'Configurando o DNS de ' + a.nome + '…'));
      const mantidos = new Set();
      if (provedor === 'automatico') {
        const backup = R.backup;
        R.adaptadores.forEach((a) => {
          const b = backup && backup.find((x) => x.indice === a.indice);
          if (b) Object.assign(a, JSON.parse(JSON.stringify(b)));
          else if (backup || deProvedor(a)) Object.assign(a, { ipv4: ['192.168.0.1'], ipv4Automatico: true, ipv6: ['2804:14d:1:0:181:213:132:2'], ipv6Automatico: true });
          else if (!a.ipv4Automatico || !a.ipv6Automatico) mantidos.add(a.indice); // sem backup: DNS digitado à mão fica
        });
        R.backup = null;
      } else {
        // Só antes da primeira troca: trocas seguintes não sobrescrevem o backup.
        if (!R.backup) R.backup = JSON.parse(JSON.stringify(R.adaptadores));
        R.adaptadores.forEach((a) => Object.assign(a, { ipv4: servidores[provedor].slice(), ipv6: servidores6[provedor].slice(), ipv4Automatico: false, ipv6Automatico: false }));
      }
      return { adaptadores: R.adaptadores.map((a) => ({ indice: a.indice, nome: a.nome, ok: true, erro: null, mantido: mantidos.has(a.indice) })), provedor };
    }
    throw new Error('Ação não disponível na demonstração: rede/' + acao);
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
