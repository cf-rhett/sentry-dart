// ignore_for_file: invalid_use_of_internal_member, experimental_member_use

import 'dart:ui';

import 'package:meta/meta.dart';

import '../../sentry_flutter.dart';
import '../frame_callback_handler.dart';
import '../native/sentry_native_binding.dart';
import '../utils/internal_logger.dart';
import '../app_start/app_start_data.dart';
import '../app_start/app_start_info.dart';
import '../app_start/app_start_trace.dart';
import '../app_start/native_app_start_parser.dart';
import '../app_start/static_app_start_span_writer.dart';
import '../app_start/static_app_start_trace.dart';
import '../app_start/stream_app_start_span_writer.dart';
import '../app_start/streaming_app_start_trace.dart';

/// Wires native app-start timing and Flutter's first frame to display and
/// standalone app-start tracing.
class NativeAppStartIntegration extends Integration<SentryFlutterOptions> {
  NativeAppStartIntegration(this._frameCallbackHandler, this._native);

  @internal
  static const integrationName = 'NativeAppStart';

  final FrameCallbackHandler _frameCallbackHandler;
  final SentryNativeBinding _native;

  TimingsCallback? _firstFrameCallback;
  SentryFlutterOptions? _options;
  AppStartTrace? _trace;
  bool _installationClaimed = false;
  bool _closed = false;
  bool _standalone = false;
  bool _displayPrepared = false;

  @override
  Future<void> call(Hub hub, SentryFlutterOptions options) async {
    if (_closed || _installationClaimed) return;
    _installationClaimed = true;
    _options = options;

    if (!options.isTracingEnabled()) {
      internalLogger.info(
        'Skipping $integrationName integration because tracing is disabled.',
      );
      return;
    }

    options.sdk.addIntegration(integrationName);
    if (!options.enableStandaloneAppStartTracing) {
      _installLegacy(hub, options);
      return;
    }

    options.sdk.addFeature(SentryFeatures.standaloneAppStartTracing);
    _standalone = true;
    if (!options.platform.isAndroid && !options.platform.isIOS) return;

    AppStartData? data;
    try {
      final nativeAppStart = await _native.fetchNativeAppStart();
      final setupTimestamp = SentryFlutter.sentrySetupStartTime;
      if (nativeAppStart != null && setupTimestamp != null) {
        data = parseStandaloneAppStart(
          nativeAppStart,
          sentrySetupTimestamp: setupTimestamp,
          snapshotTimestamp: options.clock(),
        );
      }
    } catch (error, stackTrace) {
      internalLogger.error(
        'Failed to fetch standalone app-start timing',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (_closed || !identical(_options, options)) return;

    final fallbackStart = SentryFlutter.sentrySetupStartTime ?? options.clock();
    _prepareInitialDisplay(
        options, data?.processStartTimestamp ?? fallbackStart);
    _displayPrepared = true;
    final initialScreenName = _memoizedInitialScreenName();

    if (data != null) {
      var completedBeforePublication = false;
      AppStartTrace? trace;
      void onCompleted() {
        completedBeforePublication = true;
        if (identical(_trace, trace)) {
          _trace = null;
        }
      }

      try {
        trace = switch (options.traceLifecycle) {
          SentryTraceLifecycle.static => StaticAppStartTrace.tryCreate(
              hub: hub,
              data: data,
              onCompleted: onCompleted,
              initialScreenName: initialScreenName,
            ),
          SentryTraceLifecycle.stream => StreamingAppStartTrace.tryCreate(
              hub: hub,
              data: data,
              onCompleted: onCompleted,
              initialScreenName: initialScreenName,
            ),
        };
        if (trace != null && !completedBeforePublication && !_closed) {
          _trace = trace;
        } else {
          trace?.close();
        }
      } catch (error, stackTrace) {
        internalLogger.error(
          'Failed to install standalone app-start trace',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    if (_closed || !identical(_options, options)) return;
    _installStandaloneFirstFrame(
      options,
      initialScreenName: initialScreenName,
    );
  }

  void _prepareInitialDisplay(
    SentryFlutterOptions options,
    DateTime startTimestamp,
  ) {
    switch (options.traceLifecycle) {
      case SentryTraceLifecycle.static:
        options.timeToDisplayTracker.prepareInitialDisplay(startTimestamp);
      case SentryTraceLifecycle.stream:
        options.timeToDisplayTrackerV2.prepareInitialDisplay(startTimestamp);
    }
  }

  void _installStandaloneFirstFrame(
    SentryFlutterOptions options, {
    required String Function() initialScreenName,
  }) {
    void callback(List<FrameTiming> timings) async {
      if (!identical(_firstFrameCallback, callback)) return;
      if (timings.isEmpty) return;
      _firstFrameCallback = null;
      _frameCallbackHandler.removeTimingsCallback(callback);

      final endTimestamp = DateTime.fromMicrosecondsSinceEpoch(
        timings.first.timestampInMicroseconds(
          FramePhase.rasterFinishWallTime,
        ),
      );
      Object? firstError;
      StackTrace? firstStackTrace;

      try {
        initialScreenName();
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }

      try {
        switch (options.traceLifecycle) {
          case SentryTraceLifecycle.static:
            await options.timeToDisplayTracker
                .recordInitialDisplay(endTimestamp);
          case SentryTraceLifecycle.stream:
            options.timeToDisplayTrackerV2.recordInitialDisplay(endTimestamp);
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        internalLogger.error(
          'Failed to record initial display',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        _displayPrepared = false;
      }

      try {
        _trace?.recordNaturalEnd(endTimestamp);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        internalLogger.error(
          'Failed to record standalone app-start natural end',
          error: error,
          stackTrace: stackTrace,
        );
      }

      if (firstError != null && options.automatedTestMode) {
        Error.throwWithStackTrace(firstError, firstStackTrace!);
      }
    }

    _firstFrameCallback = callback;
    _frameCallbackHandler.addTimingsCallback(callback);
  }

  String Function() _memoizedInitialScreenName() {
    String? value;
    return () {
      final frozen = value;
      if (frozen != null) return frozen;
      try {
        final routeName = SentryNavigatorObserver.currentRouteName;
        value =
            routeName != null && routeName.isNotEmpty ? routeName : 'root /';
      } catch (error, stackTrace) {
        internalLogger.warning(
          'Failed to resolve the initial app-start screen',
          error: error,
          stackTrace: stackTrace,
        );
        value = 'root /';
      }
      return value!;
    };
  }

  void _installLegacy(Hub hub, SentryFlutterOptions options) {
    final staticWriter = StaticAppStartSpanWriter(hub: hub);
    final streamWriter = StreamAppStartSpanWriter(hub: hub);
    switch (options.traceLifecycle) {
      case SentryTraceLifecycle.static:
        options.timeToDisplayTracker.prepareAppStart();
      case SentryTraceLifecycle.stream:
        options.timeToDisplayTrackerV2.prepareAppStart();
    }

    void callback(List<FrameTiming> timings) async {
      if (!identical(_firstFrameCallback, callback)) return;
      _firstFrameCallback = null;
      _frameCallbackHandler.removeTimingsCallback(callback);
      try {
        if (timings.isEmpty) return;
        final endTimestamp = DateTime.fromMicrosecondsSinceEpoch(
          timings.first.timestampInMicroseconds(
            FramePhase.rasterFinishWallTime,
          ),
        );
        final nativeAppStart = await _native.fetchNativeAppStart();
        final info = nativeAppStart == null
            ? null
            : parseNativeAppStart(nativeAppStart, endTimestamp);
        if (info == null) {
          if (options.traceLifecycle == SentryTraceLifecycle.stream) {
            options.timeToDisplayTrackerV2.cancelCurrentRoute();
          }
          return;
        }
        await _trackLegacy(
          options,
          info,
          staticWriter: staticWriter,
          streamWriter: streamWriter,
        );
      } catch (error, stackTrace) {
        internalLogger.error(
          'Error while capturing native app start',
          error: error,
          stackTrace: stackTrace,
        );
        if (options.automatedTestMode) rethrow;
      }
    }

    _firstFrameCallback = callback;
    _frameCallbackHandler.addTimingsCallback(callback);
  }

  Future<void> _trackLegacy(
    SentryFlutterOptions options,
    AppStartInfo info, {
    required StaticAppStartSpanWriter staticWriter,
    required StreamAppStartSpanWriter streamWriter,
  }) async {
    switch (options.traceLifecycle) {
      case SentryTraceLifecycle.static:
        await options.timeToDisplayTracker.trackAppStart(
          startTimestamp: info.start,
          ttidEndTimestamp: info.end,
          attachAppStart: (transaction) =>
              staticWriter.writeAttached(transaction, info),
        );
      case SentryTraceLifecycle.stream:
        options.timeToDisplayTrackerV2.trackAppStart(
          startTimestamp: info.start,
          ttidEndTimestamp: info.end,
          attachAppStart: (root) => streamWriter.writeAttached(root, info),
        );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final callback = _firstFrameCallback;
    _firstFrameCallback = null;
    final options = _options;
    final trace = _trace;
    _trace = null;
    _options = null;

    try {
      if (callback != null) {
        _frameCallbackHandler.removeTimingsCallback(callback);
      }
    } finally {
      try {
        trace?.close();
      } finally {
        if (_standalone && _displayPrepared && options != null) {
          switch (options.traceLifecycle) {
            case SentryTraceLifecycle.static:
              options.timeToDisplayTracker.clear();
            case SentryTraceLifecycle.stream:
              options.timeToDisplayTrackerV2.cancelCurrentRoute();
          }
        }
      }
    }
  }
}
