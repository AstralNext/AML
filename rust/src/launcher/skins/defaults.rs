//! Official default character skins (preferred model only).
//! PNG bytes are bundled at compile time — no CDN on open.

pub struct DefaultSkinDef {
    pub name: &'static str,
    pub texture_key: &'static str,
    pub variant: &'static str, // classic | slim
    pub section: &'static str,
    pub png: &'static [u8],
}

/// Default skin models; textures embedded via `include_bytes!`.
pub const DEFAULT_SKINS: &[DefaultSkinDef] = &[
    DefaultSkinDef {
        name: "Steve",
        texture_key: "31f477eb1a7beee631c2ca64d06f8f68fa93a3386d04452ab27f43acdf1b60cb",
        variant: "classic",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/steve.png"),
    },
    DefaultSkinDef {
        name: "Alex",
        texture_key: "46acd06e8483b176e8ea39fc12fe105eb3a2a4970f5100057e9d84d4b60bdfa7",
        variant: "slim",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/alex.png"),
    },
    DefaultSkinDef {
        name: "Ari",
        texture_key: "4c05ab9e07b3505dc3ec11370c3bdce5570ad2fb2b562e9b9dd9cf271f81aa44",
        variant: "classic",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/ari.png"),
    },
    DefaultSkinDef {
        name: "Efe",
        texture_key: "fece7017b1bb13926d1158864b283b8b930271f80a90482f174cca6a17e88236",
        variant: "slim",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/efe.png"),
    },
    DefaultSkinDef {
        name: "Kai",
        texture_key: "e5cdc3243b2153ab28a159861be643a4fc1e3c17d291cdd3e57a7f370ad676f3",
        variant: "classic",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/kai.png"),
    },
    DefaultSkinDef {
        name: "Makena",
        texture_key: "7cb3ba52ddd5cc82c0b050c3f920f87da36add80165846f479079663805433db",
        variant: "slim",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/makena.png"),
    },
    DefaultSkinDef {
        name: "Noor",
        texture_key: "6c160fbd16adbc4bff2409e70180d911002aebcfa811eb6ec3d1040761aea6dd",
        variant: "slim",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/noor.png"),
    },
    DefaultSkinDef {
        name: "Sunny",
        texture_key: "a3bd16079f764cd541e072e888fe43885e711f98658323db0f9a6045da91ee7a",
        variant: "classic",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/sunny.png"),
    },
    DefaultSkinDef {
        name: "Zuri",
        texture_key: "f5dddb41dcafef616e959c2817808e0be741c89ffbfed39134a13e75b811863d",
        variant: "classic",
        section: "默认皮肤",
        png: include_bytes!("assets/defaults/zuri.png"),
    },
];

pub fn texture_cdn_url(key: &str) -> String {
    format!("https://textures.minecraft.net/texture/{key}")
}
