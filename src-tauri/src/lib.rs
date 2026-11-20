pub mod acoes;
pub mod ajustes;
pub mod caminhos;
pub mod comandos;
pub mod host;
pub mod perfil;
pub mod protocolo;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let demo = std::env::args().any(|a| a == "--demo") || !cfg!(windows);
    let app = tauri::Builder::default()
        .setup(move |app| {
            let pastas = caminhos::pastas(app.handle());
            let versao = app.package_info().version.to_string();
            app.manage(comandos::Estado::novo(pastas, demo, versao));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            comandos::executar,
            comandos::cancelar,
            comandos::ajustes_ler,
            comandos::ajustes_gravar,
            comandos::dados,
            comandos::info,
            comandos::ponto_sessao,
        ])
        .build(tauri::generate_context!())
        .expect("erro ao construir o aplicativo Tauri");

    app.run(|app, evento| {
        if let tauri::RunEvent::Exit = evento
            && let Some(estado) = app.try_state::<comandos::Estado>()
        {
            tauri::async_runtime::block_on(async {
                let host = estado.host.lock().await.clone();
                host.encerrar().await;
            });
        }
    });
}
