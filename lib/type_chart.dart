import 'dart:ui';

/// 18개 타입의 영문 키 → 한국어 표기
const Map<String, String> typeKo = {
  'normal': '노말',
  'fire': '불꽃',
  'water': '물',
  'electric': '전기',
  'grass': '풀',
  'ice': '얼음',
  'fighting': '격투',
  'poison': '독',
  'ground': '땅',
  'flying': '비행',
  'psychic': '에스퍼',
  'bug': '벌레',
  'rock': '바위',
  'ghost': '고스트',
  'dragon': '드래곤',
  'dark': '악',
  'steel': '강철',
  'fairy': '페어리',
};

/// 타입별 대표 색상 (칩 표시용)
const Map<String, int> typeColor = {
  'normal': 0xFFA8A77A,
  'fire': 0xFFEE8130,
  'water': 0xFF6390F0,
  'electric': 0xFFF7D02C,
  'grass': 0xFF7AC74C,
  'ice': 0xFF96D9D6,
  'fighting': 0xFFC22E28,
  'poison': 0xFFA33EA1,
  'ground': 0xFFE2BF65,
  'flying': 0xFFA98FF3,
  'psychic': 0xFFF95587,
  'bug': 0xFFA6B91A,
  'rock': 0xFFB6A136,
  'ghost': 0xFF735797,
  'dragon': 0xFF6F35FC,
  'dark': 0xFF705746,
  'steel': 0xFFB7B7CE,
  'fairy': 0xFFD685AD,
};

Color colorOf(String type) => Color(typeColor[type] ?? 0xFF888888);

/// 타입별 이모지 (칩 앞에 표시)
const Map<String, String> typeEmoji = {
  'normal': '⚪',
  'fire': '🔥',
  'water': '💧',
  'electric': '⚡',
  'grass': '🌱',
  'ice': '❄️',
  'fighting': '🥊',
  'poison': '☠️',
  'ground': '⛰️',
  'flying': '🕊️',
  'psychic': '🔮',
  'bug': '🐛',
  'rock': '🪨',
  'ghost': '👻',
  'dragon': '🐉',
  'dark': '🌑',
  'steel': '⚙️',
  'fairy': '🧚',
};

/// 공격 타입 → (방어 타입 → 배율). 기본값 1.0, 여기 없는 조합은 1배.
/// 2.0 = 효과 굉장, 0.5 = 효과 별로, 0.0 = 효과 없음
const Map<String, Map<String, double>> _chart = {
  'normal': {'rock': 0.5, 'ghost': 0.0, 'steel': 0.5},
  'fire': {
    'fire': 0.5, 'water': 0.5, 'grass': 2.0, 'ice': 2.0, 'bug': 2.0,
    'rock': 0.5, 'dragon': 0.5, 'steel': 2.0,
  },
  'water': {
    'fire': 2.0, 'water': 0.5, 'grass': 0.5, 'ground': 2.0, 'rock': 2.0,
    'dragon': 0.5,
  },
  'electric': {
    'water': 2.0, 'electric': 0.5, 'grass': 0.5, 'ground': 0.0, 'flying': 2.0,
    'dragon': 0.5,
  },
  'grass': {
    'fire': 0.5, 'water': 2.0, 'grass': 0.5, 'poison': 0.5, 'ground': 2.0,
    'flying': 0.5, 'bug': 0.5, 'rock': 2.0, 'dragon': 0.5, 'steel': 0.5,
  },
  'ice': {
    'fire': 0.5, 'water': 0.5, 'grass': 2.0, 'ice': 0.5, 'ground': 2.0,
    'flying': 2.0, 'dragon': 2.0, 'steel': 0.5,
  },
  'fighting': {
    'normal': 2.0, 'ice': 2.0, 'poison': 0.5, 'flying': 0.5, 'psychic': 0.5,
    'bug': 0.5, 'rock': 2.0, 'ghost': 0.0, 'dark': 2.0, 'steel': 2.0,
    'fairy': 0.5,
  },
  'poison': {
    'grass': 2.0, 'poison': 0.5, 'ground': 0.5, 'rock': 0.5, 'ghost': 0.5,
    'steel': 0.0, 'fairy': 2.0,
  },
  'ground': {
    'fire': 2.0, 'electric': 2.0, 'grass': 0.5, 'poison': 2.0, 'flying': 0.0,
    'bug': 0.5, 'rock': 2.0, 'steel': 2.0,
  },
  'flying': {
    'electric': 0.5, 'grass': 2.0, 'fighting': 2.0, 'bug': 2.0, 'rock': 0.5,
    'steel': 0.5,
  },
  'psychic': {
    'fighting': 2.0, 'poison': 2.0, 'psychic': 0.5, 'dark': 0.0, 'steel': 0.5,
  },
  'bug': {
    'fire': 0.5, 'grass': 2.0, 'fighting': 0.5, 'poison': 0.5, 'flying': 0.5,
    'psychic': 2.0, 'ghost': 0.5, 'dark': 2.0, 'steel': 0.5, 'fairy': 0.5,
  },
  'rock': {
    'fire': 2.0, 'ice': 2.0, 'fighting': 0.5, 'ground': 0.5, 'flying': 2.0,
    'bug': 2.0, 'steel': 0.5,
  },
  'ghost': {
    'normal': 0.0, 'psychic': 2.0, 'ghost': 2.0, 'dark': 0.5,
  },
  'dragon': {'dragon': 2.0, 'steel': 0.5, 'fairy': 0.0},
  'dark': {
    'fighting': 0.5, 'psychic': 2.0, 'ghost': 2.0, 'dark': 0.5, 'fairy': 0.5,
  },
  'steel': {
    'fire': 0.5, 'water': 0.5, 'electric': 0.5, 'ice': 2.0, 'rock': 2.0,
    'steel': 0.5, 'fairy': 2.0,
  },
  'fairy': {
    'fire': 0.5, 'fighting': 2.0, 'poison': 0.5, 'dragon': 2.0, 'dark': 2.0,
    'steel': 0.5,
  },
};

const List<String> allTypes = [
  'normal', 'fire', 'water', 'electric', 'grass', 'ice', 'fighting', 'poison',
  'ground', 'flying', 'psychic', 'bug', 'rock', 'ghost', 'dragon', 'dark',
  'steel', 'fairy',
];

double _mult(String atk, String def) => _chart[atk]?[def] ?? 1.0;

/// 공격 타입들(자속)이 방어 타입 조합에게 줄 수 있는 최대 배율.
/// 카운터 추천에서 "이 포켓몬이 상대에게 얼마나 세게 들어가나" 계산용.
double bestDamageMultiplier(List<String> attackerTypes, List<String> defenderTypes) {
  double best = 0.0;
  for (final atk in attackerTypes) {
    double m = 1.0;
    for (final def in defenderTypes) {
      m *= _mult(atk, def);
    }
    if (m > best) best = m;
  }
  return best;
}

/// 방어 상성: 이 포켓몬(types)이 각 공격 타입에게 받는 최종 배율
Map<String, double> defenseMultipliers(List<String> types) {
  final result = <String, double>{};
  for (final atk in allTypes) {
    double m = 1.0;
    for (final def in types) {
      m *= _mult(atk, def);
    }
    result[atk] = m;
  }
  return result;
}

/// 공격 상성: 이 포켓몬의 타입(자속 기술)으로 공격할 때
/// 각 방어 타입에게 줄 수 있는 최대 배율
Map<String, double> offenseMultipliers(List<String> types) {
  final result = <String, double>{};
  for (final def in allTypes) {
    double best = 0.0;
    for (final atk in types) {
      final m = _mult(atk, def);
      if (m > best) best = m;
    }
    result[def] = best;
  }
  return result;
}

/// 배율별로 타입 목록을 묶어서 (큰 배율 먼저) 반환
List<MapEntry<double, List<String>>> groupByMultiplier(
  Map<String, double> mults, {
  required bool weaknessOrder,
}) {
  final groups = <double, List<String>>{};
  mults.forEach((type, m) {
    groups.putIfAbsent(m, () => []).add(type);
  });
  final keys = groups.keys.toList()
    ..sort((a, b) => weaknessOrder ? b.compareTo(a) : a.compareTo(b));
  return [for (final k in keys) MapEntry(k, groups[k]!)];
}
