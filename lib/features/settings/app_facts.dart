import '../../core/constants.dart';

/// Plain-language renderings of MiniGo's configured limits and lifetimes, so
/// every screen that quotes them stays in step with [AppConstants].
abstract final class AppFacts {
  /// "24 hours"
  static String get transferLifetime => _hours(AppConstants.transferTtlHours);

  /// "7 days"
  static String get recordRetention =>
      _days(AppConstants.transferRecordRetentionDays);

  /// "90 days"
  static String get inactiveCodeRetention =>
      _days(AppConstants.inactiveIdentityRetentionDays);

  /// "100 MB"
  static String get maxFileSize =>
      '${AppConstants.maxFileSizeBytes ~/ (1024 * 1024)} MB';

  static int get maxFiles => AppConstants.maxFilesPerTransfer;

  /// "30 minutes, 1 hour, or 2 hours"
  static String get roomLifetimes => _orList(
        AppConstants.roomLifetimeMinutesOptions.map(_minutes).toList(),
      );

  static String _hours(int hours) => hours == 1 ? '1 hour' : '$hours hours';

  static String _days(int days) => days == 1 ? '1 day' : '$days days';

  static String _minutes(int minutes) =>
      minutes % 60 == 0 ? _hours(minutes ~/ 60) : '$minutes minutes';

  static String _orList(List<String> items) {
    if (items.length < 2) return items.join();
    if (items.length == 2) return '${items.first} or ${items.last}';
    return '${items.sublist(0, items.length - 1).join(', ')}, or ${items.last}';
  }
}
