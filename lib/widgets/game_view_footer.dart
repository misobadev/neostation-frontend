import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/game_utils.dart';
import 'marquee_text.dart';

class GameViewFooter extends StatelessWidget {
  final GameModel game;
  final VoidCallback onPlay;

  const GameViewFooter({super.key, required this.game, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (game.rating > 0) ...[
            _RatingBadge(game: game),
            SizedBox(width: 8.r),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                MarqueeText(
                  text: GameUtils.formatGameName(game.name),
                  isActive: true,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15.r,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        blurRadius: 2.r,
                        color: Colors.black,
                        offset: const Offset(0, 0),
                      ),
                    ],
                  ),
                ),
                if (game.showRomFileNameSubtitle) ...[
                  Text(
                    game.romname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 11.r,
                      fontWeight: FontWeight.w400,
                      shadows: [
                        Shadow(
                          blurRadius: 2.r,
                          color: Colors.black.withValues(alpha: 0.45),
                          offset: const Offset(2, 2),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: 12.r),
          _buildPlayButton(context),
        ],
      ),
    );
  }

  Widget _buildPlayButton(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8.r),
        onTap: () {
          SfxService().playEnterSound();
          onPlay();
        },
        child: Container(
          height: 32.r,
          padding: EdgeInsets.symmetric(horizontal: 10.r),
          decoration: BoxDecoration(
            color: const Color(0xFF2ECC71),
            borderRadius: BorderRadius.circular(8.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.r, 2.r),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 16.r,
                height: 16.r,
                color: theme.colorScheme.onPrimary,
              ),
              SizedBox(width: 6.r),
              Text(
                AppLocale.playButton.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w900,
                  fontSize: 14.r,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  final GameModel game;
  const _RatingBadge({required this.game});

  @override
  Widget build(BuildContext context) {
    final ratingValue = (game.rating / 2).clamp(0.0, 10.0);
    final colorRatio = (ratingValue - 1) / 9;
    final ratingColor = Color.lerp(
      Colors.redAccent,
      Colors.lightGreenAccent,
      colorRatio,
    )!;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 5.r),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(6.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 2.r,
            offset: Offset(2.r, 2.r),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.star_rounded, color: ratingColor, size: 16.r),
          SizedBox(width: 5.r),
          Text(
            ratingValue.toStringAsFixed(1),
            style: TextStyle(
              color: Colors.white,
              fontSize: 15.r,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
