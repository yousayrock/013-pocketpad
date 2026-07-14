# Flutterエンジン（libflutter.so）のデバッグ情報を除去してAPKを小さくする。
#
# 背景：このプロジェクトはNDK（約700MBのダウンロード）を意図的に入れていない
# （IPv6オンリー回線のギガ節約。app/android/app/build.gradle.kts参照）。
# その代償として、Gradleキャッシュ内の公式エンジンJARに入っている未strip
# の libflutter.so（約160MB/ABI）がそのままAPKに入り、APKが約500MBになる。
#
# このスクリプトはNDKなしでstrip相当を行う：
# Androidの動的リンカはプログラムヘッダ（PT_LOAD）だけを使い、セクション
# ヘッダとその先のデバッグ情報は読まない。そこで
#   1. 全プログラムヘッダの (p_offset + p_filesz) の最大値でファイルを切り詰め
#   2. ELFヘッダのセクションヘッダ参照（e_shoff等）をゼロ化
# する。結果は llvm-strip とほぼ同じ約11MB/ABIになる。
#
# 使い方：flutter upgrade等でエンジンが再ダウンロードされた後に一度実行する。
#   powershell -ExecutionPolicy Bypass -File app\tool\strip_engine.ps1
# その後 flutter build apk --release すれば小さいAPKができる。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Strip-Elf([byte[]]$b) {
    if ($b[0] -ne 0x7F -or $b[1] -ne 0x45 -or $b[2] -ne 0x4C -or $b[3] -ne 0x46) {
        throw 'ELFではありません'
    }
    $is64 = ($b[4] -eq 2)
    if ($is64) {
        $phoff = [BitConverter]::ToUInt64($b, 0x20)
        $phentsize = [BitConverter]::ToUInt16($b, 0x36)
        $phnum = [BitConverter]::ToUInt16($b, 0x38)
    } else {
        $phoff = [uint64][BitConverter]::ToUInt32($b, 0x1C)
        $phentsize = [BitConverter]::ToUInt16($b, 0x2A)
        $phnum = [BitConverter]::ToUInt16($b, 0x2C)
    }
    $max = [uint64]0
    for ($i = 0; $i -lt $phnum; $i++) {
        $o = [int]($phoff + $i * $phentsize)
        if ($is64) {
            $end = [BitConverter]::ToUInt64($b, $o + 0x08) + [BitConverter]::ToUInt64($b, $o + 0x20)
        } else {
            $end = [uint64]([BitConverter]::ToUInt32($b, $o + 0x04)) + [BitConverter]::ToUInt32($b, $o + 0x10)
        }
        if ($end -gt $max) { $max = $end }
    }
    if ([uint64]$b.Length - $max -lt 1MB) { return $null } # 既にstrip済み
    $out = New-Object byte[] ([int]$max)
    [Array]::Copy($b, $out, [int]$max)
    # セクションヘッダ参照をゼロ化（e_shoff / e_shentsize / e_shnum / e_shstrndx）
    if ($is64) {
        [Array]::Clear($out, 0x28, 8)
        [Array]::Clear($out, 0x3A, 6)
    } else {
        [Array]::Clear($out, 0x20, 4)
        [Array]::Clear($out, 0x2E, 6)
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
