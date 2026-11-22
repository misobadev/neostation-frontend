import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// NeoSync's marks from its brand kit (neosync.cloud), drawn in one colour so
/// they sit with whatever theme the app wears: the theme's text colour by
/// default, white on dark themes and ink on light ones.
class NeoSyncLogo extends StatelessWidget {
  const NeoSyncLogo({super.key, required this.height, this.color})
    : _asset = 'assets/images/neosync/neosync_logo.svg';

  /// The isotype alone, for small places where the name is already said.
  const NeoSyncLogo.isotype({super.key, required this.height, this.color})
    : _asset = 'assets/images/neosync/neosync_isotype.svg';

  final String _asset;
  final double height;

  /// The colour to draw in; the theme's onSurface when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      _asset,
      height: height,
      fit: BoxFit.contain,
      semanticsLabel: 'NeoSync',
      colorFilter: ColorFilter.mode(
        color ?? Theme.of(context).colorScheme.onSurface,
        BlendMode.srcIn,
      ),
    );
  }
}
