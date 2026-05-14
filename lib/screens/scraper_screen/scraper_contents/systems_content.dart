import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/services/logger_service.dart';
import '../../settings_screen/new_settings_options/settings_title.dart';

class SystemsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const SystemsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<SystemsContent> createState() => SystemsContentState();
}

class SystemsContentState extends State<SystemsContent> {
  List<Map<String, dynamic>> _availableSystems = [];
  Map<String, bool> _selectedSystems = {};
  bool _isLoading = true;
  final ScrollController _scrollController = ScrollController();

  static final _log = LoggerService.instance;

  // Grid navigation con 5 columnas (como en el layout)
  static const int _gridColumns = 5;
  int _currentIndex = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int getItemCount() {
    // 1 item para el botón + cantidad de sistemas
    return 1 + _availableSystems.length;
  }

  void navigateUp() {
    if (_isLoading) return;

    int nextIndex;
    if (_currentIndex == 0) {
      // Desde el botón, ir a la última fila del grid
      final totalItems = 1 + _availableSystems.length;
      final lastRowFirstIndex =
          ((totalItems - 2) ~/ _gridColumns) * _gridColumns + 1;
      nextIndex = lastRowFirstIndex;
    } else if (_currentIndex <= _gridColumns) {
      // Desde la primera fila del grid, ir al botón
      nextIndex = 0;
    } else {
      nextIndex = _currentIndex - _gridColumns;
    }

    setState(() {
      _currentIndex = nextIndex;
    });
    _ensureSelectedItemVisible();
  }

  void navigateDown() {
    if (_isLoading) return;

    int nextIndex;
    if (_currentIndex == 0) {
      // Desde el botón, ir al primer elemento del grid
      nextIndex = 1;
    } else {
      final totalItems = 1 + _availableSystems.length;
      nextIndex = _currentIndex + _gridColumns;
      if (nextIndex >= totalItems) {
        // Desde la última fila, volver al botón
        nextIndex = 0;
      }
    }

    setState(() {
      _currentIndex = nextIndex;
    });
    _ensureSelectedItemVisible();
  }

  bool navigateLeft() {
    if (_isLoading) return false;
    // Si estamos en el botón (índice 0), volver al menú
    if (_currentIndex == 0) return true;

    // Convertir a índice del grid (sin el botón)
    final gridIndex = _currentIndex - 1;
    final currentCol = gridIndex % _gridColumns;

    // Si estamos en la primera columna, volver al menú
    if (currentCol == 0) {
      return true;
    }

    setState(() {
      _currentIndex = _currentIndex - 1;
    });
    _ensureSelectedItemVisible();
    return false;
  }

  void navigateRight() {
    if (_isLoading) return;
    // Si estamos en el botón (índice 0), no hacer nada
    if (_currentIndex == 0) return;

    setState(() {
      // Convertir a índice del grid (sin el botón)
      final gridIndex = _currentIndex - 1;
      final currentRow = gridIndex ~/ _gridColumns;

      // Calcular el índice del primer y último elemento de la fila actual
      final rowFirstIndex = currentRow * _gridColumns;
      final rowLastIndex = ((currentRow + 1) * _gridColumns - 1).clamp(
        0,
        _availableSystems.length - 1,
      );

      // Si estamos en la última columna de la fila, ir a la primera
      if (gridIndex >= rowLastIndex) {
        _currentIndex = rowFirstIndex + 1; // +1 porque el botón es el índice 0
      } else {
        _currentIndex = _currentIndex + 1;
      }
    });
    _ensureSelectedItemVisible();
  }

  void _ensureSelectedItemVisible() {
    if (!_scrollController.hasClients) return;

    // Altura aproximada del header (Título + Botón)
    final headerHeight = 60.r;

    // Calcular dimensiones del grid dinámicamente
    // Las tarjetas en esta pantalla son cortas (icono + texto pequeño)
    final itemHeight = 50.r;
    final spacing = 8.r;
    final rowHeight = itemHeight + spacing;

    final viewportHeight = _scrollController.position.viewportDimension;
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final minScrollExtent = _scrollController.position.minScrollExtent;

    double targetOffset;

    if (_currentIndex == 0) {
      targetOffset = minScrollExtent;
    } else {
      final gridIndex = _currentIndex - 1;
      final selectedRow = gridIndex ~/ _gridColumns;

      // Calcular el centro de la fila seleccionada
      // Header + Espaciado (12.h) + Posición en el grid
      final rowTop = headerHeight + 12.h + (selectedRow * rowHeight);
      final rowCenter = rowTop + (rowHeight / 2);

      // Centrar la fila en el viewport
      targetOffset = (rowCenter - (viewportHeight / 2)).clamp(
        minScrollExtent,
        maxScrollExtent,
      );
    }

    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
    );
  }

  void selectItem() {
    if (_isLoading) return;
    // Index 0 es el botón "Disable All / Enable All"
    if (_currentIndex == 0) {
      _toggleAllSystems();
    } else {
      // Los demás índices son sistemas (index - 1 porque el botón es el primero)
      final systemIndex = _currentIndex - 1;
      if (systemIndex >= 0 && systemIndex < _availableSystems.length) {
        final systemId = _availableSystems[systemIndex]['id'].toString();
        _toggleSystem(systemId);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSystems();
  }

  Future<void> _loadSystems() async {
    setState(() {
      _isLoading = true;
    });

    final systems = await _getAvailableSystems();
    final config = await _getCurrentSystemConfig();

    if (mounted) {
      setState(() {
        _availableSystems = systems;
        _selectedSystems = config;
        _isLoading = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _getAvailableSystems() =>
      ScraperRepository.getScraperSystems();

  Future<Map<String, bool>> _getCurrentSystemConfig() =>
      ScraperRepository.getSystemScraperConfig();

  Future<bool> _saveSystemConfig(String systemId, bool enabled) =>
      ScraperRepository.saveSystemConfig(systemId, enabled);

  Future<void> _toggleSystem(String systemId) async {
    final currentState = _selectedSystems[systemId] ?? false;
    final newState = !currentState;

    setState(() {
      _selectedSystems[systemId] = newState;
    });

    final success = await _saveSystemConfig(systemId, newState);

    if (mounted) {
      if (success) {
        final system = _availableSystems.firstWhere((s) => s['id'] == systemId);
        AppNotification.showNotification(
          context,
          '${system['name']}: ${newState ? AppLocale.enabled.getString(context) : AppLocale.disabled.getString(context)}',
          type: NotificationType.success,
        );
      } else {
        // Revertir el cambio si falló
        setState(() {
          _selectedSystems[systemId] = currentState;
        });
        AppNotification.showNotification(
          context,
          AppLocale.updateError.getString(context),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _toggleAllSystems() async {
    final allEnabled = _availableSystems.every(
      (s) => _selectedSystems[s['id']] == true,
    );
    final shouldEnable = !allEnabled;

    setState(() {
      for (final system in _availableSystems) {
        final systemId = system['id'].toString();
        _selectedSystems[systemId] = shouldEnable;
      }
    });

    try {
      await ScraperRepository.saveAllSystemsConfig(
        _availableSystems.map((s) => s['id'].toString()).toList(),
        shouldEnable,
      );

      if (mounted) {
        AppNotification.showNotification(
          context,
          shouldEnable
              ? AppLocale.allSystemsEnabled.getString(context)
              : AppLocale.allSystemsDisabled.getString(context),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      _log.e('Error toggling all systems: $e');
      // Revertir cambios
      await _loadSystems();
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.updateError.getString(context),
          type: NotificationType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Título y botón Toggle All en la misma línea
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: SettingsTitle(
                  title: AppLocale.systems.getString(context),
                  subtitle: AppLocale.systemsSub.getString(context),
                ),
              ),
              SizedBox(width: 24.r),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color: widget.isContentFocused && _currentIndex == 0
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2.r, // Consistency
                  ),
                ),
                child: ElevatedButton.icon(
                  onPressed: _toggleAllSystems,
                  icon: Icon(
                    _availableSystems.every(
                          (s) => _selectedSystems[s['id']] == true,
                        )
                        ? Symbols.deselect_rounded
                        : Symbols.select_all_rounded,
                    size: 18.r,
                  ),
                  label: Text(
                    _availableSystems.every(
                          (s) => _selectedSystems[s['id']] == true,
                        )
                        ? AppLocale.disableAll.getString(context)
                        : AppLocale.enableAll.getString(context),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(
                      horizontal: 16.r,
                      vertical: 6.r,
                    ),
                    minimumSize: Size(0, 32.r),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12.r),

          // Grid de sistemas - 5 columnas
          Wrap(
            spacing: 6.r,
            runSpacing: 6.r,
            children: _availableSystems.asMap().entries.map((entry) {
              final index = entry.key;
              final system = entry.value;
              final systemId = system['id'].toString();
              final isEnabled = _selectedSystems[systemId] ?? false;
              // index + 1 porque el botón toggle all es el _currentIndex 0
              final isFocused =
                  widget.isContentFocused && _currentIndex == (index + 1);
              return SizedBox(
                width:
                    (MediaQuery.of(context).size.width * 0.75 -
                        24.r * 2 -
                        24.r) /
                    5,
                child: _buildSystemCard(context, system, isEnabled, isFocused),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemCard(
    BuildContext context,
    Map<String, dynamic> system,
    bool isEnabled,
    bool isFocused,
  ) {
    final theme = Theme.of(context);

    return InkWell(
      canRequestFocus: false,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      onTap: () {
        SfxService().playNavSound();
        _toggleSystem(system['id'].toString());
      },
      borderRadius: BorderRadius.circular(8.r),
      child: Container(
        padding: EdgeInsets.all(4.r),
        decoration: BoxDecoration(
          color: isEnabled
              ? theme.cardColor.withValues(alpha: 0.6)
              : theme.cardColor.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: isFocused
                ? theme.colorScheme.secondary
                : isEnabled
                ? Colors.greenAccent
                : theme.colorScheme.outline.withValues(alpha: 0.1),
            width: 1.5.r,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icono de checkbox
            Container(
              width: 24.r,
              height: 24.r,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isEnabled
                    ? Colors.greenAccent.withValues(alpha: 0.25)
                    : theme.cardColor.withValues(alpha: 0.25),
                border: Border.all(
                  color: isEnabled
                      ? Colors.greenAccent
                      : theme.colorScheme.outline.withValues(alpha: 0.4),
                  width: 1.5.r,
                ),
              ),
              child: Center(
                child: Icon(
                  isEnabled ? Symbols.check_rounded : Symbols.add_rounded,
                  color: isEnabled
                      ? Colors.greenAccent
                      : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  size: 14.r,
                ),
              ),
            ),
            SizedBox(height: 2.r),

            // Nombre del sistema
            Text(
              system['name'].toString(),
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(
                  alpha: isEnabled ? 0.9 : 0.5,
                ),
                fontSize: 9.r,
                fontWeight: isEnabled ? FontWeight.w600 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
