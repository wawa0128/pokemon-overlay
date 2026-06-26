import 'package:flutter_test/flutter_test.dart';

import 'package:my_first_app/type_chart.dart';

void main() {
  test('리자몽(불꽃/비행) 약점 계산', () {
    final d = defenseMultipliers(['fire', 'flying']);
    expect(d['rock'], 4.0); // 바위 4배 약점
    expect(d['water'], 2.0);
    expect(d['electric'], 2.0);
    expect(d['ground'], 0.0); // 비행이라 땅 무효
    expect(d['grass'], 0.25); // 풀 2중 저항
  });

  test('공격 상성: 불꽃/비행은 풀에게 강하다', () {
    final o = offenseMultipliers(['fire', 'flying']);
    expect(o['grass'], 2.0);
    expect(o['bug'], 2.0);
  });

  test('카운터 상성: 악/고스트는 에스퍼(뮤츠)에게 2배', () {
    expect(bestDamageMultiplier(['dark'], ['psychic']), 2.0);
    expect(bestDamageMultiplier(['ghost'], ['psychic']), 2.0);
    // 격투는 에스퍼에게 약함(0.5) → 카운터 부적합
    expect(bestDamageMultiplier(['fighting'], ['psychic']), 0.5);
  });
}
