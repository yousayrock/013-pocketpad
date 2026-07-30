using System.Text.RegularExpressions;

namespace PocketPadTray;

/// <summary>
/// タスクの分類（phase）と優先度（priority）を決める。
///
/// まず件名からルールで拾い、決まらないものだけをAIに回す方針。
/// 分類は必ず <see cref="Vocabulary"/> の中から選ぶ。自由記述にすると
/// 「016」「BEAT TAG」「ビートタグ」のように語彙が割れて集計できなくなる。
/// </summary>
static class TaskClassifier
{
    /// <summary>分類の語彙。増やすときはここに足す。「その他」は必ず残すこと。</summary>
    public static readonly string[] Vocabulary =
    [
        "016",
        "013かんぱにっち",
        "015",
        "011",
        "002家計",
        "ランチャー",
        "買い物",
        "手続き",
        "連絡",
        "健康",
        "その他",
    ];

    public const string Fallback = "その他";

    /// <summary>スマホ側と同じ接頭辞記法。`[phase:016/P1]` や `[P2]`。</summary>
    private static readonly Regex BracketPrefix = new(
        @"^\[(?:(?:phase|フェーズ)\s*:\s*([^/\]]+?)(?:\s*/\s*(P\d+))?|(P\d+))\]\s*",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>`016:` `かんぱにっち:` のようなコロン区切りの接頭辞。</summary>
    private static readonly Regex ColonPrefix = new(
        @"^([^:：]{1,20})[:：]\s*",
        RegexOptions.Compiled);

    /// <summary>件名に現れる語から分類へ寄せる。長い語から先に見る。</summary>
    private static readonly (string Keyword, string Phase)[] Keywords =
    [
        ("かんぱにっち", "013かんぱにっち"),
        ("BEAT TAG", "016"),
        ("beat tag", "016"),
        ("ビートタグ", "016"),
        ("ランチャー", "ランチャー"),
        ("gadget.json", "ランチャー"),
        ("家計", "002家計"),
        ("016", "016"),
        ("015", "015"),
        ("013", "013かんぱにっち"),
        ("011", "011"),
        ("002", "002家計"),
        // かんぱにっちの部屋や機能の名前は、号機番号が無くても013と分かる。
        ("資料室", "013かんぱにっち"),
        ("サーバー室", "013かんぱにっち"),
        ("開発デスク", "013かんぱにっち"),
        ("図鑑室", "013かんぱにっち"),
        ("トレイ", "013かんぱにっち"),
        ("PocketPad", "013かんぱにっち"),
    ];

    /// <summary>
    /// 件名からルールで分類と優先度を拾う。分類が決まらなければ Phase は null を返し、
    /// 呼び出し側でAIに回すか「その他」にするかを決める。
    /// </summary>
    public static (string? Phase, string? Priority) FromSubject(string subject)
    {
        if (string.IsNullOrWhiteSpace(subject))
            return (null, null);

        string? priority = null;

        // 1. スマホ側と同じ [phase:X/P1] 記法。ここで決まれば最優先で採用する。
        var bracket = BracketPrefix.Match(subject);
        if (bracket.Success)
        {
            priority = Normalize(bracket.Groups[2].Value) ?? Normalize(bracket.Groups[3].Value);
            var phase = Normalize(bracket.Groups[1].Value);
            if (phase is not null)
                return (ToVocabulary(phase) ?? phase, priority);
        }

        var body = BracketPrefix.Replace(subject, "");

        // 2. `016:` のようなコロン区切りの接頭辞。
        var colon = ColonPrefix.Match(body);
        if (colon.Success)
        {
            var candidate = ToVocabulary(colon.Groups[1].Value.Trim());
            if (candidate is not null)
                return (candidate, priority);
        }

        // 3. 件名に含まれる語から寄せる。
        foreach (var (keyword, phase) in Keywords)
        {
            if (body.Contains(keyword, StringComparison.OrdinalIgnoreCase))
                return (phase, priority);
        }

        return (null, priority);
    }

    /// <summary>与えられた文字列を語彙のいずれかへ寄せる。寄せられなければ null。</summary>
    public static string? ToVocabulary(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;

        var trimmed = value.Trim();
        foreach (var item in Vocabulary)
        {
            if (string.Equals(item, trimmed, StringComparison.OrdinalIgnoreCase))
                return item;
        }
        foreach (var (keyword, phase) in Keywords)
        {
            if (trimmed.Contains(keyword, StringComparison.OrdinalIgnoreCase))
                return phase;
        }
        return null;
    }

    private static string? Normalize(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
