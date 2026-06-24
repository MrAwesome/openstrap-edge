// Onboarding profile step — collects age / weight / height / sex so the
// on-device analytics can personalize (HRmax via Tanaka 208−0.7·age, Keytel
// calories, Banister TRIMP sex constant, fitness-age). Shown once, between
// pairing and the shell, only while the profile is incomplete.
//
// Persisted via AppState.updateProfile (shared_preferences) — the same local
// map the DerivationEngine reads as a Profile. A field left blank simply means
// the dependent metric stays absent (honesty: never a fabricated default).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});
  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _age = TextEditingController();
  final _weight = TextEditingController();
  final _height = TextEditingController();
  String? _sex; // 'm' | 'f'
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user;
    if (u != null) {
      if (u['age'] != null) _age.text = '${u['age']}';
      if (u['weight_kg'] != null) _weight.text = '${u['weight_kg']}';
      if (u['height_cm'] != null) _height.text = '${u['height_cm']}';
      _sex = (u['sex'] as String?)?.toLowerCase();
    }
  }

  @override
  void dispose() {
    _age.dispose();
    _weight.dispose();
    _height.dispose();
    super.dispose();
  }

  bool get _valid {
    final a = int.tryParse(_age.text.trim());
    final w = double.tryParse(_weight.text.trim());
    final h = double.tryParse(_height.text.trim());
    return _sex != null &&
        a != null && a > 0 && a < 120 &&
        w != null && w > 0 && w < 400 &&
        h != null && h > 0 && h < 260;
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    setState(() => _saving = true);
    try {
      await context.read<AppState>().updateProfile({
        'age': int.parse(_age.text.trim()),
        'weight_kg': double.parse(_weight.text.trim()),
        'height_cm': double.parse(_height.text.trim()),
        'sex': _sex,
      });
      // AppState.route now returns shell — the _Gate rebuilds automatically.
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x6, vertical: Sp.x8),
          children: [
            const SizedBox(height: Sp.x6),
            Text('About you', style: AppText.display),
            const SizedBox(height: Sp.x3),
            Text(
              'OpenStrap computes everything on your phone. These four numbers '
              'personalize your heart-rate ceiling, calories, and training load. '
              'Leave one blank and only that metric stays unknown — never guessed.',
              style: AppText.bodySoft,
            ),
            const SizedBox(height: Sp.x8),
            _label('Sex'),
            const SizedBox(height: Sp.x2),
            Row(children: [
              _sexChip('Male', 'm'),
              const SizedBox(width: Sp.x3),
              _sexChip('Female', 'f'),
            ]),
            const SizedBox(height: Sp.x6),
            _field(_age, 'Age', 'years', TextInputType.number),
            const SizedBox(height: Sp.x4),
            _field(_weight, 'Weight', 'kg', const TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: Sp.x4),
            _field(_height, 'Height', 'cm', const TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: Sp.x8),
            SizedBox(
              height: 54,
              child: FilledButton(
                onPressed: _valid && !_saving ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.coral,
                  disabledBackgroundColor: AppColors.coral.withValues(alpha: 0.3),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(R.pill)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text('Continue',
                        style: AppText.title.copyWith(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String t) =>
      Text(t.toUpperCase(), style: AppText.overline.copyWith(color: AppColors.inkMuted));

  Widget _sexChip(String label, String value) {
    final sel = _sex == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _sex = value);
        },
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? AppColors.coral : AppColors.surface,
            borderRadius: BorderRadius.circular(R.pill),
            border: Border.all(
                color: sel ? AppColors.coral : AppColors.inkMuted.withValues(alpha: 0.3)),
          ),
          child: Text(label,
              style: AppText.title.copyWith(
                  color: sel ? Colors.white : AppColors.ink)),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String unit,
      TextInputType kb) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        const SizedBox(height: Sp.x2),
        TextField(
          controller: c,
          keyboardType: kb,
          onChanged: (_) => setState(() {}),
          style: AppText.metricSm.copyWith(fontSize: 20),
          decoration: InputDecoration(
            suffixText: unit,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(R.cardSm),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x4),
          ),
        ),
      ],
    );
  }
}
