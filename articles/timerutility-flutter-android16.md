---
title: "FlutterでAndroid 16対応のタイマーアプリを作るときに考えたこと"
emoji: "⏱️"
type: "tech"
topics: ["flutter", "dart", "android", "riverpod", "drift"]
published: false
---

## はじめに

Flutterでストップウォッチ、複数タイマー、アラーム、世界時計をまとめたAndroid向けアプリ
「TimerUtility」を作っています。

リポジトリはこちらです。

https://github.com/Bonkoturyu/TimerUtility

この記事では、アプリの機能紹介というよりも、実装中に考えた設計上の判断を書きます。
特に次の3つが中心です。

- Android 13以降の通知・アラーム制約にどう向き合うか
- Flutterアプリで時刻依存ロジックをどうテスト可能にするか
- Clean Architecture風のレイヤー分離を、個人開発規模でどう運用するか

完成品の宣伝というより、「タイマー/アラーム系アプリをFlutterで作るときの実装メモ」に近い記事です。

## 作っているもの

TimerUtilityは、Flutter製のAndroid向け時間管理アプリです。

主な機能は次の通りです。

- ストップウォッチ
- 複数タイマー
- 指定時刻アラーム
- スヌーズ
- ロック画面上でのアラーム表示
- 端末再起動後のタイマー/アラーム復元
- 世界時計
- プリセット
- 多言語対応
- ダークモード
- 診断ログのエクスポート

ただし、このプロジェクトで重視しているのは「多機能なタイマーアプリを作ること」そのものではありません。
むしろ、FlutterでAndroidのアラーム制約に向き合うためのリファレンス実装として育てています。

## 技術スタック

主要な構成は次の通りです。

| 用途 | 採用技術 |
| --- | --- |
| アプリ | Flutter / Dart |
| 状態管理 | Riverpod |
| ルーティング | go_router |
| 永続化 | Drift / SQLite |
| 通知 | flutter_local_notifications |
| 音声再生 | audioplayers |
| 権限 | permission_handler + MethodChannel |
| 時刻制御 | package:clock |
| テスト | flutter_test / mocktail / fake_async |

ターゲットはAndroid 16、minSdkは26です。
Notification ChannelやExact Alarmまわりの都合を考えると、古いAndroidまで無理に広げるより、制約が比較的読みやすい範囲に絞るほうが実装を安定させやすいと判断しました。

## アーキテクチャ

レイヤーは次のように分けています。

```text
Presentation
  ↓
Application
  ↓
Domain
  ↑
Infrastructure
```

各レイヤーの役割は次の通りです。

| レイヤー | 役割 |
| --- | --- |
| Presentation | Widget、Screen、画面イベント |
| Application | Riverpod Notifier、ユースケースの組み立て |
| Domain | Entity、ValueObject、ドメインサービス、port |
| Infrastructure | Drift、通知、音声、権限、Platform Channelのadapter |

一番強く守っているルールは、Domain層をPure Dartに保つことです。

Domain層では、次のようなものを禁止しています。

- `package:flutter` のimport
- `DateTime.now()` の直接呼び出し
- `Stopwatch` の直接利用
- `Timer.periodic` の直接利用
- DB、通知、音声、権限などの外部APIへの直接依存

これにより、時間計算や状態遷移をFlutterやAndroidから切り離してテストできます。

## なぜ時刻取得をClockに寄せたか

タイマーアプリでは、時刻取得があちこちに出てきます。

- ストップウォッチの開始時刻
- 経過時間
- タイマーの終了時刻
- アラームの次回発火時刻
- スヌーズ後の時刻
- アプリ復帰時の再計算

ここで安易に `DateTime.now()` を直接呼ぶと、テストが急に難しくなります。

例えば「5分後にタイマーが完了する」ことをテストしたいだけなのに、実時間で5分待つわけにはいきません。
また、現在時刻に依存するテストは、実行タイミングによって微妙に結果が変わるためflakyになりやすいです。

そこで、このプロジェクトでは `package:clock` を使い、時刻取得をすべて `Clock` 経由にしています。

イメージは次のような形です。

```dart
class StopwatchService {
  StopwatchService({required Clock clock}) : _clock = clock;

  final Clock _clock;

  StopwatchState start() {
    return StopwatchState.running(startedAt: _clock.now());
  }
}
```

Application層ではRiverpod Providerとして注入します。

```dart
@Riverpod(keepAlive: true)
Clock clock(ClockRef ref) => const Clock();
```

テストでは固定時刻に差し替えます。

```dart
final container = ProviderContainer(
  overrides: [
    clockProvider.overrideWithValue(
      Clock.fixed(DateTime(2026, 1, 1, 12, 0)),
    ),
  ],
);
```

この方針にしたことで、ドメインロジックの多くは「特定の時刻を与えたら、期待する状態になるか」という単純なテストに落とせました。

## 絶対時刻ベースで状態を持つ

もう一つ重要なのが、タイマーやストップウォッチの状態を「経過時間」ではなく「絶対時刻」で持つことです。

例えばタイマーなら、残り秒数を減らし続けるのではなく、終了予定時刻を保存します。

```text
startAt = 2026-01-01 12:00:00
duration = 10 minutes
endAt = 2026-01-01 12:10:00
```

残り時間は、表示時点の `now` と `endAt` の差分から計算します。

この方式にすると、アプリがバックグラウンドに回っても、端末がスリープしても、表示更新が止まっても、状態そのものは壊れません。
アプリ復帰時に現在時刻から再計算すればよいからです。

ストップウォッチも同様に、`Stopwatch` オブジェクトを持ち続けるのではなく、開始時刻や一時停止までの累積時間を状態として持ちます。

## Androidのアラーム制約が一番大変だった

タイマー/アラームアプリで一番難しいのは、UIではなくAndroid側の制約でした。

特に考える必要があったのは次のあたりです。

- `POST_NOTIFICATIONS`
- `SCHEDULE_EXACT_ALARM`
- `USE_EXACT_ALARM`
- `USE_FULL_SCREEN_INTENT`
- Doze Mode
- 端末再起動後の通知再予約
- Notification Channelの音声設定
- ロック画面上でActivityを出す挙動

Android 12以降、正確な時刻にアラームを鳴らすにはExact Alarm権限が関係します。
Android 13以降は通知許可も必要です。
Android 14以降はFull Screen Intentも制限が強くなっています。

つまり「通知を予約して鳴らすだけ」のつもりでも、実際には複数のOS制約をまたぐ必要があります。

## Foreground Serviceは使わない方針にした

最初に決めた大きな方針は、Foreground Serviceを使わないことです。

タイマーアプリでは、バックグラウンドで1秒ごとにカウントダウンを更新したくなります。
しかし、Androidのバックグラウンド実行制約は年々厳しくなっています。
Android 16を主ターゲットにするなら、長時間動くForeground Serviceに寄せるより、OSにアラームを予約して、発火時だけ通知・画面遷移するほうが素直です。

このプロジェクトでは次の方針にしています。

- アラーム発火はOSに予約する
- バックグラウンドで秒単位の表示更新はしない
- アプリ前面時だけUIを周期更新する
- 状態は絶対時刻で保存し、復帰時に再計算する

この割り切りによって、バッテリー消費やForeground Service制約との戦いを避けられました。

## ロック画面上のアラーム表示

アラームアプリらしい体験として、ロック画面上に鳴動画面を表示したい要件がありました。

AndroidではFull Screen Intentを使います。
Flutter側では `flutter_local_notifications` の `fullScreenIntent: true` を使い、Native側ではActivityに対してロック画面表示の設定を行います。

ただし、ここにも落とし穴がありました。

Manifestに常時 `showOnLockScreen` や `turnScreenOn` を付けるだけでは、Android 14以降の挙動で問題が出ることがあります。
実機検証では、ロック解除後にRecent Appsボタンが消えるような副作用も確認しました。

最終的には、キーガード状態を見て必要なときだけ `setShowWhenLocked(true)` / `setTurnScreenOn(true)` を呼び、アラーム画面から離れるときに明示的に解除する形にしました。

このあたりはエミュレータやWidget Testでは再現できないので、Pixel 6a実機で何度も確認しています。

## 通知音とアプリ内音声の二重再生

地味に苦労したのが、通知音とアプリ内音声の二重再生です。

アラーム通知にはNotification Channelの音があります。
一方で、アラーム画面が開いた後は `audioplayers` でループ再生したい。

この2つを何も考えずに両方鳴らすと、通知チャンネル音とアプリ内音声が重なります。

通知をcancelすれば止まるだろうと思っていたのですが、実機ではそう単純ではありませんでした。
Notificationをcancelしても、`AudioAttributesUsage.alarm` で鳴っているチャンネル音が即座に止まらず、少し残るケースがあります。

最終的には次のような順序にしました。

```text
通知発火
  ↓
アラーム画面を表示
  ↓
通知をcancel
  ↓
少し待つ
  ↓
audioplayersでアプリ内音声を再生
```

Pixel 6a / Android 16では、500ms程度の待機を入れることで二重再生が解消しました。

このような挙動は机上の設計だけでは分からず、実機検証の重要性を再認識しました。

## Driftで永続化する

タイマー、アラーム、プリセット、世界時計のエントリはDriftでSQLiteに保存しています。

Driftを採用した理由は、次の通りです。

- 型安全にクエリを書ける
- マイグレーションを管理しやすい
- in-memory DBでテストしやすい
- Flutterアプリのローカル永続化として十分に軽い

RepositoryはDomain層のportとして定義し、Infrastructure層でDrift実装を持つ形にしています。

```text
Domain
  ports/timer_repository.dart

Infrastructure
  database/drift_timer_repository.dart
```

これにより、Application層はDriftを直接知りません。
テスト時にはRepositoryをFakeに差し替えることもできます。

## Riverpodは依存注入の基盤としても使う

Riverpodは状態管理だけでなく、依存注入の基盤としても使っています。

例えば、通知スケジューラ、リポジトリ、Clock、音声プレイヤー、権限管理などはProvider経由で差し替え可能にしています。

```text
UI
  ↓ ref.watch
Notifier
  ↓ ref.watch
Domain Service / Port
  ↓
Adapter
```

この構成にすると、テストで外部依存を差し替えやすくなります。

```dart
final container = ProviderContainer(
  overrides: [
    notificationSchedulerProvider.overrideWithValue(fakeScheduler),
    timerRepositoryProvider.overrideWithValue(fakeRepository),
  ],
);
```

特にタイマー/アラーム系は、通知、時刻、DB、音声が絡むので、依存を差し替えられる構造にしておく価値が大きかったです。

## テスト戦略

テストはレイヤーごとに分けています。

| 対象 | テスト |
| --- | --- |
| Domain | Pure Dart unit test |
| Application | ProviderContainerを使ったNotifier test |
| Infrastructure | in-memory DBやMethodChannel mock |
| Presentation | Widget test |
| OS連携 | 実機手動テスト |

方針はシンプルです。

- ロジックは自動テストに寄せる
- OSが絡むものは無理に自動化しすぎない
- 時間制御テストで実時間sleepをしない
- 期待する振る舞いを日本語のテスト名で書く

タイマーアプリでは「数秒待つテスト」を書きたくなりますが、実時間待機は避けています。
`fake_async` や `tester.pump(Duration)`、`Clock.fixed` を使って、仮想時間で進めます。

## 実装してよかったこと

作ってみて、特によかった設計判断は次の3つです。

1つ目は、Domain層をPure Dartに保ったことです。
時間計算、上限制約、繰り返しアラーム、スヌーズなどのロジックをFlutterから切り離せたので、テストが速く安定しました。

2つ目は、時刻取得を `Clock` に寄せたことです。
タイマーアプリでは現在時刻が事実上のグローバル依存になりがちですが、それを明示的な依存にできました。

3つ目は、Android固有の挙動をドキュメント化しながら進めたことです。
Full Screen Intent、Exact Alarm、通知音、再起動復元などは、実装した本人でも後から忘れやすい領域です。
実機で起きた問題と対応を残しておくことで、同じ問題を再調査する時間を減らせました。

## 逆に難しかったこと

難しかったのは、Flutterの中だけで完結しない部分です。

特に次の領域は、公式ドキュメント、プラグイン仕様、Android実機挙動の3つを突き合わせる必要がありました。

- Full Screen Intentの権限とフォールバック
- Exact Alarmの権限
- Notification Channelの音声設定
- 通知タップ時のcold start
- ロック画面上Activityのライフサイクル
- 端末再起動後の通知復元

このあたりは、コードだけ見ると小さな差分でも、挙動の確認にはかなり時間がかかります。

## まとめ

TimerUtilityは、見た目としては普通のタイマーアプリです。
ただ、実装面ではAndroidのアラーム制約、時刻依存ロジックのテスト、Flutterでのレイヤー分離をかなり意識しています。

今回の開発で得た教訓は次の通りです。

- タイマー/アラームアプリでは、状態を絶対時刻で持つと復帰・再起動に強い
- `DateTime.now()` を直接呼ばず、`Clock` を注入するとテストが安定する
- FlutterでもDomain層をPure Dartに保つ価値は大きい
- Androidの通知・アラーム・ロック画面まわりは実機検証が必須
- Foreground Serviceに寄せず、OS予約 + 復帰時計算で済ませる設計も有効

今後はPlay Store提出に向けて、アイコン、スクリーンショット、プライバシーポリシー、署名まわりを整えていく予定です。

## 参考

- TimerUtility: https://github.com/Bonkoturyu/TimerUtility
- flutter_local_notifications: https://pub.dev/packages/flutter_local_notifications
- Riverpod: https://riverpod.dev/
- Drift: https://drift.simonbinder.eu/
- package:clock: https://pub.dev/packages/clock

---

## 注記

本記事は、AIに草稿を作成させたうえで、内容を確認・編集して生成しました。
