# mobile_scanner(ML Kitバーコード)対策。
# R8縮小がML Kit内部のコンポーネントレジストラを壊し、スキャン画面を開くと
# 「zzg.a(BarcodeScannerOptions) on a null object reference」でクラッシュするため、
# ML Kit関連クラスを縮小対象から除外する。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode_bundled.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.odml.image.** { *; }
