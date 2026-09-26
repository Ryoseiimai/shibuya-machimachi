#!/bin/bash
# アイコン・起動画面の PNG を src/*.svg から作り直す（rsvg-convert と magick が要る: brew install librsvg imagemagick）。
# 出力は ios/ と android/ に、flutter/ios・flutter/android と同じ相対パスで置く。入れるのは install.sh（統合担当）。
set -euo pipefail
cd "$(dirname "$0")"
SRC=src
IOS=ios/Runner/Assets.xcassets
AND=android/app/src/main/res

# --- iOS アプリアイコン（App Store の決まりで透過なし＝アルファを落とす）---
mkdir -p "$IOS/AppIcon.appiconset"
ios_icon() { # <ファイル名> <px>
  rsvg-convert -w "$2" -h "$2" "$SRC/icon.svg" | magick png:- -background '#c8431f' -alpha remove -alpha off "$IOS/AppIcon.appiconset/$1"
}
ios_icon Icon-App-1024x1024@1x.png 1024
ios_icon Icon-App-20x20@1x.png 20;  ios_icon Icon-App-20x20@2x.png 40;  ios_icon Icon-App-20x20@3x.png 60
ios_icon Icon-App-29x29@1x.png 29;  ios_icon Icon-App-29x29@2x.png 58;  ios_icon Icon-App-29x29@3x.png 87
ios_icon Icon-App-40x40@1x.png 40;  ios_icon Icon-App-40x40@2x.png 80;  ios_icon Icon-App-40x40@3x.png 120
ios_icon Icon-App-60x60@2x.png 120; ios_icon Icon-App-60x60@3x.png 180
ios_icon Icon-App-76x76@1x.png 76;  ios_icon Icon-App-76x76@2x.png 152
ios_icon Icon-App-83.5x83.5@2x.png 167

# --- iOS 起動画面の中央マーク（200pt 四方・透過。地の色は LaunchScreen.storyboard で #fff7f0）---
mkdir -p "$IOS/LaunchImage.imageset"
rsvg-convert -w 200 -h 200 "$SRC/splash_mark.svg" -o "$IOS/LaunchImage.imageset/LaunchImage.png"
rsvg-convert -w 400 -h 400 "$SRC/splash_mark.svg" -o "$IOS/LaunchImage.imageset/LaunchImage@2x.png"
rsvg-convert -w 600 -h 600 "$SRC/splash_mark.svg" -o "$IOS/LaunchImage.imageset/LaunchImage@3x.png"

# --- Android ランチャーアイコン（旧形式の正方形 48dp と、アダプティブの前景/背景 108dp）---
for pair in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  d=${pair%%:*}; s=${pair##*:}
  mkdir -p "$AND/mipmap-$d" "$AND/drawable-$d"
  px=$(python3 -c "print(round(48*$s))"); big=$(python3 -c "print(round(108*$s))"); sp=$(python3 -c "print(round(160*$s))")
  rsvg-convert -w "$px" -h "$px" "$SRC/icon.svg" -o "$AND/mipmap-$d/ic_launcher.png"
  rsvg-convert -w "$big" -h "$big" "$SRC/icon_foreground.svg" -o "$AND/mipmap-$d/ic_launcher_foreground.png"
  rsvg-convert -w "$big" -h "$big" "$SRC/icon_background.svg" -o "$AND/mipmap-$d/ic_launcher_background.png"
  # 起動画面の中央マーク（160dp）
  rsvg-convert -w "$sp" -h "$sp" "$SRC/splash_mark.svg" -o "$AND/drawable-$d/splash_mark.png"
done
echo "generated"
