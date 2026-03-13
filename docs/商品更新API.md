# 商品更新 API（ICタグ読取・更新連携）

## エンドポイント

- **POST** `/api/product-updates`

商品データ（主にステータス）の変更を送信し、[ICタグ台帳] と [tag_table4] を更新する。

---

## リクエスト Body（JSON）

| プロパティ | 型 | 必須 | 説明 |
|------------|-----|------|------|
| epc | string | ○ | タグID（[ICタグ台帳].[tag_id2] と一致） |
| read_at | string | ○ | 読み取り日時。API ではログ用に利用 |
| changes | object | ○ | 変更内容。`status` にステータス文字列（例: "修理中", "ＯＫ"） |
| user_id | string | - | 担当者コード。整数に変換できれば [tag_table4].[s_code] に記録 |
| product_id | string | - | 任意 |
| device_id | string | - | 任意 |

---

## 処理内容

### 1. [ICタグ台帳] の更新

- **条件:** `LTRIM(RTRIM([tag_id2])) = @epc`
- **更新列:**
  - `[tag_mode2]` = リクエストの `changes.status`
  - `[updated]` = サーバー現在時刻（**秒単位**。`CONVERT(..., 120)` でコンマ秒なし）

該当行が 0 件の場合は 404 を返し、以降のログ挿入は行わない。

### 2. [tag_table4] へのログ挿入

更新成功後に 1 行 INSERT。

| 列 | 値 |
|----|-----|
| read_time | サーバー現在時刻（秒単位） |
| tag_id2 | epc |
| tag_mode | 送信した status |
| s_code | user_id を int に変換した値。不可なら NULL |
| 受付番号 | 0 |
| mark | 0 |
| complete | 1 |
| Remarks | NULL |

ID は IDENTITY で自動採番。

---

## レスポンス

- **200 OK**  
  `{ "updated": 1, "logRecorded": true }`

- **400 Bad Request**  
  epc が空、または changes.status が未指定。

- **404 Not Found**  
  指定した epc（tag_id2）に一致する行が [ICタグ台帳] に存在しない。  
  Body に `message`, `receivedEpc`, `receivedEpcLength` 等を含む場合あり。

---

## 関連テーブル

- **[ICタグ台帳]** … 更新対象。`tag_id2`, `tag_mode2`, `updated` 等。
- **[tag_table4]** … タグモード更新履歴。tag_id2 ごとのログとして利用。

実装: `TagReaderApi/Controllers/ProductUpdatesController.cs`
