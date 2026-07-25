use crate::meta::minecraft::{Os, Rule, RuleAction};

pub fn parse_rules(rules: &[Rule], java_arch: &str, features: RuleFeatures) -> bool {
    if rules.is_empty() {
        return true;
    }
    let mut allowed = false;
    for rule in rules {
        if rule_matches(rule, java_arch, features) {
            allowed = matches!(rule.action, RuleAction::Allow);
        }
    }
    allowed
}

#[derive(Clone, Copy, Default)]
pub struct RuleFeatures {
    pub has_custom_resolution: bool,
    pub is_demo_user: bool,
    pub has_quick_plays_support: bool,
    pub is_quick_play_singleplayer: bool,
    pub is_quick_play_multiplayer: bool,
    pub is_quick_play_realms: bool,
}

fn rule_matches(rule: &Rule, java_arch: &str, features: RuleFeatures) -> bool {
    if let Some(os_rule) = &rule.os {
        if let Some(name) = &os_rule.name {
            let native = Os::native_arch(java_arch);
            if name.get_os() != native.get_os() && name != &native {
                return false;
            }
        }
        if let Some(arch) = &os_rule.arch {
            if arch == "x86" && java_arch != "x86" {
                return false;
            }
            if arch == "arm" && !java_arch.starts_with("arm") && java_arch != "aarch64" {
                // Mojang uses arch=arm sometimes; keep permissive for aarch64 mismatches via name
            }
        }
    }
    if let Some(fr) = &rule.features {
        if fr.has_custom_resolution == Some(true) && !features.has_custom_resolution {
            return false;
        }
        if fr.is_demo_user == Some(true) && !features.is_demo_user {
            return false;
        }
        if fr.has_quick_plays_support == Some(true) && !features.has_quick_plays_support {
            return false;
        }
        if fr.is_quick_play_singleplayer == Some(true) && !features.is_quick_play_singleplayer {
            return false;
        }
        if fr.is_quick_play_multiplayer == Some(true) && !features.is_quick_play_multiplayer {
            return false;
        }
        if fr.is_quick_play_realms == Some(true) && !features.is_quick_play_realms {
            return false;
        }
    }
    true
}
