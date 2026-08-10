// Resource attributes that identify WHICH build on WHICH device produced
// the telemetry.
//
// These are resource-level, not span-level, because they describe the
// whole app rather than one operation: every span, metric and log this
// process emits carries them, and backends can group by them without the
// app repeating itself.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'device_model_io.dart'
    if (dart.library.js_interop) 'device_model_web.dart';

/// Builds `app.build_id` and `device.model.identifier` for the resource.
///
/// `app.build_id` is the APP's identity, deliberately not `service.version`:
/// one app spans many services (UI, repository, integration), each versioned
/// on its own, so conflating them makes "which release is crashing?"
/// unanswerable. It is composed from platform package info, guarding the
/// Flutter quirk where a `version:` with no `+N` mirrors into the build-number
/// slot and a naive join renders "0.1.0+0.1.0".
///
/// Keys come from the semconv enums, never string literals, so a typo is a
/// compile error and a spec rename shows up as one too.
Future<Map<String, Object>> demoResourceAttributes() async {
  final info = await PackageInfo.fromPlatform();
  final buildId = _composeBuildId(info.version, info.buildNumber);
  final model = await deviceModelIdentifier();
  return <String, Object>{
    App.appBuildId.key: buildId,
    Device.deviceModelIdentifier.key: ?model,
  };
}

String _composeBuildId(String version, String buildNumber) {
  if (version.isEmpty) return buildNumber;
  if (buildNumber.isEmpty || buildNumber == version) return version;
  return '$version+$buildNumber';
}
