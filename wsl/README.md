# wsl

自宅PC（WSL の Debian）で runner を docker で動かすためのスクリプトと systemd ユニット。
cloud-scope の「self-hosted runner」で「自宅PC」を選んだときに、`wsl` ラベルのジョブを拾う。

Cloud Run 版と同じく、ジョブ 1 つにつきコンテナ 1 つを使い捨てる。`run-once.sh` は次の 1 回分だけを
行って終わり、繰り返しは systemd（`Restart=always`）に任せる。スクリプトにループは無い。

1. `runner-android:main` を pull する（新しいイメージがあればここで入れ替わる）
2. GitHub App で org に JIT runner を登録する
3. `docker run --rm` でジョブを 1 つ実行する。終わるとコンテナも runner も消え、スクリプトも終わる
4. systemd が 10 秒後に起動し直す（1 に戻る）

| ファイル | 置き場所 |
| --- | --- |
| `run-once.sh` | `/usr/local/lib/wsl-runner/run-once.sh` |
| `wsl-runner@.service` | `/etc/systemd/system/wsl-runner@.service` |
| `config.example` | `/etc/wsl-runner/config` に書き換えて置く |

## 自動更新の仕組み

main への merge で build.yml が `ghcr.io/a2ito/runner-images/runner-android:main` を押し上げる。
`run-once.sh` は起動するたびに最初に pull するので、次に起動した回から新しいイメージで動く。
時間を決めた定期チェックはしない。自宅PCは外から届かないので、起動のついでにこちらから取りに行く
（webhook も GCP の権限も要らない）。

ジョブを待っている runner は、起動したときのイメージのまま。入れ替わるのは、その runner が
ジョブを 1 つ終えた次の回から。

## 使うイメージ

`runner` ではなく `runner-android`。「自宅PC」では `RUNNER` / `RUNNER_LARGE` / `RUNNER_ANDROID` が
3 つとも `wsl` になり、Flutter のジョブも来るため。`runner-android` は `runner` に Android SDK と
Flutter を足したもの。

## 導入

前提: WSL で systemd が有効（`/etc/wsl.conf` に `[boot]` `systemd=true`）、docker、curl、jq、openssl。

Windows 側の `%UserProfile%\.wslconfig` も先に書く。反映は PowerShell / cmd で `wsl --shutdown`。

```ini
[wsl2]
# 既定は PC の半分（16GB の PC で 7.6GiB）。Build Android が 2 本重なると足りない。
memory=12GB
swap=8GB
# ターミナルを全部閉じると、systemd のサービスが動いていても WSL ごと止まる（WSL 3.0.3 で
# 閉じてから約 1 分）。止まると実行中のジョブはエラーも出さずに切れ、runner も戻らない。
vmIdleTimeout=-1

[general]
instanceIdleTimeout=-1
```

効いているかは、ターミナルを全部閉じて数分後に `wsl -l -v` が `Running` のままかで見る。

1. 今の runner（`config.sh` で登録して `svc.sh` で常駐させたもの）を外す。

   ```sh
   cd <runner のディレクトリ>
   sudo ./svc.sh stop && sudo ./svc.sh uninstall
   ./config.sh remove --token <org の Settings → Actions → Runners で出る削除用トークン>
   ```

   2 台目（`winmini-wsl-debian-2`）も同じ。

2. GitHub App の秘密鍵を置く。dispatcher と同じ App（`github-runner-registration` シークレットの
   `app_id` / `private_key`）。

   ```sh
   sudo install -d -m 700 /etc/wsl-runner
   gcloud secrets versions access latest --secret=github-runner-registration \
     --project=a2ito-github-runner | jq -r .private_key | sudo tee /etc/wsl-runner/app.pem >/dev/null
   sudo chmod 600 /etc/wsl-runner/app.pem
   ```

3. 設定とスクリプトを置いて起動する。

   ```sh
   sudo install -m 600 wsl/config.example /etc/wsl-runner/config   # APP_ID を書く
   sudo install -D -m 755 wsl/run-once.sh /usr/local/lib/wsl-runner/run-once.sh
   sudo install -m 644 wsl/wsl-runner@.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now wsl-runner@1 wsl-runner@2
   ```

4. 確かめる。org の Runners に `winmini-wsl-<slot>-<日時>` が 2 つ並ぶ。

   ```sh
   journalctl -u 'wsl-runner@*' -f
   ```

`run-once.sh` や `wsl-runner@.service` を直したときは、手順 3 の `install` をやり直して
`sudo systemctl daemon-reload`。次の回から新しいものが使われる（ジョブ中の slot はそのまま続く）。
すぐに切り替えたいときは `sudo systemctl restart wsl-runner@1 wsl-runner@2` だが、ジョブの途中なら
そのジョブは落ちる。イメージの更新では何もしなくてよい。

## ジョブを落とさずに止める（drain）

WSL の再起動や PC の停止の前に使う。`/etc/wsl-runner/drain` があると、各 slot は今のジョブを
最後までやり、次のジョブを拾わずに止まる（`wsl-runner@.service` の `ConditionPathExists`）。

```sh
sudo touch /etc/wsl-runner/drain
systemctl is-active wsl-runner@1 wsl-runner@2   # 両方 inactive になれば止まった
```

ジョブを待っているだけの slot は、ジョブを拾うまで止まらない（待機中のコンテナはジョブが来ない
限り終わらないため）。全部が inactive になるのを待たずに止めたいときは、`Runner.Worker` が
動いていない（`ps aux | grep '[R]unner.Worker'` が空）ことを確かめてから `sudo systemctl stop` する。

再開するときは、ファイルを消して起動する。**ファイルを残したまま WSL を再起動すると、起動時にも
止まったままになる。**

```sh
sudo rm /etc/wsl-runner/drain
sudo systemctl start wsl-runner@1 wsl-runner@2
```

## 気をつけること

- **App の秘密鍵が自宅PCに置かれる。** dispatcher と同じ鍵なので、漏れたら App の鍵ごと作り直す
  （Secret Manager の `github-runner-registration` も差し替える）。
- **コンテナの中では docker を使えない。** Cloud Run 版と同じ。今までの runner にあった `docker`
  ラベルは付けない。
- **2 台の並列は slot の数で決まる。** 増やすなら `wsl-runner@3` を enable する。
- **WSL が使えるメモリは、既定では PC の半分。** 16GB の PC では 7.6GiB で、Build Android（Gradle に
  `-Xmx8G`）が 2 本重なると足りない。`.wslconfig` で増やす（「導入」）。slot を増やす前に `free -h` で見る。
- **ターミナルを全部閉じると WSL が止まる。** systemd のサービスは「使われている」と数えられない。
  `.wslconfig` の `vmIdleTimeout=-1` / `instanceIdleTimeout=-1` で防ぐ（「導入」）。Windows から
  サインアウトしたときと、PC がスリープしたときは、それでも止まる。
- **`wsl --shutdown` は実行中のジョブを落とす。** 先に drain する。落ちたジョブは GitHub から re-run する。
- **止めると、登録だけされた runner を消す。** ジョブの途中で止めたときは、そのジョブは失敗する。
- **runner の名前は毎回変わる**（`winmini-wsl-<slot>-<日時>`）。cloud-scope の使用状況は runner の
  グループで種類を分けているので、名前が変わっても数えられる。
