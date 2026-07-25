use crate::meta::minecraft::Version;

#[derive(Debug, Copy, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub enum QuickPlayServerVersion {
    Builtin,
    BuiltinLegacy,
    Injected,
    Unsupported,
}

impl QuickPlayServerVersion {
    pub fn min_version(&self) -> Option<&'static str> {
        match self {
            Self::Builtin => Some("23w14a"),
            Self::BuiltinLegacy => Some("13w17a"),
            Self::Injected => Some("a1.0.5_01"),
            Self::Unsupported => None,
        }
    }

    pub fn older_version(&self) -> Option<Self> {
        match self {
            Self::Builtin => Some(Self::BuiltinLegacy),
            Self::BuiltinLegacy => Some(Self::Injected),
            Self::Injected => Some(Self::Unsupported),
            Self::Unsupported => None,
        }
    }
}

#[derive(Debug, Copy, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub enum QuickPlaySingleplayerVersion {
    Builtin,
    Unsupported,
}

impl QuickPlaySingleplayerVersion {
    pub fn min_version(&self) -> Option<&'static str> {
        match self {
            Self::Builtin => Some("23w14a"),
            Self::Unsupported => None,
        }
    }

    pub fn older_version(&self) -> Option<Self> {
        match self {
            Self::Builtin => Some(Self::Unsupported),
            Self::Unsupported => None,
        }
    }
}

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub struct QuickPlayVersion {
    pub server: QuickPlayServerVersion,
    pub singleplayer: QuickPlaySingleplayerVersion,
}

impl QuickPlayVersion {
    pub fn find_version(version_index: usize, versions: &[Version]) -> Self {
        let mut server = QuickPlayServerVersion::Builtin;
        let mut server_version = server.min_version();

        let mut singleplayer = QuickPlaySingleplayerVersion::Builtin;
        let mut singleplayer_version = singleplayer.min_version();

        for version in versions.iter().take(version_index) {
            if let Some(check_version) = server_version {
                if version.id == check_version {
                    server = server.older_version().unwrap();
                    server_version = server.min_version();
                }
            }

            if let Some(check_version) = singleplayer_version {
                if version.id == check_version {
                    singleplayer = singleplayer.older_version().unwrap();
                    singleplayer_version = singleplayer.min_version();
                }
            }

            if server_version.is_none() && singleplayer_version.is_none() {
                break;
            }
        }

        Self {
            server,
            singleplayer,
        }
    }
}
