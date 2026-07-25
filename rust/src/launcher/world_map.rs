//! Stream a top-down 2D overview chunk-by-chunk from Anvil region files.

use anyhow::Result;
use fastanvil::{Chunk, HeightMode, JavaChunk, Region};
use std::fs::File;
use std::path::{Path, PathBuf};

use crate::state::db;
use crate::state::{resource_dir, try_state};

use super::dirs;

/// Resolve where anvil region files live for a world.
/// Classic: `saves/<world>/region`
/// Newer (1.20+ / some loaders): `saves/<world>/dimensions/minecraft/overworld/region`
pub fn resolve_overworld_region_dir(world_dir: &Path) -> Option<PathBuf> {
    let candidates = [
        world_dir.join("region"),
        world_dir
            .join("dimensions")
            .join("minecraft")
            .join("overworld")
            .join("region"),
    ];
    for dir in candidates {
        if region_dir_has_mca(&dir) {
            return Some(dir);
        }
    }
    // Last resort: scan dimensions/*/region (custom dims still useful for preview).
    let dimensions = world_dir.join("dimensions");
    if dimensions.is_dir() {
        if let Ok(ns) = std::fs::read_dir(&dimensions) {
            for ns_ent in ns.flatten() {
                if !ns_ent.path().is_dir() {
                    continue;
                }
                if let Ok(dims) = std::fs::read_dir(ns_ent.path()) {
                    for dim_ent in dims.flatten() {
                        let region = dim_ent.path().join("region");
                        if region_dir_has_mca(&region) {
                            return Some(region);
                        }
                    }
                }
            }
        }
    }
    None
}

fn region_dir_has_mca(dir: &Path) -> bool {
    if !dir.is_dir() {
        return false;
    }
    std::fs::read_dir(dir)
        .ok()
        .map(|it| {
            it.flatten().any(|e| {
                e.path()
                    .extension()
                    .and_then(|x| x.to_str())
                    .map(|x| x.eq_ignore_ascii_case("mca"))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

#[derive(Clone, Copy)]
struct Sample {
    color: [u8; 4],
}

#[derive(Clone, Debug)]
pub struct WorldMapChunk {
    pub chunk_x: i32,
    pub chunk_z: i32,
    pub rgba: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct WorldMapStreamEvent {
    pub min_chunk_x: i32,
    pub min_chunk_z: i32,
    pub max_chunk_x: i32,
    pub max_chunk_z: i32,
    pub chunks_done: u32,
    pub chunks_total: u32,
    pub chunk: Option<WorldMapChunk>,
    pub done: bool,
}

const OK_STATUSES: &[&str] = &[
    "full",
    "spawn",
    "postprocessed",
    "fullchunk",
    "minecraft:full",
    "minecraft:spawn",
    "minecraft:postprocessed",
    "minecraft:fullchunk",
];

/// Generate a top-down map incrementally and emit each completed 16×16 chunk.
pub async fn stream_world_map_preview<F, Fut>(
    instance_id: &str,
    folder: &str,
    on_event: F,
) -> Result<()>
where
    F: FnMut(WorldMapStreamEvent) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let world_dir = instance_dir.join("saves").join(folder);
    stream_world_map_from_dir(&world_dir, on_event).await
}

/// Stream map preview from an already-resolved world directory.
pub async fn stream_world_map_from_dir<F, Fut>(
    world_dir: &Path,
    mut on_event: F,
) -> Result<()>
where
    F: FnMut(WorldMapStreamEvent) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let Some(region_dir) = resolve_overworld_region_dir(world_dir) else {
        return Ok(());
    };

    let mut regions = list_region_files(&region_dir)?;
    if regions.is_empty() {
        return Ok(());
    }
    regions.sort_by_key(|(rx, rz, _)| rx.abs() + rz.abs());
    let min_rx = regions.iter().map(|(x, _, _)| *x).min().unwrap_or(0);
    let max_rx = regions.iter().map(|(x, _, _)| *x).max().unwrap_or(0);
    let min_rz = regions.iter().map(|(_, z, _)| *z).min().unwrap_or(0);
    let max_rz = regions.iter().map(|(_, z, _)| *z).max().unwrap_or(0);
    let bounds = (
        min_rx * 32,
        min_rz * 32,
        (max_rx + 1) * 32 - 1,
        (max_rz + 1) * 32 - 1,
    );
    let chunks_total = (regions.len() as u32).saturating_mul(1024);
    let mut chunks_done = 0u32;

    for (rx, rz, path) in regions {
        let file = match File::open(&path) {
            Ok(file) => file,
            Err(error) => {
                tracing::warn!("skip region {}: {error}", path.display());
                chunks_done = chunks_done.saturating_add(1024);
                continue;
            }
        };
        let mut region = match Region::from_stream(file) {
            Ok(region) => region,
            Err(error) => {
                tracing::warn!("parse region {}: {error}", path.display());
                chunks_done = chunks_done.saturating_add(1024);
                continue;
            }
        };
        for cz in 0..32usize {
            for cx in 0..32usize {
                chunks_done = chunks_done.saturating_add(1);
                let raw = match region.read_chunk(cx, cz) {
                    Ok(Some(raw)) => raw,
                    _ => continue,
                };
                let chunk = match JavaChunk::from_bytes(&raw) {
                    Ok(chunk) => chunk,
                    Err(_) => continue,
                };
                if !OK_STATUSES.contains(&chunk.status().as_str()) {
                    continue;
                }
                let chunk_x = rx * 32 + cx as i32;
                let chunk_z = rz * 32 + cz as i32;
                let Some(preview) = sample_preview_chunk(&chunk, chunk_x, chunk_z) else {
                    continue;
                };
                if !on_event(stream_event(
                    bounds,
                    chunks_done,
                    chunks_total,
                    Some(preview),
                    false,
                ))
                .await
                {
                    return Ok(());
                }
            }
        }
    }

    let _ = on_event(stream_event(bounds, chunks_total, chunks_total, None, true)).await;
    Ok(())
}

fn stream_event(
    bounds: (i32, i32, i32, i32),
    chunks_done: u32,
    chunks_total: u32,
    chunk: Option<WorldMapChunk>,
    done: bool,
) -> WorldMapStreamEvent {
    WorldMapStreamEvent {
        min_chunk_x: bounds.0,
        min_chunk_z: bounds.1,
        max_chunk_x: bounds.2,
        max_chunk_z: bounds.3,
        chunks_done,
        chunks_total,
        chunk,
        done,
    }
}

fn list_region_files(region_dir: &Path) -> Result<Vec<(i32, i32, PathBuf)>> {
    let mut regions = Vec::new();
    for entry in std::fs::read_dir(region_dir)? {
        let entry = entry?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if let Some((rx, rz)) = parse_region_name(name) {
            regions.push((rx, rz, path));
        }
    }
    Ok(regions)
}

fn sample_preview_chunk(chunk: &JavaChunk, chunk_x: i32, chunk_z: i32) -> Option<WorldMapChunk> {
    let y_range = chunk.y_range();
    if y_range.start >= y_range.end {
        return None;
    }
    let mut rgba = vec![0; 16 * 16 * 4];
    let mut any = false;
    for lz in 0..16usize {
        for lx in 0..16usize {
            let Some(sample) = sample_top_block(chunk, lx, lz, y_range.start) else {
                continue;
            };
            let index = lz * 16 + lx;
            rgba[index * 4..index * 4 + 4].copy_from_slice(&sample.color);
            any = true;
        }
    }
    any.then_some(WorldMapChunk {
        chunk_x,
        chunk_z,
        rgba,
    })
}

/// Read exactly one top block using the chunk's cached heightmap.
fn sample_top_block(chunk: &JavaChunk, lx: usize, lz: usize, y_min: isize) -> Option<Sample> {
    let air_height = chunk.surface_height(lx, lz, HeightMode::Trust);
    let y = air_height - 1;
    if y < y_min {
        return None;
    }
    let block = chunk.block(lx, y, lz)?;
    let name = block.name();
    if matches!(
        name,
        "minecraft:air" | "minecraft:cave_air" | "minecraft:void_air"
    ) {
        return None;
    }
    Some(Sample {
        color: block_color(name),
    })
}

fn parse_region_name(name: &str) -> Option<(i32, i32)> {
    // r.<x>.<z>.mca
    let rest = name.strip_prefix("r.")?.strip_suffix(".mca")?;
    let mut parts = rest.split('.');
    let x: i32 = parts.next()?.parse().ok()?;
    let z: i32 = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((x, z))
}

pub(crate) fn block_color(name: &str) -> [u8; 4] {
    let id = name.strip_prefix("minecraft:").unwrap_or(name);
    match id {
        "grass_block" | "grass" | "tall_grass" | "fern" | "large_fern" => [91, 168, 70, 255],
        "dirt" | "coarse_dirt" | "rooted_dirt" | "farmland" | "dirt_path" => [134, 96, 67, 255],
        "podzol" => [92, 63, 32, 255],
        "mycelium" => [111, 99, 105, 255],
        "stone"
        | "andesite"
        | "diorite"
        | "granite"
        | "cobblestone"
        | "mossy_cobblestone"
        | "stone_bricks"
        | "mossy_stone_bricks"
        | "cracked_stone_bricks"
        | "smooth_stone" => [120, 120, 120, 255],
        "deepslate" | "cobbled_deepslate" | "deepslate_bricks" | "deepslate_tiles" => {
            [55, 55, 60, 255]
        }
        "sand" | "red_sand" | "sandstone" | "red_sandstone" | "smooth_sandstone" => {
            [219, 204, 145, 255]
        }
        "gravel" => [136, 126, 126, 255],
        "water" | "bubble_column" | "kelp" | "kelp_plant" | "seagrass" | "tall_seagrass" => {
            [54, 97, 186, 255]
        }
        "lava" | "magma_block" => [207, 82, 18, 255],
        "snow" | "snow_block" | "powder_snow" | "ice" | "packed_ice" | "blue_ice"
        | "frosted_ice" => [235, 244, 250, 255],
        "oak_log" | "spruce_log" | "birch_log" | "jungle_log" | "acacia_log" | "dark_oak_log"
        | "mangrove_log" | "cherry_log" | "pale_oak_log" | "oak_wood" | "spruce_wood"
        | "birch_wood" | "stripped_oak_log" => [101, 75, 44, 255],
        "oak_leaves"
        | "spruce_leaves"
        | "birch_leaves"
        | "jungle_leaves"
        | "acacia_leaves"
        | "dark_oak_leaves"
        | "azalea_leaves"
        | "flowering_azalea_leaves"
        | "mangrove_leaves"
        | "cherry_leaves" => [55, 120, 45, 255],
        "netherrack" | "crimson_nylium" | "warped_nylium" | "nether_bricks"
        | "red_nether_bricks" => [97, 38, 38, 255],
        "end_stone" | "end_stone_bricks" => [219, 222, 158, 255],
        "bedrock" | "obsidian" | "crying_obsidian" | "blackstone" | "gilded_blackstone" => {
            [30, 27, 34, 255]
        }
        "clay" | "terracotta" | "white_terracotta" => [158, 164, 176, 255],
        "coal_ore" | "deepslate_coal_ore" | "coal_block" => [40, 40, 40, 255],
        "iron_ore" | "deepslate_iron_ore" | "raw_iron_block" | "iron_block" => [180, 150, 120, 255],
        "gold_ore" | "deepslate_gold_ore" | "nether_gold_ore" | "raw_gold_block" | "gold_block" => {
            [220, 190, 70, 255]
        }
        "diamond_ore" | "deepslate_diamond_ore" | "diamond_block" => [80, 200, 200, 255],
        "emerald_ore" | "deepslate_emerald_ore" | "emerald_block" => [40, 180, 80, 255],
        "copper_ore" | "deepslate_copper_ore" | "raw_copper_block" | "copper_block" => {
            [180, 110, 80, 255]
        }
        "redstone_ore" | "deepslate_redstone_ore" | "redstone_block" => [160, 30, 30, 255],
        "lapis_ore" | "deepslate_lapis_ore" | "lapis_block" => [40, 70, 180, 255],
        "glowstone"
        | "shroomlight"
        | "sea_lantern"
        | "ochre_froglight"
        | "verdant_froglight"
        | "pearlescent_froglight" => [240, 210, 120, 255],
        "glass" | "glass_pane" | "white_stained_glass" => [180, 210, 230, 180],
        "white_wool"
        | "white_concrete"
        | "white_concrete_powder"
        | "quartz_block"
        | "smooth_quartz"
        | "calcite" => [235, 235, 235, 255],
        "black_wool" | "black_concrete" | "black_concrete_powder" => [25, 25, 25, 255],
        "gray_wool"
        | "gray_concrete"
        | "gray_concrete_powder"
        | "light_gray_wool"
        | "light_gray_concrete" => [110, 110, 110, 255],
        "red_wool" | "red_concrete" | "red_concrete_powder" | "red_bed" => [160, 40, 40, 255],
        "orange_wool" | "orange_concrete" | "orange_concrete_powder" => [220, 120, 40, 255],
        "yellow_wool" | "yellow_concrete" | "yellow_concrete_powder" | "hay_block" => {
            [230, 200, 50, 255]
        }
        "lime_wool" | "lime_concrete" | "lime_concrete_powder" => [110, 190, 50, 255],
        "green_wool"
        | "green_concrete"
        | "green_concrete_powder"
        | "moss_block"
        | "moss_carpet" => [70, 110, 40, 255],
        "cyan_wool"
        | "cyan_concrete"
        | "cyan_concrete_powder"
        | "prismarine"
        | "prismarine_bricks"
        | "dark_prismarine" => [40, 140, 150, 255],
        "light_blue_wool" | "light_blue_concrete" | "light_blue_concrete_powder" => {
            [80, 160, 220, 255]
        }
        "blue_wool" | "blue_concrete" | "blue_concrete_powder" => [40, 60, 170, 255],
        "purple_wool"
        | "purple_concrete"
        | "purple_concrete_powder"
        | "purpur_block"
        | "purpur_pillar" => [120, 60, 170, 255],
        "magenta_wool" | "magenta_concrete" | "magenta_concrete_powder" => [180, 60, 160, 255],
        "pink_wool" | "pink_concrete" | "pink_concrete_powder" | "cherry_planks" => {
            [230, 140, 180, 255]
        }
        "brown_wool" | "brown_concrete" | "brown_concrete_powder" | "soul_sand" | "soul_soil" => {
            [100, 70, 45, 255]
        }
        "oak_planks" | "spruce_planks" | "birch_planks" | "jungle_planks" | "acacia_planks"
        | "dark_oak_planks" | "mangrove_planks" | "bamboo_planks" => [160, 120, 70, 255],
        "bricks" | "mud_bricks" | "packed_mud" => [150, 80, 65, 255],
        "tuff" | "polished_tuff" | "tuff_bricks" => [90, 95, 90, 255],
        "sculk" | "sculk_catalyst" | "sculk_sensor" | "sculk_shrieker" | "sculk_vein" => {
            [10, 40, 45, 255]
        }
        "basalt" | "smooth_basalt" | "polished_basalt" => [70, 70, 75, 255],
        "dripstone_block" | "pointed_dripstone" => [130, 100, 80, 255],
        "amethyst_block" | "budding_amethyst" | "amethyst_cluster" => [140, 90, 190, 255],
        "crafting_table" | "furnace" | "blast_furnace" | "smoker" | "chest" | "barrel"
        | "ender_chest" | "bookshelf" | "enchanting_table" | "anvil" | "chipped_anvil"
        | "damaged_anvil" => [120, 90, 55, 255],
        "rail" | "powered_rail" | "detector_rail" | "activator_rail" => [120, 100, 80, 255],
        "torch" | "wall_torch" | "soul_torch" | "lantern" | "soul_lantern" | "campfire"
        | "soul_campfire" => [240, 200, 80, 255],
        _ => hash_color(id),
    }
}

fn hash_color(id: &str) -> [u8; 4] {
    let mut h: u32 = 2166136261;
    for b in id.as_bytes() {
        h ^= u32::from(*b);
        h = h.wrapping_mul(16777619);
    }
    let r = 60 + ((h) & 0x7F) as u8;
    let g = 60 + ((h >> 8) & 0x7F) as u8;
    let b = 60 + ((h >> 16) & 0x7F) as u8;
    [r, g, b, 255]
}
