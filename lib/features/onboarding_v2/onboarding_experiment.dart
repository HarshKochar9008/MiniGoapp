import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/analytics/analytics.dart';

/// Which onboarding a fresh install sees.
enum OnboardingVariant { classic, questionnaire }

/// Local 50/50 split for the onboarding A/B test.
///
/// The variant is drawn once, on the first launch that still needs
/// onboarding, and stored so the user keeps it (including Settings → App
/// walkthrough replays). There is no remote config in the app, so changing
/// the split means shipping an update.
///
/// Force a variant for testing with
/// `--dart-define=ONBOARDING_VARIANT=questionnaire` (or `classic`).
class OnboardingExperiment {
  OnboardingExperiment._();

  static const prefKey = 'onboarding_variant';
  static const _override = String.fromEnvironment('ONBOARDING_VARIANT');

  /// Returns the stored variant, drawing and storing one if there is none.
  static Future<OnboardingVariant> assign({Random? random}) async {
    final forced = _parse(_override);
    if (forced != null) return forced;

    final prefs = await SharedPreferences.getInstance();
    final stored = _parse(prefs.getString(prefKey));
    if (stored != null) return stored;

    final drawn = (random ?? Random()).nextBool()
        ? OnboardingVariant.questionnaire
        : OnboardingVariant.classic;
    await prefs.setString(prefKey, drawn.name);
    Analytics.instance.logEvent(
      AnalyticsEvents.onboardingVariantAssigned,
      {'variant': drawn.name},
    );
    return drawn;
  }

  /// The stored variant without drawing one. Installs that finished
  /// onboarding before the experiment existed have none and get [classic].
  static Future<OnboardingVariant> current() async {
    final forced = _parse(_override);
    if (forced != null) return forced;
    final prefs = await SharedPreferences.getInstance();
    return _parse(prefs.getString(prefKey)) ?? OnboardingVariant.classic;
  }

  static OnboardingVariant? _parse(String? raw) {
    for (final v in OnboardingVariant.values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}
