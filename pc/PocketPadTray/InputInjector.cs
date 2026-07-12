using System.Runtime.InteropServices;

namespace PocketPadTray;

/// <summary>
/// SendInput 直叩き（P/Invoke）。InputSimulatorはメンテ停止のため不使用（仕様書v1.1）。
/// </summary>
static class InputInjector
{
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT
    {
        public uint type;
        public InputUnion U;
        public static int Size => Marshal.SizeOf<INPUT>();
    }

    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public nint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public nint dwExtraInfo;
    }

    const uint INPUT_MOUSE = 0;
    const uint INPUT_KEYBOARD = 1;

    const uint MOUSEEVENTF_MOVE = 0x0001;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;
    const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    const uint MOUSEEVENTF_WHEEL = 0x0800;
    const uint MOUSEEVENTF_HWHEEL = 0x1000;

    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;

    /// <summary>PC側IMEを直接入力モードにする仮想キー（Win10 1903+）</summary>
    const ushort VK_IME_OFF = 0x1A;

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    static void Send(params INPUT[] inputs) => SendInput((uint)inputs.Length, inputs, INPUT.Size);

    static INPUT Mouse(int dx, int dy, uint flags, uint data = 0) => new()
    {
        type = INPUT_MOUSE,
        U = new InputUnion { mi = new MOUSEINPUT { dx = dx, dy = dy, dwFlags = flags, mouseData = data } },
    };

    static INPUT Kbd(ushort vk, uint flags, ushort scan = 0) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } },
    };

    public static void MouseMove(int dx, int dy) => Send(Mouse(dx, dy, MOUSEEVENTF_MOVE));

    /// <summary>delta はスマホ側スワイプ量。WHEEL_DELTA(120)単位に換算済みの値を受け取る。</summary>
    public static void Scroll(int vertical, int horizontal)
    {
        if (vertical != 0) Send(Mouse(0, 0, MOUSEEVENTF_WHEEL, unchecked((uint)vertical)));
        if (horizontal != 0) Send(Mouse(0, 0, MOUSEEVENTF_HWHEEL, unchecked((uint)horizontal)));
    }

    public static void Click(string button, string action)
    {
        var (down, up) = button switch
        {
            "right" => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            "middle" => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
            _ => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        };
        switch (action)
        {
            case "down": Send(Mouse(0, 0, down)); break;
            case "up": Send(Mouse(0, 0, up)); break;
            case "double":
                Send(Mouse(0, 0, down), Mouse(0, 0, up), Mouse(0, 0, down), Mouse(0, 0, up));
                break;
            default: Send(Mouse(0, 0, down), Mouse(0, 0, up)); break; // tap
        }
    }

    static ushort ModifierVk(string name) => name switch
    {
        "ctrl" => 0x11,
        "shift" => 0x10,
        "alt" => 0x12,
        "win" => 0x5B,
        _ => 0,
    };

    public static void Key(ushort vk, string action, string[] modifiers)
    {
        var mods = modifiers.Select(ModifierVk).Where(v => v != 0).ToArray();
        switch (action)
        {
            case "down":
                Send(mods.Select(m => Kbd(m, 0)).Append(Kbd(vk, 0)).ToArray());
                break;
            case "up":
                Send(new[] { Kbd(vk, KEYEVENTF_KEYUP) }
                    .Concat(mods.Reverse().Select(m => Kbd(m, KEYEVENTF_KEYUP))).ToArray());
                break;
            default: // tap: 修飾キーdown → 本体down/up → 修飾キーup（逆順）
                Send(mods.Select(m => Kbd(m, 0))
                    .Append(Kbd(vk, 0))
                    .Append(Kbd(vk, KEYEVENTF_KEYUP))
                    .Concat(mods.Reverse().Select(m => Kbd(m, KEYEVENTF_KEYUP)))
                    .ToArray());
                break;
        }
    }

    /// <summary>ショートカット一括（例: ["ctrl","shift","esc"]）。最後の要素を本体キーとして扱う。</summary>
    public static void Shortcut(ushort vk, string[] modifiers) => Key(vk, "tap", modifiers);

    /// <summary>
    /// KEYEVENTF_UNICODE でテキスト入力。サロゲートペアもUTF-16単位でそのまま送る。
    /// SendInputは入力キューが詰まると後半を黙って捨てるため、一括投入せず
    /// 1文字ずつ送って戻り値を確認し、失敗分はリトライする（「天気」消失バグの修正）。
    /// </summary>
    public static void Text(string text)
    {
        // スマホ側で変換済みの完成文字列を注入するため、PC側IMEは邪魔。
        // 注入前に毎回IMEをオフにして、変換候補ウィンドウによる文字の横取りを防ぐ。
        Send(Kbd(VK_IME_OFF, 0), Kbd(VK_IME_OFF, KEYEVENTF_KEYUP));
        Thread.Sleep(10); // IME状態切り替えの反映を待つ

        foreach (var ch in text)
        {
            var pair = new[]
            {
                Kbd(0, KEYEVENTF_UNICODE, ch),
                Kbd(0, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, ch),
            };
            for (var attempt = 0; attempt < 10; attempt++)
            {
                if (SendInput(2, pair, INPUT.Size) == 2) break;
                Thread.Sleep(2); // キューが空くのを待って再試行
            }
        }
    }
}
