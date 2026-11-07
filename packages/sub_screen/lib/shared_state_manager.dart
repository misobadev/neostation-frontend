import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sub_screen/utils.dart';

typedef OnSharedStateChangeListener = void Function(Map<String, dynamic>?);

const _sharedStateChannelName =
    "com.hcoderlee.subscreen.sub_screen/shared_state";

abstract class SharedState<T>
    with ChangeNotifier
    implements ValueListenable<T?> {
  T? _state;

  T? get state => _state;

  @override
  T? get value => _state;

  late final Future initialSync;
  bool _isSyncComplete = false;

  SharedState() : super() {
    SharedStateManager.instance.addStateChangeListener(
      runtimeType.toString(),
      _onStateChange,
    );

    // Try to init state from local cache
    final cachedState = SharedStateManager.instance.getCachedState(
      runtimeType.toString(),
    );
    if (cachedState != null) {
      // Mark state synchronization as completed
      _isSyncComplete = true;
      _state = fromJson(cachedState);
      return;
    }
    initialSync = _syncState();
  }

  void setState(T? state) async {
    // Update local state value
    _state = state;
    // Make sure initial value synchronization complete
    if (!_isSyncComplete) {
      await initialSync;
    }

    // Notify registered listener
    notifyListeners();
    // Notify state change for other listeners and flutter engines
    SharedStateManager.instance.updateState(
      runtimeType.toString(),
      toJson(state),
    );
  }

  void clearState() async {
    if (!_isSyncComplete) {
      await initialSync;
    }
    // Clear state value and notify to registered listener
    _state = null;
    notifyListeners();
    // Notify state clear for other listeners and flutter engines
    SharedStateManager.instance.clearState(runtimeType.toString());
  }

  /// Synchronizing the latest state for current type
  Future _syncState() async {
    final json = await SharedStateManager.instance.getState(
      runtimeType.toString(),
    );
    _isSyncComplete = true;

    if (json != null) {
      _onStateChange(json);
    }
  }

  void _onStateChange(Map<String, dynamic>? newState) {
    if (_isSameState(newState)) {
      // Filter out the state that not changed
      return;
    }

    try {
      if (newState == null) {
        _state = null;
      } else {
        _state = fromJson(newState);
      }
      notifyListeners();
    } catch (e) {
      throw Exception(
        "SharedState failed to parse for $runtimeType from: $newState, $e",
      );
    }
  }

  bool _isSameState(Map<String, dynamic>? newState) {
    return newState?.toString() == toJson(state)?.toString();
  }

  @override
  void dispose() {
    SharedStateManager.instance.removeStateChangeListener(
      runtimeType.toString(),
      _onStateChange,
    );
    super.dispose();
  }

  T fromJson(Map<String, dynamic> json);

  Map<String, dynamic>? toJson(T? data);
}

class SharedStateManager {
  static SharedStateManager? _instance;

  static SharedStateManager get instance {
    _instance ??= SharedStateManager._();
    return _instance!;
  }

  final Map<String, Set<OnSharedStateChangeListener>> _listeners = {};
  late final MethodChannel methodChannel;

  late final Future _syncSharedState;
  Map<String, Map<String, dynamic>?> _cachedSharedState = {};
  bool _hasSyncData = false;

  SharedStateManager._() {
    _initMethodChannel();
    _syncSharedState = _initSharedState();
  }

  void _initMethodChannel() {
    methodChannel = const MethodChannel(_sharedStateChannelName);
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onStateChanged':
          if (!_hasSyncData) {
            // Waiting to sync data from native platform
            await _syncSharedState;
          }

          // Parse updated state data
          final type = call.arguments['type'] as String;
          final rawData = call.arguments['data'];
          final newState = rawData != null ? convertMapToJson(rawData) : null;
          // Update local cached state
          _cachedSharedState[type] = newState;
          // Notify state change
          _notifyListeners(type, newState);
          break;
        default:
          throw "SharedStateManager: Unknown method ${call.method}";
      }
    });
  }

  /// Sync all shared state data from native platform
  Future _initSharedState() async {
    final res = await methodChannel.invokeMethod<Map<Object?, dynamic>>(
      "getAllState",
    );
    _cachedSharedState =
        res?.map(
          (key, value) => MapEntry(key.toString(), convertMapToJson(value)),
        ) ??
        {};
    _hasSyncData = true;
  }

  Future<Map<String, dynamic>?> getState(String type) async {
    if (!_hasSyncData) {
      // Waiting to sync data from native platform
      await _syncSharedState;
    }
    return _cachedSharedState[type];
  }

  Map<String, dynamic>? getCachedState(String type) {
    return _cachedSharedState[type];
  }

  Future<void> updateState(String type, Map<String, dynamic>? data) async {
    try {
      if (!_hasSyncData) {
        // Waiting to sync data from native platform
        await _syncSharedState;
      }

      // Update cached state
      _cachedSharedState[type] = data;
      // Notify state change to registered listeners
      _notifyListeners(type, data);

      // Notify other flutter engine to update state
      await methodChannel.invokeMethod('updateState', {
        'type': type,
        'state': data,
      });
    } on PlatformException catch (e) {
      debugPrint('Error updating shared state: ${e.message}');
    }
  }

  Future<void> clearState(String type) async {
    try {
      if (!_hasSyncData) {
        // Waiting to sync data from native platform
        await _syncSharedState;
      }

      // Clear local cached state for specified type
      _cachedSharedState[type] = null;
      // Notify state clear to registered listeners
      _notifyListeners(type, null);
      // Notify other flutter engine to clear state
      await methodChannel.invokeMethod('clearState', {'type': type});
    } on PlatformException catch (e) {
      debugPrint('Error clear shared state: ${e.message}');
    }
  }

  void addStateChangeListener(
    String type,
    OnSharedStateChangeListener listener,
  ) {
    _listeners.putIfAbsent(type, () => {});
    _listeners[type]!.add(listener);
  }

  void removeStateChangeListener<T>(
    String type,
    OnSharedStateChangeListener listener,
  ) {
    final stateListeners = _listeners[type];
    if (stateListeners == null || stateListeners.isEmpty) {
      return;
    }
    stateListeners.remove(listener);
  }

  void _notifyListeners(String type, Map<String, dynamic>? data) {
    final listeners = _listeners[type];
    if (listeners != null) {
      for (final listener in listeners) {
        listener(data);
      }
    }
  }
}
