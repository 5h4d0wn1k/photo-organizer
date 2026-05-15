CREATE TABLE IF NOT EXISTS library_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  library_root TEXT NOT NULL,
  default_import_mode TEXT NOT NULL,
  initialized_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS watch_folders (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  recursive INTEGER NOT NULL DEFAULT 1,
  import_mode TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_scanned_at TEXT
);

CREATE TABLE IF NOT EXISTS assets (
  id TEXT PRIMARY KEY,
  original_filename TEXT NOT NULL,
  relative_original_path TEXT NOT NULL,
  source_path TEXT NOT NULL,
  content_hash TEXT NOT NULL UNIQUE,
  media_kind TEXT NOT NULL,
  import_mode TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  mime_type TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  imported_at TEXT NOT NULL,
  archived INTEGER NOT NULL DEFAULT 0,
  favorite INTEGER NOT NULL DEFAULT 0,
  is_available INTEGER NOT NULL DEFAULT 1,
  place_hint TEXT
);

CREATE TABLE IF NOT EXISTS asset_variants (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  width INTEGER,
  height INTEGER,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS asset_metadata (
  asset_id TEXT PRIMARY KEY,
  captured_at TEXT NOT NULL,
  captured_at_source TEXT NOT NULL,
  timezone_offset_minutes INTEGER,
  width INTEGER,
  height INTEGER,
  camera_make TEXT,
  camera_model TEXT,
  lens_model TEXT,
  latitude REAL,
  longitude REAL,
  altitude_meters REAL,
  location_source TEXT,
  exact_gps_hidden INTEGER NOT NULL DEFAULT 0,
  sidecar_title TEXT,
  sidecar_description TEXT,
  folder_hint TEXT,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS albums (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  cover_asset_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(cover_asset_id) REFERENCES assets(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS album_assets (
  album_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  PRIMARY KEY (album_id, asset_id),
  FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS person_clusters (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  asset_ids_json TEXT NOT NULL DEFAULT '[]',
  face_template_ids_json TEXT NOT NULL DEFAULT '[]',
  representative_asset_id TEXT,
  hidden INTEGER NOT NULL DEFAULT 0,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS face_templates (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL,
  person_cluster_id TEXT,
  preview_variant_id TEXT,
  bounding_box_json TEXT NOT NULL,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE,
  FOREIGN KEY(person_cluster_id) REFERENCES person_clusters(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS place_clusters (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  country_code TEXT,
  region TEXT,
  centroid_latitude REAL,
  centroid_longitude REAL,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS place_assets (
  place_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  PRIMARY KEY (place_id, asset_id),
  FOREIGN KEY(place_id) REFERENCES place_clusters(id) ON DELETE CASCADE,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS event_clusters (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  title_source TEXT NOT NULL,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  place_id TEXT,
  people_ids_json TEXT NOT NULL DEFAULT '[]',
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(place_id) REFERENCES place_clusters(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS event_assets (
  event_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  PRIMARY KEY (event_id, asset_id),
  FOREIGN KEY(event_id) REFERENCES event_clusters(id) ON DELETE CASCADE,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS feedback_events (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vaults (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  storage_policy_json TEXT NOT NULL,
  key_version INTEGER NOT NULL,
  deletion_grace_days INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS device_identities (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  platform TEXT NOT NULL,
  public_key TEXT NOT NULL,
  trust_level TEXT NOT NULL,
  storage_profile_json TEXT NOT NULL,
  enrolled_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS vault_members (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  role TEXT NOT NULL,
  trust_level TEXT NOT NULL,
  display_name TEXT NOT NULL,
  added_at TEXT NOT NULL,
  revoked_at TEXT,
  UNIQUE(vault_id, device_id),
  FOREIGN KEY(vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY(device_id) REFERENCES device_identities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS blob_records (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  encrypted_hash TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  chunk_count INTEGER NOT NULL,
  encryption_key_version INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  tombstoned_at TEXT,
  -- Storage-only peers may hold opaque encrypted blobs for a remote vault
  -- without receiving that vault's searchable metadata or asset rows.
  -- Trusted viewers still resolve these IDs through their local metadata.
  UNIQUE(vault_id, asset_id)
);

CREATE TABLE IF NOT EXISTS blob_chunks (
  id TEXT PRIMARY KEY,
  blob_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  content_hash TEXT NOT NULL,
  encrypted_hash TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  encrypted_bytes INTEGER NOT NULL DEFAULT 0,
  local_path TEXT,
  nonce_hex TEXT,
  aad TEXT,
  UNIQUE(blob_id, chunk_index),
  FOREIGN KEY(blob_id) REFERENCES blob_records(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS blob_replicas (
  id TEXT PRIMARY KEY,
  blob_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  health TEXT NOT NULL,
  bytes_present INTEGER NOT NULL,
  verified_at TEXT,
  transfer_id TEXT,
  UNIQUE(blob_id, device_id),
  FOREIGN KEY(blob_id) REFERENCES blob_records(id) ON DELETE CASCADE,
  FOREIGN KEY(device_id) REFERENCES device_identities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS sync_transfers (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  blob_id TEXT NOT NULL,
  from_device_id TEXT,
  to_device_id TEXT NOT NULL,
  status TEXT NOT NULL,
  bytes_total INTEGER NOT NULL,
  bytes_completed INTEGER NOT NULL,
  started_at TEXT,
  updated_at TEXT NOT NULL,
  resumable_until TEXT NOT NULL,
  FOREIGN KEY(blob_id) REFERENCES blob_records(id) ON DELETE CASCADE,
  FOREIGN KEY(from_device_id) REFERENCES device_identities(id) ON DELETE SET NULL,
  FOREIGN KEY(to_device_id) REFERENCES device_identities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS sync_conflicts (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  asset_id TEXT,
  field TEXT NOT NULL,
  actor_device_ids_json TEXT NOT NULL,
  detected_at TEXT NOT NULL,
  detail TEXT NOT NULL,
  FOREIGN KEY(vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS vault_invites (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  invited_device_name TEXT NOT NULL,
  role TEXT NOT NULL,
  trust_level TEXT NOT NULL,
  invite_code TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  accepted_at TEXT,
  FOREIGN KEY(vault_id) REFERENCES vaults(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS relay_endpoints (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  node_id TEXT NOT NULL,
  relay_url TEXT,
  direct_addresses_json TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  FOREIGN KEY(device_id) REFERENCES device_identities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS capability_grants (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  capability TEXT NOT NULL,
  granted_by_device_id TEXT,
  granted_at TEXT NOT NULL,
  expires_at TEXT,
  FOREIGN KEY(vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY(device_id) REFERENCES device_identities(id) ON DELETE CASCADE,
  FOREIGN KEY(granted_by_device_id) REFERENCES device_identities(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS vault_key_envelopes (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  key_version INTEGER NOT NULL,
  algorithm TEXT NOT NULL,
  encrypted_vault_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT,
  UNIQUE(vault_id, device_id, key_version),
  FOREIGN KEY(vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY(device_id) REFERENCES device_identities(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS device_pairings (
  id TEXT PRIMARY KEY,
  device_name TEXT NOT NULL,
  platform TEXT NOT NULL,
  pairing_token TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT
);

CREATE TABLE IF NOT EXISTS sync_sessions (
  id TEXT PRIMARY KEY,
  pairing_id TEXT NOT NULL,
  status TEXT NOT NULL,
  started_at TEXT NOT NULL,
  last_seen_at TEXT,
  uploaded_asset_ids_json TEXT NOT NULL DEFAULT '[]',
  rejected_asset_ids_json TEXT NOT NULL DEFAULT '[]',
  FOREIGN KEY(pairing_id) REFERENCES device_pairings(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS mobile_sessions (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  vault_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT,
  FOREIGN KEY(device_id) REFERENCES device_identities(id) ON DELETE CASCADE,
  FOREIGN KEY(vault_id) REFERENCES vaults(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS mobile_uploads (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  vault_id TEXT NOT NULL,
  asset_id TEXT,
  original_filename TEXT NOT NULL,
  media_kind TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  bytes_total INTEGER NOT NULL,
  bytes_received INTEGER NOT NULL,
  content_hash TEXT,
  captured_at TEXT,
  place_hint TEXT,
  status TEXT NOT NULL,
  error_detail TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(session_id) REFERENCES mobile_sessions(id) ON DELETE CASCADE,
  FOREIGN KEY(device_id) REFERENCES device_identities(id) ON DELETE CASCADE,
  FOREIGN KEY(vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS import_sessions (
  id TEXT PRIMARY KEY,
  source_kind TEXT NOT NULL,
  source_path TEXT NOT NULL,
  import_mode TEXT NOT NULL,
  add_as_watch_folder INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  completed_at TEXT,
  place_hint TEXT,
  imported_asset_ids_json TEXT NOT NULL DEFAULT '[]',
  duplicate_asset_ids_json TEXT NOT NULL DEFAULT '[]',
  moved_asset_ids_json TEXT NOT NULL DEFAULT '[]',
  skipped_duplicate_ids_json TEXT NOT NULL DEFAULT '[]',
  failed_candidate_ids_json TEXT NOT NULL DEFAULT '[]',
  sidecars_moved INTEGER NOT NULL DEFAULT 0,
  unsupported_file_paths_json TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS import_candidates (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  source_path TEXT NOT NULL,
  original_filename TEXT NOT NULL,
  media_kind TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  captured_at TEXT,
  place_hint TEXT,
  content_hash TEXT NOT NULL,
  duplicate_asset_id TEXT,
  selected INTEGER NOT NULL DEFAULT 1,
  import_mode TEXT NOT NULL,
  destination_path TEXT,
  sidecar_paths_json TEXT NOT NULL DEFAULT '[]',
  safety_status TEXT NOT NULL DEFAULT 'ready',
  FOREIGN KEY(session_id) REFERENCES import_sessions(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  progress INTEGER NOT NULL,
  queued_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  detail TEXT,
  cancel_requested INTEGER NOT NULL DEFAULT 0,
  retry_of_job_id TEXT,
  attempt INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS job_logs (
  id TEXT PRIMARY KEY,
  job_id TEXT NOT NULL,
  level TEXT NOT NULL,
  message TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(job_id) REFERENCES jobs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS correction_records (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  asset_id TEXT,
  place_id TEXT,
  event_id TEXT,
  previous_json TEXT NOT NULL,
  applied_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS encryption_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  database_encrypted INTEGER NOT NULL DEFAULT 0,
  derived_data_encrypted INTEGER NOT NULL DEFAULT 0,
  key_storage TEXT,
  key_id TEXT,
  migrated_at TEXT,
  warning TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS model_install_audit (
  id TEXT PRIMARY KEY,
  model_id TEXT NOT NULL,
  action TEXT NOT NULL,
  source_url TEXT,
  expected_sha256 TEXT,
  actual_sha256 TEXT,
  status TEXT NOT NULL,
  message TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS face_detection_records (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL,
  bounding_box_json TEXT NOT NULL,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ocr_blocks (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL,
  text TEXT NOT NULL,
  bounding_box_json TEXT,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS scene_tags (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL,
  label TEXT NOT NULL,
  confidence REAL NOT NULL,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS embedding_records (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL,
  task TEXT NOT NULL,
  vector_path TEXT NOT NULL,
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_hash TEXT,
  created_at TEXT NOT NULL,
  rebuildable INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS search_index_status (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  filename_ready INTEGER NOT NULL DEFAULT 1,
  metadata_ready INTEGER NOT NULL DEFAULT 0,
  ocr_ready INTEGER NOT NULL DEFAULT 0,
  scene_ready INTEGER NOT NULL DEFAULT 0,
  semantic_ready INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  detail TEXT NOT NULL
);
