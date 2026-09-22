import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';

class AlbumsScreen extends StatelessWidget {
  const AlbumsScreen({
    super.key,
    required this.albums,
    required this.libraryRoot,
    required this.onCreateAlbum,
    required this.onFetchFavoriteAssets,
    required this.onFetchArchivedAssets,
    required this.onFetchAlbumAssets,
    required this.onUpdateAssetFlags,
    required this.onRemoveAlbumAssets,
    required this.onRenameAlbum,
    required this.onDeleteAlbum,
    required this.onAlbumsChanged,
  });

  final List<Album> albums;
  final String libraryRoot;
  final Future<Album> Function(String title) onCreateAlbum;
  final Future<List<Asset>> Function() onFetchFavoriteAssets;
  final Future<List<Asset>> Function() onFetchArchivedAssets;
  final Future<List<Asset>> Function(String id) onFetchAlbumAssets;
  final Future<Asset> Function(
    String assetId, {
    bool? favorite,
    bool? archived,
  }) onUpdateAssetFlags;
  final Future<Album> Function(String id, {required List<String> assetIds})
      onRemoveAlbumAssets;
  final Future<Album> Function(String id, String title) onRenameAlbum;
  final Future<void> Function(String id) onDeleteAlbum;
  final Future<void> Function() onAlbumsChanged;

  Future<void> _createAlbum(BuildContext context) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create album'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Album title',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (title == null || title.trim().isEmpty || !context.mounted) {
      return;
    }

    try {
      await onCreateAlbum(title.trim());
      await onAlbumsChanged();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album created locally.')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _renameAlbum(BuildContext context, Album album) async {
    final controller = TextEditingController(text: album.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename album'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Album title',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (title == null || title.trim().isEmpty || !context.mounted) {
      return;
    }

    try {
      await onRenameAlbum(album.id, title.trim());
      await onAlbumsChanged();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album renamed.')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _deleteAlbum(BuildContext context, Album album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete ${album.title}?'),
          content: const Text(
            'This removes only the local album record. Media files stay in the library.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete album'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) {
      return;
    }

    try {
      await onDeleteAlbum(album.id);
      await onAlbumsChanged();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album deleted. Media was untouched.')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _openAlbum(BuildContext context, Album album) async {
    List<Asset> assets;
    try {
      assets = await onFetchAlbumAssets(album.id);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
      return;
    }

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(album.title),
          content: SizedBox(
            width: 900,
            child: assets.isEmpty
                ? const EmptyStatePanel(
                    icon: Icons.photo_album_outlined,
                    title: 'Album is empty',
                    message:
                        'Open an asset from the timeline and add it to this album.',
                  )
                : SingleChildScrollView(
                    child: AssetGrid(
                      assets: assets,
                      libraryRoot: libraryRoot,
                      onAssetSelected: (asset) async {
                        final albumNavigator = Navigator.of(dialogContext);
                        final remove = await showDialog<bool>(
                          context: dialogContext,
                          builder: (context) {
                            return AlertDialog(
                              title: Text('Remove ${asset.originalFilename}?'),
                              content: const Text(
                                'This removes only album membership. The media file stays in the library.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('Remove from album'),
                                ),
                              ],
                            );
                          },
                        );
                        if (remove != true) {
                          return;
                        }
                        albumNavigator.pop();
                        await onRemoveAlbumAssets(
                          album.id,
                          assetIds: [asset.id],
                        );
                        await onAlbumsChanged();
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _renameAlbum(context, album);
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Rename'),
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _deleteAlbum(context, album);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openBuiltInCollection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Future<List<Asset>> Function() loader,
    required String emptyTitle,
    required String emptyMessage,
    required String actionLabel,
    required Future<void> Function(Asset asset) onAssetAction,
  }) async {
    List<Asset> assets;
    try {
      assets = await loader();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
      return;
    }

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 900,
            child: assets.isEmpty
                ? EmptyStatePanel(
                    icon: icon,
                    title: emptyTitle,
                    message: emptyMessage,
                  )
                : SingleChildScrollView(
                    child: AssetGrid(
                      assets: assets,
                      libraryRoot: libraryRoot,
                      onAssetSelected: (asset) async {
                        final collectionNavigator = Navigator.of(dialogContext);
                        final confirmed = await showDialog<bool>(
                          context: dialogContext,
                          builder: (context) {
                            return AlertDialog(
                              title: Text('${asset.originalFilename}?'),
                              content: const Text(
                                'This updates local metadata only. The media file stays in place.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: Text(actionLabel),
                                ),
                              ],
                            );
                          },
                        );
                        if (confirmed != true) {
                          return;
                        }
                        collectionNavigator.pop();
                        await onAssetAction(asset);
                        await onAlbumsChanged();
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Albums',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Manual local albums. They organize assets without moving, deleting, uploading, or training on media.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: () => _createAlbum(context),
              icon: const Icon(Icons.add),
              label: const Text('Create album'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _CollectionCard(
              icon: Icons.star_rounded,
              title: 'Favorites',
              description:
                  'Review assets you starred locally. Archived favorites are included.',
              onTap: () => _openBuiltInCollection(
                context,
                title: 'Favorites',
                icon: Icons.star_rounded,
                loader: onFetchFavoriteAssets,
                emptyTitle: 'No favorites yet',
                emptyMessage:
                    'Open an asset from the timeline and mark it as favorite.',
                actionLabel: 'Remove favorite',
                onAssetAction: (asset) => onUpdateAssetFlags(
                  asset.id,
                  favorite: false,
                ),
              ),
            ),
            _CollectionCard(
              icon: Icons.archive_outlined,
              title: 'Archive',
              description:
                  'Review media hidden from the main timeline. Files remain in the library.',
              onTap: () => _openBuiltInCollection(
                context,
                title: 'Archive',
                icon: Icons.archive_outlined,
                loader: onFetchArchivedAssets,
                emptyTitle: 'Archive is empty',
                emptyMessage:
                    'Archived assets will appear here without being moved or deleted.',
                actionLabel: 'Unarchive',
                onAssetAction: (asset) => onUpdateAssetFlags(
                  asset.id,
                  archived: false,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (albums.isEmpty)
          EmptyStatePanel(
            icon: Icons.photo_album_outlined,
            title: 'No albums yet',
            message:
                'Create an album here, then add assets from the timeline asset details dialog.',
            actionLabel: 'Create album',
            onAction: () => _createAlbum(context),
          )
        else
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final album in albums)
                SizedBox(
                  width: 320,
                  child: Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => _openAlbum(context, album),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.photo_album_outlined, size: 32),
                            const SizedBox(height: 16),
                            Text(
                              album.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${album.assetIds.length} assets',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            if (album.updatedAt != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Updated ${DateFormat.yMMMd().add_jm().format(album.updatedAt!.toLocal())}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 320,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 32),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(description),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
