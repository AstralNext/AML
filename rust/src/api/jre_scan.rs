use std::collections::HashSet;
use std::env;
use std::path::{Path, PathBuf};

use futures::stream::{self, StreamExt};

use super::java_download::{check_jre_impl, JavaRuntimeVersion};

const JAVA_BIN: &str = if cfg!(target_os = "windows") {
    "java.exe"
} else {
    "java"
};

pub async fn find_filtered_jres(
    java_version: i32,
    app_data_dir: Option<String>,
) -> Vec<JavaRuntimeVersion> {
    let paths = collect_jre_candidate_paths(app_data_dir).await;
    let mut found = check_java_at_paths(paths).await;
    found.sort_by(|a, b| a.path.cmp(&b.path));
    found
        .into_iter()
        .filter(|jre| jre.major_version == java_version)
        .collect()
}

async fn collect_jre_candidate_paths(app_data_dir: Option<String>) -> HashSet<PathBuf> {
    let mut paths = HashSet::new();

    if let Ok(path_var) = env::var("PATH") {
        for entry in env::split_paths(&path_var) {
            paths.insert(entry);
        }
    }

    if let Ok(java_home) = env::var("JAVA_HOME") {
        let home = PathBuf::from(java_home);
        paths.insert(home.join("bin"));
        paths.insert(home);
    }

    if let Some(app_data_dir) = app_data_dir {
        paths.extend(collect_autoinstalled_jre_paths(&app_data_dir));
    }

    paths.extend(common_installation_paths());

    #[cfg(target_os = "windows")]
    {
        paths.extend(windows_registry_paths());
    }

    paths
}

fn collect_autoinstalled_jre_paths(app_data_dir: &str) -> HashSet<PathBuf> {
    let mut paths = HashSet::new();
    let base_path = Path::new(app_data_dir).join("java");

    let Ok(entries) = std::fs::read_dir(&base_path) else {
        return paths;
    };

    for entry in entries.flatten() {
        let bin_dir = entry.path().join("bin");
        let java_exe = bin_dir.join(JAVA_BIN);
        if java_exe.exists() {
            paths.insert(java_exe);
        } else if bin_dir.is_dir() {
            paths.insert(bin_dir);
        }
    }

    paths
}

fn common_installation_paths() -> HashSet<PathBuf> {
    let mut paths = HashSet::new();

    #[cfg(target_os = "windows")]
    {
        let roots = [
            r"C:\Program Files\Java",
            r"C:\Program Files (x86)\Java",
            r"C:\Program Files\Eclipse Adoptium",
            r"C:\Program Files (x86)\Eclipse Adoptium",
            r"C:\Program Files\Microsoft",
            r"C:\Program Files\Zulu",
        ];

        for root in roots {
            let Ok(entries) = std::fs::read_dir(root) else {
                continue;
            };
            for entry in entries.flatten() {
                let install_dir = entry.path();
                paths.insert(install_dir.join("bin"));
                paths.insert(install_dir);
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        let roots = [
            "/Library/Java/JavaVirtualMachines",
            "/System/Library/Frameworks/JavaVM.framework/Versions/Current/Commands",
        ];
        for root in roots {
            let root_path = PathBuf::from(root);
            if root_path.is_dir() {
                if let Ok(entries) = std::fs::read_dir(root_path) {
                    for entry in entries.flatten() {
                        paths.insert(entry.path().join("Contents").join("Home").join("bin"));
                    }
                }
            } else {
                paths.insert(root_path);
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        let roots = ["/usr", "/usr/java", "/usr/lib/jvm", "/usr/lib64/jvm"];
        for root in roots {
            let root_path = PathBuf::from(root);
            paths.insert(root_path.join("bin"));
            paths.insert(root_path.join("jre").join("bin"));
            if let Ok(entries) = std::fs::read_dir(&root_path) {
                for entry in entries.flatten() {
                    let install_dir = entry.path();
                    paths.insert(install_dir.join("bin"));
                    paths.insert(install_dir.join("jre").join("bin"));
                }
            }
        }
    }

    paths
}

#[cfg(target_os = "windows")]
fn windows_registry_paths() -> HashSet<PathBuf> {
    use winreg::enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_32KEY, KEY_WOW64_64KEY};
    use winreg::RegKey;

    let mut paths = HashSet::new();
    let key_paths = [
        r"SOFTWARE\JavaSoft\Java Runtime Environment",
        r"SOFTWARE\JavaSoft\Java Development Kit",
        r"SOFTWARE\JavaSoft\JRE",
        r"SOFTWARE\JavaSoft\JDK",
        r"SOFTWARE\Eclipse Adoptium\JRE",
        r"SOFTWARE\Eclipse Adoptium\JDK",
        r"SOFTWARE\Eclipse Foundation\JDK",
        r"SOFTWARE\Microsoft\JDK",
    ];

    for key_path in key_paths {
        for flags in [KEY_READ | KEY_WOW64_32KEY, KEY_READ | KEY_WOW64_64KEY] {
            if let Ok(key) =
                RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(key_path, flags)
            {
                paths.extend(registry_key_paths(&key));
            }
        }
    }

    paths
}

#[cfg(target_os = "windows")]
fn registry_key_paths(key: &winreg::RegKey) -> HashSet<PathBuf> {
    let mut paths = HashSet::new();
    let value_names = ["JavaHome", "InstallationPath"];

    for subkey_name in key.enum_keys().flatten() {
        if let Ok(subkey) = key.open_subkey(&subkey_name) {
            for value_name in value_names {
                if let Ok(path) = subkey.get_value::<String, _>(value_name) {
                    let home = PathBuf::from(path);
                    paths.insert(home.join("bin"));
                    paths.insert(home);
                }
            }
        }
    }

    paths
}

async fn check_java_at_paths(paths: HashSet<PathBuf>) -> Vec<JavaRuntimeVersion> {
    stream::iter(paths.into_iter())
        .map(|path| tokio::spawn(async move { check_java_at_path(&path).await }))
        .buffer_unordered(32)
        .filter_map(|result| async move { result.ok().flatten() })
        .collect()
        .await
}

async fn check_java_at_path(path: &Path) -> Option<JavaRuntimeVersion> {
    let java_path = resolve_java_executable(path)?;
    check_jre_impl(&java_path.to_string_lossy()).await.ok()
}

fn resolve_java_executable(path: &Path) -> Option<PathBuf> {
    if path.is_file() {
        return Some(path.to_path_buf());
    }

    let file_name = path.file_name().and_then(|name| name.to_str())?;
    if file_name.eq_ignore_ascii_case("java") || file_name.eq_ignore_ascii_case("java.exe") {
        return Some(path.to_path_buf());
    }

    let direct = path.join(JAVA_BIN);
    if direct.exists() {
        return Some(direct);
    }

    let parent_bin = path.parent()?.join(JAVA_BIN);
    if parent_bin.exists() {
        return Some(parent_bin);
    }

    None
}

#[cfg(test)]
mod tests {
    use super::super::java_download::extract_java_version;

    #[test]
    fn extract_java8_major_version() {
        assert_eq!(extract_java_version("1.8.0_291").unwrap(), 8);
    }

    #[test]
    fn extract_java17_major_version() {
        assert_eq!(extract_java_version("17.0.12").unwrap(), 17);
    }
}
