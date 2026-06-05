---
title: "VRChatで巨大あみだくじワールドを個人開発してCommunity Labs通過するまで"
emoji: "🎯"
type: "tech"
topics: ["vrchat", "udonsharp", "unity", "vr", "quest"]
published: true
---

## はじめに

「あみだくじをVRChatワールドにしたら面白いのでは」という思いつきから、PC・Quest・iOSのクロスプラットフォーム対応ワールドを個人で作りました。

2026年5月末にCommunity Labsへ公開し、6月にレビューを通過しました。

この記事では、設計の決断、クロスプラットフォーム対応の工夫、UdonSharp固有のハマりポイント、そしてClaude Codeを活用した開発フローについて書きます。

VRChatワールド開発に限らず、「ネット同期のある体験コンテンツをUnityで作る」際に参考になる話が多いと思います。

---

## どんなワールドか

**Ghost-Leg Express / 巨大あみだくじ** は、カートに乗ってランダム生成されたあみだくじを自動巡回するパーティゲームです。

- 最大4人がカートに乗ってスタート
- インスタンスオーナーがスタートボタンを押すと、seedから決定論的に生成された横線配置に従ってカートが走行
- ゴール到達後、カート上のプレイヤーが賞品エリアへテレポート
- 爆発(ハズレ)・紙吹雪(当たり)・無演出の3種がseedからランダム配置される
- 非参加者は同じ床面を自由に歩き回り、カートを追いかけて観戦可能

あみだくじの「誰もコースを事前に知らない」という特性がVRChatの多人数体験と相性が良く、参加者4人 + 観戦者多数でも全員が楽しめる形になっています。

---

## 技術スタック

| 要素 | 採用技術 |
|---|---|
| エンジン | Unity 2022.3 LTS |
| SDK | VRChat World SDK 3.x |
| スクリプト | UdonSharp (U#) |
| プロジェクト管理 | VRChat Creator Companion (VCC) |
| ローカルテスト | ClientSim |
| CI | GitHub Actions (blueprintId漏洩ガード + 生成物混入ガード) |
| コードレビュー | Gemini Code Assist + GitHub Copilot |
| 開発補助 | Claude Code (Opus/Sonnet) |

---

## 設計の核心: 同期変数を最小限にする

VRChatのネットワーク同期は変数数・更新頻度に制約があります。カートの位置を毎フレーム送るのは現実的ではありません。

採用したのは **「seedだけ同期して、あとは全員がローカルで同じ計算をする」** というアプローチです。

同期している変数は4つだけです。

```csharp
[UdonSynced] int seed;                   // あみだくじ生成シード
[UdonSynced] int gameState;              // ゲーム状態 (Idle/Countdown/Running/ResultDisplay)
[UdonSynced] double raceStartTime;       // レース開始サーバー時刻
[UdonSynced] int[] participantPlayerIds; // 各座席のプレイヤーID
```

全クライアントが同じseedと同じアルゴリズムで横線配置・Waypointを計算するため、カートの現在位置も演出の割当も、追加の同期なしで全員が一致します。

途中参加(Late Joiner)への対応もスッキリします。「経過時間 × 速度」からカートの現在位置を即算出できるので、途中から入ってきたプレイヤーも自然に状態へ追いつけます。

---

## カート移動: 事前計算Waypoint + Lerp

カートの動き方にはいくつか候補がありました。

1. **リアルタイム判定**: 交差点到達ごとに横線を確認して進路決定
2. **事前計算 + Lerp**: スタート時に全Waypointを計算し、サーバー時刻ベースでLerp補間
3. **Animator駆動**: seed依存の動的経路との相性が悪く却下

採用したのは2つ目の方式です。ポイントは、カート位置が「純粋な関数」として求まる点です。

```csharp
// Update() の中
double now = Networking.GetServerTimeInSeconds();
double elapsed = Networking.CalculateServerDeltaTime(now, raceStartTime);

// elapsedからWaypoint区間とt値を計算してLerp
int seg = (int)(elapsed / SEG_DURATION);
float t = (float)((elapsed % SEG_DURATION) / SEG_DURATION);
transform.position = Vector3.Lerp(waypoints[seg], waypoints[seg + 1], t);
```

`elapsed` さえ分かればカートの位置は一意に決まります。同期処理も状態管理も不要で、Late Joinerも同じコードで即追いつけます。

`CalculateServerDeltaTime()` の使用が必須なのは後述します。

---

## 設計の転換点: 縦置き60mから平面水平レイアウトへ

実は当初、あみだくじを「高さ60mの縦置き構造」として設計していました。縦線・横線が空中に浮かぶ歩行可能な多層建築で、観戦者が階段を上り下りしながらカートを追いかけるイメージです。

仕様策定を進めるうち、**設計者と私の認識がズレていた**ことが判明しました。本来のコンセプトは次のようなものでした。

> 平たい地面にあみだくじの線が書かれていて、その上をカートが動く。
> 横線のパターンが変わってもカートの動きが変わるだけ。

縦置きは過剰解釈でした。

開発中盤でのレイアウト変更でしたが、結果的にメリットが多かったです。

| 変更前(縦置き) | 変更後(平面水平) |
|---|---|
| 60m高所からの墜落リスクあり | 墜落なし |
| 観戦者が階段・ランプで上下移動 | 同じ床面を追いかけるだけ |
| ProBuilderで複雑な床が必要 | Primitive Cube + Scaleで足りる |
| Quest描画負荷: 高 | Quest描画負荷: 大幅に軽減 |

最終的な数値は次の通りです。

- Tri数: 2,700
- バッチ数: 13
- Quest実機FPS: 70 FPS (目標60以上)

---

## クロスプラットフォーム対応 (PC + Quest + iOS)

VRChatのQuestワールドには独自の制約があります。

### マテリアルの制約

| 制約 | 内容 | 対応 |
|---|---|---|
| **透明度マテリアル禁止** | アルファブレンド一切使用不可 | 全マテリアルをOpaque/Cutoutに限定 |
| **テクスチャ上限** | 1024x1024まで | 全テクスチャをリサイズ |
| **GPU Instancing** | 全マテリアルで必須 | Inspector上で全有効化 |

爆発演出に「黒煙」を入れたかったのですが、黒煙の表現にはアルファブレンドが必要です。Questでは使えないため、**灰白色の煙** に差し替えました。

「爆発した感」は十分出ましたが、完全な煤感は諦めています。

### シェーダー選定

Questで安定するシェーダーとして `VRChat/Mobile/Standard Lite` を基本に使いました。

- `_Color` プロパティと `Enable GPU Instancing` を持つ
- Lightmap対応 + Quest向け軽量描画パス

カートの色をプレイヤーが選択できる機能(8色パレット)を実装したのですが、Static Batchingが有効な状態では `MaterialPropertyBlock` による動的な色変更ができません。

賞品エリアの壁だけ **Batching Static をOFF** にして対応しました。

### ビルドとテストの運用

PlatformをAndroidに切り替えてビルドし、同じBlueprint IDにアップロードする手順を踏みます。PC版とAndroid版、iOS版は同じBlueprint IDで紐づけられます。

ClientSimはAndroidビルドの再現ができないため、Static Batchingの動作確認は **Quest実機でJoinするしか方法がない** 項目が残ります。

---

## UdonSharpのハマりポイント

### `(int)DateTime.Now.Ticks` はオーバーフローで即クラッシュ

v1.0公開後にユーザーから「スタートを押しても何も起きない」と報告を受けて発覚したバグです。

原因はseed生成のコードでした。

```csharp
// NG: UdonSharpでは (int)long が Convert.ToInt32 にコンパイルされる
// DateTime.Now.Ticks は常にint範囲を超えているため毎回例外が発生し、
// UdonBehaviour が halt する
seed = (int)DateTime.Now.Ticks;
```

通常のC#では `(int)long` は切り捨て変換ですが、UdonSharpでは `Convert.ToInt32()` にコンパイルされます。`Convert.ToInt32` は範囲外の値に対して実行時例外を投げるため、`DateTime.Now.Ticks` は**常にオーバーフロー例外**を発生させていました。

修正はシンプルです。

```csharp
// OK: int直接返却、サーバー同期済み、約24.8日周期でラップ
seed = Networking.GetServerTimeInMilliseconds();
```

やむを得ずlongをintに変換する場合は、下位ビットマスクで範囲内に収めてから行います。

```csharp
int safeInt = (int)(someLong & 0x7FFFFFFFL);
```

### `GetServerTimeInSeconds()` の差分を直接引き算してはいけない

VRChat内部の仕様で、`GetServerTimeInSeconds()` は**約半数のクライアントで負値**を返すことがあります。ワールド滞在中は符号が固定されるため、引き算の結果が全クライアントで一致しません。

```csharp
// NG: クライアントによって結果が異なる可能性
double elapsed = Networking.GetServerTimeInSeconds() - raceStartTime;

// OK: VRChat提供のAPIで安全に差分計算
double elapsed = Networking.CalculateServerDeltaTime(
    Networking.GetServerTimeInSeconds(), raceStartTime);
```

### その他のUdonSharp制約まとめ

| 制約 | 代替手段 |
|---|---|
| `async/await` 不可 | `SendCustomEventDelayedSeconds("EventName", seconds)` |
| `IEnumerator` 不可 | 同上 |
| `List<T>` 等ジェネリック不可 | 固定長配列 `int[] arr = new int[4]` |
| `(int)long` が切り捨てでなく例外 | `Networking.GetServerTimeInMilliseconds()` または下位ビットマスク |
| `System.Random` | SDK 3.7.1以降で利用可能(自前PRNG実装不要) |

---

## AI活用: Claude Codeとの開発スタイル

本プロジェクトではClaude Code(Anthropicの開発者向けCLI)を活用して開発しました。

通常のAIコーディング支援と異なるのは、**設計判断の壁打ち相手**としての使い方です。

具体的にやっていたことは次の通りです。

- **ADR(Architecture Decision Records)の起案**: 「このAPIを選んだ理由」「却下した選択肢」をClaude Codeとの会話から文書化。上述の `CalculateServerDeltaTime` 採用の根拠なども記録済み
- **Phase単位のタスク管理**: 「今日Phase 4を終わらせる」と宣言して、設計・実装・テスト項目を一緒に整理しながら進める
- **落とし穴の横断検索**: バグが出たときに「同様のパターンが他のスクリプトにないか」をコードベース全体にGrepしてもらう

ただし、**UdonSharpのAPIは学習データの時点から変わっていることが多い**ため、コード生成よりも「方針の相談」「既存コードのレビュー」寄りに使っていました。

「このUdonSynced変数の更新タイミングは正しいか?」のような質問の方が実用的です。

---

## テスト戦略

VRChat SDKはPlayMode Test Runnerと干渉するため、PlayModeテストが書けません。代わりに **EditMode + Reflection** でprivateメソッドを呼び出す方法を採りました。

```csharp
// AmidakujiGenerator の private メソッドを EditMode テストから呼ぶ
var method = typeof(AmidakujiGenerator).GetMethod(
    "GenerateHorizontalBars",
    BindingFlags.NonPublic | BindingFlags.Instance
);
method.Invoke(generator, new object[] { seed });

// seed -> 横線配置が決定論的に一致するかを検証
Assert.AreEqual(expected[0], generator.horizontalBars[0]);
```

あみだくじ生成ロジック(seedから横線配置を作る部分)は純粋な計算処理なので、このアプローチで8テストを書くことができました。

ネットワーク同期・VRCPlayerApi絡みの部分はClientSimでの手動テストに頼らざるを得ませんが、コアロジックだけでも自動テストがあると安心感が違います。

---

## まとめ

約1ヶ月の個人開発でCommunity Labs通過まで到達できた要因として、次の点が大きかったと感じています。

**設計面:**

- **同期変数の最小化** が全てに効いた。seedと時刻だけ渡して残りはローカル計算、という原則を守ることで、Late Joiner対応・パフォーマンス・デバッグがまとめてシンプルになった
- **ADRを書く習慣** で「なぜこの制約があるのか」を記録し続けた結果、数週間後に戻ってきても迷わず判断できた

**運用面:**

- **毎日Build & Test** を徹底した。「明日まとめてテスト」をやらず、Phase終了時に必ず動作確認した
- **AI活用は実装より設計相談に** 使った。コード生成は補助、壁打ちと文書化が本命

UdonSharpの制約は確かにありますが、「計算はローカル・結果だけ同期」という原則を守ると、思いのほかシンプルに書けます。

VRChatワールドを作ってみたい方の参考になれば幸いです。

---

## 注記

この記事自体はAI (Claude Sonnet 4.6) にたたき台を作らせて生成させたものです。
