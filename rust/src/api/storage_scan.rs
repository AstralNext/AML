//! 存储用量扫描：批量测量目录/文件大小，以及实例目录单遍分桶统计。
//! 与设置页 StorageUsageService 对应；纯 std 实现，在阻塞线程池执行。

use std::collections::HashMap;
use std::path::Path;

/// 单个路径的测量请求。
#[derive(Debug, Clone)]
pub struct PathMeasureRequest {
    pub path: String,
    pub is_file: bool,
    /// 这些名称（小写比较）的顶层子项不计入统计。
    pub exclude_child_names: Vec<String>,
    /// 只统计目录根下的普通文件（用于 manifest 清单等）。
    pub only_files_at_root: bool,
}

#[derive(Debug, Clone, Default)]
pub struct PathMeasureResult {
    pub bytes: i64,
    pub file_count: i64,
}

/// 实例目录分桶统计的一部分（mods/saves/... 或 other）。
#[derive(Debug, Clone)]
pub struct InstancePartStat {
    pub id: String,
    pub bytes: i64,
    pub file_count: i64,
}

#[derive(Debug, Clone)]
pub struct InstanceMeasureResult {
    pub total_bytes: i64,
    pub total_files: i64,
    pub parts: Vec<InstancePartStat>,
}

const INSTANCE_PART_IDS: [&str; 7] = [
    "mods",
    "resourcepacks",
    "shaderpacks",
    "datapacks",
    "saves",
    "backups",
    "logs",
];

/// 批量测量多个路径（文件或目录）。失败的路径按 (0, 0) 返回。
pub async fn measure_paths(requests: Vec<PathMeasureRequest>) -> Vec<PathMeasureResult> {
    tokio::task::spawn_blocking(move || {
        requests
            .iter()
            .map(measure_request)
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default()
}

/// 批量测量实例目录：单遍扫描，按 mods/resourcepacks/... 分桶，
/// 其余（根下文件 + 未知目录）归入 `other`。
pub async fn measure_instances(paths: Vec<String>) -> Vec<InstanceMeasureResult> {
    tokio::task::spawn_blocking(move || {
        paths
            .iter()
            .map(|p| measure_instance(Path::new(p)))
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default()
}

fn measure_request(req: &PathMeasureRequest) -> PathMeasureResult {
    let path = Path::new(&req.path);
    if req.is_file {
        let (bytes, files) = file_len(path).map(|l| (l as i64, 1)).unwrap_or((0, 0));
        return PathMeasureResult {
            bytes,
            file_count: files,
        };
    }
    let excluded: Vec<String> = req.exclude_child_names.iter().map(|s| s.to_lowercase()).collect();
    let (bytes, files) = measure_dir(path, &excluded, req.only_files_at_root);
    PathMeasureResult {
        bytes,
        file_count: files,
    }
}

fn measure_dir(path: &Path, excluded: &[String], only_files_at_root: bool) -> (i64, i64) {
    let mut bytes = 0i64;
    let mut files = 0i64;
    let Ok(entries) = std::fs::read_dir(path) else {
        return (0, 0);
    };
    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else { continue };
        let name = entry.file_name().to_string_lossy().to_lowercase();
        if !only_files_at_root && excluded.contains(&name) {
            continue;
        }
        if file_type.is_file() {
            if let Some(len) = file_len(&entry.path()) {
                bytes += len as i64;
                files += 1;
            }
        } else if file_type.is_dir() && !only_files_at_root {
            let (b, f) = measure_dir(&entry.path(), &[], false);
            bytes += b;
            files += f;
        }
    }
    (bytes, files)
}

fn file_len(path: &Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|m| m.len())
}

fn measure_instance(path: &Path) -> InstanceMeasureResult {
    let mut buckets: HashMap<&str, (i64, i64)> = INSTANCE_PART_IDS
        .iter()
        .map(|id| (*id, (0, 0)))
        .collect();
    let mut other = (0i64, 0i64);

    if let Ok(entries) = std::fs::read_dir(path) {
        for entry in entries.flatten() {
            let Ok(file_type) = entry.file_type() else { continue };
            let name = entry.file_name().to_string_lossy().to_lowercase();
            let target: &mut (i64, i64) = if buckets.contains_key(name.as_str()) {
                buckets.get_mut(name.as_str()).unwrap()
            } else {
                &mut other
            };
            if file_type.is_file() {
                if let Some(len) = file_len(&entry.path()) {
                    target.0 += len as i64;
                    target.1 += 1;
                }
            } else if file_type.is_dir() {
                let (b, f) = measure_dir(&entry.path(), &[], false);
                target.0 += b;
                target.1 += f;
            }
        }
    }

    let mut parts: Vec<InstancePartStat> = INSTANCE_PART_IDS
        .iter()
        .map(|id| {
            let (bytes, files) = buckets[id];
            InstancePartStat {
                id: (*id).to_string(),
                bytes,
                file_count: files,
            }
        })
        .collect();
    parts.push(InstancePartStat {
        id: "other".to_string(),
        bytes: other.0,
        file_count: other.1,
    });

    let total_bytes = parts.iter().map(|p| p.bytes).sum();
    let total_files = parts.iter().map(|p| p.file_count).sum();
    InstanceMeasureResult {
        total_bytes,
        total_files,
        parts,
    }
}
