# TagReaderApi を GitHub に保存する手順

## 現在の状態
- ✅ Git リポジトリの初期化済み
- ✅ 初回コミット済み（12ファイル）

## GitHub にプッシュする手順

### 1. GitHub で新しいリポジトリを作成
1. https://github.com/new にアクセス
2. **Repository name** に `TagReaderApi` を入力（任意の名前でOK）
3. **Public** を選択
4. **「Add a README file」はチェックしない**（既にローカルにコードがあるため）
5. **Create repository** をクリック

### 2. リモートを追加してプッシュ
GitHub でリポジトリ作成後、表示される URL を使います。
**あなたの GitHub ユーザー名** を `YOUR_USERNAME` に置き換えて実行してください。

```powershell
cd C:\dev\TagReaderApi
git remote add origin https://github.com/YOUR_USERNAME/TagReaderApi.git
git branch -M main
git push -u origin main
```

HTTPS の代わりに SSH を使う場合：
```powershell
git remote add origin git@github.com:YOUR_USERNAME/TagReaderApi.git
git branch -M main
git push -u origin main
```

### 3. 認証
- **HTTPS**: プッシュ時に GitHub のユーザー名とパスワード（または Personal Access Token）の入力が求められます
- **SSH**: あらかじめ SSH キーを GitHub に登録している必要があります

以上で TagReaderApi が GitHub に保存されます。
