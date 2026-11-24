/// Queue ETA in human units; callers supply the smoothed rate estimate.
String transferEta(int? seconds) {
  if (seconds == null || seconds < 0) return '—';
  final hours = seconds ~/ 3600,
      minutes = seconds % 3600 ~/ 60,
      rest = seconds % 60;
  return '约 ${hours > 0 ? '$hours小时' : ''}${hours > 0 || minutes > 0 ? '$minutes分' : ''}$rest秒';
}
