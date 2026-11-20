fn main() {
    let attrs = tauri_build::WindowsAttributes::new().app_manifest(include_str!("manifest.xml"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(attrs)).expect("build");
}
