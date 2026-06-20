---
title: "VCCが起動直後にクラッシュする原因と直し方｜重複パッケージ（VRCFury）"
emoji: "🩺"
type: "tech"
topics: ["vrchat", "unity", "vcc", "vrcfury", "powershell"]
published: false
---

ALCOM では普通に開けるのに、VCC（VRChat Creator Companion）を起動すると一瞬で落ちる——そんな状態にハマったときの、原因の切り分けと直し方のメモです。最後に、複数プロジェクトを横断して自動検出・修復する PowerShell スクリプトも置いておきます。

:::message
**TL;DR**
`Packages/` の中に、`package.json` の `"name"` が同じパッケージを名乗るフォルダが **2つ** あると、VCC は起動時のスキャンで重複キー例外を吐いて **起動ごとクラッシュ** します。多くは VRCFury の自動更新が旧フォルダを消し切れずに残したのが原因。**余分な方のフォルダを退避（または削除）すれば直ります。** すぐ作業したいだけなら ALCOM で開けばOK。
:::

## 症状

VCC を起動すると、スプラッシュが出た直後に落ちる。ログ（`%LOCALAPPDATA%\VRChatCreatorCompanion\Logs\` 配下）を見ると、こんな例外が記録されています。

```text
[ERR] Creator Companion crashed: One or more errors occurred.
(An item with the same key has already been added. Key: com.vrcfury.vrcfury)
System.ArgumentException: An item with the same key has already been added. Key: com.vrcfury.vrcfury
   at System.Collections.Generic.Dictionary`2.Add(TKey key, TValue value)
   at VRC.PackageManagement.Core.Types.Providers.UnityProjectVPMProvider.Refresh()
   at VRC.PackageManagement.Core.Types.UnityProject..ctor(String path)
   at VRC.CreatorCompanion.Core.Projects.SyncWithSettings()
   at VRC.CreatorCompanion.Core.VCCDatabase.Initialize()
```

ポイントは2つ。

- `Dictionary.Add` が **重複キー** で `ArgumentException` を投げている（`Key: com.vrcfury.vrcfury`）。
- それが起動時の `SyncWithSettings()` ＝ **登録済みプロジェクトの一括同期** の中で起きている。

つまり「登録しているプロジェクトのどれか1つ」が壊れているだけで、**VCC全体が起動不能** になります。ALCOM は内部実装が別物なので、同じ状態でも開けることが多いです。

## なぜ起きるのか

VCC の `UnityProjectVPMProvider.Refresh()` は、プロジェクトの `Packages/` 配下を走査して、各フォルダの `package.json` を読み、**`"name"` フィールドをキーにした辞書** を作ります。

ここで重要なのが、**キーはフォルダ名ではなく `package.json` の `"name"`** だということ。なので次のような状態だと重複が発生します。

- `Packages/com.vrcfury.vrcfury/package.json` → `"name": "com.vrcfury.vrcfury"`
- `Packages/com.vrcfury.vrcfury (1)/package.json` → `"name": "com.vrcfury.vrcfury"`

2つ目を辞書に `Add` した瞬間に重複キー例外、というわけです。フォルダ名が `(1)` でも `- コピー` でも、**まったく無関係な名前のフォルダ** でも、中の `"name"` が一致していれば等しく地雷になります。

### よくある発生源：VRCFury の自動更新

VRCFury は自前のアップデータを持っていて、起動時に自分を更新します。このとき **旧バージョンのフォルダを消し切れず、新旧2つのフォルダが残る** ことがあります。`vpm-manifest.json` の `dependencies` と `locked` でバージョンがずれている（例：要求 `1.1296.0` / 解決 `1.1341.0`）ときは、この更新が絡んでいる兆候です。

## 原因の切り分け（手動）

エラーが `com.vrcfury.vrcfury` を名指ししているので、まず「どこで二重になっているか」を上から潰します。

### 1. `Packages/manifest.json`（Unity UPM）を見る

ここに `com.vrcfury.vrcfury` が書かれていないか確認。VRCFury は VPM 管理なので、本来ここには **居ないのが正常**。居たら削除候補。

### 2. `Packages/vpm-manifest.json`（VCC）を見る

`dependencies` と `locked` に **1回ずつ** 出てくるのは正常な構造です（要求と解決結果が別オブジェクト）。同じセクション内に2回は出ないので、ここで JSON レベルの重複が見つかることは基本ありません。

### 3. `Packages/` の実フォルダを見る（本命）

エクスプローラで `Packages/` を開き、**`com.vrcfury.vrcfury` 系のフォルダが複数ないか** を確認します。`...(1)`、`... - コピー`、見慣れない名前のフォルダがあれば、その中の `package.json` を開いて `"name"` をチェック。

:::message
エラーが特定のパッケージ名（ここでは `com.vrcfury.vrcfury`）を **ピンポイントで** 出しているのが決め手です。もし「`dependencies` と `locked` を二重カウントしている」ような汎用バグなら、最初に処理されたパッケージで落ちるはず。特定の名前を名指ししている＝そのパッケージに固有の事情（＝物理コピーが2つ）がある、と読めます。
:::

## 直し方（手動）

1. **VCC / ALCOM / Unity をすべて閉じる。**
2. `Packages/` の中で、`"name": "com.vrcfury.vrcfury"` を名乗るフォルダを全部洗い出す。
3. **フォルダ名 = パッケージ名** になっている方（＝ `com.vrcfury.vrcfury`）を正規（canonical）として残し、**それ以外を退避** する。いきなり削除せず、まずプロジェクト外へ移動してバックアップにするのが安全。
4. ついでに `com.vrcfury.temp`（VRCFury が生成する一時パッケージ）が残っていたら消してOK。揮発性なので再生成されます。
5. VCC を起動して、落ちなければ完了。バージョンがずれていたら VCC/ALCOM で Resolve / Update をかけて揃える。

## 自動化スクリプト

プロジェクトを大量に登録している人向けに、**全プロジェクトを横断して重複を検出・退避する** PowerShell スクリプトを用意しました。検出は **フォルダ名パターンではなく `package.json` の `"name"` ベース** なので、`(1)` でも `- コピー` でも無関係な名前でも拾えます。

スクリプト一式はこのリポジトリの [`VCCDuplicateChecker/`](https://github.com/Bonkoturyu/zenn-content/tree/main/VCCDuplicateChecker) に置いてあります。

構成は3ファイル＋実行用の `.cmd` ラッパー（同じフォルダに置いて使用）。

- `VccDuplicates.Common.ps1` … 共通の検出ロジック
- `Scan-VccDuplicates.ps1` … 読み取り専用スキャン（何も変更しない）
- `Fix-VccDuplicates.ps1` … 重複フォルダをプロジェクト外へ退避（既定はドライラン）

### 使い方

```powershell
# 1. まず全プロジェクトを棚卸し（読み取り専用）
.\Scan-VccDuplicates.ps1

# 2. 退避のプレビュー（ドライラン、まだ動かさない）
.\Fix-VccDuplicates.ps1

# 3. 実際に退避を実行
.\Fix-VccDuplicates.ps1 -Apply
```

`.cmd` のダブルクリックでも動くようにしてあります。

### 安全設計

- 退避は **「フォルダ名 = パッケージ名」の正規フォルダを残し、それ以外を移動**。
- 移動するのは **バージョンが正規フォルダと一致する真の重複のみ**。バージョンが違う場合は誤判定を避けるため自動では触らず、手動扱いにする。
- 正規フォルダが一意に決まらない場合（どれもフォルダ名が一致しない等）は **AMBIGUOUS** として手を出さない。
- 削除ではなく **プロジェクト外への移動（quarantine）**。Unity からもそのプロジェクトの git からも見えない場所に退避するので、確認後に消せば良い。

## 初心者向けの注意：SmartScreen と実行ポリシー

ダウンロードした `.ps1` / `.cmd` は、Windows のセキュリティ機能で実行がブロックされることがあります。

- ダウンロードした zip は、展開前に **右クリック → プロパティ → 「許可する（ブロックの解除）」** にチェックを入れてから展開する。
- それでも止まる場合は、PowerShell を開いて以下を実行してから動かす（その PowerShell セッション限定で許可）。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

中身が不安な場合は、スクリプトはただのテキストファイルなのでメモ帳で開いて読めます。**ファイルを削除せず移動するだけ** であることが確認できます。

## とりあえず今すぐ作業したい人へ：ALCOM

原因究明より先に手を動かしたいなら、[ALCOM](https://vrc-get.anatawa12.com/alcom/) を入れて開けばOKです。VCC の代替（無料・OSS・VCC と共存可）で、同じプロジェクト設定をそのまま参照します。落ちている VCC を尻目に普通に作業できることが多いです。ただし `Packages/` の重複自体は残ったままなので、VCC も使いたいなら結局は上記の掃除が必要になります。

## まとめ

- 「VCC が起動直後にクラッシュ」「`An item with the same key has already been added. Key: com.vrcfury.vrcfury`」は、**`Packages/` 内の同名パッケージフォルダ二重化** が原因。
- 検出のキーは **フォルダ名ではなく `package.json` の `"name"`**。
- 直し方は **正規フォルダを残して余分な方を退避**。
- 多発・複数プロジェクトなら名前ベースの検出スクリプトで一括処理が楽。
- 急ぐなら ALCOM で逃げて、後で掃除。

同じところでハマっている人の検索に引っかかれば幸いです。
