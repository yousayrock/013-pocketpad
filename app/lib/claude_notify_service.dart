import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Claude Code通知（claude_notify）のロック画面/バックグラウンド対応。
///
/// - flutter_local_notifications: 実際のアラート表示（音+バイブ+全画面インテント）
/// - flutter_foreground_task: アプリがバックグラウンドに回ってもAndroidに
///   プロセスを殺されないよう、フォアグラウンドサービスとして常駐させる
///   （そうしないとWebSocket接続自体が切られ、通知を受け取れない）
const _channelId = 'claude_notify';
// フォアグラウンド用は別チャンネル。Importance.defaultImportanceだと
// ヘッドアップ表示（通知バーが上から降りてくる演出）にはならないが、
// 音・バイブはSystemSound.clickよりずっとはっきり鳴る。
const _fgChannelId = 'claude_notify_fg';
const _foregroundServiceId = 9013;

final _plugin = FlutterLocalNotificationsPlugin();

/// main()の冒頭・runApp前に呼ぶ。
void initClaudeNotifyService() {
  FlutterForegroundTask.initCommunicationPort();
}

/// 通知チャンネル作成＋権限リクエスト。TrackpadScreen初期化時に1回呼ぶ。
Future<void> setupClaudeNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _plugin.initialize(
      settings: const InitializationSettings(android: androidInit));

  final androidImpl = _plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
    _channelId,
    'Claude Code通知',
    description: '作業完了・承認待ちの通知（音・バイブ・全画面表示）',
    importance: Importance.max,
  ));
  await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
    _fgChannelId,
    'Claude Code通知（アプリ使用中）',
    description: 'アプリを見ている間の通知音・バイブ（通知バーは出ません）',
    importance: Importance.defaultImportance,
  ));
  await androidImpl?.requestNotificationsPermission();
  await androidImpl?.requestFullScreenIntentPermission();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'pocketpad_keepalive',
      channelName: 'PocketPad接続維持',
      channelDescription: 'バックグラウンドでもPCとの接続とClaude Code通知を維持します',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(60000),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

@pragma('vm:entry-point')
void _keepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

/// 何もしない（プロセスを生かしておくためだけの）TaskHandler。
class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}

/// PC接続確立時に呼ぶ。アプリがバックグラウンドでも接続とClaude通知を維持する。
Future<void> startClaudeKeepAliveService() async {
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    serviceId: _foregroundServiceId,
    notificationTitle: 'PocketPad 接続中',
    notificationText: 'PCと接続中です。タップでアプリに戻ります',
    callback: _keepAliveCallback,
  );
}

/// 切断/終了時に呼ぶ。
Future<void> stopClaudeKeepAliveService() async {
  if (await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.stopService();
  }
}

/// フォアグラウンド（画面点灯中にアプリを見ている）時のアラート。
/// Importance.defaultImportanceの通知チャンネルを使う＝ヘッドアップ表示
/// （上から降りてくる通知バー）は出ないが、通知音・バイブはしっかり鳴る。
/// 視覚的な演出は呼び出し側の画面フラッシュに任せる。
Future<void> playForegroundAlert(String event, String message) async {
  HapticFeedback.heavyImpact();
  final vibrationPattern = Int64List.fromList([0, 250]);
  final androidDetails = AndroidNotificationDetails(
    _fgChannelId,
    'Claude Code通知（アプリ使用中）',
    channelDescription: 'アプリを見ている間の通知音・バイブ',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    enableVibration: true,
    vibrationPattern: vibrationPattern,
  );
  await _plugin.show(
    id: event == 'notification' ? 4 : 3,
    title: event == 'notification' ? 'Claude Codeが承認待ちです' : 'Claude Codeが完了しました',
    body: message,
    notificationDetails: NotificationDetails(android: androidDetails),
  );
}

/// claude_notify受信時、バックグラウンド/ロック中に呼ぶ。フォアグラウンド時は
/// システム通知自体を出さない（画面に通知バーが出て邪魔になるため）。
Future<void> showClaudeAlert(String event, String message) async {
  final vibrationPattern = Int64List.fromList([0, 400, 200, 400]);
  final androidDetails = AndroidNotificationDetails(
    _channelId,
    'Claude Code通知',
    channelDescription: '作業完了・承認待ちの通知',
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: true,
    enableVibration: true,
    vibrationPattern: vibrationPattern,
    category: AndroidNotificationCategory.alarm,
  );
  await _plugin.show(
    id: event == 'notification' ? 2 : 1,
    title: event == 'notification' ? 'Claude Codeが承認待ちです' : 'Claude Codeが完了しました',
    body: message,
    notificationDetails: NotificationDetails(android: androidDetails),
  );
}
