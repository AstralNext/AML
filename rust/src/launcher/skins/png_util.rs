//! Minecraft skin PNG helpers (normalize legacy 64x32 → 64x64).

use std::io::Cursor;

use anyhow::{anyhow, Result};
use png::{BitDepth, ColorType, Decoder, Encoder, Transformations};

pub fn is_png(data: &[u8]) -> bool {
    const SIG: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    data.starts_with(SIG)
}

pub fn dimensions(data: &[u8]) -> Result<(u32, u32)> {
    if !is_png(data) {
        anyhow::bail!("invalid png");
    }
    let w = u32::from_be_bytes(
        data.get(16..20)
            .ok_or_else(|| anyhow!("invalid png"))?
            .try_into()?,
    );
    let h = u32::from_be_bytes(
        data.get(20..24)
            .ok_or_else(|| anyhow!("invalid png"))?
            .try_into()?,
    );
    Ok((w, h))
}

/// Detect slim arms by sampling the classic arm gap at (54,20) 2x12.
pub fn detect_slim(normalized_rgba: &[u8]) -> bool {
    if normalized_rgba.len() < 64 * 64 * 4 {
        return false;
    }
    for y in 20..32 {
        for x in 54..56 {
            let i = (y * 64 + x) * 4 + 3;
            if normalized_rgba.get(i).copied().unwrap_or(0) != 0 {
                return false; // classic has opaque pixels here
            }
        }
    }
    true
}

/// Normalize skin to 64x64 RGBA PNG for display (vanilla SkinTextureDownloader rules).
pub fn normalize_skin_texture(png_data: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut decoder = Decoder::new(Cursor::new(png_data));
    decoder.set_transformations(Transformations::normalize_to_color8());
    let mut reader = decoder.read_info()?;
    let info = reader.info().clone();
    if info.width != 64 || ![32, 64].contains(&info.height) {
        anyhow::bail!("skin must be 64x64 or 64x32");
    }
    let is_legacy = info.height == 32;
    let output_size = reader.output_buffer_size();
    let mut raw = if is_legacy {
        vec![0u8; output_size * 2]
    } else {
        vec![0u8; output_size]
    };
    reader.next_frame(&mut raw)?;

    let mut rgba = match reader.output_color_type().0 {
        ColorType::Grayscale => raw.iter().flat_map(|&v| [v, v, v, 255]).collect::<Vec<_>>(),
        ColorType::GrayscaleAlpha => raw
            .chunks_exact(2)
            .flat_map(|c| [c[0], c[0], c[0], c[1]])
            .collect(),
        ColorType::Rgb => raw
            .chunks_exact(3)
            .flat_map(|c| [c[0], c[1], c[2], 255])
            .collect(),
        ColorType::Rgba => {
            if is_legacy {
                let mut out = vec![0u8; 64 * 64 * 4];
                out[..raw.len().min(64 * 32 * 4)]
                    .copy_from_slice(&raw[..raw.len().min(64 * 32 * 4)]);
                out
            } else {
                raw
            }
        }
        _ => anyhow::bail!("unsupported png color type"),
    };

    if rgba.len() < 64 * 64 * 4 {
        rgba.resize(64 * 64 * 4, 0);
    }

    if is_legacy {
        set_alpha(&mut rgba, 0, 32, 64, 64, 0);
        convert_legacy(&mut rgba);
        notch_transparency_hack(&mut rgba);
    }
    make_inner_opaque(&mut rgba);

    let mut encoded = Vec::new();
    {
        let mut enc = Encoder::new(&mut encoded, 64, 64);
        enc.set_color(ColorType::Rgba);
        enc.set_depth(BitDepth::Eight);
        let mut writer = enc.write_header()?;
        writer.write_image_data(&rgba)?;
    }

    Ok((encoded, rgba))
}

fn idx(x: usize, y: usize) -> usize {
    (y * 64 + x) * 4
}

fn set_alpha(buf: &mut [u8], x1: usize, y1: usize, x2: usize, y2: usize, a: u8) {
    for y in y1..y2 {
        for x in x1..x2 {
            buf[idx(x, y) + 3] = a;
        }
    }
}

fn copy_rect_mirror_h(
    buf: &mut [u8],
    x: usize,
    y: usize,
    off_x: isize,
    off_y: isize,
    width: usize,
    height: usize,
) {
    for row in 0..height {
        for col in 0..width {
            let src = idx(x + col, y + row);
            let dst_x = (x as isize + off_x) as usize + (width - 1 - col);
            let dst_y = (y as isize + off_y) as usize + row;
            let dst = idx(dst_x, dst_y);
            let pixel = [buf[src], buf[src + 1], buf[src + 2], buf[src + 3]];
            buf[dst..dst + 4].copy_from_slice(&pixel);
        }
    }
}

fn convert_legacy(buf: &mut [u8]) {
    const FACES: &[(usize, usize, isize, isize, usize, usize)] = &[
        (4, 16, 16, 32, 4, 4),
        (8, 16, 16, 32, 4, 4),
        (0, 20, 24, 32, 4, 12),
        (4, 20, 16, 32, 4, 12),
        (8, 20, 8, 32, 4, 12),
        (12, 20, 16, 32, 4, 12),
        (44, 16, -8, 32, 4, 4),
        (48, 16, -8, 32, 4, 4),
        (40, 20, 0, 32, 4, 12),
        (44, 20, -8, 32, 4, 12),
        (48, 20, -16, 32, 4, 12),
        (52, 20, -8, 32, 4, 12),
    ];
    for (x, y, ox, oy, w, h) in FACES {
        copy_rect_mirror_h(buf, *x, *y, *ox, *oy, *w, *h);
    }
}

fn notch_transparency_hack(buf: &mut [u8]) {
    for y in 0..32 {
        for x in 32..64 {
            if buf[idx(x, y) + 3] < 128 {
                return;
            }
        }
    }
    set_alpha(buf, 32, 0, 64, 32, 0);
}

fn make_inner_opaque(buf: &mut [u8]) {
    const PARTS: &[(usize, usize, usize, usize)] =
        &[(0, 0, 32, 16), (0, 16, 64, 32), (16, 48, 48, 64)];
    for (x1, y1, x2, y2) in PARTS {
        set_alpha(buf, *x1, *y1, *x2, *y2, 255);
    }
}
