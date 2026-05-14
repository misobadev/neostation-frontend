import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';
import '../app_screen.dart';
import 'login_screen/neo_sync_content.dart';

class NeoSyncTab extends StatefulWidget {
  const NeoSyncTab({super.key});

  @override
  State<NeoSyncTab> createState() => _NeoSyncTabState();
}

class _NeoSyncTabState extends State<NeoSyncTab> {
  bool _neoSyncSelected = false;
  int _selectedIndex = 0;
  late GamepadNavigation _gamepadNav;

  static const int _cardCount = 3;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: _moveLeft,
      onNavigateRight: _moveRight,
      onSelectItem: _selectCurrent,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'neosync_provider_selector',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('neosync_provider_selector');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _moveLeft() {
    setState(
      () => _selectedIndex = (_selectedIndex - 1 + _cardCount) % _cardCount,
    );
  }

  void _moveRight() {
    setState(() => _selectedIndex = (_selectedIndex + 1) % _cardCount);
  }

  void _selectCurrent() {
    if (_selectedIndex == 0) {
      GamepadNavigationManager.popLayer('neosync_provider_selector');
      setState(() => _neoSyncSelected = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_neoSyncSelected) return const NeoSyncContent();
    return _buildProviderSelector(context);
  }

  Widget _buildProviderSelector(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(height: 48.r),
        Text(
          'Sync',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
            fontSize: 22.r,
          ),
        ),
        SizedBox(height: 8.r),
        Text(
          'Select a sync provider',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            fontSize: 13.r,
          ),
        ),
        SizedBox(height: 32.r),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProviderCard(
                index: 0,
                selectedIndex: _selectedIndex,
                icon: Symbols.cloud_sync_rounded,
                name: 'NeoSync',
                subtitle: 'Cloud save backup',
                isActive: true,
                onTap: () {
                  setState(() => _selectedIndex = 0);
                  _selectCurrent();
                },
              ),
              SizedBox(width: 14.r),
              _ProviderCard(
                index: 1,
                selectedIndex: _selectedIndex,
                icon: Symbols.storage_rounded,
                name: 'Romm.app',
                subtitle: 'ROM manager',
                isActive: false,
                onTap: () => setState(() => _selectedIndex = 1),
              ),
              SizedBox(width: 14.r),
              _ProviderCard(
                index: 2,
                selectedIndex: _selectedIndex,
                icon: Symbols.add_to_drive_rounded,
                name: 'Google Drive',
                subtitle: 'Google storage',
                isActive: false,
                onTap: () => setState(() => _selectedIndex = 2),
              ),
            ],
          ),
        ),
        SizedBox(height: 40.r),
        _buildNavHint(theme),
      ],
    );
  }

  Widget _buildNavHint(ThemeData theme) {
    final hintColor = theme.colorScheme.onSurface.withValues(alpha: 0.3);
    final textStyle = TextStyle(color: hintColor, fontSize: 10.r);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          'assets/images/gamepad/Xbox_D-pad_L.png',
          width: 18.r,
          height: 18.r,
          color: hintColor,
        ),
        SizedBox(width: 3.r),
        Image.asset(
          'assets/images/gamepad/Xbox_D-pad_R.png',
          width: 18.r,
          height: 18.r,
          color: hintColor,
        ),
        SizedBox(width: 6.r),
        Text('Navigate', style: textStyle),
        SizedBox(width: 20.r),
        Image.asset(
          'assets/images/gamepad/Xbox_A_button.png',
          width: 16.r,
          height: 16.r,
          color: hintColor,
        ),
        SizedBox(width: 6.r),
        Text('Select', style: textStyle),
      ],
    );
  }
}

class _ProviderCard extends StatefulWidget {
  final int index;
  final int selectedIndex;
  final IconData icon;
  final String name;
  final String subtitle;
  final bool isActive;
  final VoidCallback onTap;

  const _ProviderCard({
    required this.index,
    required this.selectedIndex,
    required this.icon,
    required this.name,
    required this.subtitle,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _liftAnim;
  late Animation<double> _glowAnim;

  bool get _isSelected => widget.index == widget.selectedIndex;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );

    _scaleAnim = Tween<double>(
      begin: 1.0,
      end: 1.06,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _liftAnim = Tween<double>(
      begin: 0.0,
      end: -10.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _glowAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    if (_isSelected) _controller.forward();
  }

  @override
  void didUpdateWidget(_ProviderCard old) {
    super.didUpdateWidget(old);
    if (_isSelected) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;
    final bool showActive = _isSelected && widget.isActive;
    final base = theme.scaffoldBackgroundColor;

    final cardColor = showActive
        ? Color.alphaBlend(accent.withValues(alpha: 0.15), base)
        : _isSelected
        ? Color.alphaBlend(theme.cardColor.withValues(alpha: 0.22), base)
        : Color.alphaBlend(theme.cardColor.withValues(alpha: 0.14), base);

    final iconBgColor = showActive
        ? Color.alphaBlend(accent.withValues(alpha: 0.18), base)
        : Color.alphaBlend(
            theme.colorScheme.onSurface.withValues(alpha: 0.14),
            base,
          );

    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _liftAnim.value),
            child: Transform.scale(
              scale: _scaleAnim.value,
              child: Opacity(
                opacity: widget.isActive ? 1.0 : 0.70,
                child: Container(
                  width: 120.r,
                  height: 145.r,
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(16.r),
                    border: Border.all(
                      color: showActive
                          ? accent.withValues(alpha: 0.9)
                          : _isSelected
                          ? theme.colorScheme.onSurface.withValues(alpha: 0.35)
                          : theme.colorScheme.onSurface.withValues(alpha: 0.20),
                      width: showActive ? 1.5.r : 1.r,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: _isSelected ? 0.22 : 0.10,
                        ),
                        blurRadius: _isSelected ? 12.r : 4.r,
                        offset: Offset(0, _isSelected ? 4.r : 2.r),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(14.r),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 38.r,
                          height: 38.r,
                          decoration: BoxDecoration(
                            color: iconBgColor,
                            borderRadius: BorderRadius.circular(10.r),
                          ),
                          child: Icon(
                            widget.icon,
                            size: 20.r,
                            color: showActive
                                ? accent
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.45,
                                  ),
                          ),
                        ),
                        SizedBox(height: 10.r),
                        Text(
                          widget.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 12.r,
                            color: showActive
                                ? accent
                                : theme.colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 2.r),
                        Text(
                          widget.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.4,
                            ),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 8.r),
                        if (!widget.isActive)
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 7.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.15,
                              ),
                              borderRadius: BorderRadius.circular(20.r),
                            ),
                            child: Text(
                              'In Progress',
                              style: TextStyle(
                                fontSize: 8.r,
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.55,
                                ),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                        else if (_isSelected)
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 7.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(
                                alpha: 0.15 * _glowAnim.value + 0.05,
                              ),
                              borderRadius: BorderRadius.circular(20.r),
                            ),
                            child: Text(
                              'Select',
                              style: TextStyle(
                                fontSize: 8.r,
                                color: accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
