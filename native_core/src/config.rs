use std::{env, path::PathBuf};

use crate::domain::NetworkPolicy;

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub library_root: PathBuf,
    pub runtime_root: PathBuf,
    pub bind_host: String,
    pub bind_port: u16,
    pub database_filename: String,
    pub network_policy: NetworkPolicy,
    pub developer_mode: bool,
    pub allow_remote_mobile: bool,
    pub tesseract_path: Option<PathBuf>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            library_root: PathBuf::from("library"),
            runtime_root: PathBuf::from("runtime"),
            bind_host: "127.0.0.1".to_string(),
            bind_port: 4821,
            database_filename: "gallery.sqlite3".to_string(),
            network_policy: NetworkPolicy::AskBeforeDownload,
            developer_mode: false,
            allow_remote_mobile: false,
            tesseract_path: None,
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

        config
    }

    pub fn database_path(&self) -> PathBuf {
        self.runtime_root.join("db").join(&self.database_filename)
    }

    pub fn bind_address(&self) -> String {
        format!("{}:{}", self.bind_host, self.bind_port)
    }
}
