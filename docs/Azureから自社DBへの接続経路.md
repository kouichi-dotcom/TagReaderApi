# Azure B1 → 自社 DB の接続経路（A 案）

App Service を **Basic (B1)** にし、**Hybrid Connection** で自社 SQL Server（オンプレ）に接続するための手順と方針。

---

## 方針：まず読み取りのみ

- **本番DBへの接続後、当面は読み取りのみ**とする。
  - **利用する API**: 伝票一覧取得（GET /api/reception-slips）、担当者取得（GET /api/employees）、商品取得（GET /api/products）。いずれも SELECT のみ。
  - **更新はまだ使わない**: 商品ステータス更新（POST /api/product-updates）は、接続経路の安定運用を確認してから有効化する。
- アプリ側では伝票・担当者・商品の「表示・取得」だけ行い、**商品のステータス更新送信**は行わない運用でよい。

---

## B1 と Hybrid Connection の前提

- **Hybrid Connection** は **Basic (B1) 以上** で利用可能（[公式ドキュメント](https://learn.microsoft.com/ja-jp/azure/app-service/app-service-hybrid-connections)）。Free (F1) では利用できない。
- B1 ではプランあたり **最大 5 本**のハイブリッド接続まで。
- 単一の **TCP ホスト:ポート**（SQL Server の DNS 名 + 1433）に対応。Azure Relay 経由で 443 で通信。
- **料金**: App Service B1（Windows）は月額目安 約 7,000円前後（税別）。Azure Relay / Service Bus は別途（[App Service 料金](https://azure.microsoft.com/ja-jp/pricing/details/app-service/windows/)、[Service Bus 料金](https://azure.microsoft.com/ja-jp/pricing/details/service-bus/) で最新を確認）。

---

## B1 契約前の確認（プランと本番DBの両方を確認してから契約）

B1 で契約する前に、**プランの内容**と**本番DBまわりの状態**の両方を確認し、接続できる見込みがあることを確認してから契約する。

### 1. B1 プランの内容確認

| 確認項目 | 内容 | 確認方法 |
|----------|------|----------|
| **Hybrid Connection の利用可否** | B1 では **利用可能**。プランあたり **最大 5 本**。 | [Azure App Service でハイブリッド接続を作成して使用する](https://learn.microsoft.com/ja-jp/azure/app-service/app-service-hybrid-connections) の「料金プラン」を確認。 |
| **接続方式** | 単一の **TCP ホスト:ポート**（SQL Server の DNS 名 + 1433）に対応。 | SQL Server は TCP 1433 で要件を満たす。 |
| **料金** | App Service B1 + Azure Relay / Service Bus の料金を確認。 | 上記リンクで最新を確認。 |

**判定**: B1 で Hybrid Connection が使え、SQL Server（TCP 1433）への接続がサポートされていることを確認したら、プラン側は OK。
### 現在の確認状況（2026-03-03 時点）

- **① SQL Server の稼働**:  
  `sqlcmd -S OOMIYASV1 -d OOMIYADB -U sa -P superuser` で接続し、`SELECT 1` → `GO` により `1` が返ることを確認済み。

- **② TCP ポート 1433**:  
  SQL Server 構成マネージャーで TCP/IP が「有効」になっていることを確認済み。  
  あわせて PowerShell の  
  `Test-NetConnection -ComputerName OOMIYASV1 -Port 1433` で **TcpTestSucceeded : True** を確認済み。

- **③ DNS 名**:  
  HCM を置く予定のマシンから `ping OOMIYASV1` が成功（IPv6 アドレスに解決され応答あり）。  
  `nslookup OOMIYASV1` では DNS レコードなし（Non-existent domain）だが、名前解決と到達自体はできている状態。

- **④ HCM を置くマシンから 1433 に接続**:  
  上記 `sqlcmd -S OOMIYASV1 -d OOMIYADB ...` の結果より、同マシンから OOMIYASV1 の 1433 に接続できていることを確認済み。

- **⑤ インターネット（443）へのアウトバウンド**:  
  （未確認）HCM 候補マシンから `Invoke-WebRequest -Uri "https://www.microsoft.com" -UseBasicParsing` で外部サイトに到達できるか要チェック。

- **⑥ 接続文字列での API 動作**:  
  （未確認）本番DB向け接続文字列で TagReaderApi を起動し、  
  `/api/employees?code=…` や `/api/reception-slips` で本番DBからデータ取得できるか要チェック。
**判定**: ①〜⑥をすべて満たしたら、本番DB側は OK。B1 にしたうえで HCM をこのマシンに置けば、Azure → 自社 DB に接続できる見込み。

### 3. 契約の判断

- **1（プラン）と 2（本番DB）の両方で問題なし** → B1 にスケールアップし、Hybrid Connection と HCM の構築に進む。
- **どちらかで不明・不足** → 解消してから B1 契約する。

※ 現在 F1 の Web アプリは、**スケールアップ（F1 → B1）** で同じリソースのままプランだけ変更できる。

---

## Hybrid Connection を利用する場合の手順（B1 契約後）

1. **App Service プランを B1 に変更**（F1 の場合はスケールアップ）。
2. **Azure Relay / Service Bus 名前空間**を用意する（App Service と同じリージョン推奨。Japan West なら西日本）。
3. **Azure ポータル**で、対象の Web アプリ → **設定** → **ネットワーク** → **ハイブリッド接続** → **ハイブリッド接続の追加**。
4. 以下を指定する：
   - **エンドポイント ホスト**: 自社 SQL Server の **DNS 名**（例: `OOMIYASV1` または FQDN）。
   - **エンドポイント ポート**: **1433**（SQL Server の既定。別ポートの場合はその番号）。
   - **Service Bus 名前空間**: 上記で用意した名前空間。
5. **自社側**で **Hybrid Connection Manager (HCM)** をインストールする。
   - ダウンロード: Azure ポータルのハイブリッド接続の画面から「接続マネージャーのダウンロード」などで取得。
   - SQL Server が動いているサーバー、または SQL Server に 1433 でアクセスできるマシンに HCM を入れ、Azure のハイブリッド接続に「接続」させる。
6. 接続文字列は既に App Service の **環境変数（接続文字列）** で設定済みであればそのまま。**Server=** には HCM から名前解決できる **DNS 名**（上記と同じ）を使う。
7. 動作確認: アプリから Azure API を呼び、伝票一覧・担当者・商品取得が返ることを確認する。**読み取りのみ**なので、更新系の操作は行わない。

詳細は [Azure App Service のハイブリッド接続](https://learn.microsoft.com/ja-jp/azure/app-service/app-service-hybrid-connections) を参照。

---

## 読み取りのみ運用の確認

- 接続経路構築後、アプリで **伝票一覧**・**担当者コード入力**・**タグ（商品）取得** ができることを確認する。
- **商品ステータス更新（送信）** は、方針に従い「まだ使わない」。必要になったら運用で有効化する。

---

## まとめ

| 項目 | 内容 |
|------|------|
| **方針** | 本番DBは **読み取りのみ**。伝票・担当者・商品の取得のみ行い、更新は後で有効化。 |
| **接続経路** | **B1 + Hybrid Connection**。自社に HCM を設置し、SQL Server（DNS 名 + 1433）に接続。 |
| **B1 契約前** | **プランの内容**（B1 で Hybrid Connection 利用可・料金）と **本番DBの状態**（稼働・ポート・DNS 名・HCM 置き場・443 出先・接続文字列）の両方を確認し、問題なければ B1 で契約。 |
| **次のステップ** | B1 契約前の確認を実施 → OK なら B1 にスケールアップ → Hybrid Connection と HCM を構築。 |
