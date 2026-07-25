//! Create desktop shortcuts that launch AML with an `aml://` deep-link argument.

use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use url::Url;

use crate::state::{db, resource_dir, try_state};

use super::{dirs, download, icons, server_ping, worlds};

pub const SHORTCUT_EXTENSION: &str = if cfg!(target_os = "windows") {
    "lnk"
} else if cfg!(target_os = "linux") {
    "desktop"
} else {
    "app"
};

/// Build `aml://launch/instance/{id}[?server=…|&world=…]`.
pub fn instance_launch_url(
    instance_id: &str,
    server: Option<&str>,
    world: Option<&str>,
) -> Result<Url> {
    if server.is_some() && world.is_some() {
        bail!("shortcut cannot launch both a server and a singleplayer world");
    }
    let mut launch_url = Url::parse("aml://launch/instance")
        .expect("static aml launch URL should parse");
    launch_url
        .path_segments_mut()
        .map_err(|_| anyhow!("launch URL cannot be a base"))?
        .push(instance_id);
    if let Some(server) = server.map(str::trim).filter(|s| !s.is_empty()) {
        launch_url
            .query_pairs_mut()
            .append_pair("server", server);
    } else if let Some(world) = world.map(str::trim).filter(|s| !s.is_empty()) {
        launch_url
            .query_pairs_mut()
            .append_pair("world", world);
    }
    Ok(launch_url)
}

pub fn ensure_shortcut_extension(mut path: PathBuf) -> PathBuf {
    let need = path
        .extension()
        .map(|e| e != SHORTCUT_EXTENSION)
        .unwrap_or(true);
    if need {
        path.set_extension(SHORTCUT_EXTENSION);
    }
    path
}

pub async fn create_desktop_shortcut(
    _display_name: &str,
    output_path: PathBuf,
    instance_id: &str,
    server: Option<&str>,
    world: Option<&str>,
    // Preferred icon: local path or data URL. When omitted, servers prefer
    // `servers.dat` favicon, else the instance icon.
    icon: Option<&str>,
) -> Result<PathBuf> {
    let launch_url = instance_launch_url(instance_id, server, world)?;
    let output_path = ensure_shortcut_extension(output_path);
    if let Some(parent) = output_path.parent() {
        tokio::fs::create_dir_all(parent).await.ok();
    }
    let icon_path = resolve_shortcut_icon(instance_id, server, icon).await;
    create_platform_shortcut(&launch_url, &output_path, icon_path.as_deref()).await?;
    Ok(output_path)
}

async fn resolve_shortcut_icon(
    instance_id: &str,
    server: Option<&str>,
    preferred: Option<&str>,
) -> Option<PathBuf> {
    match resolve_shortcut_icon_inner(instance_id, server, preferred).await {
        Ok(path) => path,
        Err(e) => {
            eprintln!("[AML shortcut] icon resolve failed: {e:#}");
            None
        }
    }
}

async fn resolve_shortcut_icon_inner(
    instance_id: &str,
    server: Option<&str>,
    preferred: Option<&str>,
) -> Result<Option<PathBuf>> {
    let resource = resource_dir().await?;

    if let Some(src) = preferred.map(str::trim).filter(|s| !s.is_empty()) {
        if let Some(path) = materialize_shortcut_ico(&resource, src).await? {
            return Ok(Some(path));
        }
    }

    if let Some(address) = server.map(str::trim).filter(|s| !s.is_empty()) {
        if let Some(raw) = worlds::find_server_icon(instance_id, address).await? {
            if let Some(normalized) = server_ping::normalize_favicon(&raw) {
                if let Some(path) = materialize_shortcut_ico(&resource, &normalized).await? {
                    return Ok(Some(path));
                }
            }
        }
    }

    let state = try_state()?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    if let Some(icon) = instance.icon.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        if let Some(path) = materialize_shortcut_ico(&resource, icon).await? {
            return Ok(Some(path));
        }
    }

    // Pack icon sitting in the instance folder.
    let pack_icon = dirs::instance_dir(&resource, &instance.path).join("icon.png");
    if pack_icon.is_file() {
        if let Some(path) =
            materialize_shortcut_ico(&resource, &pack_icon.to_string_lossy()).await?
        {
            return Ok(Some(path));
        }
    }

    Ok(None)
}

/// Turn a file path or data URL into a cached `.ico` path suitable for ShellLink.
async fn materialize_shortcut_ico(resource_dir: &str, source: &str) -> Result<Option<PathBuf>> {
    let trimmed = source.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }

    if !trimmed.starts_with("data:") {
        let path = PathBuf::from(trimmed);
        if path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("ico"))
            && path.is_file()
        {
            let abs = dunce::canonicalize(&path).unwrap_or(path);
            return Ok(Some(abs));
        }
    }

    let bytes = load_icon_bytes(resource_dir, trimmed).await?;
    if bytes.is_empty() {
        return Ok(None);
    }

    let ico = if is_ico(&bytes) {
        // Re-encode PNG-in-ICO or odd containers via decode when possible;
        // keep classic ICOs as-is.
        bytes
    } else if is_png(&bytes) {
        png_to_bmp_ico(&bytes)?
    } else {
        bail!("unsupported icon image format (need PNG or ICO)");
    };

    let hash = download::sha1_hex(&ico);
    let dir = icons::icons_cache_dir(resource_dir);
    tokio::fs::create_dir_all(&dir).await?;
    let out = dir.join(format!("shortcut_{hash}.ico"));
    if !out.exists() {
        tokio::fs::write(&out, &ico)
            .await
            .with_context(|| format!("write {}", out.display()))?;
    }
    let abs = dunce::canonicalize(&out).unwrap_or(out);
    eprintln!("[AML shortcut] icon ready: {}", abs.display());
    Ok(Some(abs))
}

async fn load_icon_bytes(resource_dir: &str, source: &str) -> Result<Vec<u8>> {
    if source.starts_with("data:") {
        let normalized = server_ping::normalize_favicon(source)
            .ok_or_else(|| anyhow!("invalid favicon data URL"))?;
        let url = data_url::DataUrl::process(&normalized)
            .map_err(|e| anyhow!("parse data URL: {e:?}"))?;
        let (bytes, _) = url
            .decode_to_vec()
            .map_err(|e| anyhow!("decode data URL: {e:?}"))?;
        return Ok(bytes);
    }

    let path = Path::new(source);
    if path.is_file() {
        return tokio::fs::read(path)
            .await
            .with_context(|| format!("read icon {}", path.display()));
    }

    if let Some(cached) = icons::resolve_icon_source(resource_dir, source).await? {
        return tokio::fs::read(&cached)
            .await
            .with_context(|| format!("read cached icon {cached}"));
    }

    bail!("icon source not found: {source}");
}

fn is_png(data: &[u8]) -> bool {
    data.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

fn is_ico(data: &[u8]) -> bool {
    data.len() >= 6 && data[0] == 0 && data[1] == 0 && data[2] == 1 && data[3] == 0
}

/// Decode PNG → classic 32-bit BMP ICO (ShellLink does not reliably use PNG-in-ICO).
fn png_to_bmp_ico(png: &[u8]) -> Result<Vec<u8>> {
    use png::{ColorType, Decoder, Transformations};
    use std::io::Cursor;

    let mut decoder = Decoder::new(Cursor::new(png));
    decoder.set_transformations(Transformations::normalize_to_color8());
    let mut reader = decoder.read_info()?;
    let info = reader.info().clone();
    let mut raw = vec![0u8; reader.output_buffer_size()];
    reader.next_frame(&mut raw)?;

    let rgba: Vec<u8> = match reader.output_color_type().0 {
        ColorType::Rgba => raw,
        ColorType::Rgb => raw
            .chunks_exact(3)
            .flat_map(|c| [c[0], c[1], c[2], 255])
            .collect(),
        ColorType::Grayscale => raw.iter().flat_map(|&v| [v, v, v, 255]).collect(),
        ColorType::GrayscaleAlpha => raw
            .chunks_exact(2)
            .flat_map(|c| [c[0], c[0], c[0], c[1]])
            .collect(),
        other => bail!("unsupported png color type: {other:?}"),
    };

    let (w, h, pixels) = fit_icon_rgba(&rgba, info.width, info.height);
    rgba_to_bmp_ico(&pixels, w, h)
}

fn fit_icon_rgba(rgba: &[u8], width: u32, height: u32) -> (u32, u32, Vec<u8>) {
    const MAX: u32 = 256;
    if width == 0 || height == 0 {
        return (1, 1, vec![0, 0, 0, 0]);
    }
    if width <= MAX && height <= MAX {
        return (width, height, rgba.to_vec());
    }
    let scale = (MAX as f32 / width as f32).min(MAX as f32 / height as f32);
    let nw = ((width as f32) * scale).round().max(1.0) as u32;
    let nh = ((height as f32) * scale).round().max(1.0) as u32;
    let mut out = vec![0u8; (nw * nh * 4) as usize];
    for y in 0..nh {
        for x in 0..nw {
            let sx = (x as u64 * width as u64 / nw as u64) as u32;
            let sy = (y as u64 * height as u64 / nh as u64) as u32;
            let si = ((sy * width + sx) * 4) as usize;
            let di = ((y * nw + x) * 4) as usize;
            if si + 3 < rgba.len() {
                out[di..di + 4].copy_from_slice(&rgba[si..si + 4]);
            }
        }
    }
    (nw, nh, out)
}

fn rgba_to_bmp_ico(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>> {
    if width == 0 || height == 0 || width > 256 || height > 256 {
        bail!("invalid ico size {width}x{height}");
    }
    let xor_size = (width * height * 4) as usize;
    let and_stride = ((width + 31) / 32) * 4;
    let and_size = (and_stride * height) as usize;
    let dib_size = 40 + xor_size + and_size;

    let mut out = Vec::with_capacity(6 + 16 + dib_size);
    // ICONDIR
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    // ICONDIRENTRY
    out.push(if width == 256 { 0 } else { width as u8 });
    out.push(if height == 256 { 0 } else { height as u8 });
    out.push(0);
    out.push(0);
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&(dib_size as u32).to_le_bytes());
    out.extend_from_slice(&22u32.to_le_bytes());
    // BITMAPINFOHEADER — biHeight is XOR+AND stacked
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(width as i32).to_le_bytes());
    out.extend_from_slice(&((height * 2) as i32).to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    out.extend_from_slice(&(xor_size as u32).to_le_bytes());
    out.extend_from_slice(&0i32.to_le_bytes());
    out.extend_from_slice(&0i32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    // XOR bitmap bottom-up BGRA
    for y in (0..height).rev() {
        for x in 0..width {
            let i = ((y * width + x) * 4) as usize;
            let (r, g, b, a) = if i + 3 < rgba.len() {
                (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
            } else {
                (0, 0, 0, 0)
            };
            out.extend_from_slice(&[b, g, r, a]);
        }
    }
    // AND mask
    out.resize(out.len() + and_size, 0);
    Ok(out)
}

#[cfg(target_os = "windows")]
async fn create_platform_shortcut(
    launch_url: &Url,
    output_path: &Path,
    icon_path: Option<&Path>,
) -> Result<()> {
    windows_impl::create_shortcut(launch_url, output_path, icon_path).await
}

#[cfg(not(target_os = "windows"))]
async fn create_platform_shortcut(
    _launch_url: &Url,
    _output_path: &Path,
    _icon_path: Option<&Path>,
) -> Result<()> {
    bail!("desktop shortcuts are only supported on Windows in this build");
}

#[cfg(target_os = "windows")]
mod windows_impl {
    use super::*;
    use std::os::windows::ffi::OsStrExt;
    use windows::{
        core::{Interface, PCWSTR},
        Win32::{
            System::Com::{
                CoCreateInstance, CoInitializeEx, CoUninitialize, IPersistFile,
                CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE,
            },
            UI::Shell::{IShellLinkW, ShellLink},
        },
    };

    pub async fn create_shortcut(
        launch_url: &Url,
        output_path: &Path,
        icon_path: Option<&Path>,
    ) -> Result<()> {
        let target_path = std::env::current_exe()?;
        let working_dir = target_path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let output_path = output_path.to_path_buf();
        let launch_url = launch_url.to_string();
        let icon_path = icon_path.map(Path::to_path_buf);

        tokio::task::spawn_blocking(move || {
            create_windows_shortcut(
                output_path,
                target_path,
                working_dir,
                launch_url,
                icon_path,
            )
        })
        .await
        .map_err(|e| anyhow!("shortcut task join failed: {e}"))??;
        Ok(())
    }

    fn create_windows_shortcut(
        output_path: PathBuf,
        target_path: PathBuf,
        working_dir: PathBuf,
        launch_url: String,
        icon_path: Option<PathBuf>,
    ) -> std::io::Result<()> {
        let icon_log = icon_path
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| target_path.display().to_string());
        let args_log = launch_url.clone();
        let output_path = windows_wide_path(&output_path);
        let target_path_w = windows_wide_path(&target_path);
        let working_dir = windows_wide_path(&working_dir);
        let launch_url = windows_wide_string(&launch_url);
        let icon_location = icon_path
            .as_ref()
            .map(|p| windows_wide_path(p))
            .unwrap_or_else(|| target_path_w.clone());

        unsafe {
            let init_result =
                CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
            windows_result(init_result.ok())?;
            let _com = WindowsComGuard;

            let shortcut: IShellLinkW =
                windows_result(CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER))?;
            windows_result(shortcut.SetPath(windows_pcwstr(&target_path_w)))?;
            windows_result(shortcut.SetArguments(windows_pcwstr(&launch_url)))?;
            windows_result(shortcut.SetWorkingDirectory(windows_pcwstr(&working_dir)))?;
            windows_result(shortcut.SetIconLocation(windows_pcwstr(&icon_location), 0))?;
            eprintln!("[AML shortcut] lnk args={args_log} icon={icon_log}");

            let persist_file: IPersistFile = windows_result(shortcut.cast())?;
            windows_result(persist_file.Save(windows_pcwstr(&output_path), true))?;
        }
        Ok(())
    }

    fn windows_result<T>(result: windows::core::Result<T>) -> std::io::Result<T> {
        result.map_err(std::io::Error::other)
    }

    struct WindowsComGuard;
    impl Drop for WindowsComGuard {
        fn drop(&mut self) {
            unsafe {
                CoUninitialize();
            }
        }
    }

    fn windows_wide_path(path: &Path) -> Vec<u16> {
        path.as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    fn windows_wide_string(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn windows_pcwstr(value: &[u16]) -> PCWSTR {
        PCWSTR::from_raw(value.as_ptr())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_instance_url() {
        let u = instance_launch_url("local:abc", None, None).unwrap();
        assert_eq!(u.scheme(), "aml");
        assert!(u.as_str().contains("instance"));
        assert!(u.path().contains("local") || u.as_str().contains("local"));
    }

    #[test]
    fn builds_server_and_world_urls() {
        let u = instance_launch_url("id", Some("host:25565"), None).unwrap();
        let q = u.query().unwrap_or("");
        assert!(q.contains("server="), "{q}");
        let u = instance_launch_url("id", None, Some("World")).unwrap();
        let q = u.query().unwrap_or("");
        assert!(q.contains("world="), "{q}");
        assert!(instance_launch_url("id", Some("a"), Some("b")).is_err());
    }

    #[test]
    fn converts_png_to_bmp_ico() {
        // Minimal valid 1x1 RGBA PNG via png crate encode would be nicer;
        // use a tiny hand-built PNG that decoders accept.
        let mut png_bytes = Vec::new();
        {
            use png::{ColorType, Encoder};
            use std::io::Cursor;
            let mut cursor = Cursor::new(&mut png_bytes);
            let mut enc = Encoder::new(&mut cursor, 2, 2);
            enc.set_color(ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut writer = enc.write_header().unwrap();
            writer
                .write_image_data(&[
                    255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255,
                ])
                .unwrap();
        }
        let ico = png_to_bmp_ico(&png_bytes).unwrap();
        assert!(is_ico(&ico));
        // ICONDIRENTRY width/height = 2
        assert_eq!(ico[6], 2);
        assert_eq!(ico[7], 2);
    }

    #[cfg(target_os = "windows")]
    #[tokio::test]
    async fn creates_windows_lnk() {
        let dir = std::env::temp_dir().join("aml_shortcut_test");
        let _ = tokio::fs::create_dir_all(&dir).await;
        let out = dir.join("AML - test.lnk");
        let path = create_desktop_shortcut(
            "test",
            out.clone(),
            "local:test-id",
            Some("127.0.0.1:25565"),
            None,
            None,
        )
        .await
        .expect("create shortcut");
        assert!(path.exists(), "{}", path.display());
        assert_eq!(path.extension().and_then(|e| e.to_str()), Some("lnk"));
        let _ = tokio::fs::remove_file(&path).await;
    }
}
