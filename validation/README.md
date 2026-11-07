# 検証ガイド

この公開物に含まれるSQLとPowerShellスクリプトを使って、4つのケースをPostgreSQL上で実行できます。記録済みの結果は`results.json`と各ケースの`results.json`にあります。再実行すると、これらのファイルが新しい実行結果で置き換わります。記録を残す場合は、公開チェックアウトの使い捨てコピーを作って、そのコピーで実行してください。

## 必要な環境

- Windows上のPowerShell 7
- PostgreSQL 18.6のWindowsバイナリ（`initdb.exe`、`pg_ctl.exe`、`psql.exe`を含むbinディレクトリ）

## 専用のローカルクラスター

`PG_BIN`にPostgreSQL 18.6のbinディレクトリを設定します。クラスターは公開チェックアウト内の`.local/postgres`に作成し、ループバックアドレス`127.0.0.1`のポート`55467`で起動します。データベースは`research_validation`、ユーザーは`research`です。管理スクリプトは[Manage.ps1](environment/README.md)の説明に従って起動・停止します。

```powershell
$env:PG_BIN = 'C:\path\to\postgresql\18.6\bin'
./validation/environment/Manage.ps1 -Action Start -PgBin $env:PG_BIN -Port 55467
try {
  ./validation/run-all.ps1 -PgBin $env:PG_BIN -DbPort 55467
} finally {
  ./validation/environment/Manage.ps1 -Action Stop -PgBin $env:PG_BIN -Port 55467
}
```

実行スクリプトは専用データベース内の`v01_smoke`〜`v04_smoke`スキーマを初期化します。既定ポートが使用中の場合は、起動・実行の両方に同じ空きポートを指定してください。ケースは失敗を成功として再利用せず、実行結果に期待結果、実行結果、アサーションの成否を記録します。

## ケース

- [V01](cases/V01/README.md)：基本フロー、訂正、ロールバック、事実からの派生データと現在状態テーブルの再構築を確認します。
- [V02](cases/V02/README.md)：READ COMMITTEDでの過剰引当と、在庫行ロックを使う引当コマンドを比較します。
- [V03](cases/V03/README.md)：コマンド再送、内容不一致、外部入金重複、同一キーの同時実行を確認します。
- [V04](cases/V04/README.md)：出荷と取消が競合したとき、先に確定した処理だけが有効になることを確認します。

4ケースで合計108アサーションを記録しています。これは固定テストフィクスチャでの設計不変条件の実証であり、性能や本番運用全般の保証ではありません。
