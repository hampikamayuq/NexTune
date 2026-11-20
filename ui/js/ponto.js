'use strict';

// Ponto de restauração antes da primeira ação de escrita da sessão (spec §9.1).
// Devolve false só quando o usuário cancelou o modal; falha ao criar o ponto nunca bloqueia a ação.
// Chamada sequencial: cada api.executar ocupa a interface até terminar.
// Mensagem de falha com ou sem detalhe (o PowerShell pode devolver mensagem vazia).
function pontoFalhou(chave, mensagem) {
  const m = mensagem ? String(mensagem).trim().replace(/[.\s]+$/, '') : '';
  return m ? t('ponto.' + chave, { erro: m }) : t('ponto.' + chave + 'Sem');
}

function eSessaoDiferente(e) {
  const msg = e && e.message ? e.message : String(e);
  return msg === 'sessao_diferente' || msg.endsWith('sessao_diferente');
}

async function garantirPonto() {
  try {
    if (S.ajustes.pontoRestauracao === 'pular') return true;
    if (await api.pontoSessao()) return true;

    const estado = await api.executar('sistema', 'protecaoEstado', {}, null);
    if (!estado.ativa) {
      let escolha = S.ajustes.pontoRestauracao;
      if (escolha === 'perguntar') {
        const r = await perguntar({
          titulo: t('ponto.titulo'),
          corpo: [
            h('p', { text: t('ponto.texto') }),
            h('p', { text: t('ponto.ligarExplica') }),
            h('p', { text: t('ponto.semExplica') }),
            h('p', { class: 'suave pequeno', text: t('ponto.lembrete') }),
          ],
          ok: t('ponto.ligar'),
          extra: t('ponto.semPonto'),
        });
        if (!r) return false;
        escolha = r === 'extra' ? 'pular' : 'ligar';
        try { S.ajustes = await api.ajustes.gravar({ pontoRestauracao: escolha }); } catch (e) { mostrarErro(e); }
      }
      if (escolha === 'pular') return true;
      try {
        const lig = await api.executar('sistema', 'ligarProtecao', {}, null);
        if (!lig.ligada) { toast(pontoFalhou('ligarFalhou', lig.mensagem), 'aviso'); return true; }
      } catch (e) {
        if (eSessaoDiferente(e)) throw e;
        toast(pontoFalhou('ligarFalhou', e && e.message ? e.message : String(e)), 'aviso');
        return true;
      }
    }

    const r = await api.executar('sistema', 'criarPonto', {}, null);
    if (r.criado) toast(t('ponto.criado'), 'ok');
    else toast(pontoFalhou('criarFalhou', r.mensagem), 'aviso');
    return true;
  } catch (e) {
    mostrarErroEscrita(e);
    // Sessão bloqueada: o chamador já não deve seguir (e não repete o mesmo toast).
    return S.sessaoOk !== false;
  }
}
