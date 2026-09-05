import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/cache_providers.dart';
import '../../core/connections/connection_providers.dart';
import 'download_controller.dart';
import 'download_models.dart';
import 'download_repository.dart';
import 'download_save_service.dart';

/// 下载存储保存服务 Provider。
final downloadSaveServiceProvider = Provider<DownloadSaveService>((ref) {
  return DownloadSaveService();
});

/// 下载记录持久化仓储 Provider。
final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DownloadRepository(db);
});

/// 下载执行器签名：可选 [onProgress] 回调（received, total；total=-1 未知）。
typedef DownloadBytesDownloader = Future<Uint8List> Function(
  Uri url, {
  void Function(int receivedBytes, int totalBytes)? onProgress,
});

/// 下载网络执行器 Provider（默认走激活连接的 ApiClient.downloadData）。
final downloadDownloaderProvider = Provider<DownloadBytesDownloader>((ref) {
  final client = ref.watch(apiClientProvider);
  return (url, {onProgress}) =>
      client.downloadData(url, onReceiveProgress: onProgress);
});

/// 下载状态与队列控制器 Provider。
final downloadControllerProvider =
    NotifierProvider<DownloadController, DownloadState>(DownloadController.new);

/// 全部下载任务列表 Provider。
final downloadTasksProvider = Provider<List<DownloadTask>>((ref) {
  final state = ref.watch(downloadControllerProvider);
  return state.tasks;
});

/// 活跃中（排队中 / 正在下载）任务计数 Provider。
final activeDownloadsCountProvider = Provider<int>((ref) {
  final state = ref.watch(downloadControllerProvider);
  return state.tasks.where((t) => t.isActive).length;
});
