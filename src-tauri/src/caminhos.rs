use regex::Regex;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tauri::Manager;

/// Pastas usadas pelo aplicativo.
#[derive(Debug, Clone)]
pub struct Pastas {
    pub appdata: PathBuf,
    pub programdata: PathBuf,
    pub scripts: PathBuf,
    pub data: PathBuf,
}

fn env_pasta(nome: &str) -> PathBuf {
    std::env::var_os(nome)
        .map(PathBuf::from)
        .unwrap_or_default()
}

fn pastas_de_ambiente(scripts: PathBuf, data: PathBuf) -> Pastas {
    Pastas {
        appdata: env_pasta("APPDATA").join("Otimizador"),
        programdata: env_pasta("ProgramData").join("Otimizador"),
        scripts,
        data,
    }
}

/// Pastas de desenvolvimento/teste (sem Tauri): `scripts/` e `data/` na raiz do repositório.
pub fn pastas_dev() -> Pastas {
    let raiz = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    pastas_de_ambiente(raiz.join("scripts"), raiz.join("data"))
}

/// Pastas do aplicativo: empacotado usa os recursos do bundle; em desenvolvimento, a raiz do repositório.
pub fn pastas(app: &tauri::AppHandle) -> Pastas {
    if cfg!(debug_assertions) {
        return pastas_dev();
    }
    match app.path().resource_dir() {
        Ok(r) => pastas_de_ambiente(r.join("scripts"), r.join("data")),
        Err(_) => pastas_dev(),
    }
}

fn segmentos_protegidos() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"\\(windows defender|windows nt|windowsapps|windows kits|dotnet|microsoft\.net|common files|edgewebview|edgecore|edgeupdate|microsoft\\edge)(\\|$)",
        )
        .expect("regex valida")
    })
}

fn normalizar(p: &str) -> String {
    p.trim_end_matches('\\').to_lowercase()
}

/// Resolve `.` e `..` lexicalmente (sem tocar no disco).
fn resolver(p: &str) -> String {
    let p = p.replace('/', "\\");
    let mut partes: Vec<&str> = Vec::new();
    for s in p.split('\\') {
        match s {
            "" | "." => {}
            ".." => {
                if partes.len() > 1 {
                    partes.pop();
                }
            }
            outro => partes.push(outro),
        }
    }
    partes.join("\\")
}

fn env_ou(nome: &str, padrao: &str) -> PathBuf {
    match std::env::var_os(nome) {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from(padrao),
    }
}

fn env_opt(nome: &str) -> Option<PathBuf> {
    std::env::var_os(nome)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// Espelha `Test-ProtectedPath` de `scripts/common.ps1` (defesa em profundidade, spec 9.3).
/// A expansão de nomes curtos 8.3 é feita apenas no lado PowerShell; aqui a comparação é
/// lexical (minúsculas, sem `\` final, `.`/`..` resolvidos). Caminho vazio ou relativo é protegido.
pub fn caminho_protegido(p: &Path) -> bool {
    let bruto = p.to_string_lossy();
    if bruto.trim().is_empty() {
        return true;
    }
    let b = bruto.as_bytes();
    let absoluto =
        b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && matches!(b[2], b'\\' | b'/');
    if !absoluto {
        return true;
    }
    let n = normalizar(&resolver(&bruto));
    if n.len() <= 3 {
        return true; // raiz de unidade
    }

    let windir = env_ou("windir", "C:\\Windows");
    let base = env_opt("ProgramData")
        .map(|d| d.join("Otimizador"))
        .unwrap_or_default();
    for pre in [&windir, &base] {
        let s = pre.to_string_lossy();
        if s.is_empty() {
            continue;
        }
        let x = normalizar(&s);
        if n == x || n.starts_with(&format!("{x}\\")) {
            return true;
        }
    }

    let pf = env_ou("ProgramFiles", "C:\\Program Files");
    let pf86 = env_ou("ProgramFiles(x86)", "C:\\Program Files (x86)");

    let mut exatos: Vec<PathBuf> = vec![
        env_ou("SystemDrive", "C:"),
        windir.clone(),
        windir.join("System32"),
        windir.join("SysWOW64"),
        pf.clone(),
        pf86.clone(),
        pf.join("Common Files"),
        pf86.join("Common Files"),
        pf.join("WindowsApps"),
        pf.join("Microsoft"),
        pf86.join("Microsoft"),
        base,
    ];
    let menu = "Microsoft\\Windows\\Start Menu\\Programs";
    if let Some(d) = env_opt("ProgramData") {
        exatos.extend([d.clone(), d.join("Microsoft"), d.join(menu)]);
    }
    if let Some(d) = env_opt("APPDATA") {
        exatos.extend([d.clone(), d.join("Microsoft"), d.join(menu)]);
    }
    if let Some(d) = env_opt("LOCALAPPDATA") {
        exatos.extend([d.clone(), d.join("Programs"), d.join("Microsoft")]);
    }
    if let Some(d) = env_opt("USERPROFILE") {
        exatos.extend([d.clone(), d.join("Documents"), d.join("Desktop")]);
    }
    for e in exatos {
        let s = e.to_string_lossy();
        if s.is_empty() {
            continue;
        }
        if n == normalizar(&resolver(&s)) {
            return true;
        }
    }

    segmentos_protegidos().is_match(&n)
}

#[cfg(test)]
mod testes {
    use super::*;
    use std::path::Path;

    #[test]
    fn protegidos() {
        assert!(caminho_protegido(Path::new("C:\\Windows\\")));
        assert!(caminho_protegido(Path::new("c:\\WINDOWS\\System32")));
        assert!(caminho_protegido(Path::new(
            "C:\\Program Files\\Microsoft\\EdgeWebView"
        )));
    }

    #[test]
    fn nao_protegido() {
        assert!(!caminho_protegido(Path::new("C:\\Program Files\\Qualquer")));
    }

    #[test]
    fn raiz_relativo_e_dotdot_sao_protegidos() {
        assert!(caminho_protegido(Path::new("C:\\")));
        assert!(caminho_protegido(Path::new("")));
        assert!(caminho_protegido(Path::new("relativo\\x")));
        assert!(caminho_protegido(Path::new("C:\\Temp\\..\\Windows")));
    }

    #[test]
    fn pastas_dev_aponta_para_o_repositorio() {
        let p = pastas_dev();
        assert!(p.scripts.join("host.ps1").exists());
    }
}
