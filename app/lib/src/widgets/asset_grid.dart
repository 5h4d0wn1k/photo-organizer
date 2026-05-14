import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/gallery_models.dart';

class AssetGrid extends StatelessWidget {
  const AssetGrid({
    super.key,
    required this.assets,
    this.libraryRoot,
    this.onAssetSelected,
    this.selectionEnabled = false,
    this.selectedAssetIds = const <String>{},
    this.onAssetSelectionToggled,
  });

  final List<Asset> assets;
  final String? libraryRoot;
  final ValueChanged<Asset>? onAssetSelected;
  final bool selectionEnabled;
  final Set<String> selectedAssetIds;
  final ValueChanged<Asset>? onAssetSelectionToggled;

  @override
  Widget build(BuildContext context) {
    if (assets.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 1100
            ? 4
            : width >= 760
                ? 3
                : 2;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: assets.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.05,
          ),
          itemBuilder: (context, index) {
            final asset = assets[index];
            final metadataSource =
                asset.metadata?.capturedAtSource ?? 'filesystem';
            final dimensions =
                asset.metadata?.width != null && asset.metadata?.height != null
                    ? '${asset.metadata!.width}x${asset.metadata!.height}'
                    : null;
            final previewPath = _previewPath(asset);
            final selected = selectedAssetIds.contains(asset.id);
            final canSelect =
                selectionEnabled && onAssetSelectionToggled != null;
            return MouseRegion(
              cursor: onAssetSelected == null && !canSelect
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              child: GestureDetector(
                onLongPress: onAssetSelectionToggled == null
                    ? null
                    : () => onAssetSelectionToggled!(asset),
                onTap: canSelect
                    ? () => onAssetSelectionToggled!(asset)
                    : onAssetSelected == null
                        ? null
                        : () => onAssetSelected!(asset),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: LinearGradient(
                      colors: asset.mediaKind == 'video'
                          ? const [Color(0xFF1D4ED8), Color(0xFF0F172A)]
                          : const [Color(0xFF0F766E), Color(0xFF99F6E4)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (previewPath != null)
                          Image.file(
                            File(previewPath),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.black.withValues(alpha: 0.18),
                                Colors.black.withValues(alpha: 0.08),
                                Colors.black.withValues(alpha: 0.72),
                              ],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Align(
                                alignment: Alignment.topRight,
                                child: Icon(
                                  asset.archived
                                      ? Icons.archive_outlined
                                      : asset.favorite
                                          ? Icons.star_rounded
                                          : asset.mediaKind == 'video'
                                              ? Icons.videocam_outlined
                                              : Icons.image_outlined,
                                  color: Colors.white,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                asset.originalFilename,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${asset.placeHint ?? 'Unknown place'} • ${DateFormat.yMMMd().format(asset.capturedAt)}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  _AssetBadge(
                                    label: metadataSource.replaceAll('_', ' '),
                                  ),
                                  if (asset.archived)
                                    const _AssetBadge(label: 'archived'),
                                  if (asset.metadata?.geo != null)
                                    const _AssetBadge(label: 'GPS'),
                                  if (dimensions != null)
                                    _AssetBadge(label: dimensions),
                                  if (previewPath != null)
                                    const _AssetBadge(label: 'local preview'),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                asset.relativeOriginalPath,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                        if (selectionEnabled || selected)
                          Positioned(
                            top: 12,
                            left: 12,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.48),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Checkbox(
                                value: selected,
                                onChanged: onAssetSelectionToggled == null
                                    ? null
                                    : (_) => onAssetSelectionToggled!(asset),
                                visualDensity: VisualDensity.compact,
                                side: const BorderSide(color: Colors.white),
                                checkColor: Colors.black,
                                fillColor:
                                    WidgetStateProperty.resolveWith<Color>(
                                  (states) {
                                    if (states.contains(WidgetState.selected)) {
                                      return Colors.white;
                                    }
                                    return Colors.transparent;
                                  },
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  String? _previewPath(Asset asset) {
    if (asset.mediaKind != 'photo' || !asset.isAvailable) {
      return null;
    }
    if (asset.importMode == ImportMode.reference) {
      return asset.sourcePath.isEmpty ? null : asset.sourcePath;
    }
    final root = libraryRoot;
    if (root == null || root.isEmpty || asset.relativeOriginalPath.isEmpty) {
      return null;
    }
    final separator =
        root.endsWith('/') || root.endsWith('\\') ? '' : Platform.pathSeparator;
    final relative = asset.relativeOriginalPath.replaceFirst(
      RegExp(r'^[\\/]+'),
      '',
    );
    return '$root$separator$relative';
  }
}

class _AssetBadge extends StatelessWidget {
  const _AssetBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    );
  }
}
