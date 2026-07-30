import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'kanpanicchi.dart' show PixelSprite, kCharacterName, kDisplayNameKey;

/// 天国 — 世界の始まり。
///
/// docs/VISION.md §1 より:
/// > 全員同じ場所から始まる。「天国」。
/// > ここは宗教を説明する場所ではない。安心して人生を始める場所。
/// > AIが優しく迎えてくれる。
///
/// **ここではAIを呼ばない。** 天国はまだ何のデータも無い瞬間で、
/// 行動履歴も日誌もゼロなので、AIに読ませる材料が存在しない。だから台本は手書き。
/// AIの仕事は2日目から始まる。
///
/// この判断の副産物として、トレイが起動していなくてもAPIキーが無くても
/// 天国は必ず通れる。**初回体験がPC側の状態に依存しないのは譲れない。**

// 天使長。光輪と翼を持ち、ふわりと浮いている。
// '.'=透明 / '1'=体 / '2'=光輪 / '3'=翼 / '0'=目
const _archangelFloat = [
  '...222...',
  '..2...2..',
  '...111...',
  '..11111..',
  '..10101..',
  '311111113',
  '33.111.33',
  '3..111..3',
  '..11111..',
  '...111...',
];

const _archangelPalette = <String, Color>{
  '1': Color(0xFFFFF4D6), // やわらかい生成り
  '2': Color(0xFFFFD86B), // 光輪
  '3': Color(0xFFBFE7FF), // 翼
  '0': Color(0xFF2A2438), // 目
};

const _skyTop = Color(0xFF1A2340);
const _skyBottom = Color(0xFF3E4A78);
const _halo = Color(0xFFFFD86B);

/// 天国で天使長が話す言葉。
///
/// §1「宗教を説明する場所ではない」を守り、宗教色は出さず、迎える温度だけを出す。
/// 説明しない。約束もしない。ただ迎える。
const _script = <String>[
  'ようこそ。',
  'ここは、はじまりの場所。',
  'あなたがなにをしてきたかは、\nまだ聞きません。',
  'これからのことも、\n決めなくていい。',
  '毎日ちいさなことをするだけで、\nこの世界は少しずつ育ちます。',
  'さいごに、ひとつだけ。',
];

class HeavenPage extends StatefulWidget {
  const HeavenPage({super.key, required this.onDone});

  /// 名前を決めて世界へ降りるときに呼ばれる。
  final VoidCallback onDone;

  /// 天国をもう通ったかどうか。**専用のフラグは持たない。**
  /// 表示名が保存されていれば通ったとみなす（真実を一箇所に保つため）。
  static Future<bool> shouldShow() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString(kDisplayNameKey);
    return name == null || name.isEmpty;
  }

  @override
  State<HeavenPage> createState() => _HeavenPageState();
}

class _HeavenPageState extends State<HeavenPage>
    with SingleTickerProviderStateMixin {
  int _page = 0;
  bool _naming = false;
  final _nameController = TextEditingController();
  late final AnimationController _float;

  bool get _isLastLine => _page >= _script.length - 1;

  @override
  void initState() {
    super.initState();
    // 天使長がゆっくり上下する。急かさない速さにする。
    _float = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _float.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _advance() {
    if (_naming) return;
    if (_isLastLine) {
      setState(() => _naming = true);
      return;
    }
    setState(() => _page++);
  }

  Future<void> _descend() async {
    final typed = _nameController.text.trim();
    final name = typed.isEmpty ? kCharacterName : typed;
    final p = await SharedPreferences.getInstance();
    await p.setString(kDisplayNameKey, name);
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _skyTop,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _advance,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_skyTop, _skyBottom],
            ),
          ),
          child: SafeArea(
            // キーボードが出ると高さが半分近く削られる。天使長を小さくして
            // 入力欄と「はじめる」を必ず画面に残す（縮めないと下がはみ出す）。
            child: LayoutBuilder(
              builder: (context, constraints) {
                final keyboard = MediaQuery.of(context).viewInsets.bottom;
                final cramped = keyboard > 0;
                return Padding(
                  padding: EdgeInsets.only(
                    left: 24,
                    right: 24,
                    top: cramped ? 8 : 24,
                    bottom: 16 + keyboard,
                  ),
                  child: Column(
                    children: [
                      if (!cramped) const Spacer(),
                      _angel(compact: cramped),
                      SizedBox(height: cramped ? 14 : 36),
                      // 名前入力のときは天使長より下に枠を回す（ボタンまで収める）。
                      Expanded(
                        flex: _naming ? 3 : 2,
                        child: _naming ? _nameForm(cramped) : _line(),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _angel({bool compact = false}) {
    return AnimatedBuilder(
      animation: _float,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_float.value);
        return Transform.translate(offset: Offset(0, -6 * t), child: child);
      },
      child: Container(
        padding: EdgeInsets.all(compact ? 14 : 28),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              _halo.withValues(alpha: 0.22),
              _halo.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: PixelSprite(
          rows: _archangelFloat,
          glow: _halo,
          palette: _archangelPalette,
          pixelSize: compact ? 5 : 9,
        ),
      ),
    );
  }

  Widget _line() {
    return Column(
      children: [
        // 台詞が入れ替わるとき、前の文が残って見えないよう溶暗させる。
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          child: Text(
            _script[_page],
            key: ValueKey(_page),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              height: 1.8,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _script.length; i++)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _page ? _halo : Colors.white24,
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'タップして進む',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
        ),
      ],
    );
  }

  Widget _nameForm(bool cramped) {
    // 「はじめる」は列の外に固定し、キーボードが出ていても必ず見えるようにする。
    // スクロールしないと押すものが見つからない、は初回体験として弱い。
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Text(
                  'あなたのそばにいる子に、\n名前をつけてあげてください。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: cramped ? 14 : 16,
                    height: 1.8,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: cramped ? 12 : 22),
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _nameController,
                    autofocus: true,
                    maxLength: 4,
                    textAlign: TextAlign.center,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _descend(),
                    style: const TextStyle(color: Colors.white, fontSize: 20),
                    decoration: InputDecoration(
                      hintText: kCharacterName,
                      hintStyle: const TextStyle(color: Colors.white24),
                      counterText: '',
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.3),
                        ),
                      ),
                      focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: _halo),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'あとから変えられます',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _descend,
          style: FilledButton.styleFrom(
            backgroundColor: _halo,
            foregroundColor: const Color(0xFF2A2438),
            padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 14),
          ),
          child: const Text(
            'はじめる',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
