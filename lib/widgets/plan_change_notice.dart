import 'package:flutter/material.dart';

import 'plan_farewell_modal.dart';
import 'plan_welcome_modal.dart';

/// Tells the user about a NeoSync plan change once, whichever path noticed it
/// first.
///
/// A change made in the app, the notification socket and the next app resume
/// can each notice the same change; on their own, each showed its own modal.
class PlanChangeNotice {
  PlanChangeNotice._();

  static const _levels = {
    'free': 0,
    'micro': 1,
    'mini': 2,
    'mega': 3,
    'ultra': 4,
  };

  /// The account and plan the user was last told about.
  static String? _announced;

  /// Whether [newPlan] is above [oldPlan]. Unknown plans count as free.
  static bool isUpgrade(String oldPlan, String newPlan) =>
      (_levels[newPlan.toLowerCase()] ?? 0) >
      (_levels[oldPlan.toLowerCase()] ?? 0);

  /// Shows the welcome modal for an upgrade to [to], or the farewell modal for
  /// a move down from [from], unless [account]'s user was already told about
  /// [to].
  ///
  /// [upgrade] overrides the comparison of [from] and [to]; a farewell needs
  /// [from].
  static void show(
    BuildContext context, {
    required String? account,
    String? from,
    required String to,
    bool? upgrade,
  }) {
    final key = '${account ?? ''}:$to';
    if (from == to || _announced == key) return;
    final isUp = upgrade ?? (from != null && isUpgrade(from, to));
    if (!isUp && from == null) return;
    _announced = key;
    if (isUp) {
      PlanWelcomeModal.show(context, to);
    } else {
      PlanFarewellModal.show(context, from!, to);
    }
  }

  /// Forgets the last plan announced, so each test starts afresh.
  @visibleForTesting
  static void debugReset() => _announced = null;
}
