import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:video_trimmer/video_trimmer.dart' as vt;

import '../../models/gallery_models.dart' show MobileAssetSummary;
import '../../theme/app_theme.dart';

class MobileMediaViewer extends StatefulWidget {
  const MobileMediaViewer.local({
    super.key,
    required AssetEntity asset,
    required this.canUpload,
    required this.onUpload,
  }) : localAsset = asset,
       groupAsset = null,
       loadOriginalFile = null,
       saveOriginal = null;

  const MobileMediaViewer.group({
    super.key,
    required MobileAssetSummary asset,
    required this.loadOriginalFile,
    required this.saveOriginal,
  }) : groupAsset = asset,
       localAsset = null,
       canUpload = false,
       onUpload = null;

  final AssetEntity? localAsset;
  final MobileAssetSummary? groupAsset;
  final bool canUpload;
  final Future<void> Function()? onUpload;
  final Future<File> Function()? loadOriginalFile;
  final Future<File> Function()? saveOriginal;

  @override
  State<MobileMediaViewer> createState() => _MobileMediaViewerState();
}

class _MobileMediaViewerState extends State<MobileMediaViewer> {
  late Future<File?> _fileFuture;
  var _showDetails = false;
  var _busy = false;
  String? _status;

  bool get _isLocal => widget.localAsset != null;

  bool get _isVideo {
    final local = widget.localAsset;
    if (local != null) {
      return local.type == AssetType.video;
    }
    final group = widget.groupAsset!;
    return group.mediaKind == 'video' ||
        group.mimeType.toLowerCase().startsWith('video/');
  }

  bool get _isImage {
    final local = widget.localAsset;
    if (local != null) {
      return local.type == AssetType.image;
    }
    final group = widget.groupAsset!;
    return group.mediaKind == 'photo' ||
        group.mimeType.toLowerCase().startsWith('image/');
  }

  bool get _canEdit => _isImage || _isVideo;

  String get _kindLabel {
    final local = widget.localAsset;
    if (local != null) {
      return local.type == AssetType.video ? 'video' : 'photo';
    }
    return switch (widget.groupAsset!.mediaKind.toLowerCase()) {
      'photo' => 'photo',
      'video' => 'video',
      'document' => 'document',
      'audio' => 'audio',
      'archive' => 'archive',
      'text' => 'text',
      'other' => 'file',
      _ => widget.groupAsset!.mediaKind,
    };
  }

  String get _kindTitle {
    final label = _kindLabel.trim();
    if (label.isEmpty) {
      return 'File';
    }
    return '${label[0].toUpperCase()}${label.substring(1)}';
  }

  IconData get _kindIcon {
    final group = widget.groupAsset;
    if (_isVideo) {
      return Icons.play_circle_outline;
    }
    if (_isImage) {
      return Icons.image_outlined;
    }
    final kind = group?.mediaKind.toLowerCase() ?? '';
    final mime = group?.mimeType.toLowerCase() ?? '';
    if (kind == 'document' || mime == 'application/pdf') {
      return Icons.description_outlined;
    }
    if (kind == 'audio' || mime.startsWith('audio/')) {
      return Icons.audiotrack_outlined;
    }
    if (kind == 'archive') {
      return Icons.folder_zip_outlined;
    }
    if (kind == 'text' || mime.startsWith('text/')) {
      return Icons.article_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  bool get _isAvailable =>
      widget.localAsset != null ||
      (widget.groupAsset?.available == true && widget.loadOriginalFile != null);

  String get _title =>
      widget.localAsset?.title ??
      widget.groupAsset?.originalFilename ??
      'Media item';

  DateTime get _capturedAt =>
      widget.localAsset?.createDateTime ?? widget.groupAsset!.capturedAt;

  @override
  void initState() {
    super.initState();
    _fileFuture = _resolveOriginalFile();
  }

  Future<File?> _resolveOriginalFile() async {
    final local = widget.localAsset;
    if (local != null) {
      return await local.originFile ?? await local.file;
    }
    if (!_isAvailable) {
      return null;
    }
    return widget.loadOriginalFile!();
  }

  Future<File> _requireFile() async {
    final file = await _fileFuture;
    if (file == null) {
      throw StateError('Original is not available on this device.');
    }
    return file;
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _share() {
    return _runAction(() async {
      final file = await _requireFile();
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: _title, text: _title),
      );
    });
  }

  Future<void> _saveOriginal() {
    final save = widget.saveOriginal;
    if (save == null) {
      return Future<void>.value();
    }
    return _runAction(() async {
      final file = await save();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Saved original to ${file.path}.';
      });
    });
  }

  Future<void> _addToGroup() {
    final upload = widget.onUpload;
    if (upload == null) {
      return Future<void>.value();
    }
    return _runAction(() async {
      await upload();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Queued this item for the same-LAN group.';
      });
    });
  }

  Future<void> _edit() {
    return _runAction(() async {
      if (!_canEdit) {
        throw StateError('This file type does not have an editor.');
      }
      final navigator = Navigator.of(context);
      final file = await _requireFile();
      if (!mounted) {
        return;
      }
      final result = _isVideo
          ? await navigator.push<String>(
              MaterialPageRoute(
                builder: (_) => MobileVideoTrimScreen(
                  sourceFile: file,
                  title: _title,
                  creationDate: _capturedAt,
                ),
              ),
            )
          : await navigator.push<String>(
              MaterialPageRoute(
                builder: (_) => MobilePhotoEditorScreen(
                  sourceFile: file,
                  title: _title,
                  creationDate: _capturedAt,
                ),
              ),
            );
      if (!mounted || result == null) {
        return;
      }
      setState(() {
        _status = result;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: _busy || !_isAvailable ? null : _share,
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_outlined),
          ),
          IconButton(
            onPressed: _busy || !_isAvailable ? null : _edit,
            tooltip: _isVideo ? 'Trim video' : 'Edit photo',
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            onPressed: () => setState(() => _showDetails = !_showDetails),
            tooltip: 'Details',
            icon: Icon(_showDetails ? Icons.info : Icons.info_outline),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(child: _buildPreview(theme)),
            _buildActionBar(theme),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  _status!,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 180),
              crossFadeState: _showDetails
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: _DetailsDrawer(child: _buildDetails()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.black),
      child: FutureBuilder<File?>(
        future: _fileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done &&
              widget.groupAsset != null &&
              widget.groupAsset!.available) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ViewerMessage(
              icon: Icons.warning_amber_outlined,
              title: 'Original unavailable',
              message: '${snapshot.error}',
            );
          }
          final file = snapshot.data;
          if (_isVideo) {
            if (file == null) {
              return const _ViewerMessage(
                icon: Icons.cloud_off_outlined,
                title: 'Video stored elsewhere',
                message:
                    'Connect the same-LAN device that has the original to play it here.',
              );
            }
            return _InlineVideoPlayer(file: file);
          }
          if (_isImage && file != null) {
            return InteractiveViewer(
              minScale: 0.7,
              maxScale: 5,
              child: Center(
                child: Image.file(
                  file,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => _thumbnailFallback(),
                ),
              ),
            );
          }
          if (!_isImage) {
            return _ViewerMessage(
              icon: _kindIcon,
              title: file == null ? 'Original unavailable' : _title,
              message: file == null
                  ? 'Connect the same-LAN device that has the original.'
                  : '$_kindTitle file ready.',
            );
          }
          return _thumbnailFallback();
        },
      ),
    );
  }

  Widget _thumbnailFallback() {
    final local = widget.localAsset;
    if (local == null) {
      return _ViewerMessage(
        icon: Icons.cloud_off_outlined,
        title: '$_kindTitle stored elsewhere',
        message:
            'Connect the same-LAN device that has the original to preview it here.',
      );
    }
    return FutureBuilder<Uint8List?>(
      future: local.thumbnailDataWithSize(
        const ThumbnailSize.square(1600),
        quality: 96,
      ),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return const _ViewerMessage(
            icon: Icons.image_outlined,
            title: 'Preview unavailable',
            message: 'Android media storage did not return a preview.',
          );
        }
        return InteractiveViewer(
          minScale: 0.7,
          maxScale: 5,
          child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
        );
      },
    );
  }

  Widget _buildActionBar(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            _ViewerActionButton(
              icon: Icons.ios_share_outlined,
              label: 'Share',
              onPressed: _busy || !_isAvailable ? null : _share,
            ),
            _ViewerActionButton(
              icon: _isVideo ? Icons.content_cut : Icons.tune,
              label: _isVideo ? 'Trim' : 'Edit',
              onPressed: _busy || !_isAvailable || !_canEdit ? null : _edit,
            ),
            if (_isLocal)
              _ViewerActionButton(
                icon: Icons.cloud_upload_outlined,
                label: 'Add',
                onPressed: _busy || !widget.canUpload ? null : _addToGroup,
              )
            else
              _ViewerActionButton(
                icon: Icons.download_outlined,
                label: 'Save',
                onPressed: _busy || !_isAvailable ? null : _saveOriginal,
              ),
            _ViewerActionButton(
              icon: _showDetails ? Icons.expand_more : Icons.info_outline,
              label: 'Details',
              onPressed: () => setState(() => _showDetails = !_showDetails),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails() {
    final local = widget.localAsset;
    final group = widget.groupAsset;
    final rows = <Widget>[
      _DetailRow(label: 'Filename', value: _title),
      _DetailRow(
        label: 'Source',
        value: _isLocal ? 'This Android device' : 'Same-LAN group',
      ),
      _DetailRow(label: 'Kind', value: _kindLabel),
      _DetailRow(
        label: 'Captured',
        value: DateFormat.yMMMd().add_jm().format(_capturedAt.toLocal()),
      ),
      if (local != null) ...[
        _DetailRow(
          label: 'Dimensions',
          value: '${local.orientatedWidth} x ${local.orientatedHeight}',
        ),
        if (local.type == AssetType.video)
          _DetailRow(
            label: 'Duration',
            value: _formatDuration(local.videoDuration),
          ),
        _DetailRow(
          label: 'Album path',
          value: local.relativePath ?? 'Device media store',
        ),
        if (local.mimeType != null)
          _DetailRow(label: 'MIME type', value: local.mimeType!),
        if (local.latLng != null)
          _DetailRow(
            label: 'GPS',
            value:
                '${local.latLng!.latitude.toStringAsFixed(5)}, ${local.latLng!.longitude.toStringAsFixed(5)}',
          ),
      ],
      if (group != null) ...[
        _DetailRow(label: 'MIME type', value: group.mimeType),
        _DetailRow(label: 'Bytes', value: _formatBytes(group.bytes)),
        _DetailRow(
          label: 'Available',
          value: group.available ? 'Here' : 'Stored elsewhere',
        ),
        _DetailRow(label: 'Content hash', value: group.contentHash),
      ],
      FutureBuilder<File?>(
        future: _fileFuture,
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file == null) {
            return const SizedBox.shrink();
          }
          final length = file.existsSync() ? file.lengthSync() : null;
          return Column(
            children: [
              if (length != null)
                _DetailRow(label: 'File size', value: _formatBytes(length)),
              _DetailRow(label: 'Local path', value: file.path),
            ],
          );
        },
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _InlineVideoPlayer extends StatefulWidget {
  const _InlineVideoPlayer({required this.file});

  final File file;

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  late final VideoPlayerController _controller;
  late final Future<void> _initializeFuture;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file);
    _initializeFuture = _controller.initialize().then((_) {
      _controller.setLooping(false);
      if (mounted) {
        setState(() {});
      }
    });
    _controller.addListener(_handleTick);
  }

  void _handleTick() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleTick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initializeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !_controller.value.isInitialized) {
          return _ViewerMessage(
            icon: Icons.warning_amber_outlined,
            title: 'Video could not play',
            message: '${snapshot.error ?? 'Unsupported video format.'}',
          );
        }
        final value = _controller.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio == 0
                    ? 16 / 9
                    : value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.82),
                    ],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 36, 16, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          IconButton.filled(
                            onPressed: () {
                              value.isPlaying
                                  ? _controller.pause()
                                  : _controller.play();
                            },
                            icon: Icon(
                              value.isPlaying ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class MobilePhotoEditorScreen extends StatefulWidget {
  const MobilePhotoEditorScreen({
    super.key,
    required this.sourceFile,
    required this.title,
    required this.creationDate,
  });

  final File sourceFile;
  final String title;
  final DateTime creationDate;

  @override
  State<MobilePhotoEditorScreen> createState() =>
      _MobilePhotoEditorScreenState();
}

class _MobilePhotoEditorScreenState extends State<MobilePhotoEditorScreen> {
  var _quarterTurns = 0;
  var _flipHorizontal = false;
  var _saving = false;
  String? _status;

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        throw StateError('Photo library permission is required to save edits.');
      }
      final bytes = await widget.sourceFile.readAsBytes();
      var decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw StateError('This image format could not be edited.');
      }
      if (_flipHorizontal) {
        decoded = img.flipHorizontal(decoded);
      }
      final turns = _quarterTurns % 4;
      if (turns != 0) {
        decoded = img.copyRotate(decoded, angle: turns * 90);
      }
      final encoded = Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
      final filename = _editedFilename(widget.title, extension: 'jpg');
      await PhotoManager.editor.saveImage(
        encoded,
        filename: filename,
        title: filename,
        creationDate: DateTime.now(),
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop('Saved edited photo as $filename.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Edit Photo'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving' : 'Save copy'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..scaleByDouble(
                        _flipHorizontal ? -1.0 : 1.0,
                        1.0,
                        1.0,
                        1.0,
                      ),
                    child: RotatedBox(
                      quarterTurns: _quarterTurns,
                      child: Image.file(widget.sourceFile, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _status!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            Material(
              color: AppColors.canvas,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _ViewerActionButton(
                      icon: Icons.rotate_left,
                      label: 'Left',
                      onPressed: () => setState(
                        () => _quarterTurns = (_quarterTurns - 1) % 4,
                      ),
                    ),
                    _ViewerActionButton(
                      icon: Icons.rotate_right,
                      label: 'Right',
                      onPressed: () => setState(
                        () => _quarterTurns = (_quarterTurns + 1) % 4,
                      ),
                    ),
                    _ViewerActionButton(
                      icon: Icons.flip,
                      label: 'Flip',
                      onPressed: () =>
                          setState(() => _flipHorizontal = !_flipHorizontal),
                    ),
                    _ViewerActionButton(
                      icon: Icons.restart_alt,
                      label: 'Reset',
                      onPressed: () => setState(() {
                        _quarterTurns = 0;
                        _flipHorizontal = false;
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MobileVideoTrimScreen extends StatefulWidget {
  const MobileVideoTrimScreen({
    super.key,
    required this.sourceFile,
    required this.title,
    required this.creationDate,
  });

  final File sourceFile;
  final String title;
  final DateTime creationDate;

  @override
  State<MobileVideoTrimScreen> createState() => _MobileVideoTrimScreenState();
}

class _MobileVideoTrimScreenState extends State<MobileVideoTrimScreen> {
  final _trimmer = vt.Trimmer();
  late final Future<void> _loadFuture;
  var _start = 0.0;
  var _end = 0.0;
  var _saving = false;
  var _playing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _loadFuture = _trimmer.loadVideo(videoFile: widget.sourceFile);
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        throw StateError('Photo library permission is required to save edits.');
      }
      String? outputPath;
      await _trimmer.saveTrimmedVideo(
        startValue: _start,
        endValue: _end,
        storageDir: vt.StorageDir.temporaryDirectory,
        videoFolderName: 'PrivateGalleryEdits',
        videoFileName: _editedFilename(
          widget.title,
          extension: 'mp4',
        ).replaceAll(RegExp(r'\.mp4$'), ''),
        onSave: (path) => outputPath = path,
      );
      final savedPath = outputPath;
      if (savedPath == null || savedPath.isEmpty) {
        throw StateError('Trimmed video was not created.');
      }
      final filename = _editedFilename(widget.title, extension: 'mp4');
      await PhotoManager.editor.saveVideo(
        File(savedPath),
        title: filename,
        creationDate: DateTime.now(),
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop('Saved trimmed video as $filename.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Trim Video'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving' : 'Save copy'),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<void>(
          future: _loadFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _ViewerMessage(
                icon: Icons.warning_amber_outlined,
                title: 'Video could not load',
                message: '${snapshot.error}',
              );
            }
            return Column(
              children: [
                if (_saving) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: vt.VideoViewer(trimmer: _trimmer)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: vt.TrimViewer(
                    trimmer: _trimmer,
                    viewerHeight: 56,
                    viewerWidth: MediaQuery.sizeOf(context).width - 32,
                    maxVideoLength: const Duration(minutes: 10),
                    durationTextStyle: const TextStyle(color: Colors.white),
                    onChangeStart: (value) => _start = value,
                    onChangeEnd: (value) => _end = value,
                    onChangePlaybackState: (playing) {
                      if (mounted) {
                        setState(() => _playing = playing);
                      }
                    },
                  ),
                ),
                if (_status != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _status!,
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: _saving
                        ? null
                        : () async {
                            final playing = await _trimmer.videoPlaybackControl(
                              startValue: _start,
                              endValue: _end,
                            );
                            if (mounted) {
                              setState(() => _playing = playing);
                            }
                          },
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    label: Text(_playing ? 'Pause preview' : 'Play selection'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ViewerActionButton extends StatelessWidget {
  const _ViewerActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: TextButton(
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _DetailsDrawer extends StatelessWidget {
  const _DetailsDrawer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.min(MediaQuery.sizeOf(context).height * 0.42, 360),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
            Text('Details', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _ViewerMessage extends StatelessWidget {
  const _ViewerMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 54),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) {
    return 'Unknown';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  final precision = value >= 10 || index == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[index]}';
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _editedFilename(String title, {required String extension}) {
  final base = title
      .replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final safeBase = base.isEmpty ? 'private_gallery_edit' : base;
  final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
  return '${safeBase}_edit_$stamp.$extension';
}
