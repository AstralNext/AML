use std::ffi::OsString;
use std::path::PathBuf;
use std::process::{exit, Command};
use std::{env, fs};

fn main() {
    println!("cargo::rerun-if-changed=java/gradle");
    println!("cargo::rerun-if-changed=java/src");
    println!("cargo::rerun-if-changed=java/build.gradle.kts");
    println!("cargo::rerun-if-changed=java/settings.gradle.kts");
    println!("cargo::rerun-if-changed=java/gradle.properties");

    build_java_jars();
}

fn build_java_jars() {
    let out_dir = dunce::canonicalize(PathBuf::from(env::var_os("OUT_DIR").unwrap())).unwrap();

    let jars_dir = out_dir.join("java").join("libs");
    println!("cargo::rustc-env=JAVA_JARS_DIR={}", jars_dir.display());

    let gradle_path = fs::canonicalize(
        #[cfg(target_os = "windows")]
        "java\\gradlew.bat",
        #[cfg(not(target_os = "windows"))]
        "java/gradlew",
    )
    .unwrap();

    let mut build_dir_str = OsString::from("-Dorg.gradle.project.buildDir=");
    build_dir_str.push(out_dir.join("java"));

    let mut cmd = Command::new(&gradle_path);
    cmd.arg(build_dir_str)
        .arg("build")
        .arg("--no-daemon")
        .arg("--console=rich")
        .current_dir(dunce::canonicalize("java").unwrap());

    // Gradle 启动需要 java。若环境未设 JAVA_HOME（常见于非 login shell
    // 或 IDE 集成终端未读 ~/.zshrc），从常见位置兜底找一个 JDK。
    if env::var_os("JAVA_HOME").is_none() {
        if let Some(home) = locate_java_home() {
            cmd.env("JAVA_HOME", &home);
            // 同时把 bin 注入 PATH，确保 gradlew 能直接调到 java。
            if let Some(path) = env::var_os("PATH") {
                let mut new_path = OsString::from(format!("{}/bin:", home.display()));
                new_path.push(path);
                cmd.env("PATH", new_path);
            }
        }
    }

    let exit_status = cmd
        .status()
        .expect("Failed to wait on Gradle build");

    if !exit_status.success() {
        println!("cargo::error=Gradle build failed with {exit_status}");
        exit(exit_status.code().unwrap_or(1));
    }
}

/// 环境没有 JAVA_HOME 时，从常见位置查找一个 JDK 的 Contents/Home。
fn locate_java_home() -> Option<PathBuf> {
    let home = env::var_os("HOME")?;
    let home = PathBuf::from(home);

    let mut candidates: Vec<PathBuf> = Vec::new();

    // 用户解压式安装：~/development/jdk-*  (Temurin 等)
    if let Ok(entries) = fs::read_dir(home.join("development")) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with("jdk-") || name_str.starts_with("jdk") {
                candidates.push(entry.path());
            }
        }
    }

    // macOS 标准安装位置：/Library/Java/JavaVirtualMachines/*/Contents/Home
    let jvm_root = PathBuf::from("/Library/Java/JavaVirtualMachines");
    if let Ok(entries) = fs::read_dir(&jvm_root) {
        for entry in entries.flatten() {
            candidates.push(entry.path());
        }
    }

    // 取第一个存在 Contents/Home/bin/java 的候选。
    for c in candidates {
        // macOS bundle 结构
        let mac_home = c.join("Contents").join("Home");
        if mac_home.join("bin").join("java").exists() {
            return Some(mac_home);
        }
        // 非 mac 扁平结构
        if c.join("bin").join("java").exists() {
            return Some(c);
        }
    }
    None
}
