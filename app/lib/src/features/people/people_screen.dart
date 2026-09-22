import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';

class PeopleScreen extends StatelessWidget {
  const PeopleScreen({
    super.key,
    required this.people,
    required this.models,
    required this.libraryRoot,
    required this.privacyStatus,
    required this.onIndexPeople,
    required this.onResetPeople,
    required this.onCreateManualPerson,
    required this.onFetchPersonAssets,
    required this.onRemovePersonAssets,
    required this.onPeopleChanged,
    required this.onRenamePerson,
    required this.onHidePerson,
    required this.onRejectPersonMatch,
    required this.onMergePerson,
    required this.onSplitPerson,
  });

  final List<PersonCluster> people;
  final List<ModelArtifact> models;
  final String libraryRoot;
  final PrivacyStatus? privacyStatus;
  final Future<void> Function() onIndexPeople;
  final Future<void> Function() onResetPeople;
  final Future<void> Function(String displayName) onCreateManualPerson;
  final Future<List<Asset>> Function(String id) onFetchPersonAssets;
  final Future<PersonCluster> Function(
    String id, {
    required List<String> assetIds,
  })
  onRemovePersonAssets;
  final Future<void> Function() onPeopleChanged;
  final Future<void> Function(String id, String displayName) onRenamePerson;
  final Future<void> Function(String id, bool hidden) onHidePerson;
  final Future<void> Function(String id) onRejectPersonMatch;
  final Future<void> Function(String targetId, List<String> sourceIds)
  onMergePerson;
  final Future<void> Function(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  })
  onSplitPerson;

  @override
  Widget build(BuildContext context) {
    final faceModels = models
        .where(
          (model) =>
              model.task == ModelTask.faceDetection ||
              model.task == ModelTask.faceEmbedding,
        )
        .toList();
    final detectionReady = faceModels.any(
      (model) =>
          model.task == ModelTask.faceDetection &&
          model.installed &&
          model.approvedForPersonalFamilyUse,
    );
    final embeddingReady = faceModels.any(
      (model) =>
          model.task == ModelTask.faceEmbedding &&
          model.installed &&
          model.approvedForPersonalFamilyUse,
    );
    final encrypted =
        privacyStatus?.encryption.sensitiveIndexingAllowed ?? false;
    final canIndex = encrypted && detectionReady && embeddingReady;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _FaceGateCard(
          encrypted: encrypted,
          canIndex: canIndex,
          faceModels: faceModels,
          onIndexPeople: onIndexPeople,
          onResetPeople: onResetPeople,
          onCreateManualPerson: onCreateManualPerson,
          onPeopleChanged: onPeopleChanged,
        ),
        const SizedBox(height: 16),
        if (people.isEmpty)
          EmptyStatePanel(
            icon: Icons.face_outlined,
            title: 'No people yet',
            message:
                'You can manually create people and assign photos now. Automatic face clustering stays blocked until encryption is active and local face models are approved with pinned hashes.',
            actionLabel: 'Create manual person',
            onAction: () => _showCreatePersonDialog(context),
          )
        else
          for (final person in people) ...[
            _PersonCard(
              person: person,
              people: people,
              libraryRoot: libraryRoot,
              onFetchPersonAssets: onFetchPersonAssets,
              onRemovePersonAssets: onRemovePersonAssets,
              onPeopleChanged: onPeopleChanged,
              onRenamePerson: onRenamePerson,
              onHidePerson: onHidePerson,
              onRejectPersonMatch: onRejectPersonMatch,
              onMergePerson: onMergePerson,
              onSplitPerson: onSplitPerson,
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  Future<void> _showCreatePersonDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create manual person'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Display name',
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
    if (name != null && name.trim().isNotEmpty) {
      await onCreateManualPerson(name.trim());
      await onPeopleChanged();
    }
  }
}

class _FaceGateCard extends StatelessWidget {
  const _FaceGateCard({
    required this.encrypted,
    required this.canIndex,
    required this.faceModels,
    required this.onIndexPeople,
    required this.onResetPeople,
    required this.onCreateManualPerson,
    required this.onPeopleChanged,
  });

  final bool encrypted;
  final bool canIndex;
  final List<ModelArtifact> faceModels;
  final Future<void> Function() onIndexPeople;
  final Future<void> Function() onResetPeople;
  final Future<void> Function(String displayName) onCreateManualPerson;
  final Future<void> Function() onPeopleChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  canIndex ? Icons.verified_user_outlined : Icons.lock_outline,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    canIndex
                        ? 'Local face indexing is ready'
                        : 'Local face indexing is gated',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'People organization is biometric, so the app refuses face indexing until encrypted storage is active and both local face models are approved. Photos and face templates never leave this machine.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text(
                    encrypted
                        ? 'Encrypted DB active'
                        : 'Encryption unavailable',
                  ),
                ),
                for (final model in faceModels)
                  Chip(
                    label: Text(
                      '${model.task.label}: ${model.installStatus.label}',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: onIndexPeople,
                  icon: const Icon(Icons.face_retouching_natural_outlined),
                  label: Text(
                    canIndex
                        ? 'Start local face indexing'
                        : 'Check face indexing gate',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _confirmResetPeople(context),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Reset people data'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showCreatePersonDialog(context),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Create manual person'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreatePersonDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create manual person'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Display name',
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
    if (name != null && name.trim().isNotEmpty) {
      await onCreateManualPerson(name.trim());
      await onPeopleChanged();
    }
  }

  Future<void> _confirmResetPeople(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reset people data?'),
          content: const Text(
            'This removes local people labels and face template assignments. Media files stay in the library.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset people data'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    try {
      await onResetPeople();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('People data reset.')));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.person,
    required this.people,
    required this.libraryRoot,
    required this.onFetchPersonAssets,
    required this.onRemovePersonAssets,
    required this.onPeopleChanged,
    required this.onRenamePerson,
    required this.onHidePerson,
    required this.onRejectPersonMatch,
    required this.onMergePerson,
    required this.onSplitPerson,
  });

  final PersonCluster person;
  final List<PersonCluster> people;
  final String libraryRoot;
  final Future<List<Asset>> Function(String id) onFetchPersonAssets;
  final Future<PersonCluster> Function(
    String id, {
    required List<String> assetIds,
  })
  onRemovePersonAssets;
  final Future<void> Function() onPeopleChanged;
  final Future<void> Function(String id, String displayName) onRenamePerson;
  final Future<void> Function(String id, bool hidden) onHidePerson;
  final Future<void> Function(String id) onRejectPersonMatch;
  final Future<void> Function(String targetId, List<String> sourceIds)
  onMergePerson;
  final Future<void> Function(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  })
  onSplitPerson;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(20),
        onTap: () => _showAssets(context),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(person.displayName.characters.first.toUpperCase()),
        ),
        title: Text(person.displayName),
        subtitle: Text(
          '${person.assetIds.length} assets • ${person.faceTemplateIds.length} face templates',
        ),
        trailing: Wrap(
          spacing: 8,
          children: [
            Chip(label: Text(person.derived.modelName)),
            if (person.hidden) const Chip(label: Text('Hidden')),
            PopupMenuButton<_PeopleAction>(
              onSelected: (action) => _handleAction(context, action),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _PeopleAction.rename,
                  child: Text('Rename'),
                ),
                PopupMenuItem(
                  value: _PeopleAction.hide,
                  child: Text(person.hidden ? 'Unhide' : 'Hide'),
                ),
                const PopupMenuItem(
                  value: _PeopleAction.reject,
                  child: Text('Reject match'),
                ),
                if (people.length > 1)
                  const PopupMenuItem(
                    value: _PeopleAction.merge,
                    child: Text('Merge another person into this'),
                  ),
                if (person.faceTemplateIds.isNotEmpty)
                  const PopupMenuItem(
                    value: _PeopleAction.split,
                    child: Text('Split first face template'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAssets(BuildContext context) async {
    final assetsFuture = onFetchPersonAssets(person.id);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(person.displayName),
          content: SizedBox(
            width: 920,
            child: FutureBuilder<List<Asset>>(
              future: assetsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Text(
                    'Unable to load assigned assets: ${snapshot.error}',
                  );
                }

                final assets = snapshot.data ?? const [];
                if (assets.isEmpty) {
                  return const EmptyStatePanel(
                    icon: Icons.photo_library_outlined,
                    title: 'No assigned assets',
                    message:
                        'Assign photos from the timeline to build this local people group manually.',
                  );
                }

                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${assets.length} assigned asset(s). Select one to remove the manual people assignment.',
                      ),
                      const SizedBox(height: 16),
                      AssetGrid(
                        assets: assets,
                        libraryRoot: libraryRoot,
                        onAssetSelected: (asset) async {
                          await _removeAssetAssignment(context, asset);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _removeAssetAssignment(BuildContext context, Asset asset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove person assignment?'),
          content: Text(
            'This only removes ${asset.originalFilename} from ${person.displayName}. It does not delete or move the media file.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove assignment'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    await onRemovePersonAssets(person.id, assetIds: [asset.id]);
    await onPeopleChanged();
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Person assignment removed.')),
      );
    }
  }

  Future<void> _handleAction(BuildContext context, _PeopleAction action) async {
    switch (action) {
      case _PeopleAction.rename:
        final name = await _askForText(
          context,
          title: 'Rename person',
          initialValue: person.displayName,
        );
        if (!context.mounted) {
          return;
        }
        if (name != null && name.trim().isNotEmpty) {
          await _runPersonMutation(
            context,
            () => onRenamePerson(person.id, name.trim()),
            'Person renamed.',
          );
        }
        return;
      case _PeopleAction.hide:
        await _runPersonMutation(
          context,
          () => onHidePerson(person.id, !person.hidden),
          person.hidden ? 'Person unhidden.' : 'Person hidden.',
        );
        return;
      case _PeopleAction.reject:
        await _runPersonMutation(
          context,
          () => onRejectPersonMatch(person.id),
          'Face match rejected.',
        );
        return;
      case _PeopleAction.merge:
        final sourceId = await _choosePersonToMerge(context);
        if (!context.mounted) {
          return;
        }
        if (sourceId != null) {
          await _runPersonMutation(
            context,
            () => onMergePerson(person.id, [sourceId]),
            'People merged.',
          );
        }
        return;
      case _PeopleAction.split:
        await _runPersonMutation(
          context,
          () => onSplitPerson(
            person.id,
            faceTemplateIds: [person.faceTemplateIds.first],
            newDisplayName: 'Split from ${person.displayName}',
          ),
          'Face template split into a new person.',
        );
        return;
    }
  }

  Future<void> _runPersonMutation(
    BuildContext context,
    Future<void> Function() mutation,
    String successMessage,
  ) async {
    try {
      await mutation();
      await onPeopleChanged();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<String?> _choosePersonToMerge(BuildContext context) {
    final candidates = people.where((item) => item.id != person.id).toList();
    if (candidates.isEmpty) {
      return Future.value(null);
    }

    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Merge which person?'),
        children: [
          for (final candidate in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(candidate.id),
              child: Text(candidate.displayName),
            ),
        ],
      ),
    );
  }

  Future<String?> _askForText(
    BuildContext context, {
    required String title,
    required String initialValue,
  }) async {
    var value = initialValue;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initialValue,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onChanged: (text) => value = text,
          onFieldSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(value),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

enum _PeopleAction { rename, hide, reject, merge, split }
