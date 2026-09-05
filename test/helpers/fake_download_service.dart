import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hermes_ui/core/cache/app_database.dart';
import 'package:hermes_ui/core/cache/cache_providers.dart';
import 'package:hermes_ui/features/downloads/download_providers.dart';
import 'package:hermes_ui/features/downloads/download_repository.dart';
import 'package:hermes_ui/features/downloads/download_save_service.dart';
import 'package:hermes_ui/features/notifications/notification_providers.dart';
import 'package:hermes_ui/features/notifications/turn_notification_service.dart';

class FakeTurnNotificationService implements TurnNotificationService {
  final List<(String id, String fileName, int size)> downloadCompletedCalls =
      [];

  @override
  Future<void> notifyDownloadCompleted(
    String downloadId,
    String fileName,
    int byteSize,
  ) async {
    downloadCompletedCalls.add((downloadId, fileName, byteSize));
  }

  @override
  Future<void> notifyTurnCompleted(
    String sessionId,
    String title,
    String preview,
  ) async {}

  @override
  Future<void> notifyClarificationNeeded(
    String sessionId,
    String question,
  ) async {}

  @override
  Future<void> notifySessionError(
    String sessionId,
    String title,
    String preview,
  ) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> areNotificationsEnabled() async => true;

  @override
  Future<String?> getLaunchSessionId() async => null;
}

List<Override> createDownloadTestOverrides({
  AppDatabase? db,
  Directory? tempDir,
  DownloadBytesDownloader? downloader,
  TurnNotificationService? notificationService,
}) {
  final database = db ?? AppDatabase.memory();
  return [
    appDatabaseProvider.overrideWithValue(database),
    downloadRepositoryProvider.overrideWithValue(DownloadRepository(database)),
    downloadSaveServiceProvider.overrideWithValue(
      DownloadSaveService(
        destinationDirOverride:
            tempDir ?? Directory.systemTemp.createTempSync('hermes_dl_test_'),
      ),
    ),
    turnNotificationServiceProvider.overrideWithValue(
      notificationService ?? FakeTurnNotificationService(),
    ),
    downloadDownloaderProvider.overrideWithValue(
      downloader ??
          ((uri, {onProgress}) async => Uint8List.fromList([1, 2, 3, 4])),
    ),
  ];
}
