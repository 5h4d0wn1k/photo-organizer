use std::sync::Arc;

use native_core::{AppConfig, AppState, GalleryService, router};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let config = AppConfig::from_env();
    if config.vault_key_storage == native_core::domain::VaultKeyStorage::File {
        tracing::warn!(
            "vault AES keys are stored as files under {}/security/vault-keys \
             (PRIVATE_GALLERY_VAULT_KEY_STORAGE=file). Key material shares a \
             trust domain with the ciphertext; use the OS keychain wherever a \
             keyring exists. See docs/security-model.md.",
            config.runtime_root.display()
        );
    }
    let service = Arc::new(GalleryService::new(config.clone())?);
    let listener = TcpListener::bind(config.bind_address()).await?;
    let app = router(AppState { service });

    tracing::info!(
        "private gallery core listening on {}",
        config.bind_address()
    );
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await?;
    Ok(())
}
