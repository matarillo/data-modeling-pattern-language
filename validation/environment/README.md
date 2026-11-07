# ローカルPostgreSQLクラスター

[Manage.ps1](Manage.ps1)は公開チェックアウト内の`.local/postgres`に専用クラスターを作成し、`127.0.0.1`の指定ポートで起動または停止します。PostgreSQL 18.6のbinディレクトリを`PG_BIN`環境変数または`-PgBin`で指定してください。`-Port`の既定値は`55467`です。利用する実行ポートは、[一括実行手順](../README.md)の`-DbPort`にも指定してください。

```powershell
$env:PG_BIN = 'C:\path\to\postgresql\18.6\bin'
./validation/environment/Manage.ps1 -Action Start -PgBin $env:PG_BIN -Port 55467
./validation/environment/Manage.ps1 -Action Status -PgBin $env:PG_BIN -Port 55467
./validation/environment/Manage.ps1 -Action Stop -PgBin $env:PG_BIN -Port 55467
```

`Start`は`research_validation`データベースを用意します。検証後は`Stop`でクラスターを停止してください。管理スクリプトは公開チェックアウト内の専用データを対象にします。
