# SpeakerKeeper

[English](README.md) | 日本語

無音が続くと自動でスリープしてしまうPCスピーカー向けの、Windows用の小さなツールです。

一部のアクティブスピーカーは、入力が一定レベルを下回るとすぐにスリープし、次に音が来たときはフェードインしながら復帰します。そのため、動画の冒頭や静かな場面のあとで、音がこもったりぼやけたりして聞こえます。

SpeakerKeeper は、**他のアプリ(ブラウザ・ゲームなど)が音を出している間だけ**、[SoundKeeper](https://veg.by/projects/soundkeeper) を使って小さなサイン波を流し、スピーカーを起こしたままにします。音が止まってから設定した時間が経つと、サイン波も止めます。

## 主な機能

- 他のアプリの音量メーターを監視して、音が出ている間だけサイン波を流す(SoundKeeper自身の音には反応しません)
- 音が止まってからも、設定した秒数だけ鳴らし続ける(余韻時間)
- 指定した出力デバイスのときだけ動作(ヘッドホンなどに切り替えると自動で停止)
- `settings.txt` を書き換えて保存するだけで、動作中でも設定を反映
- 追加のインストールは不要(Windows標準のPowerShellで動作)

## 動作環境

- Windows 10 / 11
- [SoundKeeper](https://veg.by/projects/soundkeeper)(別途ダウンロード)

## インストール

1. このリポジトリをダウンロードして解凍します(緑の **Code** ボタン → **Download ZIP**)
2. [SoundKeeperの公式サイト](https://veg.by/projects/soundkeeper)から `soundkeeper.7z` をダウンロードします
3. 中の **`SoundKeeper64.exe`** を、`SpeakerKeeper.ps1` と同じフォルダにコピーします
   - ファイル名は変えないでください(`Sine` などを付けない)
4. すでにSoundKeeperをスタートアップに登録している場合は、削除して終了しておきます

## 使い方

| ファイル | 内容 |
|---|---|
| `1_test_run.bat` | 画面を表示して実行します。動作確認や設定の調整用です。ウィンドウを閉じると終了します |
| `2_add_to_startup.bat` | スタートアップに登録し、すぐに裏で起動します。次回からはサインイン時に自動で起動します |
| `3_remove_from_startup.bat` | スタートアップから削除し、停止します |

まず `1_test_run.bat` を実行し、音を再生すると「SoundKeeper 開始」、止めてから余韻時間が経つと「停止」と表示されることを確認してください。

> フォルダを移動した場合は、`2_add_to_startup.bat` を実行し直してください。

## 設定

`settings.txt` をメモ帳で開き、値を書き換えて保存します。

| 項目 | 初期値 | 内容 |
|---|---|---|
| `Frequency` | `300` | 鳴らす音の周波数(Hz) |
| `Amplitude` | `0.1` | 鳴らす音の大きさ(%) |
| `LingerSeconds` | `30` | 音が止まってから鳴らし続ける秒数 |
| `Threshold` | `0.001` | 「音が出ている」と判断するレベル(0〜1)。通知音などで反応してしまう場合は上げる |
| `DeviceName` | (空欄) | この文字を名前に含む出力先のときだけ動作。空欄ならすべての出力先で動作 |
| `SoundKeeper` | `SoundKeeper64.exe` | SoundKeeperの実行ファイル名 |

`DeviceName` に入れる名前は、`1_test_run.bat` の画面の「**現在の出力先: ~**」に表示されます。例: `スピーカー (Realtek(R) Audio)`

### 自分に合った音の見つけ方

スピーカーによって反応する音が違います。

1. まず、はっきり聞こえる音(例: `Frequency=1000`、`Amplitude=1`)で、こもりがなくなるか確認します
   - それでも直らない場合、スピーカーの問題はオートスリープ以外が原因の可能性があります
2. 直ったら、`Amplitude` を少しずつ下げ、`Frequency` も変えながら、**効果が残る範囲で一番気にならない設定**を探します

> [!WARNING]
> **音を小さくしすぎると、スピーカーが音を検出できず、スリープを防げなくなります。**
> `Amplitude` を下げたらこもりが戻ってきた場合は、少し上げてください。
>
> サイン波の大きさは **Windowsの音量にも左右されます**。Windowsの音量を下げると同じ設定でも効かなくなるので、Windowsの音量は大きめにし、スピーカー本体のつまみで聞きやすい大きさに調整するのがおすすめです。
>
> 極端に低い音(20Hz未満)や高い音(20kHz付近)は、スピーカーの検出回路が反応しないことがあります。

## 注意事項

- 完全に無音の状態からの**最初の再生**では、スピーカーはスリープ中なので、冒頭のフェードインは残ります。防げるのは、再生中の静かな場面や、余韻時間内の再生です
- SoundKeeperが動いている間は、PCが自動でスリープしないことがあります(余韻時間が過ぎて止まれば元に戻ります)
- 耳が敏感な方は、静かな部屋でサイン波がかすかに聞こえることがあります
- 個人用に作ったツールです。動作の保証やサポートはできません

## 仕組み

- Windowsの音声セッションAPI(WASAPI / Core Audio)で、既定の出力デバイスにある各アプリの音量メーターを0.25秒ごとに読み取ります
- このスクリプト自身とSoundKeeperのプロセスは除外します
- 音を検出したら `SoundKeeper64.exe sine -f <周波数> -a <大きさ>` を起動し、止める時はそのプロセスを終了します
- 外部への通信やファイルの書き込みは行いません(スタートアップ登録時のショートカット作成を除く)

`.bat` は `powershell -ExecutionPolicy Bypass` で `SpeakerKeeper.ps1` を実行するだけです。中身はテキストエディタで確認できます。

## クレジット

サイン波の再生には、Evgeny Vrublevsky 氏の [SoundKeeper](https://veg.by/projects/soundkeeper) を使用しています。SoundKeeperはこのリポジトリには含まれていません。

## ライセンス

[MIT License](LICENSE)

## Optional GUI and personal configuration (English)

The CLI still works through the original three BAT files. `settings.txt` is now optional and ignored by Git: copy `settings.example.txt` for CLI customization, or let the GUI create it on Save. Without it, both modes use 300 Hz, 0.1% amplitude, and a 30-second linger. Existing settings are not overwritten. For GUI launch, separate GUI autostart, and current limitations, see [README_GUI.md](README_GUI.md). GUI mode does not replace the CLI startup shortcut. Download SoundKeeper separately from its official website.
