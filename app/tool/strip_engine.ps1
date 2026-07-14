# Flutterエンジン（libflutter.so）のデバッグ情報を除去してAPKを小さくする。
#
# 背景：このプロジェクトはNDK（約700MBのダウンロード）を意図的に入れていない
# （IPv6オンリー回線のギガ節約。app/android/app/build.gradle.kts参照）。
# その代償として、Gradleキャッシュ内の公式エンジンJARに入っている未strip
# の libflutter.so（約160MB/ABI）がそのままAPKに入り、APKが約500MBになる。
#
# このスクリプトはNDKなしでstrip相当を行う：
#   1. 全プログラムヘッダの (p_offset + p_filesz) の最大値でファイルを切り詰め
#   2. 最小限のセクションヘッダテーブルを末尾に合成して付加
#
# (2)が必須な理由：Androidのbionicリンカはロードにはプログラムヘッダしか
# 使わないが、targetSdk 26以上ではdlopen時にセクションヘッダを検証する
# （e_shentsize / e_shstrndx / .dynamicセクションがPT_DYNAMICと一致するか）。
# セクションヘッダ参照を単にゼロ化すると
#   "has unsupported e_shentsize: 0x0 (expected 0x40)"
# で起動クラッシュする。そこで NULL / .dynamic / .dynstr の3エントリだけの
# テーブルを付加して検証を通す。結果は llvm-strip とほぼ同じ約11MB/ABI。
#
# 使い方：flutter upgrade等でエンジンが再ダウンロードされた後に一度実行する。
#   powershell -ExecutionPolicy Bypass -File app\tool\strip_engine.ps1
# その後 flutter build apk --release すれば小さいAPKができる。
# （旧版スクリプトでゼロ化してしまったファイルの修復にも使える）
#
# 注意：一度ビルドした後にJARを書き換え直した場合、Gradleのtransformsキャッシュ
# （~/.gradle/caches/<ver>/transforms）に旧libflutter.soの展開済みコピーが残り、
# 再ビルドしてもAPKに反映されないことがある。その場合は `gradlew --stop` 後に
# transforms内のエンジン関連ディレクトリを削除してから flutter clean & 再ビルド。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function W16([byte[]]$a, [int]$o, [uint16]$v) { [Array]::Copy([BitConverter]::GetBytes($v), 0, $a, $o, 2) }
function W32([byte[]]$a, [int]$o, [uint32]$v) { [Array]::Copy([BitConverter]::GetBytes($v), 0, $a, $o, 4) }
function W64([byte[]]$a, [int]$o, [uint64]$v) { [Array]::Copy([BitConverter]::GetBytes($v), 0, $a, $o, 8) }

function Strip-Elf([byte[]]$b) {
    if ($b[0] -ne 0x7F -or $b[1] -ne 0x45 -or $b[2] -ne 0x4C -or $b[3] -ne 0x46) {
        throw 'ELFではありません'
    }
    $is64 = ($b[4] -eq 2)
    if ($is64) {
        $phoff = [BitConverter]::ToUInt64($b, 0x20)
        $shoff = [BitConverter]::ToUInt64($b, 0x28)
        $phentsize = [BitConverter]::ToUInt16($b, 0x36)
        $phnum = [BitConverter]::ToUInt16($b, 0x38)
        $shentsize = 0x40
    } else {
        $phoff = [uint64][BitConverter]::ToUInt32($b, 0x1C)
        $shoff = [uint64][BitConverter]::ToUInt32($b, 0x20)
        $phentsize = [BitConverter]::ToUInt16($b, 0x2A)
        $phnum = [BitConverter]::ToUInt16($b, 0x2C)
        $shentsize = 0x28
    }

    # プログラムヘッダを走査：ファイル末端の計算と PT_DYNAMIC / PT_LOAD の収集
    $max = [uint64]0
    $dynOff = $null; $dynVaddr = [uint64]0; $dynSize = [uint64]0
    $loads = @()
    for ($i = 0; $i -lt $phnum; $i++) {
        $o = [int]($phoff + $i * $phentsize)
        $type = [BitConverter]::ToUInt32($b, $o)
        if ($is64) {
            $pOffset = [BitConverter]::ToUInt64($b, $o + 0x08)
            $pVaddr  = [BitConverter]::ToUInt64($b, $o + 0x10)
            $pFilesz = [BitConverter]::ToUInt64($b, $o + 0x20)
        } else {
            $pOffset = [uint64][BitConverter]::ToUInt32($b, $o + 0x04)
            $pVaddr  = [uint64][BitConverter]::ToUInt32($b, $o + 0x08)
            $pFilesz = [uint64][BitConverter]::ToUInt32($b, $o + 0x10)
        }
        $end = $pOffset + $pFilesz
        if ($end -gt $max) { $max = $end }
        if ($type -eq 2) { $dynOff = $pOffset; $dynVaddr = $pVaddr; $dynSize = $pFilesz } # PT_DYNAMIC
        if ($type -eq 1) { $loads += ,@($pVaddr, $pFilesz, $pOffset) }                    # PT_LOAD
    }
    if ($null -eq $dynOff) { throw 'PT_DYNAMICがありません' }

    $needTruncate = ([uint64]$b.Length - $max -ge 1MB)
    if (-not $needTruncate -and $shoff -ne 0) { return $null } # 処理済み

    if ($needTruncate) {
        $data = New-Object byte[] ([int]$max)
        [Array]::Copy($b, $data, [int]$max)
    } else {
        $data = $b # 旧版で切り詰め済み（セクションヘッダ合成のみ行う）
    }

    # .dynamic から DT_STRTAB(5) / DT_STRSZ(10) を取得
    $dynEnt = if ($is64) { 16 } else { 8 }
    $strtabV = [uint64]0; $strsz = [uint64]0
    for ([uint64]$p = $dynOff; $p -lt $dynOff + $dynSize; $p += $dynEnt) {
        if ($is64) {
            $tag = [BitConverter]::ToUInt64($data, [int]$p)
            $val = [BitConverter]::ToUInt64($data, [int]$p + 8)
        } else {
            $tag = [uint64][BitConverter]::ToUInt32($data, [int]$p)
            $val = [uint64][BitConverter]::ToUInt32($data, [int]$p + 4)
        }
        if ($tag -eq 0) { break }
        if ($tag -eq 5) { $strtabV = $val }
        if ($tag -eq 10) { $strsz = $val }
    }
    if ($strtabV -eq 0 -or $strsz -eq 0) { throw 'DT_STRTAB/DT_STRSZが見つかりません' }

    # .dynstr の仮想アドレス→ファイルオフセット変換
    $strtabOff = [uint64]0
    foreach ($l in $loads) {
        if ($strtabV -ge $l[0] -and $strtabV -lt $l[0] + $l[1]) {
            $strtabOff = $strtabV - $l[0] + $l[2]; break
        }
    }
    if ($strtabOff -eq 0) { throw '.dynstrのオフセット解決に失敗' }

    # セクションヘッダテーブル（NULL / .dynamic / .dynstr）を8バイト境界に付加
    $pad = (8 - ($data.Length % 8)) % 8
    $newShoff = [uint64]($data.Length + $pad)
    $out = New-Object byte[] ([int]$newShoff + 3 * $shentsize)
    [Array]::Copy($data, $out, $data.Length)

    $e1 = [int]$newShoff + $shentsize      # .dynamic (index 1)
    $e2 = [int]$newShoff + 2 * $shentsize  # .dynstr  (index 2)
    if ($is64) {
        W32 $out ($e1 + 0x04) 6                    # sh_type = SHT_DYNAMIC
        W64 $out ($e1 + 0x08) 3                    # sh_flags = WRITE|ALLOC
        W64 $out ($e1 + 0x10) $dynVaddr            # sh_addr
        W64 $out ($e1 + 0x18) $dynOff              # sh_offset
        W64 $out ($e1 + 0x20) $dynSize             # sh_size
        W32 $out ($e1 + 0x28) 2                    # sh_link = .dynstr
        W64 $out ($e1 + 0x30) 8                    # sh_addralign
        W64 $out ($e1 + 0x38) 16                   # sh_entsize
        W32 $out ($e2 + 0x04) 3                    # sh_type = SHT_STRTAB
        W64 $out ($e2 + 0x08) 2                    # sh_flags = ALLOC
        W64 $out ($e2 + 0x10) $strtabV
        W64 $out ($e2 + 0x18) $strtabOff
        W64 $out ($e2 + 0x20) $strsz
        W64 $out ($e2 + 0x30) 1
        W64 $out 0x28 $newShoff                    # e_shoff
        W16 $out 0x3A ([uint16]$shentsize)         # e_shentsize
        W16 $out 0x3C 3                            # e_shnum
        W16 $out 0x3E 2                            # e_shstrndx
    } else {
        W32 $out ($e1 + 0x04) 6
        W32 $out ($e1 + 0x08) 3
        W32 $out ($e1 + 0x0C) ([uint32]$dynVaddr)
        W32 $out ($e1 + 0x10) ([uint32]$dynOff)
        W32 $out ($e1 + 0x14) ([uint32]$dynSize)
        W32 $out ($e1 + 0x18) 2
        W32 $out ($e1 + 0x20) 4
        W32 $out ($e1 + 0x24) 8
        W32 $out ($e2 + 0x04) 3
        W32 $out ($e2 + 0x08) 2
        W32 $out ($e2 + 0x0C) ([uint32]$strtabV)
        W32 $out ($e2 + 0x10) ([uint32]$strtabOff)
        W32 $out ($e2 + 0x14) ([uint32]$strsz)
        W32 $out ($e2 + 0x20) 1
        W32 $out 0x20 ([uint32]$newShoff)
        W16 $out 0x2E ([uint16]$shentsize)
        W16 $out 0x30 3
        W16 $out 0x32 2
    }
    return $out
}

$cache = Join-Path $env:USERPROFILE '.gradle\caches\modules-2\files-2.1\io.flutter'
$jars = Get-ChildItem $cache -Recurse -Filter '*.jar' |
    Where-Object { $_.Name -match '^(arm64_v8a|armeabi_v7a|x86_64|x86)_(release|profile|debug)-' }
if (-not $jars) { Write-Host 'エンジンJARが見つかりません（先に一度ビルドしてください）'; exit 1 }

foreach ($jar in $jars) {
    $zip = [System.IO.Compression.ZipFile]::Open($jar.FullName, 'Update')
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -eq 'libflutter.so' }
        if (-not $entry) { Write-Host "skip (libflutter.soなし): $($jar.Name)"; continue }
        $ms = New-Object System.IO.MemoryStream
        $s = $entry.Open(); $s.CopyTo($ms); $s.Dispose()
        $stripped = Strip-Elf $ms.ToArray()
        if ($null -eq $stripped) { Write-Host "skip (strip済み): $($jar.Name)"; continue }
        $name = $entry.FullName
        $orig = $ms.Length
        $entry.Delete()
        $new = $zip.CreateEntry($name, 'Optimal')
        $ws = $new.Open(); $ws.Write($stripped, 0, $stripped.Length); $ws.Dispose()
        Write-Host ("{0}: {1:N0} -> {2:N0} bytes" -f $jar.Name, $orig, $stripped.Length)
    } finally {
        $zip.Dispose()
    }
}
Write-Host '完了。flutter build apk --release で小さいAPKが作れます。'
