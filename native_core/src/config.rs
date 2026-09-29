use std::{env, path::PathBuf};

use crate::domain::{NetworkPolicy, VaultKeyStorage};

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub library_root: PathBuf,
    pub runtime_root: PathBuf,
    pub local_web_root: Option<PathBuf>,
    pub bind_host: String,
    pub bind_port: u16,
    pub database_filename: String,
    pub network_policy: NetworkPolicy,
    pub developer_mode: bool,
    pub allow_remote_mobile: bool,
    pub tesseract_path: Option<PathBuf>,
    pub vault_key_storage: VaultKeyStorage,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            library_root: PathBuf::from("library"),
            runtime_root: PathBuf::from("runtime"),
            local_web_root: None,
            bind_host: "127.0.0.1".to_string(),
            bind_port: 4821,
            database_filename: "gallery.sqlite3".to_string(),
            network_policy: NetworkPolicy::AskBeforeDownload,
            developer_mode: false,
            allow_remote_mobile: false,
            tesseract_path: None,
            vault_key_storage: VaultKeyStorage::OsKeychain,
        }
    }
}

impl AppConfig {
    pub fn from_env() -> Self {
        let mut config = Self::default();

        if let Ok(value) = env::var("PRIVATE_GALLERY_LIBRARY_ROOT")
            && !value.trim().is_empty()
        {
            config.library_root = PathBuf::from(value);
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_RUNTIME_ROOT")
            && !value.trim().is_empty()
        {
            config.runtime_root = PathBuf::from(value);
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_LOCAL_WEB_ROOT")
            && !value.trim().is_empty()
        {
            config.local_web_root = Some(PathBuf::from(value));
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_BIND_HOST")
            && !value.trim().is_empty()
        {
            config.bind_host = value;
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_BIND_PORT")
            && let Ok(port) = value.parse::<u16>()
        {
            config.bind_port = port;
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_DATABASE_FILENAME")
            && !value.trim().is_empty()
        {
            config.database_filename = value;
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_NETWORK_POLICY") {
            config.network_policy = match value.as_str() {
                "offline_only" => NetworkPolicy::OfflineOnly,
                "developer_fetch" => NetworkPolicy::DeveloperFetch,
                _ => NetworkPolicy::AskBeforeDownload,
            };
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_DEVELOPER_MODE") {
            config.developer_mode = matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES");
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE") {
            config.allow_remote_mobile =
                matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES");
        }
        if let Ok(value) = env::var("PRIVATE_GALLERY_TESSERACT_PATH")
            && !value.trim().is_empty()
        {
            config.tesseract_path = Some(PathBuf::from(value));
        }
        // Vault AES key store. "file" keeps keys as hex under
        // <runtime_root>/security/vault-keys/ -- same trust domain as the
        // ciphertext -- and is only for headless deployments with no OS
        // keyring. Anything else (including unset) is the OS keychain, and an
        // unrecognised value warns on stderr and falls back to the keychain:
        // silently accepting a typo here would choose the weaker store.
        // eprintln, not tracing: from_env runs before the subscriber exists.
        match env::var("PRIVATE_GALLERY_VAULT_KEY_STORAGE").map(|value| value.trim().to_lowercase())
        {
            Ok(value) if value == "file" => {
                config.vault_key_storage = VaultKeyStorage::File;
            }
            Ok(value) if value.is_empty() || value == "os_keychain" || value == "keychain" => {
                config.vault_key_storage = VaultKeyStorage::OsKeychain;
            }
            Ok(other) => {
                eprintln!(
                    "warning: unrecognised PRIVATE_GALLERY_VAULT_KEY_STORAGE={other:?}; \
                     using the OS keychain. Set it to 'file' only for headless \
                     deployments with no keyring -- see docs/security-model.md."
                );
                config.vault_key_storage = VaultKeyStorage::OsKeychain;
            }
            Err(_) => {
                config.vault_key_storage = VaultKeyStorage::OsKeychain;
            }
        }

        config
    }

    pub fn database_path(&self) -> PathBuf {
        self.runtime_root.join("db").join(&self.database_filename)
    }

    pub fn bind_address(&self) -> String {
        format!("{}:{}", self.bind_host, self.bind_port)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // from_env reads the real process environment, and Rust runs tests in
    // threads: without serialisation, two tests setting the knob concurrently
    // would observe each other's values. The lock also restores the previous
    // value, so these tests cannot leak configuration into unrelated ones.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn vault_storage_with_env(value: Option<&str>) -> VaultKeyStorage {
        let _guard = ENV_LOCK.lock().unwrap();
        // SAFETY: the mutex serialises every writer in this module, and
        // PRIVATE_GALLERY_VAULT_KEY_STORAGE is read only by from_env, whose
        // other callers in the test suite do not depend on this knob's value
        // (vault_store forces the file store under cfg(test) regardless, and
        // the security tests build AppConfig::default() directly). No test
        // observes a half-written value; the previous value is restored below.
        unsafe {
            let old = std::env::var("PRIVATE_GALLERY_VAULT_KEY_STORAGE").ok();
            match value {
                Some(v) => std::env::set_var("PRIVATE_GALLERY_VAULT_KEY_STORAGE", v),
                None => std::env::remove_var("PRIVATE_GALLERY_VAULT_KEY_STORAGE"),
            }
            let parsed = AppConfig::from_env().vault_key_storage;
            match old {
                Some(v) => std::env::set_var("PRIVATE_GALLERY_VAULT_KEY_STORAGE", v),
                None => std::env::remove_var("PRIVATE_GALLERY_VAULT_KEY_STORAGE"),
            }
            parsed
        }
    }

    #[test]
    fn vault_key_storage_defaults_to_os_keychain() {
        assert_eq!(vault_storage_with_env(None), VaultKeyStorage::OsKeychain);
        assert_eq!(
            AppConfig::default().vault_key_storage,
            VaultKeyStorage::OsKeychain
        );
    }

    #[test]
    fn vault_key_storage_file_is_explicit() {
        assert_eq!(vault_storage_with_env(Some("file")), VaultKeyStorage::File);
        // Case and surrounding whitespace are tolerated; the choice stays loud
        // (warning + status) wherever it is spelled.
        assert_eq!(
            vault_storage_with_env(Some("  FILE ")),
            VaultKeyStorage::File
        );
    }

    #[test]
    fn vault_key_storage_unknown_values_fall_back_to_keychain() {
        // A typo must choose the stronger store, never the weaker one: the
        // defect in #110 was a silent downgrade, so the fallback direction is
        // the load-bearing property here, not the parsing.
        for value in ["os_keychain", "keychain", "", "files", "disk", "FILEE"] {
            assert_eq!(
                vault_storage_with_env(Some(value)),
                VaultKeyStorage::OsKeychain,
                "value {value:?} must not select the file store"
            );
        }
    }
}
