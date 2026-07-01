import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'type_chart.dart';

/// 깃허브 저장소(owner/repo) — 앱 내 업데이트 확인에 사용
const String kGithubRepo = 'wawa0128/pokemon-overlay';

/// 오버레이를 '검색 카드' 크기로 바로 띄운다(메인앱 포그라운드에서 호출 → 안정적).
/// 시작 시 리사이즈(키우기/줄이기)를 안 해서 표면 잔상('흰 네모')이 생기지 않음.
Future<void> showCardOverlay() async {
  await FlutterOverlayWindow.showOverlay(
    // 전체 창 드래그(enableDrag)는 떨림의 원인 → 끄고, 카드 안 포켓볼 핸들로만 이동.
    enableDrag: false,
    overlayTitle: '포켓몬 약점',
    overlayContent: '탭하여 검색',
    flag: OverlayFlag.focusPointer, // 키보드 입력 가능
    visibility: NotificationVisibility.visibilityPublic,
    positionGravity: PositionGravity.none,
    height: 820, // px (요약 카드 높이에 맞춤)
    width: WindowSize.matchParent,
    startPosition: const OverlayPosition(0, 0),
  );
}

// ─────────────────────────────────────────────────────────────
// 화면 캡처 + 한국어 OCR (메인 아이솔레이트에서만 동작)
// ─────────────────────────────────────────────────────────────
class OcrService {
  static const _ch = MethodChannel('pokemon/ocr');

  static Future<bool> requestProjection() async =>
      (await _ch.invokeMethod('requestProjection')) == true;
  static Future<bool> isReady() async =>
      (await _ch.invokeMethod('isProjectionReady')) == true;
  static Future<void> log(String m) async {
    try {
      await _ch.invokeMethod('log', m);
    } catch (_) {}
  }

  /// 오버레이 엔진에도 OCR 채널을 등록 (showOverlay 직후 메인이 호출)
  static Future<bool> prepareOverlayEngine() async {
    try {
      return (await _ch.invokeMethod('prepareOverlayEngine')) == true;
    } catch (_) {
      return false;
    }
  }

  /// 네이티브에서 화면 캡처 + 한국어 OCR 을 한 번에 수행 → 인식된 텍스트 줄 목록
  static Future<List<String>> captureAndOcr() async {
    final r = await _ch.invokeMethod<List<dynamic>>('captureAndOcr');
    return (r ?? const []).map((e) => e.toString()).toList();
  }

  /// OCR 텍스트에서 포켓몬 이름 찾기. (포켓몬, 인식률 0~1) 반환.
  static (Pokemon?, double) matchName(List<Pokemon> all, List<String> texts) {
    Pokemon? best;
    int bestLen = 0;
    bool exact = false;
    for (final p in all) {
      if (p.ko.length < 2) continue;
      for (final t in texts) {
        final clean = t.replaceAll(RegExp(r'\s'), '');
        if (clean == p.ko) {
          if (!exact || p.ko.length > bestLen) {
            best = p;
            bestLen = p.ko.length;
            exact = true;
          }
        } else if (!exact && clean.contains(p.ko) && p.ko.length > bestLen) {
          best = p;
          bestLen = p.ko.length;
        }
      }
    }
    double conf = 0;
    if (best != null) {
      conf = exact ? 0.97 : (bestLen >= 3 ? 0.88 : 0.78);
    }
    return (best, conf);
  }
}

// ─────────────────────────────────────────────────────────────
// 업데이트 — 깃허브 최신 릴리스 확인 → 릴리스 페이지를 브라우저로 열기
// (앱 내 APK 자동설치는 금융앱 악성앱 오탐을 유발해 폐기함)
// ─────────────────────────────────────────────────────────────
class ReleaseInfo {
  final String version; // 예: 1.2.3
  final String pageUrl; // 릴리스 페이지(html_url) — 브라우저로 열어 APK 내려받기
  final String notes;
  ReleaseInfo(this.version, this.pageUrl, this.notes);
}

class UpdateService {
  /// 깃허브 최신 릴리스 조회. 없거나 실패하면 null.
  static Future<ReleaseInfo?> fetchLatest() async {
    try {
      final res = await http
          .get(
            Uri.parse(
                'https://api.github.com/repos/$kGithubRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').replaceAll(
          RegExp(r'^v', caseSensitive: false), '');
      // 릴리스 페이지 URL(없으면 저장소 릴리스 목록으로 대체).
      final page = (data['html_url'] as String?) ??
          'https://github.com/$kGithubRepo/releases';
      if (tag.isEmpty) return null;
      return ReleaseInfo(tag, page, data['body'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  /// remote 가 local 보다 높은 버전이면 true (1.2.10 > 1.2.9 같은 숫자 비교).
  static bool isNewer(String remote, String local) {
    List<int> parse(String v) => v
        .split('+')
        .first
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final r = parse(remote), l = parse(local);
    final n = r.length > l.length ? r.length : l.length;
    for (var i = 0; i < n; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }
}

void main() {
  runApp(const ControlApp());
}

/// 오버레이(게임 위 떠있는 창)의 진입점
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const OverlayApp());
}

// ─────────────────────────────────────────────────────────────
// 포켓몬 데이터 모델 & 저장소
// ─────────────────────────────────────────────────────────────
class Pokemon {
  final int id;
  final String ko;
  final String en;
  final List<String> types;
  final int atk; // 공격력 (attack / sp.attack 중 큰 값)
  final int bst; // 종족값 합계
  final bool leg; // 전설/환상 여부
  Pokemon(this.id, this.ko, this.en, this.types, this.atk, this.bst, this.leg);

  factory Pokemon.fromJson(Map<String, dynamic> j) => Pokemon(
        j['id'] as int,
        j['ko'] as String,
        j['en'] as String,
        (j['types'] as List).map((e) => e as String).toList(),
        (j['atk'] as num).toInt(),
        (j['bst'] as num).toInt(),
        j['leg'] as bool? ?? false,
      );
}

class PokemonRepo {
  static List<Pokemon>? _cache;

  static Future<List<Pokemon>> load() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle.loadString('assets/pokemon.json');
    final list = (jsonDecode(raw) as List)
        .map((e) => Pokemon.fromJson(e as Map<String, dynamic>))
        .toList();
    _cache = list;
    return list;
  }

  /// 한국어 이름 부분검색. 정확일치 → 시작일치 → 포함 순.
  static List<Pokemon> search(List<Pokemon> all, String q) {
    final query = q.trim();
    if (query.isEmpty) return const [];
    final matches = all.where((p) => p.ko.contains(query)).toList();
    matches.sort((a, b) {
      int rank(Pokemon p) {
        if (p.ko == query) return 0;
        if (p.ko.startsWith(query)) return 1;
        return 2;
      }

      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return a.id.compareTo(b.id);
    });
    return matches.take(30).toList();
  }

  /// 타입 상성 기반 카운터 추천: 상대 약점을 찌르는 강한 공격수 순.
  static List<Pokemon> counters(List<Pokemon> all, Pokemon target) {
    final list = all.where((q) {
      if (q.id == target.id) return false;
      // 포켓몬고 효과굉장(1.6배) 이상이면 카운터 후보
      return bestDamageMultiplier(q.types, target.types) > 1.0;
    }).toList();
    list.sort((a, b) {
      final ea = bestDamageMultiplier(a.types, target.types);
      final eb = bestDamageMultiplier(b.types, target.types);
      if (eb != ea) return eb.compareTo(ea); // 더 잘 통하는 순
      return b.atk.compareTo(a.atk); // 공격력 높은 순
    });
    return list.take(5).toList();
  }
}

// ─────────────────────────────────────────────────────────────
// 메인(컨트롤) 앱 — 오버레이 켜고 끄기
// ─────────────────────────────────────────────────────────────
class ControlApp extends StatelessWidget {
  const ControlApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '포켓몬 약점 검색',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const RootPager(),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 메인 페이저 — 좌우 스와이프(검색 ↔ 티어표) + 하단 탭
// ─────────────────────────────────────────────────────────────
class RootPager extends StatefulWidget {
  const RootPager({super.key});
  @override
  State<RootPager> createState() => _RootPagerState();
}

class _RootPagerState extends State<RootPager> {
  final _pc = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _go(int i) => _pc.animateToPage(i,
      duration: const Duration(milliseconds: 280), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pc,
        onPageChanged: (i) => setState(() => _page = i),
        children: const [ControlPage(), TierListPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: _go,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.search), label: '약점 검색'),
          NavigationDestination(
              icon: Icon(Icons.leaderboard), label: '타입별 티어'),
        ],
      ),
    );
  }
}

class ControlPage extends StatefulWidget {
  const ControlPage({super.key});
  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  String _status = '오버레이가 꺼져 있어요';
  bool _ocrReady = false;
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
    // 시작 시 조용히 업데이트 확인
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
  }

  Future<void> _checkUpdate({bool manual = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    if (manual) setState(() => _status = '업데이트 확인 중…');
    final info = await PackageInfo.fromPlatform();
    final latest = await UpdateService.fetchLatest();
    if (!mounted) return;
    setState(() => _checking = false);
    if (latest == null) {
      if (manual) setState(() => _status = '업데이트 정보를 가져오지 못했어요.');
      return;
    }
    if (UpdateService.isNewer(latest.version, info.version)) {
      _promptUpdate(latest);
    } else if (manual) {
      setState(() => _status = '이미 최신 버전이에요 (v${info.version}).');
    }
  }

  void _promptUpdate(ReleaseInfo r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('새 버전 v${r.version}'),
        content: SingleChildScrollView(
          child: Text(
            '${r.notes.trim().isEmpty ? '새 버전이 있어요.' : r.notes.trim()}'
            '\n\n[다운로드]를 누르면 브라우저로 릴리스 페이지가 열려요.\n'
            '거기서 APK를 내려받아 설치하면 됩니다.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openRelease(r);
            },
            child: const Text('다운로드'),
          ),
        ],
      ),
    );
  }

  /// 릴리스 페이지를 외부 브라우저로 연다(앱 내 자동설치 대신).
  Future<void> _openRelease(ReleaseInfo r) async {
    final uri = Uri.parse(r.pageUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      setState(() => _status = '브라우저를 열지 못했어요: ${r.pageUrl}');
    }
  }

  Future<void> _enableOcr() async {
    setState(() => _status = '화면 캡처 권한을 요청합니다…');
    final ok = await OcrService.requestProjection();
    setState(() {
      _ocrReady = ok;
      _status = ok ? '화면 인식 준비 완료! 오버레이의 📷 버튼을 누르세요.' : '화면 캡처 권한이 거부됐어요.';
    });
  }

  Future<void> _startOverlay() async {
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted) {
      setState(() => _status = '권한을 요청합니다…');
      await FlutterOverlayWindow.requestPermission();
      final after = await FlutterOverlayWindow.isPermissionGranted();
      if (!after) {
        setState(() => _status = '권한이 거부되었습니다. 설정에서 허용해주세요.');
        return;
      }
    }
    if (await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.closeOverlay();
    }
    await showCardOverlay();
    // 오버레이 엔진에도 OCR 채널 등록 (엔진 생성 대기 후)
    await Future.delayed(const Duration(milliseconds: 800));
    final okEng = await OcrService.prepareOverlayEngine();
    setState(() => _status = okEng
        ? '오버레이 실행 중! 🔍 버튼 탭 → 검색 또는 📷 자동인식'
        : '오버레이 실행 중! 포켓몬고를 켜고 🔍 버튼을 탭하세요.');
  }

  Future<void> _stopOverlay() async {
    await FlutterOverlayWindow.closeOverlay();
    setState(() => _status = '오버레이를 껐습니다');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('포켓몬 약점 검색'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.catching_pokemon, size: 80, color: Colors.red),
            const SizedBox(height: 16),
            const Text(
              '게임 위에 뜨는 약점 검색창',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _startOverlay,
              icon: const Icon(Icons.play_arrow),
              label: const Text('오버레이 켜기'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _stopOverlay,
              icon: const Icon(Icons.stop),
              label: const Text('오버레이 끄기'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _enableOcr,
              icon: Icon(_ocrReady ? Icons.check_circle : Icons.camera_alt),
              label: Text(_ocrReady ? '화면 인식 준비됨' : '화면 인식(OCR) 켜기'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _checking ? null : () => _checkUpdate(manual: true),
              icon: _checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.system_update),
              label: Text(_checking ? '확인 중…' : '업데이트 확인'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const Spacer(),
            if (_version.isNotEmpty)
              Text('현재 버전 v$_version',
                  style: const TextStyle(fontSize: 12, color: Colors.black38)),
            const SizedBox(height: 4),
            const Text(
              '① "다른 앱 위에 표시" + ② "화면 캡처" 권한을 허용해주세요.\n'
              '화면 인식은 게임 속 포켓몬 이름을 자동으로 읽어줍니다.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 타입별 레이드 티어표 (포켓몬고 공격 메타)
// ─────────────────────────────────────────────────────────────
class TierEntry {
  final String ko;
  final String tier; // S / A / B
  final bool mega;
  TierEntry(this.ko, this.tier, this.mega);
  factory TierEntry.fromJson(Map<String, dynamic> j) =>
      TierEntry(j['ko'] as String, j['tier'] as String, j['mega'] as bool? ?? false);
}

Color _tierColor(String t) {
  switch (t) {
    case 'S':
      return const Color(0xFFE53935);
    case 'A':
      return const Color(0xFFFB8C00);
    default:
      return const Color(0xFF757575);
  }
}

class TierListPage extends StatefulWidget {
  const TierListPage({super.key});
  @override
  State<TierListPage> createState() => _TierListPageState();
}

class _TierListPageState extends State<TierListPage> {
  Map<String, List<TierEntry>> _tiers = {};
  Map<String, Pokemon> _byName = {};
  String _type = 'fire';
  bool _includeMega = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await PokemonRepo.load();
    final raw = await rootBundle.loadString('assets/raid_tiers.json');
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final tiers = m.map((k, v) => MapEntry(
        k, (v as List).map((e) => TierEntry.fromJson(e as Map<String, dynamic>)).toList()));
    if (!mounted) return;
    setState(() {
      _byName = {for (final p in all) p.ko: p};
      _tiers = tiers;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = [
      for (final e in (_tiers[_type] ?? const <TierEntry>[]))
        if (_includeMega || !e.mega) e
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('타입별 레이드 티어'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 메가 포함/제외 토글
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('메가 포함')),
                      ButtonSegment(value: false, label: Text('메가 제외')),
                    ],
                    selected: {_includeMega},
                    onSelectionChanged: (s) =>
                        setState(() => _includeMega = s.first),
                  ),
                ),
                // 타입 선택 가로 스크롤
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final t in allTypes)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: ChoiceChip(
                            label: Text(
                                '${typeEmoji[t] ?? ''}${typeKo[t] ?? t}',
                                style: TextStyle(
                                    color: _type == t
                                        ? Colors.white
                                        : Colors.black87,
                                    fontWeight: FontWeight.bold)),
                            selected: _type == t,
                            selectedColor: colorOf(t),
                            backgroundColor: colorOf(t).withValues(alpha: 0.18),
                            showCheckmark: false,
                            onSelected: (_) => setState(() => _type = t),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('데이터가 없어요.'))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                          itemCount: entries.length + 1,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 8),
                          itemBuilder: (ctx, i) {
                            if (i == entries.length) {
                              return const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  '※ 포켓몬고 레이드 공격 메타 기준(대략). '
                                  '게임 업데이트로 순위는 바뀔 수 있어요.',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.black45),
                                ),
                              );
                            }
                            return _tierRow(i + 1, entries[i]);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _tierRow(int rank, TierEntry e) {
    final p = _byName[e.ko];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6)
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text('$rank',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.black45)),
          ),
          // 티어 배지
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _tierColor(e.tier),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(e.tier,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(e.ko,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                    if (e.mega)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('메가/원시',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.purple,
                                fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
                if (p != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 4,
                      children: [for (final t in p.types) _miniTypeChip(t)],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniTypeChip(String type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorOf(type),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('${typeEmoji[type] ?? ''}${typeKo[type] ?? type}',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 오버레이 앱 — 3단계: 버블 → 미니카드 → 상세 바텀시트
// ─────────────────────────────────────────────────────────────
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OverlayRoot(),
    );
  }
}

enum Stage { bubble, mini, full }

class OverlayRoot extends StatefulWidget {
  const OverlayRoot({super.key});
  @override
  State<OverlayRoot> createState() => _OverlayRootState();
}

class _OverlayRootState extends State<OverlayRoot> {
  Stage _stage = Stage.mini;
  List<Pokemon> _all = [];
  List<Pokemon> _results = [];
  Pokemon? _selected;
  final _controller = TextEditingController();
  bool _scanning = false;
  int? _confidence; // 마지막 OCR 인식률(%)
  double _opacity = 1.0; // 카드 투명도(0.3~1.0)
  int _repaint = 0; // 표면 잔상 방지용 강제 리페인트 카운터
  double _cardDy = 0; // 카드 세로 오프셋(화면 중앙 기준, dp)
  double _bx = 12, _by = 90; // 버블 위치(화면 중앙 기준 오프셋, dp)

  @override
  void initState() {
    super.initState();
    PokemonRepo.load().then((v) {
      setState(() => _all = v);
      // 예시로 한 마리 미리 표시 (목업과 동일하게)
      _select(v.firstWhere((p) => p.ko == '뮤츠', orElse: () => v.first));
    });
    // 시작 시 카드를 '중앙 기준(0,0)'으로 정규화 → 이후 최소화 좌표 계산이 일관됨.
    // (matchParent 폭 유지 + 높이 키우기만이라 흰 네모 없음)
    WidgetsBinding.instance.addPostFrameCallback((_) => _goMini());
  }

  /// 📷 화면 인식: 잠깐 작게 줄여 화면을 가린 카드를 치우고 캡처 → 매칭 → 카드 복귀
  Future<void> _scan() async {
    setState(() => _scanning = true);
    // 캡처 동안만 작게(시각은 중요치 않음 — 뒤 게임화면을 캡처)
    await FlutterOverlayWindow.resizeOverlay(40, 40, true);
    await Future.delayed(const Duration(milliseconds: 400));
    try {
      final texts = await OcrService.captureAndOcr()
          .timeout(const Duration(seconds: 12), onTimeout: () => <String>[]);
      if (_all.isEmpty) _all = await PokemonRepo.load();
      final (poke, conf) = OcrService.matchName(_all, texts);
      if (poke != null) {
        _controller.text = poke.ko;
        setState(() {
          _selected = poke;
          _results = [poke];
          _confidence = (conf * 100).round();
          _scanning = false;
        });
      } else {
        setState(() {
          _scanning = false;
          _confidence = null;
        });
      }
    } catch (_) {
      setState(() => _scanning = false);
    }
    await _goMini();
  }

  /// 오버레이 자체를 완전히 끄기
  Future<void> _closeOverlay() async {
    await FlutterOverlayWindow.closeOverlay();
  }

  void _select(Pokemon p) {
    _controller.text = p.ko;
    setState(() {
      _selected = p;
      _results = [p];
    });
  }

  void _onSearch(String q) {
    final r = PokemonRepo.search(_all, q);
    setState(() {
      _results = r;
      _selected = r.isNotEmpty ? r.first : null;
      _confidence = null; // 수동 검색이면 인식률 표시 안 함
    });
  }

  // 미니 카드 높이(dp). 핸들 위치 계산에 사용.
  static const double _miniH = 320;
  static const double _fullH = 640;
  // 카드 좌상단에서 포켓볼 핸들 중심까지의 대략 오프셋(dp)
  static const double _handleX = 31;
  static const double _handleY = 30;

  // 미니 카드로 펼치기(폭 matchParent로 '키우기' → 잔상 없음).
  // fromBubble=true면 버블이 있던 자리에서 핸들이 시작되도록 카드 위치를 맞춘다.
  Future<void> _goMini({bool fromBubble = false}) async {
    if (fromBubble) {
      // 버블이 (드래그로) 옮겨진 실제 위치를 먼저 읽어와 인계 좌표로 쓴다.
      await _syncPos();
      // 버블 중심 y = 핸들 중심 y 가 되도록 카드 세로 오프셋 역산(미니 기준).
      final maxDy = _screenH / 2 - _miniH / 2;
      _cardDy = (_by + (_miniH / 2 - _handleY)).clamp(-maxDy, maxDy);
    } else {
      _cardDy = 0;
    }
    setState(() {
      _stage = Stage.mini;
      _repaint++;
    });
    await FlutterOverlayWindow.updateFlag(OverlayFlag.focusPointer);
    // 미니는 위치 이동 가능 → 네이티브 드래그 on(떨림 없음).
    await FlutterOverlayWindow.resizeOverlay(WindowSize.matchParent, 320, true);
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(0, _cardDy));
    if (mounted) setState(() => _repaint++);
  }

  Future<void> _goFull() async {
    _cardDy = 0; // 상세(3단계)는 화면 중앙 고정(드래그 없음) → 넘침 방지.
    setState(() {
      _stage = Stage.full;
      _repaint++;
    });
    await FlutterOverlayWindow.updateFlag(OverlayFlag.focusPointer);
    await FlutterOverlayWindow.resizeOverlay(WindowSize.matchParent, 640, false);
    await FlutterOverlayWindow.moveOverlay(const OverlayPosition(0, 0));
    if (mounted) setState(() => _repaint++);
  }

  /// 최소화: 카드 → 좌측 포켓볼 버블. (창을 작게 '줄이는' 동작이라
  /// 잔상이 생기지 않도록 내용→리사이즈→다중 강제 리페인트 순으로 처리)
  Future<void> _goBubble() async {
    // 최소화 직전 카드 높이로 핸들(포켓볼) 위치를 계산 → 버블을 그 자리에 둔다.
    // moveOverlay(x,y) = 화면 중앙 기준 오프셋(dp). 카드는 Align.topCenter라 핸들 ≈ 창 상단.
    final cardH = _stage == Stage.full ? _fullH : _miniH;
    // 미니가 드래그로 옮겨졌을 수 있으니 실제 카드 위치를 먼저 읽어온다.
    if (_stage == Stage.mini) await _syncPos();
    final mx = _screenW / 2 - _bubble / 2;
    final my = _screenH / 2 - _bubble / 2;
    _bx = (-_screenW / 2 + _handleX).clamp(-mx, mx);
    _by = (_cardDy - cardH / 2 + _handleY).clamp(-my, my);
    // 1) 먼저 버블 내용으로 바꿔 현재 크기에서 한 프레임 그린다.
    setState(() {
      _stage = Stage.bubble;
      _repaint++;
    });
    await Future.delayed(const Duration(milliseconds: 32));
    // 2) 창을 작게 줄이고 포커스 해제(키보드 안 뜨게) + 버블 자리로 이동.
    //    네이티브 드래그 on → 버블을 손가락으로 매끄럽게 옮길 수 있다.
    await FlutterOverlayWindow.updateFlag(OverlayFlag.defaultFlag);
    await FlutterOverlayWindow.resizeOverlay(_bubble.round(), _bubble.round(), true);
    await FlutterOverlayWindow.moveOverlay(OverlayPosition(_bx, _by));
    // 3) 줄어든 새 크기에서 새 프레임을 여러 번 강제로 그려 흰 네모(표면 잔상) 제거.
    for (final ms in const [40, 90, 170]) {
      await Future.delayed(Duration(milliseconds: ms));
      if (mounted) setState(() => _repaint++);
    }
  }

  /// 화면(디스플레이) 크기 dp — moveOverlay 좌표 계산용.
  double get _screenW {
    final d = ui.PlatformDispatcher.instance.displays.first;
    return d.size.width / d.devicePixelRatio;
  }

  double get _screenH {
    final d = ui.PlatformDispatcher.instance.displays.first;
    return d.size.height / d.devicePixelRatio;
  }

  /// 최소화 버블(몬스터볼) 한 변 크기(dp). 흰 배경 없이 공만.
  static const double _bubble = 34;

  // ── 떨림 없는 드래그 ─────────────────────────────
  // 드래그는 네이티브(enableDrag=true)가 getRawX/Y(절대 화면좌표)로 직접 처리한다.
  // Flutter에서 moveOverlay를 매 이벤트 호출하면 창이 움직이며 터치 좌표계가 어긋나
  // 피드백 진동(떨림)이 생기는데, 네이티브 드래그는 그 루프가 없어 매끄럽다.
  // 탭(이동 5px 미만)은 그대로 통과하므로 onTap(최소화/펼치기)도 정상 동작한다.

  /// 네이티브 드래그로 옮겨진 실제 위치(dp, 화면 중앙 기준)를 Dart 상태로 동기화.
  /// 단계 전환 직전에 호출해 인계 좌표가 어긋나지 않게 한다.
  Future<void> _syncPos() async {
    try {
      final p = await FlutterOverlayWindow.getOverlayPosition();
      if (_stage == Stage.bubble) {
        _bx = p.x;
        _by = p.y;
      } else if (_stage == Stage.mini) {
        _cardDy = p.y;
      }
    } catch (_) {
      // 위치 조회 실패 시 마지막으로 알던 값 유지.
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_stage == Stage.bubble) {
      child = _buildBubble();
    } else {
      final card = _stage == Stage.full ? _buildFull() : _buildMini();
      child = Opacity(opacity: _opacity, child: card);
    }
    return Material(
      color: Colors.transparent,
      // 키를 바꿔 새 프레임을 강제(줄이기 후 흰 네모 방지).
      child: KeyedSubtree(key: ValueKey(_repaint), child: child),
    );
  }

  // ── 1단계: 최소화 버블(좌측 포켓볼) ──────────────────
  // 탭 → 미니 카드로 복귀, 드래그(이동)는 네이티브가 처리.
  Widget _buildBubble() {
    return Align(
      alignment: Alignment.topLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _goMini(fromBubble: true),
        // 흰 원 배경 없이 몬스터볼 아이콘만(절반 크기). 어두운 배경서도 보이게 옅은 그림자.
        child: Container(
          width: _bubble,
          height: _bubble,
          alignment: Alignment.center,
          child: Icon(
            Icons.catching_pokemon,
            color: Colors.red,
            size: _bubble,
            shadows: const [
              Shadow(color: Colors.black54, blurRadius: 4),
            ],
          ),
        ),
      ),
    );
  }

  // ── 2단계: 미니 정보 카드 (드래그로 이동 가능) ──────────────────
  Widget _buildMini() {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(6),
        decoration: _cardDeco(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _searchBar(),
            const Divider(height: 1),
            _opacityBar(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: _all.isEmpty
                    ? const Text('데이터 로딩 중…')
                    : _selected == null
                        ? const Text('검색 결과가 없어요.',
                            style: TextStyle(color: Colors.black54))
                        : _miniBody(_selected!),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniBody(Pokemon p) {
    final weakTypes = _weaknesses(p);
    final counters = PokemonRepo.counters(_all, p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(p.ko,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const Spacer(),
            for (final t in p.types) ...[
              _typeChip(t),
              const SizedBox(width: 4)
            ],
          ],
        ),
        if (_confidence != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('📷 인식률 $_confidence%',
                style: const TextStyle(fontSize: 11, color: Colors.green)),
          ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('약점  ', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [for (final t in weakTypes) _typeChip(t)],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (counters.isNotEmpty)
          Row(
            children: [
              const Text('추천  ', style: TextStyle(fontWeight: FontWeight.bold)),
              Expanded(
                child: Text(counters.first.ko,
                    style: const TextStyle(color: Colors.black87)),
              ),
            ],
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _goFull,
            icon: const Icon(Icons.expand_more, size: 20),
            label: const Text('자세히 보기'),
          ),
        ),
      ],
    );
  }

  // ── 3단계: 상세 패널 (드래그로 이동 가능) ──────────────────
  Widget _buildFull() {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(6),
        decoration: _cardDeco(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            _searchBar(),
            const Divider(height: 1),
            _opacityBar(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: _all.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('데이터 로딩 중…'))
                    : _selected == null
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('검색 결과가 없어요.'))
                        : _fullBody(_selected!),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fullBody(Pokemon p) {
    final defense = defenseMultipliers(p.types);
    final offense = offenseMultipliers(p.types);
    final weakGroups = groupByMultiplier(defense, weaknessOrder: true)
        .where((e) => e.key > 1.0)
        .toList();
    final resistGroups = groupByMultiplier(defense, weaknessOrder: false)
        .where((e) => e.key < 1.0)
        .toList();
    final strongTypes = [
      for (final e in offense.entries)
        if (e.value > 1.0) e.key
    ];
    final counters = PokemonRepo.counters(_all, p);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 후보 칩 (여러 검색 결과일 때)
        if (_results.length > 1) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in _results.take(12))
                ChoiceChip(
                  label: Text(r.ko, style: const TextStyle(fontSize: 12)),
                  selected: r.id == p.id,
                  onSelected: (_) => setState(() => _selected = r),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        // 이름 + 타입
        Row(
          children: [
            Text(p.ko,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text('#${p.id}',
                style: const TextStyle(color: Colors.black38, fontSize: 14)),
            const Spacer(),
            for (final t in p.types) ...[
              _typeChip(t, big: true),
              const SizedBox(width: 4)
            ],
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              '${p.types.map((t) => typeKo[t]).join(' · ')} 타입',
              style: const TextStyle(color: Colors.black54),
            ),
            if (_confidence != null) ...[
              const SizedBox(width: 8),
              Text('· 📷 인식률 $_confidence%',
                  style: const TextStyle(color: Colors.green, fontSize: 13)),
            ],
          ],
        ),
        const SizedBox(height: 14),
        // 약점
        _sectionTitle('🔴 약점 (데미지 많이 받음)'),
        _multiplierRows(weakGroups),
        const SizedBox(height: 12),
        // 저항
        if (resistGroups.isNotEmpty) ...[
          _sectionTitle('🔵 저항 (데미지 적게 받음)'),
          _multiplierRows(resistGroups),
          const SizedBox(height: 12),
        ],
        // 추천 카운터
        _sectionTitle('⭐ 추천 카운터 (상성 기반)'),
        const SizedBox(height: 4),
        if (counters.isEmpty)
          const Text('추천할 카운터가 없어요.',
              style: TextStyle(color: Colors.black54))
        else
          for (int i = 0; i < counters.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Text('${i + 1}. ',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(counters[i].ko, style: const TextStyle(fontSize: 15)),
                  if (counters[i].leg)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Text('전설',
                          style: TextStyle(
                              fontSize: 10, color: Colors.deepOrange)),
                    ),
                  const SizedBox(width: 8),
                  for (final t in counters[i].types) ...[
                    _typeChip(t),
                    const SizedBox(width: 3),
                  ],
                ],
              ),
            ),
        const SizedBox(height: 12),
        // 배틀 참고
        _sectionTitle('⚔️ 배틀 참고'),
        const SizedBox(height: 4),
        _tipRow('강함', strongTypes, Colors.green),
        const SizedBox(height: 4),
        _tipRow(
            '조심', [for (final g in weakGroups) ...g.value], Colors.redAccent),
        const SizedBox(height: 14),
        // OCR 안내 (Phase B)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '📷 버튼을 누르면 화면 속 포켓몬 이름을 자동 인식합니다. '
            '(메인 앱에서 "화면 인식 켜기" 권한 필요)',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
      ],
    );
  }

  // ── 공통 위젯 ──────────────────────────────
  BoxDecoration _cardDeco() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12)
        ],
      );

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Row(
        children: [
          // 포켓볼 핸들: 탭 → 최소화(버블). 카드 이동은 네이티브 드래그(아무 데나 끌기).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _goBubble,
            child: Tooltip(
              message: '탭: 최소화 / 카드를 끌어 이동',
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.catching_pokemon, color: Colors.red, size: 26),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: _onSearch,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '포켓몬 이름 (예: 뮤츠)',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ),
          _scanning
              ? const SizedBox(
                  width: 40,
                  height: 40,
                  child: Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.red),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.camera_alt, color: Colors.red),
                  tooltip: '화면 인식',
                  visualDensity: VisualDensity.compact,
                  onPressed: _scan,
                ),
          const SizedBox(width: 6),
          // 닫기(X) = 오버레이 완전히 끄기 (최소화/버블 없음)
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 20),
            tooltip: '오버레이 끄기',
            style: IconButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: _closeOverlay,
          ),
        ],
      ),
    );
  }

  // 투명도(게임 화면 비치게) 조절 슬라이더
  Widget _opacityBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
      child: Row(
        children: [
          const Icon(Icons.opacity, size: 18, color: Colors.black45),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                min: 0.3,
                max: 1.0,
                value: _opacity,
                onChanged: (v) => setState(() => _opacity = v),
              ),
            ),
          ),
          SizedBox(
            width: 38,
            child: Text('${(_opacity * 100).round()}%',
                style: const TextStyle(fontSize: 11, color: Colors.black45)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(t,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      );

  Widget _multiplierRows(List<MapEntry<double, List<String>>> groups) {
    if (groups.isEmpty) {
      return const Text('없음', style: TextStyle(color: Colors.black54));
    }
    return Column(
      children: [
        for (final g in groups)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 42,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('×${_fmt(g.key)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [for (final t in g.value) _typeChip(t)],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _tipRow(String label, List<String> types, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          padding: const EdgeInsets.only(top: 3),
          child: Text(label,
              style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ),
        Expanded(
          child: Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [for (final t in types) _typeChip(t)],
          ),
        ),
      ],
    );
  }

  Widget _typeChip(String type, {bool big = false}) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: big ? 12 : 8, vertical: big ? 5 : 3),
      decoration: BoxDecoration(
        color: colorOf(type),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '${typeEmoji[type] ?? ''}${typeKo[type] ?? type}',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: big ? 14 : 12,
        ),
      ),
    );
  }

  List<String> _weaknesses(Pokemon p) {
    final d = defenseMultipliers(p.types);
    final groups = groupByMultiplier(d, weaknessOrder: true)
        .where((e) => e.key > 1.0)
        .toList();
    return [for (final g in groups) ...g.value];
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    // 포켓몬고 배율(2.56/1.6/0.625/0.390625/0.244…)을 최대 3자리로 표기
    var s = v.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s;
  }
}

