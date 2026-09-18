# API公開のチェックリスト

TagReaderApi を Azure App Service で公開し、自社 SQL Server に接続するための最小チェックリスト。

> **本番構成（2026-08-21 採用）**: Azure App Service ＋ ASP.NET Core Web API ＋ Azure Key Vault → 自社 SQL Server  
> 方針の正本: [本番アーキテクチャ方針.md](./本番アーキテクチャ方針.md)

## 前提（このアプリで使うアカウント・リソース）

**旧アカウントや別サブスクリプションのリソースは参照しない。** 作業は次の Azure 環境を正とする。

| 項目 | 値 |
|------|-----|
| 組織 | 有限会社 大宮工機 |
| サインイン | 社用 Azure アカウント（ポータル右上に表示される **この** アカウント。TagReader 作業は常にここで行う） |
| サブスクリプション | `Azure subscription 1` |
| リソースグループ | `rg-tagreader-prod` |
| リージョン | Japan West（西日本） |
| App Service（API ホスト） | `tagreader-api` |
| App Service プラン | `ASP-rgtagreaderprod-90fb`（必要に応じてポータルで確認） |

IP 許可・接続文字列・デプロイ先の確認は、上記 **tagreader-api** を起点に進める。

## 0. まず何をしたらいい？

最初の着手は次の 3 ステップ。

- [ ] **公開先を上表の App Service（`tagreader-api`）で固定**した（別 RG・別アプリに勝手に切り替えない）
- [ ] **Azure 側の最新送信元IPを採取**した（`Outbound IP Addresses` と `Possible Outbound IP Addresses` は **この** App Service の画面から）
- [ ] **DB/社内FWに新IPで許可申請**した（旧環境の IP を流用しない。許可完了後に不要な旧許可を整理）

開始順の目安:

1. `tagreader-api` を起動状態にして送信元IPを確定
2. DB/ネットワーク管理者へ開放依頼（許可元IP + 1433/TCP）
3. 開放完了連絡後に API の疎通確認（`/api/environment` -> DB参照API）

## 1. 事前確認

- [ ] 公開対象環境（開発/本番）と接続先DB（サーバー名、DB名）が確定している
- [ ] DB接続アカウント（最小権限）が発行済み
- [ ] 社内ネットワーク管理者と FW 開放手順を合意済み

## 2. Azure 側（App Service）

- [ ] **`tagreader-api`**（`rg-tagreader-prod`）へ `TagReaderApi` をデプロイ済み
- [ ] **Azure Key Vault** に本番の接続文字列等を格納済み（コード・リポジトリに直書きしない）
- [ ] App Service から Key Vault を参照できる（マネージド ID 等）／当面の代替として App Service の `Configuration` に設定済み
  - [ ] キー名: `ConnectionStrings__DefaultConnection`（アプリ設定または Key Vault 参照）
  - [ ] 値例: `Server=<db-host>,1433;Database=<db-name>;User Id=<user>;Password=<password>;TrustServerCertificate=True;Encrypt=False;`
- [ ] `Always On` を有効化済み（Basic 以上）
- [ ] 必要に応じて `ASPNETCORE_ENVIRONMENT=Production` を設定済み
- [ ] **この App Service** の `Outbound IP Addresses` を最新値で控えた（他サブスク・他アプリの過去値を使い回さない）
- [ ] `Possible Outbound IP Addresses` も控え、将来変動分の許可要否を判断した

## 3. DB/ネットワーク側（自社 SQL Server）

- [ ] SQL Server の TCP/IP が有効
- [ ] SQL Server が待受ポート `1433/TCP`（または運用ポート）で受信可能
- [ ] サーバー OS ファイアウォールで該当ポートを許可
- [ ] 社内/境界 FW で **tagreader-api の** Azure 側送信元IPからの受信を許可
- [ ] 許可対象は必要最小限の IP のみに絞っている
- [ ] 旧環境の IP 許可を削除する前に、**現行 App Service** の IP で疎通確認を完了した

## 4. アプリ設定（TagReaderApi）

- [ ] `appsettings.Development.json` はローカル接続、Azure本番は環境変数優先に分離
- [ ] 接続文字列をコード直書きしていない
- [ ] 接続失敗時のログ（タイムアウト、認証失敗）が識別可能
- [ ] CORS 設定が公開先クライアントに一致

## 5. 疎通確認（公開後）

- [ ] `/api/environment` 等の軽量エンドポイントが 200 を返す
- [ ] DB参照を含むAPI（例: 商品一覧）が 200 を返す
- [ ] DB認証エラー/タイムアウトが発生しない
- [ ] クライアント（tag_reader_app）から実機でAPI呼び出し確認済み

## 6. セキュリティ最低限

- [ ] パスワード/秘密値をリポジトリに保存していない
- [ ] 不要な 0.0.0.0/0 許可を行っていない
- [ ] 将来運用として `Encrypt=True` + 正式証明書への移行方針がある
- [ ] ログ監視（App Service Logs / Application Insights）を有効化済み

## 7. 運用メモ（推奨）

- [ ] App Service の送信元IP変動に備え、定期的なFW許可IP見直し手順がある
- [ ] 必要に応じて VNet Integration + NAT Gateway で送信元IP固定化を検討
- [ ] 障害時の切り分け順（Azure -> Network -> SQL Server -> API）をチーム共有済み
