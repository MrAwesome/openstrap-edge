// Gesture settings — maps a band double-tap to an action. Only offers actions the
// current platform actually supports (from native capabilities); falls back to a
// "nothing available yet" note otherwise. Same card/sheet idiom as the rest of Profile.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../gestures/device_action.dart';
import '../../gestures/gesture_settings.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class GestureSettingsCard extends StatelessWidget {
  const GestureSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppState>().gestureSettings;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return ProCard(
          onTap: () => _pick(context, settings),
          child: Row(
            children: [
              Icon(Ic.watch, size: 22, color: AppColors.coral),
              const SizedBox(width: Sp.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Double-tap your band', style: AppText.title),
                    const SizedBox(height: 2),
                    Text(settings.doubleTap.label, style: AppText.bodySoft),
                  ],
                ),
              ),
              Icon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
            ],
          ),
        );
      },
    );
  }

  void _pick(BuildContext context, GestureSettings settings) {
    final options =
        DeviceAction.values.where((a) => settings.supported.contains(a)).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x5, Sp.x4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Double-tap action', style: AppText.h2),
                const SizedBox(height: 4),
                Text('What happens when you double-tap the band.',
                    style: AppText.captionMuted),
                const SizedBox(height: Sp.x4),
                ...options.map((a) {
                  final selected = a == settings.doubleTap;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      settings.setDoubleTap(a);
                      Navigator.of(sheetCtx).pop();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: Sp.x3, horizontal: Sp.x2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(a.label, style: AppText.body),
                                const SizedBox(height: 2),
                                Text(a.blurb, style: AppText.caption),
                              ],
                            ),
                          ),
                          if (selected)
                            Icon(Ic.check, size: 20, color: AppColors.good),
                        ],
                      ),
                    ),
                  );
                }),
                if (options.length <= 1) ...[
                  const SizedBox(height: Sp.x3),
                  Text('No band actions are available on this device yet.',
                      style: AppText.caption),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
