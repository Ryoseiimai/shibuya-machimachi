// デモモード: 端末内の模擬だけで、作成→相手参加→承認→相手が近づく まで進む。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';

void main() {
  test('デモの流れ（承認後に 1F が自動で入り、相手が近づく）', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.listen(roomControllerProvider, (_, _) {});
    final ctrl = c.read(roomControllerProvider.notifier);
    final s = await ctrl.startDemo('');
    expect(s.roomId, DemoConfig.roomId);
    expect(s.inviteUrl, DemoConfig.inviteText);
    expect(c.read(demoModeProvider), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.read(roomControllerProvider).phase, Phase.waitingGuest);
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    expect(c.read(roomControllerProvider).phase, Phase.waitingHostApproval);
    expect(ctrl.approve(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final v = c.read(roomControllerProvider);
    expect(v.phase, Phase.active);
    expect(v.server!.distanceM, inInclusiveRange(250, 262));
    expect(v.server!.other!.nickname, 'すず');
    expect(c.read(ownFloorProvider), '1F');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(c.read(roomControllerProvider).server!.distanceM, lessThan(v.server!.distanceM!));
    await ctrl.leave();
    expect(c.read(demoModeProvider), isFalse);
  });
}
