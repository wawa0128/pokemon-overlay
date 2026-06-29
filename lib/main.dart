import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ota_update/ota_update.dart';

import 'type_chart.dart';

/// 깃허브 저장소(owner/repo) — 앱 내 업데이트 확인에 사용
const String kGithubRepo = 'wawa0128/pokemon-overlay';

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
// 앱 내 업데이트 — 깃허브 최신 릴리스 확인 → APK 다운로드/설치
// ─────────────────────────────────────────────────────────────
class ReleaseInfo {
  final String version; // 예: 1.2.3
  final String apkUrl;
  final String notes;
  ReleaseInfo(this.version, this.apkUrl, this.notes);
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
      final assets = (data['assets'] as List?) ?? const [];
      String? apkUrl;
      for (final a in assets) {
        final name = (a['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk')) {
          apkUrl = a['browser_download_url'] as String?;
          break;
        }
      }
      if (tag.isEmpty || apkUrl == null) return null;
      return ReleaseInfo(tag, apkUrl, data['body'] as String? ?? '');
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
  int? _dlPercent; // 업데이트 다운로드 진행률(%)

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
          child: Text(r.notes.trim().isEmpty
              ? '새 버전이 있어요. 지금 업데이트할까요?'
              : r.notes.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _runOta(r);
            },
            child: const Text('업데이트'),
          ),
        ],
      ),
    );
  }

  void _runOta(ReleaseInfo r) {
    setState(() {
      _dlPercent = 0;
      _status = '업데이트 다운로드 중…';
    });
    try {
      OtaUpdate()
          .execute(r.apkUrl, destinationFilename: 'pokemon-update.apk')
          .listen((e) {
        switch (e.status) {
          case OtaStatus.DOWNLOADING:
            final p = int.tryParse(e.value ?? '');
            if (mounted) setState(() => _dlPercent = p);
            break;
          case OtaStatus.INSTALLING:
            if (mounted) {
              setState(() {
                _dlPercent = null;
                _status = '설치 화면을 여는 중…';
              });
            }
            break;
          default:
            if (mounted) {
              setState(() {
                _dlPercent = null;
                _status = '업데이트 실패: ${e.status.name}. "알 수 없는 앱 설치" 권한을 확인하세요.';
              });
            }
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _dlPercent = null;
          _status = '업데이트 오류: $e';
        });
      }
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
    await FlutterOverlayWindow.showOverlay(
      enableDrag: true,
      overlayTitle: '포켓몬 약점',
      overlayContent: '탭하여 검색',
      flag: OverlayFlag.defaultFlag,
      visibility: NotificationVisibility.visibilityPublic,
      // none: 위치를 moveOverlay로 직접 제어(auto면 가장자리로 스냅되어 덮어씀).
      // 좌표는 "화면 중앙 기준 offset". showOverlay는 px, resize/move는 dp 단위.
      positionGravity: PositionGravity.none,
      height: 160,
      width: 160,
      startPosition: const OverlayPosition(0, 0),
    );
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
            if (_dlPercent != null) ...[
              LinearProgressIndicator(value: _dlPercent! / 100),
              const SizedBox(height: 6),
              Text('다운로드 중… $_dlPercent%',
                  style: const TextStyle(color: Colors.black54)),
            ] else
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
  Stage _stage = Stage.bubble;
  List<Pokemon> _all = [];
  List<Pokemon> _results = [];
  Pokemon? _selected;
  final _controller = TextEditingController();
  bool _scanning = false;
  int? _confidence; // 마지막 OCR 인식률(%)

  @override
  void initState() {
    super.initState();
    PokemonRepo.load().then((v) {
      setState(() => _all = v);
      // 예시로 한 마리 미리 표시 (목업과 동일하게)
      _select(v.firstWhere((p) => p.ko == '뮤츠', orElse: () => v.first));
    });
    // 시작 시 버블 크기를 56dp로 정규화(showOverlay px 크기와 무관하게 통일 → 깨짐 방지)
    WidgetsBinding.instance.addPostFrameCallback((_) => _goBubble());
  }

  /// 📷 화면 인식: 버블로 접은 뒤 네이티브에서 직접 캡처+OCR → 매칭 → 표시
  Future<void> _scan() async {
    setState(() => _scanning = true);
    await _goBubble(); // 버블로 접어 화면을 가리지 않게 (캡처에 카드 안 들어가게)
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

  // 좌표는 화면 중앙 기준 offset(dp). 양수 y = 아래로.
  // 버블: 우하단 + 기본 플래그(포커스 안 뺏음). 미니/상세: 중앙 + focusPointer(키보드 입력 가능).
  Future<void> _goBubble() async {
    // 먼저 버블 위젯으로 전환(투명 배경) → 작은 창에 카드가 안 남도록
    if (mounted) setState(() => _stage = Stage.bubble);
    await FlutterOverlayWindow.updateFlag(OverlayFlag.defaultFlag);
    // 창(40dp)을 동그라미(34dp)에 최대한 맞춤 → 혹시 안 그려져도 빈 여백 최소화.
    await FlutterOverlayWindow.resizeOverlay(40, 40, true);
    // 플러그인 버그: resizeOverlay 후 표면이 즉시 갱신 안 돼 이전 카드가 '흰 네모'로 남음.
    // 기기 성능 편차를 고려해 여러 프레임에 걸쳐 강제로 다시 그린다.
    for (final ms in const [0, 90, 200, 350, 550]) {
      await Future.delayed(Duration(milliseconds: ms));
      if (!mounted) return;
      // 토글로 확실한 리빌드 유도 후 버블 고정
      setState(() => _stage = Stage.bubble);
    }
  }

  Future<void> _goMini() async {
    await FlutterOverlayWindow.updateFlag(OverlayFlag.focusPointer);
    // 미니 카드: enableDrag=true → 플러그인 네이티브 드래그(떨림 없이 부드럽게).
    // 카드 어디를 잡아도 이동 가능, 버튼/검색창 탭은 그대로 동작.
    await FlutterOverlayWindow.resizeOverlay(330, 280, true);
    await FlutterOverlayWindow.moveOverlay(const OverlayPosition(0, -150));
    setState(() => _stage = Stage.mini);
  }

  Future<void> _goFull() async {
    await FlutterOverlayWindow.updateFlag(OverlayFlag.focusPointer);
    // 상세 화면: 위치 고정(중앙) + 드래그 불가 → X 버튼을 항상 누를 수 있게.
    await FlutterOverlayWindow.resizeOverlay(350, 560, false);
    await FlutterOverlayWindow.moveOverlay(const OverlayPosition(0, 0));
    setState(() => _stage = Stage.full);
  }

  /// 미니 카드 상단의 이동 손잡이(시각 표시용). 실제 이동은 네이티브 드래그가 처리.
  Widget _gripBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          width: 44,
          height: 5,
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    switch (_stage) {
      case Stage.bubble:
        child = _buildBubble();
        break;
      case Stage.mini:
        child = _buildMini();
        break;
      case Stage.full:
        child = _buildFull();
        break;
    }
    return Material(color: Colors.transparent, child: child);
  }

  // ── 1단계: 플로팅 마크 ──────────────────────────────
  Widget _buildBubble() {
    return GestureDetector(
      onTap: _goMini,
      child: Center(
        child: _scanning
            ? Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: Colors.red),
                child: const Padding(
                  padding: EdgeInsets.all(9),
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5),
                ),
              )
            : _pokeballWidget(40),
      ),
    );
  }

  /// 포켓볼(몬스터볼) — 일반 위젯으로 구성(빨강 베이스).
  /// 혹시 일부가 안 그려져도 최소 '빨간 공'으로 보여 '흰 네모'가 안 생김.
  Widget _pokeballWidget(double d) {
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFEE1515), // 빨강 베이스
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 5),
        ],
      ),
      child: ClipOval(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              children: [
                Expanded(child: Container(color: const Color(0xFFEE1515))),
                Expanded(child: Container(color: Colors.white)),
              ],
            ),
            // 가운데 검은 띠
            Container(height: d * 0.12, width: d, color: Colors.black),
            // 가운데 버튼(흰 원 + 검은 테두리)
            Container(
              width: d * 0.34,
              height: d * 0.34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: Colors.black, width: d * 0.05),
              ),
            ),
          ],
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
            _gripBar(),
            _searchBar(onCollapse: _goBubble),
            const Divider(height: 1),
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
            _searchBar(onCollapse: _goMini),
            const Divider(height: 1),
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

  Widget _searchBar({required VoidCallback onCollapse}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.catching_pokemon, color: Colors.red, size: 22),
          const SizedBox(width: 8),
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
          IconButton(
            icon: const Icon(Icons.camera_alt, color: Colors.red),
            tooltip: '화면 인식',
            visualDensity: VisualDensity.compact,
            onPressed: _scan,
          ),
          IconButton(
            icon: const Icon(Icons.remove, size: 26),
            tooltip: '버블로 접기',
            visualDensity: VisualDensity.compact,
            onPressed: onCollapse,
          ),
          const SizedBox(width: 6),
          // 닫기(X)는 빨간 원 배경으로 확실히 구분 → 접기와 헷갈려 잘못 끄는 것 방지
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 20),
            tooltip: '오버레이 끄기',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: _closeOverlay,
          ),
          const SizedBox(width: 2),
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

// ─────────────────────────────────────────────────────────────
// 포켓볼 그리기 (이미지 파일 없이 벡터로 — 어떤 해상도에서도 선명)
// ─────────────────────────────────────────────────────────────
class _PokeballPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final circle = Rect.fromCircle(center: c, radius: r);

    // 본체를 원으로 클립
    canvas.save();
    canvas.clipPath(Path()..addOval(circle));

    // 아래쪽 흰색
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = Colors.white);
    // 위쪽 빨강(원의 위 절반)
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height / 2),
        Paint()..color = const Color(0xFFEE1515));

    // 가운데 검은 띠
    final bandH = size.height * 0.14;
    canvas.drawRect(
        Rect.fromLTWH(0, c.dy - bandH / 2, size.width, bandH),
        Paint()..color = Colors.black);
    canvas.restore();

    // 바깥 테두리
    canvas.drawCircle(
        c,
        r - 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.05
          ..color = Colors.black);

    // 가운데 버튼: 검은 원 → 흰 원
    final btnR = size.width * 0.18;
    canvas.drawCircle(c, btnR, Paint()..color = Colors.black);
    canvas.drawCircle(c, btnR * 0.62, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
