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

/// Pastas do sistema lidas da API do Windows, nunca das variáveis de ambiente: um processo sem
/// elevação altera `HKCU\Environment`, e este app (elevado) herdaria `windir`/`ProgramFiles` falsos.
#[derive(Debug, Clone)]
pub struct Sistema {
    pub windir: PathBuf,
    pub program_files: PathBuf,
    pub program_files_x86: PathBuf,
    pub program_data: PathBuf,
    pub appdata: PathBuf,
    pub local_appdata: PathBuf,
    pub perfil: PathBuf,
    pub publico: PathBuf,
}

impl Sistema {
    /// `C:` a partir da pasta do Windows.
    pub fn system_drive(&self) -> PathBuf {
        let s = self.windir.to_string_lossy();
        PathBuf::from(s.get(..2).filter(|p| p.ends_with(':')).unwrap_or("C:"))
    }

    /// Variáveis que o host PowerShell recebe no lugar das herdadas (os scripts seguem lendo `$env:`).
    pub fn variaveis(&self) -> Vec<(&'static str, PathBuf)> {
        let temp = self.local_appdata.join("Temp");
        vec![
            ("windir", self.windir.clone()),
            ("SystemRoot", self.windir.clone()),
            ("SystemDrive", self.system_drive()),
            ("ProgramFiles", self.program_files.clone()),
            ("ProgramFiles(x86)", self.program_files_x86.clone()),
            ("ProgramData", self.program_data.clone()),
            ("APPDATA", self.appdata.clone()),
            ("LOCALAPPDATA", self.local_appdata.clone()),
            ("USERPROFILE", self.perfil.clone()),
            ("PUBLIC", self.publico.clone()),
            ("TEMP", temp.clone()),
            ("TMP", temp),
        ]
    }
}

pub fn sistema() -> &'static Sistema {
    static S: OnceLock<Sistema> = OnceLock::new();
    S.get_or_init(ler_sistema)
}

/// Variável de ambiente ou padrão: só como último recurso, quando a API falha (ou fora do Windows).
fn env_ou(nome: &str, padrao: &str) -> PathBuf {
    match std::env::var_os(nome) {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from(padrao),
    }
}

#[cfg(windows)]
fn ler_sistema() -> Sistema {
    use windows_sys::Win32::UI::Shell::{
        FOLDERID_LocalAppData, FOLDERID_Profile, FOLDERID_ProgramData, FOLDERID_ProgramFiles,
        FOLDERID_ProgramFilesX86, FOLDERID_Public, FOLDERID_RoamingAppData,
    };
    let ou_env =
        |id, nome: &str, padrao: &str| pasta_conhecida(id).unwrap_or_else(|| env_ou(nome, padrao));
    Sistema {
        windir: pasta_windows().unwrap_or_else(|| env_ou("windir", r"C:\Windows")),
        program_files: ou_env(&FOLDERID_ProgramFiles, "ProgramFiles", r"C:\Program Files"),
        program_files_x86: ou_env(
            &FOLDERID_ProgramFilesX86,
            "ProgramFiles(x86)",
            r"C:\Program Files (x86)",
        ),
        program_data: ou_env(&FOLDERID_ProgramData, "ProgramData", r"C:\ProgramData"),
        appdata: ou_env(&FOLDERID_RoamingAppData, "APPDATA", ""),
        local_appdata: ou_env(&FOLDERID_LocalAppData, "LOCALAPPDATA", ""),
        perfil: ou_env(&FOLDERID_Profile, "USERPROFILE", ""),
        publico: ou_env(&FOLDERID_Public, "PUBLIC", r"C:\Users\Public"),
    }
}

#[cfg(not(windows))]
fn ler_sistema() -> Sistema {
    Sistema {
        windir: env_ou("windir", r"C:\Windows"),
        program_files: env_ou("ProgramFiles", r"C:\Program Files"),
        program_files_x86: env_ou("ProgramFiles(x86)", r"C:\Program Files (x86)"),
        program_data: env_ou("ProgramData", r"C:\ProgramData"),
        appdata: env_ou("APPDATA", ""),
        local_appdata: env_ou("LOCALAPPDATA", ""),
        perfil: env_ou("USERPROFILE", ""),
        publico: env_ou("PUBLIC", r"C:\Users\Public"),
    }
}

/// `GetWindowsDirectoryW`; `None` se falhar.
#[cfg(windows)]
fn pasta_windows() -> Option<PathBuf> {
    use windows_sys::Win32::System::SystemInformation::GetWindowsDirectoryW;
    let mut buf = [0u16; 260];
    // SAFETY: `buf` é válido e o tamanho passado é o do buffer.
    let n = unsafe { GetWindowsDirectoryW(buf.as_mut_ptr(), buf.len() as u32) } as usize;
    (n > 0 && n < buf.len()).then(|| PathBuf::from(String::from_utf16_lossy(&buf[..n])))
}

/// `SHGetKnownFolderPath` do token deste processo; `None` se falhar.
#[cfg(windows)]
fn pasta_conhecida(id: &windows_sys::core::GUID) -> Option<PathBuf> {
    use windows_sys::Win32::System::Com::CoTaskMemFree;
    use windows_sys::Win32::UI::Shell::SHGetKnownFolderPath;
    let mut p: *mut u16 = std::ptr::null_mut();
    // SAFETY: `id` e `p` são válidos; a string devolvida termina em zero e é liberada com CoTaskMemFree.
    unsafe {
        if SHGetKnownFolderPath(id, 0, std::ptr::null_mut(), &mut p) != 0 || p.is_null() {
            return None;
        }
        let mut n = 0;
        while *p.add(n) != 0 {
            n += 1;
        }
        let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, n));
        CoTaskMemFree(p as _);
        Some(PathBuf::from(s))
    }
}

fn pastas_de_ambiente(scripts: PathBuf, data: PathBuf) -> Pastas {
    let s = sistema();
    Pastas {
        appdata: s.appdata.join("NexTune"),
        programdata: s.program_data.join("NexTune"),
        scripts,
        data,
    }
}

/// Pastas de desenvolvimento/teste (sem Tauri): `scripts/` e `data/` na raiz do repositório.
pub fn pastas_dev() -> Pastas {
    let raiz = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    pastas_de_ambiente(raiz.join("scripts"), raiz.join("data"))
}

/// O Tauri devolve `resource_dir` com o prefixo verbatim (duas barras invertidas e `?`); o PowerShell 5.1
/// falha em Join-Path/Test-Path com ele (argumento "drive" nulo). Remove o prefixo de caminhos com
/// letra de unidade e deixa os demais como estão.
fn sem_prefixo_verbatim(p: PathBuf) -> PathBuf {
    let s = p.to_string_lossy();
    match s.strip_prefix(r"\\?\") {
        Some(resto) if resto.as_bytes().get(1) == Some(&b':') => PathBuf::from(resto),
        _ => p,
    }
}

/// Pastas do aplicativo: empacotado usa os recursos do bundle; em desenvolvimento, a raiz do repositório.
pub fn pastas(app: &tauri::AppHandle) -> Pastas {
    if cfg!(debug_assertions) {
        return pastas_dev();
    }
    match app.path().resource_dir() {
        Ok(r) => {
            let r = sem_prefixo_verbatim(r);
            pastas_de_ambiente(r.join("scripts"), r.join("data"))
        }
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
            outro => {
                // Como GetFullPath: o Windows ignora pontos e espaços no fim de cada segmento.
                let t = outro.trim_end_matches(['.', ' ']);
                if !t.is_empty() {
                    partes.push(t);
                }
            }
        }
    }
    partes.join("\\")
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

    let s = sistema();
    let windir = &s.windir;
    let base = s.program_data.join("NexTune");
    for pre in [windir, &base] {
        let x = normalizar(&pre.to_string_lossy());
        if n == x || n.starts_with(&format!("{x}\\")) {
            return true;
        }
    }

    let (pf, pf86) = (&s.program_files, &s.program_files_x86);
    let menu = "Microsoft\\Windows\\Start Menu\\Programs";
    let exatos: Vec<PathBuf> = vec![
        s.system_drive(),
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
        s.program_data.clone(),
        s.program_data.join("Microsoft"),
        s.program_data.join(menu),
        s.appdata.clone(),
        s.appdata.join("Microsoft"),
        s.appdata.join(menu),
        s.local_appdata.clone(),
        s.local_appdata.join("Programs"),
        s.local_appdata.join("Microsoft"),
        s.perfil.clone(),
        s.perfil.join("Documents"),
        s.perfil.join("Desktop"),
    ];
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
    fn pontos_e_espacos_no_fim_do_segmento() {
        assert!(caminho_protegido(Path::new("C:\\Windows.\\System32")));
        assert!(caminho_protegido(Path::new("C:\\Windows \\System32")));
        assert!(!caminho_protegido(Path::new(
            "C:\\Program Files\\Qualquer."
        )));
    }

    #[test]
    fn remove_prefixo_verbatim_so_com_letra_de_unidade() {
        assert_eq!(
            sem_prefixo_verbatim(PathBuf::from(r"\\?\C:\Program Files\NexTune")),
            PathBuf::from(r"C:\Program Files\NexTune")
        );
        assert_eq!(
            sem_prefixo_verbatim(PathBuf::from(r"C:\x")),
            PathBuf::from(r"C:\x")
        );
        assert_eq!(
            sem_prefixo_verbatim(PathBuf::from(r"\\?\UNC\srv\p")),
            PathBuf::from(r"\\?\UNC\srv\p")
        );
    }

    #[test]
    fn sistema_devolve_caminhos_absolutos() {
        let s = sistema();
        let v = s.variaveis();
        assert_eq!(v.len(), 12);
        for (k, p) in &v {
            assert!(p.is_absolute(), "{k}: {}", p.display());
        }
        assert!(
            s.windir.to_string_lossy().to_lowercase().ends_with("windows"),
            "{}",
            s.windir.display()
        );
        assert_eq!(s.system_drive().to_string_lossy().len(), 2);
    }

    #[test]
    fn pastas_dev_aponta_para_o_repositorio() {
        let p = pastas_dev();
        assert!(p.scripts.join("host.ps1").exists());
    }
}
