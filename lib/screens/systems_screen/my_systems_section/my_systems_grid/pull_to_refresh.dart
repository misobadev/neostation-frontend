part of '../my_systems_grid.dart';

/// Pull-to-refresh and pinch-to-zoom gesture handling for the systems grid.
///
/// The pointer slice of [_SystemCardGridViewState] — tracking active pointers to
/// drive the pull-to-refresh drag and the two-finger pinch that adjusts grid
/// density, plus the refresh trigger and the transient card-size label — moved out
/// of the monolith. Behaviour is unchanged. State lives on the host [State]
/// (extensions can't declare fields); `setState` calls route through the host
/// [rebuild] bridge (`State.setState` is `@protected` and can't be invoked from an
/// extension).
extension _PullToRefresh on _SystemCardGridViewState {
  void _handlePointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.position;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length < 2 || !widget.enablePinchResize) return;

    final now = DateTime.now();
    if (_lastPinchTime != null &&
        now.difference(_lastPinchTime!).inMilliseconds < 120) {
      return;
    }

    final positions = _activePointers.values.toList();
    final distance = (positions[0] - positions[1]).distance;

    if (_lastPinchDistance != null) {
      final deltaDistance = distance - _lastPinchDistance!;
      if (deltaDistance > 35) {
        _adjustGridDensity(1);
        _lastPinchDistance = distance;
        _lastPinchTime = now;
      } else if (deltaDistance < -35) {
        _adjustGridDensity(-1);
        _lastPinchDistance = distance;
        _lastPinchTime = now;
      }
    } else {
      _lastPinchDistance = distance;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      _lastPinchDistance = null;
    }
    if (_activePointers.isEmpty && _pullReady) {
      _pullReady = false;
      _pullProgress.value = 0.0;
      _triggerRefresh();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      _lastPinchDistance = null;
    }
    if (_activePointers.isEmpty && _pullReady) {
      _pullReady = false;
      _pullProgress.value = 0.0;
      _triggerRefresh();
    }
  }

  /// Triggers ROM directory rescan when pull-to-refresh reaches 100%.
  void _triggerRefresh() {
    if (!widget.enablePullToRescan) return;
    try {
      final configProvider = context.read<SqliteConfigProvider>();
      if (!configProvider.isScanning) {
        SfxService().playNavSound();
        configProvider.scanSystems();
      }
    } catch (_) {
      // Ignore if context/provider is no longer valid.
    }
  }

  /// Adjusts grid column density based on pinch gesture direction.
  void _adjustGridDensity(int delta) {
    try {
      final provider = context.read<SqliteConfigProvider>();
      final sizes = widget.pinchSizes;
      final currentSize = widget.pinchSize ?? provider.config.systemGridColumns;
      final currentIndex = sizes.indexOf(currentSize);
      if (currentIndex == -1) return;
      final newIndex = (currentIndex + delta).clamp(0, sizes.length - 1);
      if (newIndex != currentIndex) {
        final newSize = sizes[newIndex];
        final onChanged = widget.onPinchSizeChanged;
        if (onChanged != null) {
          onChanged(newSize);
        } else {
          provider.updateSystemGridColumns(newSize);
        }
        _cols =
            widget.crossAxisCountForSize?.call(newSize) ??
            Responsive.getSystemsCrossAxisCountFromSize(newSize);
        _cachedVirtualGrid = null;
        _cachedGridCols = null;
        _showCardSizeLabel(newSize);
        rebuild(() {});
      }
    } catch (_) {}
  }

  void _showCardSizeLabel(String size) {
    _cardSizeLabelTimer?.cancel();
    _cardSizeLabel.value = size;
    _cardSizeLabelTimer = Timer(const Duration(milliseconds: 1200), () {
      _cardSizeLabel.value = null;
    });
  }
}
