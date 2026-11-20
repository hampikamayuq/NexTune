pub mod acoes;
pub mod protocolo;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("erro ao executar o aplicativo Tauri");
}
