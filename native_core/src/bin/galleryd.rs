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
    let service = Arc::new(GalleryService::new(config.clone())?);
    let listener = TcpListener::bind(config.bind_address()).await?;
    let app = router(AppState { service });

    tracing::info!(
        "private gallery core listening on {}",
        config.bind_address()
    );
    axum::serve(listener, app).await?;
    Ok(())
}
