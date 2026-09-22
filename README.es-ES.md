# Photo Organizer

> Traducción al español cortesía de [@webbrain-one](https://github.com/webbrain-one),
> contribuyente de [photo-organizer PR #1](https://github.com/5h4d0wn1k/photo-organizer/pull/1).

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![CI](https://github.com/5h4d0wn1k/photo-organizer/actions/workflows/ci.yml/badge.svg)](https://github.com/5h4d0wn1k/photo-organizer/actions/workflows/ci.yml)

Photo Organizer es una biblioteca de fotos y vídeos **local-por-defecto y privada
por defecto**. Te ofrece una experiencia de organización al estilo Google Photos —
línea de tiempo, lugares, eventos, álbumes, archivo, etiquetas y búsqueda — pero
manteniendo tu medio, metadatos, texto OCR e inteligencia en dispositivos que
tú controlas. Sin almacenamiento en la nube, sin IA en la nube, sin analizar tu
biblioteca en servidores de terceros.

Las capturas de pantalla se publicarán en [`docs/screenshots/`](docs/screenshots/)
en v1.0.

## Funcionalidades

- **Importar** — escanea carpetas y unidades extraíbles, confirma con modos
  `copy` (copiar) o `reference` (referenciar), más carpetas de vigilancia
  persistentes.
- **Deduplicación por checksum** — almacenamiento direccionado por contenido y
  deduplicación por SHA-256 en escaneos e importaciones.
- **Línea de tiempo, lugares, eventos** — fechas de captura, agrupaciones por
  lugar a partir de pistas EXIF/manuales y agrupaciones por evento de tiempo + lugar.
- **Álbumes** — crear, renombrar, añadir/quitar elementos y eliminar álbumes.
- **Archivo y etiquetas** — marcas de archivado/favorito/papelera y etiquetas
  manuales de elementos.
- **Búsqueda** — búsqueda de texto completo y por metadatos, ampliada con **OCR
  local** (CLI de Tesseract) y **etiquetas de escena** (analizador heurístico
  en el dispositivo).
- **Cifrado en reposo** — toda la base de datos de metadatos queda sellada con
  **SQLCipher**, y los originales se almacenan como fragmentos cifrados de bóveda
  con **ChaCha20-Poly1305**, con nonces por fragmento y verificación de hash de
  contenido.
- **Sincronización P2P en LAN** — los fragmentos cifrados de bóveda se mueven
  entre dispositivos de escritorio mediante el transporte Iroh, con salud de
  réplicas, planificación de transferencias, reintentos y cancelación.
- **Emparejamiento Android** — empareja un teléfono con invitación QR, sube
  elementos de la cámara mediante subidas reanudables autenticadas y descarga
  originales con rangos acotados.

## Privacidad

- La API del daemon se enlaza a `127.0.0.1:4821` por defecto; el enlace fuera de
  loopback se rechaza salvo que se defina explícitamente
  `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1`, y los clientes remotos quedan limitados
  a `/health` y las rutas `/mobile/*` autenticadas.
- **Solo ML en el dispositivo en v1** — el OCR se ejecuta mediante la CLI local
  de Tesseract, las etiquetas de escena se calculan localmente y las descargas de
  modelos están verificadas por hash y son opt-in. Sin IA en la nube, SDK de
  analítica, telemetría ni geocodificación remota.
- Los tokens de emparejamiento, los hashes de tokens portadores y las claves de
  biblioteca permanecen en el dispositivo; las claves pasan por el llavero del
  sistema operativo.
- Las claves, plantillas faciales y tokens se almacenan cifrados en reposo.

## Estado

Photo Organizer es un **MVP usable en escritorio** en evolución. El cliente de
escritorio Linux es el destino principal, con emparejamiento móvil Android a
través de la red local. Los shells de escritorio macOS y Windows existen pero
requieren toolchains de plataforma nativas. El resto de lo planificado está en
[Roadmap](#roadmap) y en el [CHANGELOG.md](CHANGELOG.md).

## Plataformas soportadas

- **Escritorio Linux** — destino de referencia totalmente soportado.
- **Android** — emparejamiento móvil, subida del carrete y descarga de
  originales de bóveda.
- **macOS / Windows / web** — existen scaffolds de ejecución; los instaladores
  son trabajo futuro.

## Arquitectura

```
+----------------+  HTTP sobre loopback   +------------------------------------+
|  App Flutter   | <--------------------> |  galleryd  (daemon Rust)           |
| escritorio+móvil|   127.0.0.1:4821       |  importar · metadatos · buscar · sync|
+----------------+                        +-----------+-------+------+-------+
                                                    |       |      |
                        +--------------------------+       |      |
                        |                                  |      |
                 Base de datos SQLite + SQLCipher          |      |
                 (metadatos, índices)                      |      |
                 Almacén de fragmentos cifrado  <----------+      |
                 (originales sellados ChaCha20-Poly1305)           |
                 Sidecar OCR Tesseract + ML Python  <-------------+
                 (local, con guardas offline)
```

- `native_core/` — daemon y biblioteca Rust (almacenamiento, orquestación de
  importaciones, API local).
- `app/` — cliente Flutter para escritorio Linux y Android.
- `ml_sidecar/` — sidecar local Python de OCR/escenas (solo línea de comandos,
  nunca un listener).
- `tools/quick-face-sort/` — clasificador facial Python independiente y heredado.
- `supabase/` — bootstrap opcional solo-metadatos para grupos creados en el teléfono.

## Inicio rápido

### Producción (Linux)

Requiere los toolchains de Rust y Flutter además de herramientas nativas del
host (`cmake`, `ninja`, `g++`, cabeceras de desarrollo de GTK3).

```bash
bash scripts/build_linux_release.sh        # compila galleryd + app Flutter y los empaqueta
bash scripts/install_linux_desktop_entry.sh # añade una entrada de lanzador en el menú de aplicaciones
scripts/private_gallery_linux_launcher.sh  # arranca el daemon y lanza la app
```

El resultado empaquetado está en `app/build/linux/x64/release/bundle/` con `galleryd`
y `ml_sidecar/` junto al binario Flutter; la entrada del menú de aplicaciones aún
muestra el nombre heredado *Private Gallery* hasta que madure la migración de
marca (ver [CHANGELOG](CHANGELOG.md)).

Para el emparejamiento Android durante el desarrollo, ejecuta el daemon en modo
LAN en una red de confianza:

```bash
PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1 scripts/private_gallery_mobile_lan_daemon.sh
```

Luego abre la pantalla Vaults de la app, crea un grupo de dispositivos, añade el
teléfono y escanea el QR de invitación desde la app Android.

### Desarrollo

```bash
# Daemon Rust
cargo build --manifest-path native_core/Cargo.toml --bin galleryd
cargo test --manifest-path native_core/Cargo.toml

# Cliente de escritorio Flutter
cd app
flutter run -d linux
flutter analyze
flutter test
```

Una comprobación de un solo paso ejecuta la puerta mínima soportada:

```bash
scripts/dev-check.sh
```

Consulta [CONTRIBUTING.md](CONTRIBUTING.md) para el flujo de desarrollo completo.

## Quick Face Sort

`tools/quick-face-sort/` es una herramienta independiente y heredada (Python +
tkinter) que ordena una carpeta de fotos contra una cara de referencia usando
encoding facial de dlib. Se mantiene para flujos de importación/exportación y es
independiente del daemon de Photo Organizer.

```bash
pip install -r tools/quick-face-sort/requirements.txt
python tools/quick-face-sort/main.py
```

La rueda pip de `dlib` usa solo CPU; las compilaciones de `dlib` con CUDA
permiten aceleración por GPU a mayor rendimiento.

## Roadmap

- Reconocimiento facial (agrupación + plantillas) con almacenamiento biométrico
  cifrado y consentimiento explícito.
- Miniaturas y vistas previas para escritorio y móvil.
- Reproducción de vídeo en escritorio.
- Búsqueda semántica e indexación vectorial.
- Instaladores para Windows y macOS.
- Internacionalización (traducción al español en
  [README.es-ES.md](README.es-ES.md)).

## Documentación

- [docs/architecture.md](docs/architecture.md) — diseño del sistema y superficie de API.
- [docs/PRIVACY.md](docs/PRIVACY.md) — modelo detallado de privacidad de inteligencia local.
- [docs/security-model.md](docs/security-model.md) — límites de confianza y controles.
- [docs/product-vision.md](docs/product-vision.md) — objetivos y dirección del producto.
- [PRIVACY.md](PRIVACY.md) — política de privacidad resumida.
- [SECURITY.md](SECURITY.md) — cómo informar de vulnerabilidades.
- [CONTRIBUTING.md](CONTRIBUTING.md) — cómo construir y probar.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — expectativas de la comunidad.
- [CHANGELOG.md](CHANGELOG.md) — historial de versiones.

## Herencia y afiliación

Photo Organizer se desarrollaba anteriormente como **Private Gallery**, que nació
del proyecto *photos-and-videos-organizer* y aún conserva prefijos de
configuración `PG_*` en algunos scripts. El clasificador facial Python heredado
vive ahora en [`tools/quick-face-sort/`](tools/quick-face-sort/).

Photo Organizer **no está afiliado ni respaldado por Google Photos**, ni por
ningún otro proveedor de alojamiento de fotos.

## Licencia

Apache-2.0. Consulta [LICENSE](LICENSE).