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

    /// <summary>
    /// AIに渡す語彙の説明。裸のリストだけを渡すと、号機番号や機能名が件名に無いタスクを
    /// 当てずっぽうで振り分けてしまう（実測で25件中7件が誤分類だった）。
    /// 「その分野が何であるか」を書いておくことが精度に直結する。
    /// </summary>
    public static readonly (string Phase, string Description)[] VocabularyGuide =
    [
        ("016", "BEAT TAG。9パッドのリズムゲーム。Flutter製でAndroidとWebで動く。音の合成・レイテンシ・譜面・パッドUIの話"),
        ("013かんぱにっち", "PocketPadとその中のかんぱにっち。スマホからPCを操作するアプリで、TODO管理・タスクの分類や優先度・詳細表示・実況コメント・キャラ表示・部屋（資料室/サーバー室/開発デスク/図鑑室）・トレイ常駐アプリ・task_state.jsonなどのタスク保存の話。TODOやタスクの仕組みそのものに関する作業は基本ここ"),
        ("015", "PROJECT GODDESS。ブラウザ間のリアルタイムチャット"),
        ("011", "RoadTalk。送迎・代行業務向けの通話と配車のシステム"),
        ("002家計", "家系Bot。レシート写真から家計簿をつけるDiscord bot。確定申告用のExcel出力やGoogleカレンダー連携もある"),
        ("ランチャー", "複数の号機を一覧して起動する共通ランチャー構想。gadget.jsonというマニフェストで各号機を登録する話に限る。かんぱにっち自身のTODO機能はここではない"),
        ("買い物", "日用品や食料品の購入など、開発と無関係な買い物"),
        ("手続き", "役所や契約、支払いなどの事務手続き"),
        ("連絡", "誰かへの連絡や返信、電話"),
        ("健康", "通院、睡眠、運動など体に関すること"),
        ("その他", "上のどれにも当てはまらないもの"),
    ];

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
        ("部屋", "013かんぱにっち"),
        ("実況", "013かんぱにっち"),
        // TODOの仕組みそのものに関する作業はかんぱにっちの機能開発。
        // ここを拾わないとAIが「ランチャー」へ流してしまう（実測で3件誤分類した）。
        ("TODO", "013かんぱにっち"),
        ("todo", "013かんぱにっち"),
        ("タスク", "013かんぱにっち"),
        ("task_state", "013かんぱにっち"),
        ("activeForm", "013かんぱにっち"),
        ("下半分", "013かんぱにっち"),
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
