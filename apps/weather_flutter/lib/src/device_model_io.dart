// Device model on platforms with dart:io. Web gets the stub next to this
// file, picked by the conditional import in resources.dart.

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

/// The machine-readable device model for `device.model.identifier`.
///
/// Android reports `Build.MODEL` ("Pixel 8 Pro"); iOS reports
/// `utsname.machine` ("iPhone17,3") rather than the marketing name, which
/// is what the semconv key asks for. Returns null on desktop, where the
/// attribute would be meaningless, so the caller can omit it entirely
/// rather than ship an empty string.
Future<String?> deviceModelIdentifier() async {
  final info = DeviceInfoPlugin();
  if (Platform.isAndroid) return (await info.androidInfo).model;
  if (Platform.isIOS) {
    final ios = await info.iosInfo;
    // On a simulator `utsname.machine` is the HOST arch (x86_64/arm64),
    // which is useless for slicing. The simulator exposes the device it
    // is pretending to be in the environment instead.
    return Platform.environment['SIMULATOR_MODEL_IDENTIFIER'] ??
        ios.utsname.machine;
  }
  if (Platform.isMacOS) return (await info.macOsInfo).model;
  return null;
}
