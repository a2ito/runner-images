# runner-images

a2ito の GitHub Actions self-hosted runner（Cloud Run ジョブと自宅PCの WSL）のコンテナイメージ。
ジョブ 1 つにつきコンテナ 1 つを起動し、`run.sh --jitconfig` でそのジョブを実行して終わる。
自宅PCで動かすための常駐スクリプトは [`wsl/`](wsl/README.md) にある。

runner を起動する dispatcher や webhook、ON / OFF の切り替えは
[a2ito/github-management](https://github.com/a2ito/github-management) の `runner/` にある。

| イメージ | ディレクトリ | 使うジョブ（`runs-on`） |
| --- | --- | --- |
| `runner` | `images/runner` | `gcp`（`gh-runner-runner`）、`gcp-large`（`gh-runner-runner-large`） |
| `runner-android` | `images/runner-android` | `gcp-android`（`gh-runner-runner-android`）、`wsl`（自宅PC） |

## 含まれるソフトウェア

版の正は Dockerfile。版を上げたら、この表も一緒に直す。

### runner

| ソフトウェア | 版 | 備考 |
| --- | --- | --- |
| ベース | `mcr.microsoft.com/dotnet/runtime-deps:10.0-noble` | Ubuntu 24.04。.NET が使うライブラリ（ICU、OpenSSL）と ca-certificates を含む |
| GitHub Actions runner | 2.337.0（`RUNNER_VERSION`） | `/home/runner`。ユーザーは `runner`（uid 1001） |
| Node.js | runner 同梱の node24 | `/usr/local/bin/node` にリンク。`externals/node20` は node24 へのリンク |
| GitHub CLI（`gh`） | 2.102.0（`GH_VERSION`） | `/usr/local/bin/gh` |
| AWS CLI v2 | 2.38.5（`AWS_CLI_VERSION`） | `/usr/local/aws-cli`。`/usr/local/bin/aws` にリンク |
| git、curl、jq、unzip | Ubuntu 24.04 の apt | |
| python3、make、g++ | Ubuntu 24.04 の apt | node-gyp がネイティブの npm パッケージ（better-sqlite3 など）をビルドするため |

### runner-android

runner イメージの中身に、次のものを足している。

| ソフトウェア | 版 | 備考 |
| --- | --- | --- |
| Android SDK command-line tools | build 16111833（`CMDLINE_TOOLS_BUILD`） | `ANDROID_HOME` / `ANDROID_SDK_ROOT` は `/opt/android-sdk` |
| Android SDK Platform-Tools | 入れた時点の最新 | |
| Android SDK Platform | android-36 | |
| Android SDK Build-Tools | 35.0.0、36.0.0 | |
| Android NDK | 28.2.13676358 | |
| Flutter | 3.44.8 stable（`FLUTTER_VERSION`） | `/home/runner/_work/_tool/flutter/stable-<版>-x64/flutter`（subosito/flutter-action が探す場所）。Android 向けのみ precache |
| clang、xz-utils | Ubuntu 24.04 の apt | |

JDK と Gradle は入れていない（actions/setup-java と Gradle wrapper がジョブごとに落とす）。

## 分担

| | このリポジトリ | github-management | cloud-management |
| --- | --- | --- | --- |
| 持つもの | runner のイメージ（ghcr.io）、自宅PCの常駐スクリプト（`wsl/`） | dispatcher のコードとイメージ、webhook | Cloud Run のサービスとジョブ、サービスアカウントと IAM（`modules/gcp/github_runner_dispatcher`） |
| イメージ | main への merge で push する。Cloud Run は `make deploy` で差し替え、自宅PCは `:main` を自動で取り込む | dispatcher を `make runner-build` / `make runner-deploy` で差し替える | 仮のイメージで作り、image は `ignore_changes` |

## ビルドとデプロイ

イメージは GitHub Actions（`.github/workflows/build.yml`）が作る。PR ではビルドだけして
Dockerfile を確かめ、main への merge で `ghcr.io/a2ito/runner-images/{runner,runner-android}:<コミットの SHA>`
と `:main` に push する。`runner-android` は同じジョブで作った `runner` を土台にする。Cloud Build は使わない。
push の前に、`runner-android` の中で runner・node・gh・aws などが起動できるかを確かめる（smoke test）。

自宅PC（`wsl/`）は、ジョブのたびに `runner-android:main` を pull するので、merge すれば次のジョブから
新しいイメージで動く。下の `make deploy` は Cloud Run だけの話。

Cloud Run は public な ghcr.io のイメージを直接引ける（Artifact Registry の remote repository は要らない）。
パッケージは **public にしておく**。private のままだと、ジョブの起動時にイメージを引けずに落ちる。

ジョブへの反映は手元から行う。gcloud を動かすアカウント（`GCLOUD_ACCOUNT`）は環境変数か `.env` で渡す。
このリポジトリは public なので、既定値を持たせていない。

```sh
cp .env.example .env   # GCLOUD_ACCOUNT を書く（または export する）
git switch main && git pull
make deploy            # 全ジョブ（JOBS / ANDROID_JOBS）を HEAD のイメージに差し替える
make deploy TAG=<sha>  # 別のコミットに差し替える（戻すときも同じ）
```

`TAG` は完全な SHA。build.yml が走り終わる前に `make deploy` すると、まだ無いイメージを指して落ちる。

## 気をつけること

- **runner は 1 回きり。** JIT 設定は 1 回しか使えないため、ジョブの再試行は 0 回にしてある。
  runner ジョブを手で起動しても `JIT_CONFIG` が空なので即座に失敗する（`entrypoint.sh`）。
- **runner イメージには `node`、`gh`、`aws` を足してある。** 公式の runner イメージには
  どれも入っていないが、GitHub-hosted には入っていて、`setup-terraform` のラッパーや
  `gh pr merge`、`aws` を直接呼ぶ workflow（cloud-scope の monthly-collect）が前提にしている。
- **runner イメージは公式イメージではなく、runner の tarball から作っている。** docker・buildx・
  k8s hooks・sudo など、使わない部品を持たないため（1.31GB → 473MB）。速さとメモリのためでは
  ない。起動時間はイメージの大きさに依らず（数 MB のイメージでも約 1.5 分）、イメージの大きさは
  使えるメモリに影響しない（Cloud Run が数えるのは書き込んだファイル）。
- **Node.js は node24 だけ。** node20 の action も `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` で
  node24 で動かす。`externals/node20` は node24 へのリンクにしてある。runner 自身の
  `hashFiles()` などはこの変数と関係なく `externals/node20` を名前で呼ぶため、消すと壊れる。
- **runner、gh、AWS CLI を上げるときは、Dockerfile の版と SHA-256 を一緒に直す。** ハッシュは
  リリースページにある（runner はリリースノート、gh は `gh_<版>_checksums.txt`）。AWS CLI は
  PGP 署名（`<zip>.sig`）しか公開されていないため、署名を確かめた zip の SHA-256 を自分で取る。
- **Android 用のイメージ（`images/runner-android`）は、runner イメージに Android SDK と Flutter を足したもの。**
  ジョブが落とすファイルはメモリに数えられるが、イメージの中身は数えられないため、焼き込めるものは
  焼き込む。flutter アプリが `FLUTTER_VERSION` を上げたら、Dockerfile の `FLUTTER_VERSION` と
  ハッシュも上げる（上げないと、flutter-action が毎回その版を落とすので遅くなり、メモリも食う）。
- **ツールを足すときは、焼き込むかジョブで落とすかを考える。** 焼き込んだものは起動時間にも
  メモリにも効かない。ジョブが落としたものは、毎回その分の時間とメモリを使う。
- **大きさを足したら Makefile にジョブ名を足す。** `JOBS`（runner イメージ）か
  `ANDROID_JOBS`（Android 用）のどちらか。どちらにも無いジョブは仮のイメージのまま残る。
  逆に、cloud-management でジョブを作る前に足すと、`make deploy` がそのジョブで落ちる。
- **runner のコンテナでは docker を使えない。** コンテナを使うジョブ（`container:` や
  `services:`）はこの runner では動かない。
