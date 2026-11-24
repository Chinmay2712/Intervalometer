import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Connection to the iPhone, as the Bluetooth keyboard sees it.
enum LinkState { disconnected, connecting, connected }

@immutable
class RemoteLink {
  const RemoteLink(this.state, {this.name, this.address});
  static const none = RemoteLink(LinkState.disconnected);

  final LinkState state;
  final String? name;
  final String? address;

  bool get connected => state == LinkState.connected;

  factory RemoteLink.fromMap(Map<dynamic, dynamic> m) => RemoteLink(
        switch (m['state']) {
          'connected' => LinkState.connected,
          'connecting' => LinkState.connecting,
          _ => LinkState.disconnected,
        },
        name: m['name'] as String?,
        address: m['address'] as String?,
      );
}

@immutable
class PairedDevice {
  const PairedDevice(this.name, this.address);
  final String name;
  final String address;
}

/// Android only: this phone pretends to be a Bluetooth keyboard and sends
/// "Volume Up", which the iPhone Camera app takes as the shutter button.
class RemoteTrigger {
  RemoteTrigger() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'state') link.value = RemoteLink.fromMap(call.arguments as Map);
    });
  }

  static const _channel = MethodChannel('valometer/remote');

  final ValueNotifier<RemoteLink> link = ValueNotifier(RemoteLink.none);

  /// Registers the keyboard with Android. Throws [PlatformException] with
  /// code `bluetooth_off`, `permission`, `unsupported` or `no_bluetooth`.
  /// Returns this phone's Bluetooth name (what the iPhone will list).
  Future<String?> start() async {
    final m = await _channel.invokeMethod<Map<dynamic, dynamic>>('start');
    if (m != null) link.value = RemoteLink.fromMap(m);
    return m?['phoneName'] as String?;
  }

  Future<void> enableBluetooth() => _channel.invokeMethod<void>('enableBluetooth');

  /// Asks Android to make this phone visible to the iPhone for 2 minutes.
  Future<String?> makeDiscoverable() => _channel.invokeMethod<String>('makeDiscoverable');

  Future<List<PairedDevice>> pairedDevices() async {
    final list = await _channel.invokeMethod<List<dynamic>>('pairedDevices') ?? const [];
    return [
      for (final e in list.cast<Map<dynamic, dynamic>>())
        PairedDevice(e['name'] as String? ?? '', e['address'] as String? ?? ''),
    ];
  }

  Future<bool> connect(String address) async =>
      await _channel.invokeMethod<bool>('connect', {'address': address}) ?? false;

  Future<void> disconnect() => _channel.invokeMethod<void>('disconnect');

  /// One shutter press. False when the iPhone isn't connected.
  Future<bool> press() async {
    try {
      return await _channel.invokeMethod<bool>('press') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    link.dispose();
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already gone.
    } on MissingPluginException {
      // Tests / platforms without the remote.
    }
  }
}
