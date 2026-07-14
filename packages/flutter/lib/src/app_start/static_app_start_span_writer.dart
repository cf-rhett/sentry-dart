// ignore_for_file: invalid_use_of_internal_member

import 'package:meta/meta.dart';

// ignore: implementation_imports
import 'package:sentry/src/sentry_tracer.dart';

import '../../sentry_flutter.dart';
import '../utils/internal_logger.dart';
import 'app_start_info.dart';

const _appStartTypeKey = 'app_start_type';

@internal
final class StaticAppStartSpanWriter {
  StaticAppStartSpanWriter({required Hub hub}) : _hub = hub;

  final Hub _hub;

  Future<void> writeAttached(
    SentryTracer transaction,
    AppStartInfo appStartInfo,
  ) async {
    transaction.setData(_appStartTypeKey, appStartInfo.type.name);

    // Measurements must be added before child spans. If a child span finishes
    // the transaction, measurements can no longer be added.
    final measurement = appStartInfo.toMeasurement();
    transaction.measurements[measurement.name] = measurement;

    await _attachAppStartSpans(appStartInfo, transaction);
  }

  Future<void> _attachAppStartSpans(
    AppStartInfo appStartInfo,
    SentryTracer transaction,
  ) async {
    final transactionTraceId = transaction.context.traceId;
    final appStartEnd = appStartInfo.end;
    final appStartSpan = await _createAndFinishSpan(
      tracer: transaction,
      operation: appStartInfo.appStartTypeOperation,
      description: appStartInfo.appStartTypeDescription,
      origin: null,
      parentSpanId: transaction.context.spanId,
      traceId: transactionTraceId,
      startTimestamp: appStartInfo.start,
      endTimestamp: appStartEnd,
      appStartType: appStartInfo.type.name,
    );
    final parentSpanId = appStartSpan.context.spanId;

    await _attachNativeSpans(
      appStartInfo,
      transaction,
      parentSpanId,
      operation: appStartInfo.appStartTypeOperation,
      origin: null,
    );

    final pluginRegistrationSpan = await _createAndFinishSpan(
      tracer: transaction,
      operation: appStartInfo.appStartTypeOperation,
      description: AppStartInfo.pluginRegistrationDescription,
      origin: null,
      parentSpanId: parentSpanId,
      traceId: transactionTraceId,
      startTimestamp: appStartInfo.start,
      endTimestamp: appStartInfo.pluginRegistration,
      appStartType: appStartInfo.type.name,
    );

    final sentrySetupSpan = await _createAndFinishSpan(
      tracer: transaction,
      operation: appStartInfo.appStartTypeOperation,
      description: AppStartInfo.sentrySetupDescription,
      origin: null,
      parentSpanId: parentSpanId,
      traceId: transactionTraceId,
      startTimestamp: appStartInfo.pluginRegistration,
      endTimestamp: appStartInfo.sentrySetupStart,
      appStartType: appStartInfo.type.name,
    );

    final firstFrameRenderSpan = await _createAndFinishSpan(
      tracer: transaction,
      operation: appStartInfo.appStartTypeOperation,
      description: AppStartInfo.firstFrameRenderDescription,
      origin: null,
      parentSpanId: parentSpanId,
      traceId: transactionTraceId,
      startTimestamp: appStartInfo.sentrySetupStart,
      endTimestamp: appStartEnd,
      appStartType: appStartInfo.type.name,
    );

    transaction.children.addAll([
      appStartSpan,
      pluginRegistrationSpan,
      sentrySetupSpan,
      firstFrameRenderSpan
    ]);
  }

  Future<void> _attachNativeSpans(
    AppStartInfo appStartInfo,
    SentryTracer transaction,
    SpanId parentSpanId, {
    required String operation,
    required String? origin,
  }) async {
    for (final timeSpan in appStartInfo.nativeSpanTimes) {
      try {
        final span = await _createAndFinishSpan(
          tracer: transaction,
          operation: operation,
          description: timeSpan.description,
          origin: origin,
          parentSpanId: parentSpanId,
          traceId: transaction.context.traceId,
          startTimestamp: timeSpan.start,
          endTimestamp: timeSpan.end,
          appStartType: appStartInfo.type.name,
        );
        span.data.putIfAbsent('native', () => true);
        transaction.children.add(span);
      } catch (error, stackTrace) {
        internalLogger.warning(
          'Failed to attach native span to app start transaction',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<SentrySpan> _createAndFinishSpan({
    required SentryTracer tracer,
    required String operation,
    required String description,
    required String? origin,
    required SpanId parentSpanId,
    required SentryId traceId,
    required DateTime startTimestamp,
    required DateTime endTimestamp,
    required String appStartType,
  }) async {
    final span = SentrySpan(
      tracer,
      SentrySpanContext(
        operation: operation,
        description: description,
        origin: origin,
        parentSpanId: parentSpanId,
        traceId: traceId,
      ),
      _hub,
      startTimestamp: startTimestamp,
    );
    span.setData(_appStartTypeKey, appStartType);
    await span.finish(endTimestamp: endTimestamp);
    return span;
  }
}
