//! Content kinds placed into instance folders.

/// Which content folder a project lands in and how its versions are matched.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum ContentType {
    Mod,
    ResourcePack,
    Shader,
    DataPack,
}

impl ContentType {
    pub(super) fn parse(s: Option<&str>) -> Self {
        match s.unwrap_or("mod") {
            "resourcepack" => Self::ResourcePack,
            "shader" => Self::Shader,
            "datapack" => Self::DataPack,
            _ => Self::Mod,
        }
    }

    pub(super) fn folder(self) -> &'static str {
        match self {
            Self::Mod => "mods",
            Self::ResourcePack => "resourcepacks",
            Self::Shader => "shaderpacks",
            Self::DataPack => "datapacks",
        }
    }

    /// Target loader preference used when matching versions.
    pub(super) fn target_loaders(self, instance_loader: &str) -> Vec<String> {
        match self {
            Self::Mod => {
                if instance_loader.is_empty() || instance_loader == "vanilla" {
                    vec![]
                } else {
                    vec![instance_loader.to_lowercase()]
                }
            }
            Self::DataPack => vec!["datapack".into()],
            Self::ResourcePack => vec!["minecraft".into()],
            Self::Shader => vec!["iris".into()],
        }
    }
}
