import 'package:flutter_test/flutter_test.dart';

import 'package:my_first_app/type_chart.dart';

// 포켓몬고 상성: 1.6배 기반 (2.56 / 1.6 / 1.0 / 0.625 / 0.390625 / 0.244…)
void main() {
  test('리자몽(불꽃/비행) 약점 계산 - 포켓몬고 기준', () {
    final d = defenseMultipliers(['fire', 'flying']);
    expect(d['rock'], closeTo(2.56, 1e-9)); // 바위 2중약점
    expect(d['water'], closeTo(1.6, 1e-9));
    expect(d['electric'], closeTo(1.6, 1e-9));
    // 땅: 불꽃 약점(1.6) × 비행 무효→저항(0.390625) = 0.625 (고는 무효가 없음)
    expect(d['ground'], closeTo(0.625, 1e-9));
    expect(d['grass'], closeTo(0.390625, 1e-9)); // 풀 2중 저항
  });

  test('공격 상성(고): 불꽃/비행은 풀에게 강하다', () {
    final o = offenseMultipliers(['fire', 'flying']);
    expect(o['grass'], closeTo(1.6, 1e-9));
    expect(o['bug'], closeTo(1.6, 1e-9));
  });

  test('카운터 상성(고): 악/고스트는 에스퍼(뮤츠)에게 1.6배', () {
    expect(bestDamageMultiplier(['dark'], ['psychic']), closeTo(1.6, 1e-9));
    expect(bestDamageMultiplier(['ghost'], ['psychic']), closeTo(1.6, 1e-9));
    // 격투는 에스퍼에게 약함(0.625) → 카운터 부적합
    expect(bestDamageMultiplier(['fighting'], ['psychic']), closeTo(0.625, 1e-9));
  });
}
