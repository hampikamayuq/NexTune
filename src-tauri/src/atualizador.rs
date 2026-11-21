//! Atualizador do NexTune (`tauri-plugin-updater`, assinatura minisign).
//!
//! Contrato com a UI:
//! - `atualizacao_verificar() -> {versao, notas} | null`: `null` sem atualização, no modo
//!   demonstração ou sem `latest.json` publicado (`Error::ReleaseNotFound`, até o Plano 6);
//!   outro erro (rede fora do ar, JSON inválido) volta como `Err` e a UI mostra o aviso de falha.
//! - `atualizacao_instalar()`: baixa, confere a assinatura com a chave pública de
//!   `tauri.conf.json`, instala e reinicia o programa. Erro em português se não houver
//!   atualização; recusa no modo demonstração.

use crate::comandos::Estado;
use serde::Serialize;
use tauri::{AppHandle, State};
use tauri_plugin_updater::UpdaterExt;

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Atualizacao {
    pub versao: String,
    pub notas: Option<String>,
}

#[tauri::command]
pub async fn atualizacao_verificar(
    app: AppHandle,
    estado: State<'_, Estado>,
) -> Result<Option<Atualizacao>, String> {
    if estado.demo {
        return Ok(None);
    }
    match app.updater().map_err(|e| e.to_string())?.check().await {
        Ok(Some(u)) => Ok(Some(Atualizacao {
            versao: u.version.clone(),
            notas: u.body.clone(),
        })),
        // Sem `latest.json` publicado (404 em todos os endpoints) não é erro para o usuário; rede
        // fora do ar e o resto vão para a UI, que mostra `opcoes.atualizacaoErro`.
        Ok(None) | Err(tauri_plugin_updater::Error::ReleaseNotFound) => Ok(None),
        Err(e) => {
            eprintln!("atualizador: {e}");
            Err(e.to_string())
        }
    }
}

#[tauri::command]
pub async fn atualizacao_instalar(
    app: AppHandle,
    estado: State<'_, Estado>,
) -> Result<(), String> {
    if estado.demo {
        return Err("demo".into());
    }
    let Some(u) = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?
    else {
        return Err("nenhuma atualização disponível".into());
    };
    u.download_and_install(|_chunk, _total| {}, || {})
        .await
        .map_err(|e| e.to_string())?;
    app.restart()
}
