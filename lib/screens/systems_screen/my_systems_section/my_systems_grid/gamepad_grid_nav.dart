part of '../my_systems_grid.dart';

/// Gamepad/keyboard grid navigation for the systems grid.
///
/// The input-driven slice of [_SystemCardGridViewState] — gamepad layer setup,
/// directional grid traversal (row/column virtual-grid walk), and keeping the
/// selected card scrolled into view — moved out of the monolith. Behaviour is
/// unchanged. State lives on the host [State] (extensions can't declare fields);
/// `setState` calls route through the host [rebuild] bridge (`State.setState` is
/// `@protected` and can't be invoked from an extension).
extension _GamepadGridNav on _SystemCardGridViewState {
  /// Configures the gamepad navigation layer for the systems grid.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          rebuild(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('up');
      },
      onNavigateDown: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          rebuild(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('down');
      },
      onNavigateLeft: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          rebuild(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('left');
      },
      onNavigateRight: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          rebuild(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('right');
      },
      onSelectItem: () => widget.onEnterPressed?.call(),
      onSettings: () => widget.onEscapePressed?.call(),
      // Read through `widget` on every press, exactly as A and START above do.
      // The host rebuilds this callback each frame around the *currently*
      // selected card, so binding the closure itself here would pin Y to
      // whichever card was selected when this state was created — Y opened the
      // context menu for that first card no matter where the cursor had moved
      // (the long-press route never had the bug: the card reads `widget` when
      // it is built). A null `onYPressed` still does nothing, and Y counts as
      // handled either way, so nothing else changes.
      onFavorite: widget.bindYButton ? () => widget.onYPressed?.call() : null,
      // Likewise B: the systems screen is a root tab with nothing to pop, and a
      // null onBack also leaves the keyboard's Backspace unhandled, as it was.
      onBack: widget.onBackPressed,
      onXButton: widget.onXPressed,
      // Bound only for a host that supplies them (the systems screen's recent
      // card), so the collections browser's triggers stay silent.
      onLeftTrigger: widget.onLeftTrigger == null
          ? null
          : () => widget.onLeftTrigger?.call(),
      onRightTrigger: widget.onRightTrigger == null
          ? null
          : () => widget.onRightTrigger?.call(),
      onWestButton: widget.onWestPressed,
      // A pushed host is not part of the tab strip, so its shoulder buttons
      // must not cycle tabs out from under it.
      onPreviousTab: widget.enableTabBumpers ? AppNavigation.previousTab : null,
      onNextTab: widget.enableTabBumpers ? AppNavigation.nextTab : null,
      onLeftBumper: widget.enableTabBumpers ? AppNavigation.previousTab : null,
      onRightBumper: widget.enableTabBumpers ? AppNavigation.nextTab : null,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      // A rebuild can re-mount this view while the screen sits behind a pushed
      // route (the shared view-mode setting changing is the case that bites).
      // Registering on top there would steal the controller from the route in
      // front, so a backgrounded push slots in beneath it instead.
      final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
      GamepadNavigationManager.pushLayer(
        widget.navLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
        background: !isCurrentRoute,
      );
    });
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer(widget.navLayerId);
    _gamepadNav.dispose();
  }

  void _navigateGrid(String direction) {
    if (!mounted) return;
    _navigateVirtual(direction);
  }

  /// Resolve the next focused index based on the virtual spatial grid.
  void _navigateVirtual(String direction) {
    final cards = _systemCards;
    final cols = _cols;
    final current = widget.selectedIndex;

    final grid = _buildVirtualGrid(cards, cols);

    // Resolve current 2D coordinates.
    int curRow = -1, curCol = -1;
    outer:
    for (int r = 0; r < grid.length; r++) {
      for (int c = 0; c < cols; c++) {
        if (grid[r][c] == current) {
          curRow = r;
          curCol = c;
          break outer;
        }
      }
    }
    if (curRow == -1) return;

    int newIndex = current;

    switch (direction) {
      case 'up':
        int targetRow = curRow;
        int idx = current;
        int safety = 0;
        while ((idx == current || idx == -1) && safety < grid.length) {
          targetRow = (targetRow - 1 + grid.length) % grid.length;
          idx = grid[targetRow][curCol.clamp(0, cols - 1)];
          if (idx == -1) {
            idx = findNearestInRow(grid, targetRow, curCol.clamp(0, cols - 1));
          }
          safety++;
        }
        newIndex = idx >= 0 ? idx : current;
      case 'down':
        int targetRow = curRow;
        int idx = current;
        int safety = 0;
        while ((idx == current || idx == -1) && safety < grid.length) {
          targetRow = (targetRow + 1) % grid.length;
          idx = grid[targetRow][curCol.clamp(0, cols - 1)];
          if (idx == -1) {
            idx = findNearestInRow(grid, targetRow, curCol.clamp(0, cols - 1));
          }
          safety++;
        }
        newIndex = idx >= 0 ? idx : current;
      case 'left':
        int firstCol = curCol;
        while (firstCol > 0 && grid[curRow][firstCol - 1] == current) {
          firstCol--;
        }
        if (firstCol > 0) {
          final idx = grid[curRow][firstCol - 1];
          newIndex = idx >= 0 ? idx : current;
        } else {
          int targetRow = (curRow - 1 + grid.length) % grid.length;
          for (int c = cols - 1; c >= 0; c--) {
            if (grid[targetRow][c] != -1 && grid[targetRow][c] != current) {
              newIndex = grid[targetRow][c];
              break;
            }
          }
        }
      case 'right':
        int lastCol = curCol;
        while (lastCol < cols - 1 && grid[curRow][lastCol + 1] == current) {
          lastCol++;
        }
        if (lastCol < cols - 1) {
          final idx = grid[curRow][lastCol + 1];
          newIndex = idx >= 0 ? idx : current;
        } else {
          int targetRow = (curRow + 1) % grid.length;
          for (int c = 0; c < cols; c++) {
            if (grid[targetRow][c] != -1 && grid[targetRow][c] != current) {
              newIndex = grid[targetRow][c];
              break;
            }
          }
        }
    }

    if (newIndex != current) {
      widget.onCardTapped?.call(newIndex);
    }
  }

  /// Keeps the selected card inside a comfortable vertical band instead of
  /// recentering it on every D-pad step.
  ///
  /// The old version always animated the selected row to the middle of the
  /// viewport, which made a one-row move read as a full-screen jump. This
  /// version only scrolls when the card leaves the band, moves by the minimum
  /// needed, and uses the same per-row heights as the renderer (including
  /// wide recent cards and square logo-less cards).
  void _ensureSelectedItemVisibleUniversal() {
    if (!_scrollController.hasClients || widget.systems.isEmpty) return;

    final cards = _systemCards;
    final cols = _cols;
    final grid = _buildVirtualGrid(cards, cols);

    int selectedRow = -1;
    for (int r = 0; r < grid.length; r++) {
      if (grid[r].contains(widget.selectedIndex)) {
        selectedRow = r;
        break;
      }
    }
    if (selectedRow == -1) return;

    final dimensions = _calculateGridDimensions();
    final colWidth = dimensions['itemWidth']!;
    final mainAxisSpacing = dimensions['mainAxisSpacing']!;

    double aspectRatio(int index) {
      final ratios = widget.aspectRatios;
      if (ratios != null && index >= 0 && index < ratios.length) {
        return ratios[index];
      }
      return widget.childAspectRatio;
    }

    final rowItemHeights = List<double>.filled(grid.length, 0);
    final rowHeights = List<double>.filled(grid.length, 0);
    for (int r = 0; r < grid.length; r++) {
      final seen = <int>{};
      double maxHeight = 0;
      for (int c = 0; c < grid[r].length; c++) {
        final cardIdx = grid[r][c];
        if (cardIdx == -1 || seen.contains(cardIdx)) continue;
        seen.add(cardIdx);
        final height = colWidth / aspectRatio(cardIdx);
        if (height > maxHeight) maxHeight = height;
      }
      rowItemHeights[r] = maxHeight;
      rowHeights[r] = maxHeight + mainAxisSpacing;
    }

    double rowTop(int row) {
      double top = 0;
      for (int i = 0; i < row; i++) {
        top += rowHeights[i];
      }
      return top;
    }

    final selectedCard = cards[widget.selectedIndex];
    final (_, recentH) = recentCardSpan(widget.recentCardSize, cols);
    final spanH = selectedCard.isGame ? recentH : 1;

    double itemTop = rowTop(selectedRow);
    double itemHeight;
    if (selectedCard.isGame) {
      itemHeight = 0;
      for (
        int i = 0;
        i < spanH && selectedRow + i < rowItemHeights.length;
        i++
      ) {
        itemHeight += rowItemHeights[selectedRow + i];
      }
      itemHeight += (spanH - 1) * mainAxisSpacing;
    } else {
      itemHeight = colWidth / aspectRatio(widget.selectedIndex);
      itemTop += (rowItemHeights[selectedRow] - itemHeight) / 2;
    }
    final itemBottom = itemTop + itemHeight;

    final viewportHeight = _scrollController.position.viewportDimension;
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final minScrollExtent = _scrollController.position.minScrollExtent;
    final currentOffset = _scrollController.offset;

    // Keep a fifth of the viewport clear at each edge. A card already inside
    // this band is left alone; moving one row no longer animates the whole
    // list.
    final safeTop = viewportHeight * 0.2;
    final safeBottom = viewportHeight * 0.8;
    final safeHeight = safeBottom - safeTop;

    double targetOffset = currentOffset;
    if (itemHeight > safeHeight) {
      targetOffset = itemTop - safeTop;
    } else if (itemTop < currentOffset + safeTop) {
      targetOffset = itemTop - safeTop;
    } else if (itemBottom > currentOffset + safeBottom) {
      targetOffset = itemBottom - safeBottom;
    }

    targetOffset = targetOffset.clamp(minScrollExtent, maxScrollExtent);
    if ((targetOffset - currentOffset).abs() < 1) return;

    final distance = (targetOffset - currentOffset).abs();
    final duration = _isNavigatingFast
        ? const Duration(milliseconds: 150)
        : Duration(
            milliseconds: (220 + distance * 0.25).clamp(220, 360).toInt(),
          );

    _scrollController.animateTo(
      targetOffset,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }
}
