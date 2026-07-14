import 'package:meta/meta.dart';

import '../native/native_app_start.dart';
import '../utils/internal_logger.dart';
import 'app_start_info.dart';

const _maxSnapshotAge = Duration(seconds: 60);

/// Intrinsic app-start timing captured before the first Flutter frame.
@internal
final class AppStartData {
  AppStartData({
    required this.type,
    required this.processStartTimestamp,
    required this.pluginRegistrationTimestamp,
    required this.sentrySetupTimestamp,
    required this.nativePhaseIntervals,
  });

  final AppStartType type;
  final DateTime processStartTimestamp;
  final DateTime pluginRegistrationTimestamp;
  final DateTime sentrySetupTimestamp;
  final List<AppStartPhaseInterval> nativePhaseIntervals;
}

@internal
final class AppStartPhaseInterval {
  AppStartPhaseInterval({
    required this.startTimestamp,
    required this.endTimestamp,
    required this.description,
  });

  final DateTime startTimestamp;
  final DateTime endTimestamp;
  final String description;
}

/// Parses a start-only native timing snapshot for standalone app start.
@internal
AppStartData? parseStandaloneAppStart(
  NativeAppStart nativeAppStart, {
  required DateTime sentrySetupTimestamp,
  required DateTime snapshotTimestamp,
}) {
  final processStart =
      DateTime.fromMillisecondsSinceEpoch(nativeAppStart.appStartTime).toUtc();
  final pluginRegistration = DateTime.fromMillisecondsSinceEpoch(
    nativeAppStart.pluginRegistrationTime,
  ).toUtc();
  final setup = sentrySetupTimestamp.toUtc();
  final snapshot = snapshotTimestamp.toUtc();

  final age = snapshot.difference(processStart);
  if (age.isNegative ||
      age > _maxSnapshotAge ||
      pluginRegistration.isBefore(processStart) ||
      setup.isBefore(pluginRegistration) ||
      setup.isAfter(snapshot)) {
    return null;
  }

  final phases = <AppStartPhaseInterval>[];
  for (final entry in nativeAppStart.nativeSpanTimes.entries) {
    try {
      final value = entry.value;
      final startMilliseconds = value['startTimestampMsSinceEpoch'] as int;
      final endMilliseconds = value['stopTimestampMsSinceEpoch'] as int;
      final start =
          DateTime.fromMillisecondsSinceEpoch(startMilliseconds).toUtc();
      final end = DateTime.fromMillisecondsSinceEpoch(endMilliseconds).toUtc();
      if (start.isBefore(processStart) ||
          end.isBefore(start) ||
          end.isAfter(snapshot)) {
        continue;
      }
      phases.add(
        AppStartPhaseInterval(
          startTimestamp: start,
          endTimestamp: end,
          description: entry.key as String,
        ),
      );
    } catch (error, stackTrace) {
      internalLogger.warning(
        'Failed to parse native app-start phase',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  phases.sort((a, b) => a.startTimestamp.compareTo(b.startTimestamp));

  return AppStartData(
    type: nativeAppStart.isColdStart ? AppStartType.cold : AppStartType.warm,
    processStartTimestamp: processStart,
    pluginRegistrationTimestamp: pluginRegistration,
    sentrySetupTimestamp: setup,
    nativePhaseIntervals: phases,
  );
}
