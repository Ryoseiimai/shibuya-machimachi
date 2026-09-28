// 「今いる階」のチップ（B5〜10F、横スクロール）。room と route が共有する。
// 値は ownFloorProvider。押すと setByUser（部屋が開いていればサーバーへ floor を送る）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../sensors/floor.dart';
import '../theme.dart';

class FloorChips extends ConsumerStatefulWidget {
  const FloorChips({super.key, this.showLabel = true, this.onChanged});
  final bool showLabel;

  /// 選んだあとに呼ぶ（道順の再計算など）。送信は ownFloorProvider がする。
  final ValueChanged<String>? onChanged;

  @override
  ConsumerState<FloorChips> createState() => _FloorChipsState();
}

class _FloorChipsState extends ConsumerState<FloorChips> {
  final _keys = {for (final f in kFloors) f: GlobalKey()};

  void _center(String? f) {
    final ctx = f == null ? null : _keys[f]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 200));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _center(ref.read(ownFloorProvider)));
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(ownFloorProvider);
    ref.listen(ownFloorProvider, (_, next) => WidgetsBinding.instance.addPostFrameCallback((_) => _center(next)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.showLabel)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '今いる階', style: AppText.label),
            TextSpan(text: '(違ったらタップで直せます)', style: AppText.small),
          ])),
        ),
      Semantics(
        container: true,
        label: '今いる階',
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final f in kFloors)
              Padding(
                key: _keys[f],
                padding: const EdgeInsets.only(right: 6),
                child: _Chip(
                  label: f,
                  selected: f == selected,
                  onTap: () {
                    ref.read(ownFloorProvider.notifier).setByUser(f);
                    widget.onChanged?.call(f);
                  },
                ),
              ),
          ]),
        ),
      ),
    ]);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? AppColors.brandOrange : AppColors.secondaryBg,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 50, minHeight: 44),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800, color: selected ? Colors.white : AppColors.secondaryText)),
                ),
              ),
            ),
          ),
        ),
      );
}
