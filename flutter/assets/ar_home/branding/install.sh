#!/bin/bash
# 【統合担当が実行】アイコンと起動画面を flutter/ios・flutter/android に上書きで入れる。
# ar_home 担当は ios/・android/ を触れない決まりなので、ここに同じ相対パスで用意してある。
# 中身: iOS AppIcon 一式（透過なし）・LaunchImage（200pt）・LaunchScreen.storyboard（地 #fff7f0）、
#       Android mipmap（旧形式＋アダプティブ）・launch_background（〜11）・values-v31/styles.xml（12〜）・colors.xml
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
flutter_dir="$(cd "$here/../../.." && pwd)"
cp -R "$here/ios/." "$flutter_dir/ios/"
cp -R "$here/android/." "$flutter_dir/android/"
echo "installed into $flutter_dir/ios and $flutter_dir/android"
