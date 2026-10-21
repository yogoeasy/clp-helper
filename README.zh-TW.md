# CLP Helper — CloudPanel 的 WordPress 網站管理工具

> **語言切換 / Language**: **繁體中文** | [English](README.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![OS: Ubuntu 22.04 / 24.04 / 26.04](https://img.shields.io/badge/OS-Ubuntu%2022.04%20%7C%2024.04%20%7C%2026.04%20LTS-orange.svg)](https://ubuntu.com/)
[![Platform: CloudPanel v2](https://img.shields.io/badge/Platform-CloudPanel%20v2-blue.svg)](https://www.cloudpanel.io/)
[![Shell: Bash 5+](https://img.shields.io/badge/Shell-Bash%205%2B-green.svg)](https://www.gnu.org/software/bash/)

**CLP Helper** 是一套在 **CloudPanel v2** 伺服器上管理 **WordPress 網站**的命令列工具，著重在 WordPress 網站的日常維運：建立網站、SSL 憑證、備份與還原、複製與跨主機搬移、存取防護，以及 PHP-FPM 效能調校；也能一鍵部署全新的 VPS 並強化安全設定。

**CLP Helper (`clp`)** 補足 CloudPanel 網頁介面與 Linux 底層自動化之間的落差，讓習慣命令列的使用者可以用指令或腳本完成：Let's Encrypt 雙軌簽發（HTTP-01 與 Cloudflare DNS-01）、來源主機零寫入的跨主機搬移，以及透過 rclone 備份到多種雲端空間。

> **免責聲明：** CLP Helper 是獨立開發的社群專案，與 CloudPanel 及 MGT Commerce GmbH 沒有任何關聯，也未獲得其背書或贊助。文中提到「CloudPanel」僅用於說明相容性。`clp` 指令與 CloudPanel 官方的 `clpctl` 是不同的工具。

---

## 目錄 (Table of Contents)

- [一、核心特色 (Key Features)](#一核心特色-key-features)
- [二、系統需求與相容性 (System Requirements)](#二系統需求與相容性-system-requirements)
- [三、安裝與快速開始 (Quick Start)](#三安裝與快速開始-quick-start)
- [四、指令總覽與架構 (Command Architecture)](#四指令總覽與架構-command-architecture)
- [五、多語系與 i18n 設定說明 (Language & Internationalization)](#五多語系與-i18n-設定說明-language--internationalization)
- [六、各模組詳細手冊 (Modules Reference)](#六各模組詳細手冊-modules-reference)
  - [1. 網站管理模組 (`clp site`)](#1-網站管理模組-clp-site)
  - [2. 伺服器管理與安全加固 (`clp server`)](#2-伺服器管理與安全加固-clp-server)
  - [3. 網站與資料庫備份模組 (`clp backup`)](#3-網站與資料庫備份模組-clp-backup)
  - [4. 網站與資料庫還原模組 (`clp restore`)](#4-網站與資料庫還原模組-clp-restore)
  - [5. HTTP Basic 認證防護模組 (`clp httpauth`)](#5-http-basic-認證防護模組-clp-httpauth)
  - [6. PHP-FPM 行程池調校模組 (`clp php-pm`)](#6-php-fpm-行程池調校模組-clp-php-pm)
  - [7. 全域設定管理模組 (`clp config`)](#7-全域設定管理模組-clp-config)
- [七、常用維運排程建議做法 (Crontab Best Practices)](#七常用維運排程建議做法-crontab-best-practices)
- [八、架構與安全性防護設計 (Security Architecture)](#八架構與安全性防護設計-security-architecture)
- [九、專案結構 (Directory Structure)](#九專案結構-directory-structure)
- [十、授權條款 (License)](#十授權條款-license)

---

## 一、核心特色 (Key Features)

- ⚡ **WordPress 網站全生命週期管理**：一鍵建立網站、MySQL 資料庫與繁體中文版 WordPress，並自動設定快取外掛、重新載入 Nginx、申請 SSL 憑證。
- 🔒 **Let's Encrypt 雙軌憑證管理**：支援 CloudPanel 原生 HTTP-01 驗證與 Cloudflare DNS-01 API 自動驗證，自動安裝獨立的 Certbot 環境，並建立每週日自動續約的排程。
- 🔄 **同機網站完整複製 (Staging / Clone)**：快速複製網站至新網域，自動完成路徑校正 (Path Sanitization)、Wordfence 防護檔重設、Redis Cache Salt 隨機隔離、`wp search-replace` 與 `robots.txt` 修正。
- 🚀 **跨主機零寫入安全搬遷 (Zero-Write Remote Migration)**：
  - 對來源伺服器**只做讀取**，不會在來源端產生暫存檔或寫入任何資料。
  - 依序從三個地方確認網站資訊（CloudPanel 資料庫 ➔ Nginx 設定 ➔ 網站目錄）。
  - 搬遷前自動檢查來源站有效登入 Session 與 10 分鐘內文章心跳鎖定 (`_edit_lock`)，避免蓋掉其他人正在編輯的文章。
  - 資料庫以壓縮的 SSH 連線傳到本機，確認完整後再匯入；來源主機不會寫入任何檔案。
  - 支援單站指定網域搬遷與全伺服器批次多站無人值守遷移 (`-all`)。
- 🛡️ **伺服器維運與 17 模組一鍵安裝部署**：
  - **系統看板**：三大面向即時檢視系統概要、各項服務運作與資安指標。
  - **全新安裝**：動態匹配最新官方相容資料庫 (MySQL 8.4 LTS, MariaDB 11.4 LTS 等)，提供 17 個核心模組自由勾選。
  - **防自鎖安全加固**：SSH 雙重金鑰檢驗、停用密碼登入、UFW 防火牆規則、Fail2ban 暴力破解攔截、systemd 日誌上限 (500M) 與核心參數最佳化。
- 📦 **靈活備份與雲端同步**：四種備份型態（`db` 資料庫、`compact` 精簡打包、`archive` 歷年 uploads 封存、`full` 完整封裝），直接整合 `rclone` 支援 Google Drive、Backblaze B2、Cloudflare R2 與 AWS S3，可以依備份類型自動刪除過期的備份 (`-expire`)。
- 🔐 **HTTP Basic 認證與 IP 白名單**：保護 WordPress 後台 (`/wp-admin/` 與 `wp-login.php`)、全站或任意自訂子目錄，支援 IP/CIDR 白名單免密碼直通。
- ⚙️ **PHP-FPM 動態效能調校**：動態辨識各網站設定之實際 PHP 版本，自動調整行程池（Process Pool）參數；修改前會先備份，並做語法檢查。
- 💡 **智慧防呆與打字錯誤提示 (Smart Typo Suggestion)**：網域名稱打錯時，會自動找出最接近的現有網域提示你（Levenshtein 演算法）。

---

## 二、系統需求與相容性 (System Requirements)

| 項目 | 需求說明 |
| :--- | :--- |
| **作業系統** | Ubuntu 22.04 LTS / Ubuntu 24.04 LTS / Ubuntu 26.04 LTS（一般版與 Minimal 映像檔；已實機測試）<br>Debian 11 / Debian 12（預期可運作，但未經實機測試） |
| **管理面板** | CloudPanel v2 |
| **執行權限** | `root` 使用者權限 (`sudo`) |
| **系統環境** | Bash 5.0+, `curl`, `rsync`, `tar`, `gzip`（缺少的套件會由安裝程式自動安裝） |

所有實機測試都在 Ubuntu 22.04、24.04 與 26.04 上進行。CloudPanel 支援 Debian，CLP Helper 也不會阻擋，但尚未在 Debian 上實機測試；如遇問題歡迎回報。

---

## 三、安裝與快速開始 (Quick Start)

### 1. 下載與安裝

在 CloudPanel 伺服器上，以 root 權限執行以下任一種方式（三種結果相同，選一種即可）。

**方式一：一行安裝（建議）**

先把安裝腳本下載成檔案再執行，執行前也可以先打開檢查內容：

使用 curl：

```bash
curl -fsSL https://raw.githubusercontent.com/yogoeasy/clp-helper/main/get.sh -o clp-get.sh && sudo bash clp-get.sh
```

或使用 wget：

```bash
wget -qO clp-get.sh https://raw.githubusercontent.com/yogoeasy/clp-helper/main/get.sh && sudo bash clp-get.sh
```

`get.sh` 會從 GitHub 下載最新版本到暫存目錄、執行 `install.sh`，完成後自動刪除暫存檔案。

**方式二：下載壓縮檔**

使用 curl：

```bash
curl -fsSL https://github.com/yogoeasy/clp-helper/archive/refs/heads/main.tar.gz | tar xz && sudo bash clp-helper-main/install.sh
```

或使用 wget：

```bash
wget -qO- https://github.com/yogoeasy/clp-helper/archive/refs/heads/main.tar.gz | tar xz && sudo bash clp-helper-main/install.sh
```

安裝完成後，可以刪除解壓縮出來的 `clp-helper-main` 目錄。

**方式三：git clone**

```bash
git clone https://github.com/yogoeasy/clp-helper.git && sudo bash clp-helper/install.sh
```

安裝完成後，可以刪除 `clp-helper` 目錄。

**指定介面語言**：在任一種方式的最後加上 `--lang=zh_TW`（或 `--lang=en_US`），例如 `sudo bash clp-get.sh --lang=zh_TW`。

安裝程式會自動完成：
- 將程式安裝到 `/usr/local/lib/clp-helper/`（舊版安裝在 `/home/clp/clp/` 的會自動搬移過去）。
- 建立指令連結 `/usr/local/bin/clp`，之後在任何目錄都可以直接執行 `clp`。
- 設定檔案的擁有者與權限，並建立 `/var/log/clp` 日誌目錄。

**更新到最新版**：重新執行上面任一種安裝方式即可。設定檔（`/etc/clp/`）、備份（`/root/clpBackup/`）與網站資料都不會受到影響。

### 2. 驗證安裝

在終端機任意目錄輸入：

檢視版本資訊 (顯示版本號碼與建置時間戳記)：

```bash
clp -v
```

輸出範例：`CLP Helper v1.0.2 (建置時間 2026-10-21 11:46:33)`

查看全域功能說明選單：

```bash
clp --help
```

### 3. 解除安裝

若日後需要從主機完整移除 CLP Helper (`clp`)：

```bash
sudo bash /usr/local/lib/clp-helper/install.sh --uninstall
```

### 4. 設定中文語系

主機的系統語系不是中文時，預設以英文顯示。若要改成臺灣正體中文介面：

```bash
sudo clp config -set lang=zh_TW
```

設定會寫入設定檔，之後執行 `clp` 都會以中文顯示。其他語系設定方式請見[五、多語系與 i18n 設定說明](#五多語系與-i18n-設定說明-language--internationalization)。

---

## 四、指令總覽與架構 (Command Architecture)

CLP Helper 的指令架構設計遵循統一、直覺的語法規範：

```bash
sudo clp <module> [target_domain] [options...]
```

> [!NOTE]
> 需要帶值的選項一律使用 `-option=value` 語法（例如 `-type=full`、`-to=google`、`-cf-waf=off`）。以空白分隔的選項值或無法識別的多餘位置參數將會直接報錯並提供正確語法提示，以避免誤套用非預期的設定。

### 核心模組速覽

| 模組 | 主要功能 | 常用操作指令 |
| :--- | :--- | :--- |
| **`site`** | WordPress 網站管理 | `-new`, `-list`, `-on`, `-off`, `-ssl`, `-cf-waf`, `-cf-only`, `-varnish`, `-clone-from`, `-migrate`, `delete` |
| **`server`** | 主機維運與安全加固 | `(無參數狀態檢查)`, `install`, `-harden`, `-ufw`, `-ssh`, `-fail2ban`, `-clean` |
| **`backup`** | 網站與資料庫備份 | `-type={db\|full\|compact\|archive}`, `-to={local\|<remote>}`, `-expire=<Nd>` |
| **`restore`** | 備份還原作業 | `[-file=<name>]`, `-type={db\|full\|compact\|archive}`, `-to={local\|<remote>}` |
| **`httpauth`** | HTTP 認證與存取防護 | `-add`, `-delete`, `-list`, `-wp-admin`, `-path`, `-whitelist` |
| **`php-pm`** | PHP-FPM 行程池調校 | `<domain>`, `-all`, `-status`, `-fix`, `-max-children=`, `-idle-timeout=`, `-max-requests=` |
| **`config`** | 全域偏好設定與金鑰管理 | `-set <key>=<val>`, `-get <key>`, `-list`, `-unset <key>` |

### 全域共用選項 (Global Options)

| 參數 | 說明 | 範例 |
| :--- | :--- | :--- |
| `--lang=<lang>` | 指定介面語言 (`en_US`, `zh_TW`) | `sudo clp --lang=zh_TW --help` |
| `-h`, `--help` | 顯示全域說明或指定模組說明 | `sudo clp --help` |
| `-v`, `-V`, `--version` | 顯示目前版本資訊與建置時間戳記 | `clp -v` |

---

## 五、多語系與 i18n 設定說明 (Language & Internationalization)

CLP Helper 內建多語系（i18n）功能，語系代碼遵循 **WordPress 與 GNU gettext 標準**（`ISO-639` 語言代碼 + `ISO-3166` 國家代碼），目前支援 **台灣繁體中文 (`zh_TW`)** 與 **英文 (`en_US`)**。

### 語系判定優先順序 (Detection Cascade)

系統依照以下順序動態判定並載入介面語言：
1. **命令列參數** (`--lang=...` 或 `-lang=...`)：優先順序最高，直接影響當次指令執行（支援 `--lang=en_US` 或 `--lang=zh_TW`；傳統 `--lang=en` 自動相容對應至 `en_US`）。
2. **環境變數** (`CLP_LANG`)：可在目前終端機工作階段或全域環境設定中覆寫。
3. **全域設定檔** (`/etc/clp/clp.conf` 透過 `clp config` 管理)：跨工作階段與使用者的系統全域永久設定。
4. **系統環境語系** (`LC_ALL`、`LC_MESSAGES`、`LANG`)：
   - 自動辨識 `zh_TW`、`zh_HK`、`zh_MO`、`zh_Hant` 等語系並載入台灣繁體中文 (`zh_TW`)。
   - 其餘國際化語系（如 `en_US`、`en_GB`、`C`、`POSIX` 等）一律預設為英文 (`en_US`)。
5. **預設機制**：都未設定時，預設使用英文（`en_US`）。

### 操作語法與範例 (Usage Examples)

#### 1. 執行期命令列切換 (Runtime Override)
在任何 `clp` 指令中加入 `--lang=zh_TW` 或 `--lang=en_US`：

以繁體中文顯示說明選單：

```bash
sudo clp --lang=zh_TW --help
```

以英文顯示說明選單：

```bash
sudo clp --lang=en_US --help
```

以繁體中文檢視版本資訊：

```bash
clp --lang=zh_TW -v
```

以英文檢視版本資訊：

```bash
clp --lang=en_US -v
```

搭配各模組指令使用：

```bash
sudo clp --lang=zh_TW site -list
```

```bash
sudo clp --lang=en_US site example.com -new
```

```bash
sudo clp --lang=zh_TW server
```

#### 2. 環境變數設定 (Persistent Override)
在終端機中匯出 `CLP_LANG`，或加入 `~/.bashrc` / `/etc/environment`：

將目前工作階段切換為繁體中文：

```bash
export CLP_LANG="zh_TW"
```

```bash
clp -v
```

```bash
sudo clp --help
```

將目前工作階段切換為英文：

```bash
export CLP_LANG="en_US"
```

```bash
clp -v
```

```bash
sudo clp --help
```

#### 3. 透過 `clp config` 永久設定預設語系 (Persistent Configuration)
可以用 `clp config` 設定預設語系，之後就不必每次登入都設定環境變數：

將系統全域預設語系永久設定為繁體中文：

```bash
sudo clp config -set lang=zh_TW
```

將系統全域預設語系永久設定為英文 (WordPress 標準)：

```bash
sudo clp config -set lang=en_US
```

查詢目前已設定之預設語系：

```bash
clp config -get lang
```

清除語系設定（恢復為依系統環境自動判斷）：

```bash
sudo clp config -unset lang
```

#### 4. 安裝程式語系指定 (`install.sh`)
安裝程式也支援切換語系，並會自動偵測系統語系：

以繁體中文執行安裝程式：

```bash
sudo bash install.sh --lang=zh_TW
```

以英文執行安裝程式 (國際化伺服器環境預設)：

```bash
sudo bash install.sh --lang=en_US
```

檢視安裝程式說明選單：

```bash
bash install.sh --help
```

```bash
bash install.sh --lang=zh_TW --help
```

以指定語系執行解除安裝：

```bash
sudo bash /usr/local/lib/clp-helper/install.sh --uninstall --lang=zh_TW
```

---

## 六、各模組詳細手冊 (Modules Reference)

### 1. 網站管理模組 (`clp site`)

#### ① 網站清單檢視 (`clp site -list`)

以表格列出所有網站：

```bash
sudo clp site -list
```

**依狀態或 SSL 憑證篩選**

僅列出已啟用網站：

```bash
sudo clp site -list=enabled
```

僅列出暫停中網站：

```bash
sudo clp site -list=disabled
```

僅列出具備 SSL 憑證網站：

```bash
sudo clp site -list=ssl
```

腳本專用的純文字模式（-raw），每行輸出一個網域名稱，方便在迴圈中使用：

```bash
sudo clp site -list=enabled -raw
```

#### ② 建立全新 WordPress 網站 (`clp site <domain> -new`)

互動式建立 (依序提示 Site User、PHP 版本、SSL 模式與管理員帳密)：

```bash
sudo clp site example.com -new
```

一鍵指定參數建立 (採用 CloudPanel 原生 HTTP-01 驗證)：

```bash
sudo clp site example.com -new -http -php=8.4 -user=myuser
```

一鍵指定參數建立 (採用 Cloudflare DNS-01 API 驗證)：

```bash
sudo clp site example.com -new -dns -php=8.4
```

略過 SSL 申請建立：

```bash
sudo clp site example.com -new -ssl=off
```

覆寫已存在的同名網站：

```bash
sudo clp site example.com -new -force-replace
```

> [!TIP]
> 執行 `-new` 建立網站時，詢問 WordPress 管理員帳號密碼若直接按 `Enter` 留空，系統將自動套用預設值（帳號預設 `wpadmin`，密碼自動產生高強度隨機密碼並存至 `/root/.clp/<網域>-wp-admin.txt`，Email 預設 `wpadmin@wp.com`）。

#### ③ SSL 憑證管理 (`clp site <domain> -ssl`)

透過 Cloudflare DNS-01 申請 SSL（自動完成驗證並設定續約排程）：

```bash
sudo clp site example.com -ssl=on -dns
```

```bash
sudo clp site example.com -dns
```

指定特定 Cloudflare API 金鑰設定檔：

```bash
sudo clp site example.com -ssl=on -dns -api=my-cloudflare.ini
```

申請 CloudPanel 原生 HTTP-01 SSL (網域已指向本機 IP)：

```bash
sudo clp site example.com -ssl=on -http
```

關閉並移除 SSL 憑證：

```bash
sudo clp site example.com -ssl=off
```

#### ④ 同機網站複製 (`clp site -clone-from`)

基本複製 (目標站不存在將全自動建立)：

```bash
sudo clp site -clone-from=example.com new-example.com
```

覆寫已存在的目標站：

```bash
sudo clp site -clone-from=example.com new-example.com -force-replace
```

自訂目標站使用者或 PHP 版本：

```bash
sudo clp site -clone-from=example.com new-example.com -user=newuser -php=8.4
```

- **自動處理項目**：
  - 複製時優先申請 SSL，驗證失敗就提早停止 (Fail-Fast)，避免白白傳輸資料。
  - 自動偵測 Wordfence WAF 路徑並替換，若檔案遺失會自動處理，避免網站出現 500 錯誤。
  - 自動為 Redis 注入全站隨機 Salt（`WP_CACHE_KEY_SALT`），避免網站之間的快取互相干擾。
  - WP-CLI 深度置換網址，並自動校正 `robots.txt` 內之 Sitemap 網址。

#### ⑤ 跨主機網站安全搬移 (`clp site -migrate`)

同網域跨主機搬遷 (網域保持不變，略過 search-replace)：

```bash
sudo clp site -migrate=remote-vps -from=example.com
```

不同網域跨主機搬遷 (自動執行資料庫網址置換)：

```bash
sudo clp site -migrate=remote-vps -from=example.com new-site.com
```

批次搬移遠端主機所有網站至本地 (網域不變)：

```bash
sudo clp site -migrate=remote-vps -all
```

批次搬移並排除特定測試子網域：

```bash
sudo clp site -migrate=remote-vps -all -exclude="test.,dev.,staging." -force-replace
```

- **搬移防護**：
  - **遠端唯讀存取**：資料庫以壓縮的 SSH 連線傳到本機，確認完整後再匯入；來源主機不會寫入任何檔案。
  - **心跳鎖定預警**：自動檢查來源網站在 10 分鐘內是否有人正在編輯文章（`_edit_lock`），避免蓋掉正在撰寫的文章。
  - **SSH 金鑰解鎖整合**：金鑰有設定密碼時，會自動載入 `ssh-agent`，只需要輸入一次。

#### ⑥ 啟用、停用與刪除網站

暫停網站服務 (檔案與資料庫完整保留)：

```bash
sudo clp site example.com -off
```

重新啟動網站：

```bash
sudo clp site example.com -on
```

互動確認刪除網站與對應資料庫：

```bash
sudo clp site delete example.com
```

強制刪除網站 (略過確認提示)：

```bash
sudo clp site delete example.com --force
```

#### ⑦ Cloudflare 邊緣 WAF 防護與安全最佳化 (`clp site <domain> -cf-waf`)

> ⚠️ **作用範圍為整個 zone：** [CLP] WAF 規則與 SSL／HTTPS／TLS 設定會套用到整個 Cloudflare zone（其中所有主機名稱）。對任一網域執行 `-cf-waf`（或 `-cf-waf=off`）都會取代整個 zone 的 [CLP] 規則，您自建的非 [CLP] 規則會保留。若已設定 `clp config -set cf-default-mode / cf-always-https / cf-min-tls`，zone 設定會依設定值套用。

一鍵為網域設定 Cloudflare 的 Full (Strict) SSL、Always Use HTTPS、最低 TLS 1.2，並部署 4 條 WAF 規則（保護 WP 後台登入、阻斷 XML-RPC、封鎖敏感原始檔/備份檔、攔截惡意掃描器與空 UA）：

一鍵為指定網域設定邊緣安全性並部署 WAF 規則：

```bash
sudo clp site example.com -cf-waf
```

模擬執行 (驗證 Token、解析 Zone ID 並輸出即將套用之規則 JSON，不實際變更)：

```bash
sudo clp site example.com -cf-waf --dry-run
```

指定後台登入放行白名單 IP：

```bash
sudo clp site example.com -cf-waf --whitelist="1.2.3.4,5.6.7.8"
```

查詢網域目前邊緣安全防禦與 WAF 規則狀態：

```bash
sudo clp site example.com -cf-waf=status
```

安全清理與停用 (僅刪除 [CLP] 規則，完整保留使用者自訂規則)：

```bash
sudo clp site example.com -cf-waf=off
```

- **安全設計**：
  - **Token 四級解析**：自動支援 CLI `--token`、既有 Certbot `/root/.secrets/*.ini` 憑證檔、全域 `/etc/clp/clp.conf` 或環境變數。
  - **自訂規則隔離保護**：僅變更標註 `[CLP]` 前綴之規則，使用者原有業務規則絕不覆蓋。
  - **配額上限檢查**：部署前依 zone 方案檢查自訂規則數量上限（Free 5／Pro 20／Business 100／Enterprise 1000），超過時停止並列出現有規則，避免 API 400 錯誤。

#### ⑧ 只允許來自 Cloudflare 的流量 (`clp site <domain> -cf-only`)

對應 CloudPanel 後台每個網站的「Allow traffic from Cloudflare only」。開啟後，直接連主機 IP 的請求在 Nginx 就回應 403，不會進入 PHP，可以擋下繞過 Cloudflare 直接掃描主機的流量。CloudPanel 後台只能一個一個網站開關，這個指令可以對單一網站或所有網站批次開關。

開啟：

```bash
sudo clp site example.com -cf-only
```

關閉：

```bash
sudo clp site example.com -cf-only=off
```

查看單一網站或所有網站的狀態（資料庫、vhost、DNS 是否經過 Cloudflare）：

```bash
sudo clp site example.com -cf-only=status
```

```bash
sudo clp site -cf-only=status
```

先預覽、再批次開啟所有網站（`-exclude` 用法與 `backup all` 相同）：

```bash
sudo clp site -cf-only -all -dry-run
```

```bash
sudo clp site -cf-only -all -exclude="test.,dev."
```

批次關閉所有網站：

```bash
sudo clp site -cf-only=off -all
```

- **DNS 檢查**：開啟前會解析網域與 www／非 www 的 A／AAAA 記錄，必須全部是 Cloudflare 的位址（橘雲）。灰雲或指向其他主機的網域開啟後會連不上，所以會擋下並列出原因；確定要開啟可加 `-force`。批次開啟時會自動略過 DNS 不符的網站。
- **同時修改 vhost 與 CloudPanel 資料庫**：只修改主要 server 區塊的兩處（`access_log` 改用 `cloudflare` 格式、加上 `include /etc/nginx/cloudflare/ips;`），格式與 CloudPanel 後台產生的相同；同時更新資料庫欄位，之後在後台重新產生 vhost 也會保留這個設定，後台的開關也會顯示正確。
- **安全措施**：修改前備份 vhost、資料庫欄位的原值與資料庫（`/root/.clp/cf-only-backup/`，資料庫備份保留最近 3 份）；`nginx -t` 失敗會還原 vhost，資料庫寫入失敗也會還原；已是目標狀態時不變更。停用中的網站不處理。
- **批次確認**：批次變更前會列出要處理與略過的網站，需輸入 `yes` 確認；使用 `-y` 時直接執行，非互動模式沒有 `-y` 會報錯。
- **封住 `X-Real-IP` 繞過**：CloudPanel 預設的 `/etc/nginx/nginx.conf` 有 `set_real_ip_from 0.0.0.0/0;`，任何人直連主機並帶上 `X-Real-IP: <Cloudflare IP>` 標頭都能繞過這個設定。開啟時，clp 會先詢問，再把這一行註解掉（保留原行，並加上 `# disabled by CLP Helper (cf-only)`；`-y` 時直接處理）。這會影響伺服器上所有網站；`127.0.0.1` 與私有網段仍受信任，所以 Varnish 不受影響。檔案會備份到同一個備份資料夾，`nginx -t` 失敗時自動還原。關閉最後一個網站時，clp 會詢問是否恢復這一行（預設不恢復；`-y` 時維持註解）。
- **有 `real_ip_header` 時拒絕開啟**：如果 `nginx.conf` 有未註解、且不是 `X-Real-IP` 的 `real_ip_header`（例如為了顯示訪客真實 IP 而設的 `X-Forwarded-For`），nginx 會在檢查 Cloudflare 允許清單之前換掉來源位址，所有訪客都會被擋，所以 clp 不會開啟。
- **防火牆檢查**：這個設定不涵蓋 8080（nginx 後端）與 6081（Varnish）埠。UFW 未啟用或開放了這兩個埠時，clp 會顯示警告。

#### ⑨ Varnish 快取沒有作用？(`clp site <domain> -varnish=status|fix`)

CloudPanel 後台顯示 Varnish 已開啟，但網站可能完全沒有被快取，每個請求都還是執行 PHP，流量一大就會把記憶體吃光。可以用下面的指令檢查與修正。

檢查單一網站或所有網站：

```bash
sudo clp site example.com -varnish=status
```

```bash
sudo clp site -varnish=status
```

修正單一網站（先預覽）：

```bash
sudo clp site example.com -varnish=fix -dry-run
```

```bash
sudo clp site example.com -varnish=fix
```

批次修正所有需要修的網站（`-exclude` 用法與 `backup all` 相同）：

```bash
sudo clp site -varnish=fix -all -dry-run
```

```bash
sudo clp site -varnish=fix -all -exclude="test.,dev."
```

**為什麼會沒有快取**

1. **Varnish 只快取 PHP 送出 `Cache-Control` 的頁面**：這些標頭由 `/home/<user>/.varnish-cache/controller.php` 送出，它必須透過 PHP 的 `auto_prepend_file` 載入。瀏覽器看到的 `Cache-Control: no-store` 是 Varnish 固定加上的，與是否快取無關，判斷時不要看它。
2. **開關要在 CloudPanel 後台切換**（或在 Vhost 分頁按 Save）：後台的 Varnish 開關對應 `/home/<user>/.varnish-cache/settings.json` 的 `enabled`，切換時 CloudPanel 也會重新產生 vhost，在 `PHP_VALUE` 加上 `auto_prepend_file`。WordPress 後台「CLP Varnish Cache」外掛的開關只改 `settings.json`，不會更新 vhost。（CloudPanel 資料庫的 `site.varnish_cache` 是建立 WordPress 網站時的預設值，通常都是 1，不代表後台開關是開的。）
3. **Wordfence 防火牆最佳化時要選「Include」，不要選「Override」，而且要先開 Varnish、再做 Wordfence 最佳化**：Wordfence 會建立 `.user.ini` 改用自己的 `wordfence-waf.php`，它的優先順序比 vhost 高，所以 `wordfence-waf.php` 必須 include `controller.php`。順序相反或選了 Override 時，用 `clp site <domain> -varnish=fix` 補上。
4. **`.user.ini` 修改後最多 5 分鐘才生效**（PHP 的 `user_ini.cache_ttl`）。`-varnish=fix` 不會修改 `.user.ini`，修改的 vhost 與 `wordfence-waf.php` 都會立即生效。
5. **Wordfence 提醒 `.user.ini` 可能被公開讀取**：`clp server -harden` 的 Nginx 安全規則已經擋下 `.user.ini`（規則在 `/etc/nginx/clp-security.conf`，由 `/etc/nginx/global_settings` 載入）。

**`-varnish=fix` 做什麼**

- vhost：在 8080 區塊的 `PHP_VALUE` 中，於 `upload_max_filesize=…;` 之後加上 `auto_prepend_file=/home/<user>/.varnish-cache/controller.php;`，位置與內容和 CloudPanel 產生的相同；`nginx -t` 失敗會還原。
- `wordfence-waf.php`：`.user.ini` 指向它、而它沒有 include `controller.php` 時，加上與 Wordfence「Include」相同格式的區塊；會先以 `php -l` 檢查，並保留檔案的擁有者與權限。
- 修改前會備份到 `/root/.clp/varnish-backup/<時間>/<網域>/`；修改後重新檢查是否已有快取。
- **不處理**：Varnish 未開啟（後台開關關閉，也就是 `settings.json` 的 `enabled` 為 false）、資料庫的 `varnish_cache` 為 0（CloudPanel 重新產生 vhost 時不會加上那一行，修了也會被蓋掉；檢查結果中另外標示）、`.user.ini` 指向其他檔案、vhost 已有其他 `auto_prepend_file`、原因不明的網站；這些只會在檢查結果中列出。

**自己檢查**：

```bash
curl -s -D- -o /dev/null -H "Host: example.com" -H "X-Forwarded-Proto: https" http://127.0.0.1:8080/ | grep -i x-cache-lifetime
```

有 `X-Cache-Lifetime` 就表示 Varnish 會快取這個頁面。

**修正後要確認的事**

修正後，Varnish 會把頁面存起來，在 `cacheLifetime`（預設 7 天，`604800` 秒）內直接用同一份內容回應所有訪客，不再每次執行 PHP。這些網站過去從未被快取，建議先挑幾個網站或一台主機試，確認以下功能正常後再全部修正。

- **已經自動排除、不會被快取的**：
  - 已登入的使用者（有 `wordpress_logged_in_` cookie 的請求一律不經過快取，`controller.php` 也會檢查 `is_user_logged_in()`）。
  - POST 請求（表單送出的那一次）。
  - `settings.json` 的 `excludes`，預設為 `/my-account/`、`/cart/`、`/checkout/`、`wp-login.php`。
- **可能出問題、需要實際操作確認的**：
  1. **表單送出失敗**：有些表單外掛會在頁面中放有時效的驗證碼（例如 WordPress nonce，通常 12～24 小時失效）。頁面被快取 7 天後，訪客拿到的是過期的驗證碼，送出時會出現「連結已過期」或「驗證失敗」。請用未登入的身分實際送出一次，最好隔天再試一次。
  2. **購物車與會員資訊**：未登入訪客加入購物車後，購物車的 cookie（例如 WooCommerce 的 `woocommerce_items_in_cart`）不會讓請求略過快取，其他頁面上「購物車 N 件」這類小工具可能顯示舊的狀態。購物車與結帳頁本身已排除。
  3. **Cookie 被移除**：會被快取的回應，Varnish 會刪除 `Set-Cookie`；依賴 cookie 的功能（語言切換、首次造訪彈窗等）可能失效。
  4. **隨時間變動的內容**：庫存、「已售完」、倒數計時、隨機推薦、依地區顯示的內容，可能停在被快取的那一刻。
  5. **修改內容後**：在 WordPress 後台更新文章或頁面時，CLP Varnish Cache 外掛通常會清除相關快取；用其他方式修改的內容（外掛設定、直接改資料庫）需要手動清除快取。
- **怎麼確認**：用無痕視窗（未登入）實際操作：送出表單、加入購物車後瀏覽其他頁面、註冊／登入／登出、切換語言。
- **有問題時**：
  - 在 CloudPanel 該網站的 Varnish Cache 分頁，把有問題的網址加入排除清單（寫入 `settings.json` 的 `excludes`），例如 `/contact/`。
  - 在同一分頁縮短快取時間（例如 1 天），降低表單驗證碼過期的機會。
  - 在 WordPress 後台的 CLP Varnish Cache 外掛或 CloudPanel 後台清除快取。

---

### 2. 伺服器管理與安全加固 (`clp server`)

#### ① 系統資訊與安全狀態總覽

直接執行 `sudo clp server` 會顯示系統資訊總覽：

```bash
sudo clp server
```

看板涵蓋三大面向：
1. **系統概要**：OS 版本、Kernel、開機時間、對外 IP、CPU 負載、記憶體與 Swap 用量、磁碟空間。
2. **服務狀態**：CloudPanel 版本、精確資料庫類型 (如 MySQL 8.4 / MariaDB 11.4)、Nginx、動態掃描之各版 PHP-FPM、Redis、UFW 防火牆、Fail2ban 封鎖狀態。
3. **資安指標**：SSH 密碼認證生效狀態、防火牆規則、日誌空間上限、自動安全更新狀態。

#### ② 全新伺服器一鍵部署與加固 (`sudo clp server install`)

適用於剛開通的 Ubuntu／Debian VPS（Debian 未經測試）：

互動式引導安裝 (自選資料庫引擎與 17 個核心模組)：

```bash
sudo clp server install
```

一鍵快速安裝建議設定 (預設 MySQL 8.4 LTS)：

```bash
sudo clp server install -y
```

指定 MariaDB 11.4 LTS 安裝：

```bash
sudo clp server install -y --db=MARIADB_11.4
```

模擬測試模式 (不對系統做任何異動)：

```bash
sudo clp server install --dry-run
```

**16 個核心部署模組一覽**：
1. `cloudpanel`：官方最新版 CloudPanel (動態 SHA256 驗證)
2. `system_basics`：維運必備套件 (`ncdu`, `jq`, `rsync`, 時區與語系)
3. `ufw`：防火牆預設拒絕，放行 22, 80, 443, 8443，阻擋 ICMP Ping
4. `ssh_hardening`：SSH 嚴格金鑰防反鎖檢測，停用密碼登入
5. `fail2ban`：安裝並設定暴力破解自動封鎖規則
6. `dns`：調整系統 DNS 解析器 (Google 8.8.8.8 與 Cloudflare 1.1.1.1)
7. `sysctl`：Linux 核心最佳化 (`swappiness=10`, `file-max=500000`)
8. `journald`：限制 Systemd 日誌上限為 500M，避免日誌占滿硬碟空間
9. `unattended_upgrades`：啟用系統安全漏洞自動修補
10. `snap_retention`：限制 Snap 歷史版本保留數為 2 份以節省空間
11. `php_timezone`：同步變更全系統與所有 PHP 版本之時區
12. `nginx_security`：全域阻擋 `.user.ini` 與 `debug.log` 洩漏
13. `smtp`：安裝 Postfix 並設定外部 SMTP Relay
14. `certbot`：部署 `/opt/certbot` 獨立虛擬環境與 Cloudflare DNS 套件
15. `netdata`：安裝 Netdata 即時效能監控 Agent (Port 19999)
16. `rclone`：安裝官方 Rclone 多遠端雲端備份引擎

#### ③ 互動式資安加固流程 (`sudo clp server -harden`)

針對已經在使用中的 CloudPanel 主機，逐項強化安全設定：

逐項互動確認加固：

```bash
sudo clp server -harden
```

一鍵套用加固：

```bash
sudo clp server -harden -y
```

#### ④ 輔助工具隨選安裝 (`sudo clp server -install=...`)

安裝 Netdata 效能監控：

```bash
sudo clp server -install=netdata
```

安裝 Rclone 雲端備份工具：

```bash
sudo clp server -install=rclone
```

安裝 Certbot 與 Cloudflare DNS 外掛：

```bash
sudo clp server -install=certbot
```

安裝 Postfix Relay 郵件服務：

```bash
sudo clp server -install=smtp
```

一鍵全數安裝：

```bash
sudo clp server -install=all -y
```

#### ⑤ 獨立日常維運指令

**防火牆維運**

檢視防火牆規則清單：

```bash
sudo clp server -ufw
```

放行特定連接埠：

```bash
sudo clp server -ufw -allow=8080
```

阻擋外網 Ping：

```bash
sudo clp server -ufw -icmp=drop
```

**SSH 維運與緊急復原**

查看 SSH 設定與金鑰數量：

```bash
sudo clp server -ssh
```

停用密碼登入：

```bash
sudo clp server -ssh -harden
```

緊急復原，暫時恢復密碼登入：

```bash
sudo clp server -ssh -unharden
```

**Fail2ban 入侵防護**

查看被封鎖的 IP 清單：

```bash
sudo clp server -fail2ban
```

解鎖指定 IP：

```bash
sudo clp server -fail2ban -unban=203.0.113.10
```

一鍵解鎖所有 IP：

```bash
sudo clp server -fail2ban -unban=all
```

新增白名單：

```bash
sudo clp server -fail2ban -whitelist=1.2.3.4
```

**系統 DNS 與時區同步**

自動設定 Google/Cloudflare DNS：

```bash
sudo clp server -dns=auto
```

一鍵同步系統與全機所有 PHP 版本時區：

```bash
sudo clp server -timezone=Asia/Taipei
```

**郵件測試與磁碟空間瘦身**

發送測試信驗證 SMTP：

```bash
sudo clp server -smtp -test=admin@example.com
```

清理日誌、APT 暫存套件與暫存檔，並顯示釋放了多少空間：

```bash
sudo clp server -clean
```

---

### 3. 網站與資料庫備份模組 (`clp backup`)

#### ① 參數規格

```bash
sudo clp backup <domain|all> [options...]
```

| 參數 | 預設值 | 說明 |
| :--- | :--- | :--- |
| `-type={db\|full\|compact\|archive}` | `full` | • `db`: 僅備份資料庫 (`.sql.gz`)<br>• `full`: 完整打包資料庫與全站實體檔案 (`.tar.gz`；資料庫傾印為封裝最上層的 `backup.sql`，與 `<domain>/` 目錄並排)<br>• `compact`: 精簡備份（不含 DB，uploads 僅保留當年度）<br>• `archive`: 歷年封存（uploads 中今年以外的全部內容，加上 `wp-content/shield`、`WPvivid_Uploads`），與 `compact` 互補 |
| `-to={local\|<remote>}` | `local` | • `local`: 儲存於本機伺服器 (`/root/clpBackup`)<br>• `<remote>`: 指定 rclone 設定檔中之雲端名稱 (如 `google`, `b2`, `r2`) |
| `-path=<path>` | 依目的地 | 自訂本機目錄或雲端資料夾路徑 |
| `-expire=<Nd>` | 無 | 自動清除過期備份（如 `-expire=7d` 或 `-expire=30d`），只會清除同類型的備份 |
| `-exclude=<pattern>` | 無 | 排除特定網站（適用於 `backup all`，支援逗號分隔） |
| `-skip-disabled` | 無 | 搭配 `backup all`：跳過已停用的網站（`clp site <domain> -off`，vhost 不在 `sites-enabled`）。預設停用的網站也會備份；指定單一網站時一律照常備份 |

#### ② 各備份類型的內容

所有類型都**不會**備份以下目錄（快取與其他備份外掛的本機備份），還原時也不會刪除它們：

- `wp-content/cache`
- UpdraftPlus `wp-content/updraft`、WPvivid `wp-content/wpvividbackups`、All-in-One WP Migration `wp-content/ai1wm-backups`
- Duplicator `wp-content/backups-dup-lite`、`wp-content/backups-dup-pro`、`wp-snapshots`
- Backup Migration `wp-content/backup-migration*`、BackUpWordPress `wp-content/backupwordpress-*-backups`
- BackWPup `wp-content/uploads/backwpup-*`、Solid Backups (BackupBuddy) `wp-content/uploads/backupbuddy_backups`、`backupbuddy_temp`、WP Staging `wp-content/uploads/wp-staging/backups`

| 類型 | 資料庫 | 網站檔案 | `wp-content/uploads` | `shield`、`WPvivid_Uploads` |
| :--- | :---: | :---: | :--- | :---: |
| `full` | ✅ | ✅ | 全部 | ✅ |
| `compact` | — | ✅ | 只有當年度目錄（`uploads/<今年>/`）與 uploads 根目錄的隱藏檔 | — |
| `archive` | — | — | 當年度以外的全部（歷年目錄、`elementor/` 等非年份目錄、uploads 根目錄的一般檔案） | ✅ |
| `db` | ✅ | — | — | — |

**`full` 與 `compact` + `db` + `archive` 的差異**：

- **檔案範圍相同**：三者合起來涵蓋的檔案與 `full` 相同。
- **時間點不同**：`full` 是同一時間打包；三個檔案則分開產生（例如 `db`、`compact` 每日，`archive` 每月）。還原後，歷年 uploads 可能比網站檔案與資料庫舊，最多差一個排程週期。
- **結論**：需要單一時間點、完整的網站狀態時用 `full`；`compact` + `db` + `archive` 是節省空間的日常組合。

#### ③ 實用操作範例

備份指定網站資料庫至本機：

```bash
sudo clp backup example.com -type=db
```

每日備份資料庫並保留 7 天：

```bash
sudo clp backup example.com -type=db -expire=7d
```

完整備份網站至本地，自動清除 30 天前備份：

```bash
sudo clp backup example.com -type=full -expire=30d
```

精簡備份至 Google Drive (透過 rclone)：

```bash
sudo clp backup example.com -type=compact -to=google
```

歷年封存備份至 Google Drive，保留 35 天：

```bash
sudo clp backup example.com -type=archive -to=google -expire=35d
```

全伺服器網站批次備份至雲端，排除測試網站並保留 14 天：

```bash
sudo clp backup all -type=full -to=b2 -expire=14d -exclude="test.,dev.,staging."
```

---

### 4. 網站與資料庫還原模組 (`clp restore`)

#### ① 互動式選單還原 (省略 `-file` 參數)

從本機備份清單中選取還原：

```bash
sudo clp restore example.com
```

從 Google Drive 雲端備份清單中選取還原：

```bash
sudo clp restore example.com -to=google
```

執行後系統會自動列出歷史備份清單，輸入號碼並輸入 `yes` 確認即可自動執行資料庫匯入、檔案還原、重新載入 PHP-FPM 與清除 WordPress 快取。可以用 `-type={db|full|compact|archive}` 只列出特定類型。

#### ② 精確命令列還原

指定本機特定備份檔案還原：

```bash
sudo clp restore example.com -file=example.com-db-20261005_120000.sql.gz
```

指定遠端備份檔案且免確認強制還原：

```bash
sudo clp restore example.com -file=example.com-full-20261005_153000.tar.gz -to=b2 --force
```

#### ③ 還原後與備份完全一致（刪除多出來的檔案）

還原檔案時預設會刪除網站上「備份中沒有」的檔案（rsync `--delete`），例如被植入的惡意檔案或已移除的外掛，讓還原結果等於備份當時的狀態。

- **只處理該類型自己的範圍**：
  - `full`：整個網站目錄。
  - `compact`：備份當年的 `uploads/<年份>/` 與網站其他檔案；不會動 uploads 中其他年份與非年份目錄、`shield`、`WPvivid_Uploads`。
  - `archive`：只處理 `wp-content/uploads`（備份當年的目錄除外），以及備份中有的 `shield`、`WPvivid_Uploads`；網站其他檔案不會動。
  - `db`：只匯入資料庫，不涉及檔案。
- **年份以備份當時為準**：從檔名的時間戳記判斷，不是還原當天的年份。
- **一律保護**：目前的 `wp-config.php`（備份中的版本另存到快照目錄）、上方列出的快取與備份外掛目錄。
- **確認提示**：互動模式下會先列出將刪除的項目數量與前 20 筆，輸入 `yes` 才會繼續；使用 `-y` 或 `--force` 時直接執行。
- **保留舊行為**：加上 `-keep-extra` 只覆蓋、不刪除。
- **可以復原**：還原前會先建立快照（`/root/clpBackup/rollback/`），涵蓋所有可能被刪除的檔案；還原失敗會自動回復。

#### ④ 還原前快照

- **先檢查空間**：建立快照前，會估算網站目錄（不含上方的快取與備份外掛目錄）加上資料庫的大小，再加 10% 餘裕，與 `/root/clpBackup` 的剩餘空間比較。
- **空間不足或快照失敗**：會刪除不完整的快照，此時尚未變更任何內容。互動模式下會詢問是否在沒有快照的情況下繼續（需輸入 `yes`）；使用 `-y` 或 `--force` 時一律中止。
- **略過快照**：加上 `-no-snapshot` 就不建立快照，還原失敗時也無法自動回復，風險自負。

```bash
sudo clp restore example.com -type=compact -no-snapshot
```

保留網站上多出來的檔案：

```bash
sudo clp restore example.com -type=compact -keep-extra
```

#### ⑤ 用 compact + db + archive 還原完整網站

`restore` 一次還原一個檔案。三個類型各自只會處理自己範圍內的檔案，所以依序還原三個檔案即可得到完整網站，建議順序為 `db` → `compact` → `archive`：

```bash
sudo clp restore example.com -type=db -to=google
```

```bash
sudo clp restore example.com -type=compact -to=google
```

```bash
sudo clp restore example.com -type=archive -to=google
```

注意：每次還原前都會建立一次完整的網站快照，三次還原會產生三份快照，請確認 `/root/clpBackup` 有足夠空間。

---

### 5. HTTP Basic 認證防護模組 (`clp httpauth`)

針對網站提供密碼防護與存取控制，密碼檔放在網站使用者的家目錄（`/home/<user>/.htpasswd`），不在網站根目錄中：

#### ① 帳號管理

互動式新增使用者 (密碼輸入時遮蔽)：

```bash
sudo clp httpauth example.com -add
```

指令指定帳號與密碼新增（注意：密碼會留在 shell 歷史紀錄中，建議使用互動模式）：

```bash
sudo clp httpauth example.com -add=[admin,StrongPassword123!]
```

刪除指定使用者：

```bash
sudo clp httpauth example.com -delete=admin
```

列出目前所有認證使用者：

```bash
sudo clp httpauth example.com -list
```

#### ② WordPress 後台保護 (`-wp-admin`)

針對 `/wp-admin/` 與 `wp-login.php` 加上 HTTP 認證，阻擋暴力破解的機器人：

開啟後台防護：

```bash
sudo clp httpauth example.com -wp-admin
```

關閉後台防護：

```bash
sudo clp httpauth example.com -wp-admin -off
```

#### ③ 全站或自訂路徑保護 (`-path`)

全站密碼保護 (適合 Staging 預備環境)：

```bash
sudo clp httpauth example.com -path=/
```

移除全站保護：

```bash
sudo clp httpauth example.com -path=/ -off
```

保護特定子目錄：

```bash
sudo clp httpauth example.com -path=/staging
```

#### ④ IP / 網段免密碼白名單 (`-whitelist`)

設定固定 IP 或公司網段免密碼直接通行（Nginx `satisfy any` 機制）：

追加 IP 至白名單 (支援 CIDR)：

```bash
sudo clp httpauth example.com -whitelist=203.0.113.50,192.168.1.0/24
```

移除特定 IP：

```bash
sudo clp httpauth example.com -whitelist=203.0.113.50 -delete
```

清除全部白名單 (所有人皆須密碼)：

```bash
sudo clp httpauth example.com -whitelist=clear
```

檢視綜合防護狀態看板：

```bash
sudo clp httpauth example.com -list=protected
```

---

### 6. PHP-FPM 行程池調校模組 (`clp php-pm`)

針對高負載環境調校 PHP-FPM 行程池參數（`pm.max_children = 35`, `pm.process_idle_timeout = 30s`, `pm.max_requests = 300`）：

調校單一網站 (自動對應網站實際使用的 PHP 版本)：

```bash
sudo clp php-pm example.com
```

批次調校全機所有網站：

```bash
sudo clp php-pm -all
```

舊寫法 `sudo clp php-pm all` 仍可使用。

- 調校前自動在 `/root/php/` 留下帶有時間戳記之設定檔備份。
- 調校後自動以 `php-fpm<version> -t` 檢查語法，檢查失敗時立即還原。

#### 自訂調校參數

三個參數都可以在單站或 `-all` 執行時帶入，也可以用 `clp config` 存成預設值。執行時會顯示每個值實際使用的來源。

| 參數 | 指令參數 | `clp config` 設定鍵 | 預設值 | 格式 |
| :--- | :--- | :--- | :--- | :--- |
| `pm.max_children` | `-max-children=N` | `php-max-children` | `35` | 1～999999 |
| `pm.process_idle_timeout` | `-idle-timeout=T` | `php-idle-timeout` | `30s` | 數字，可加 `s`／`m`／`h`／`d`，例如 `60s`、`5m` |
| `pm.max_requests` | `-max-requests=N` | `php-max-requests` | `300` | 0～999999999（`0` 表示不回收行程） |

**優先順序**：指令參數 > 環境變數（`PHP_FPM_MAX_CHILDREN`、`PHP_FPM_IDLE_TIMEOUT`、`PHP_FPM_MAX_REQUESTS`）> `clp config` > 預設值。只帶部分參數時，其餘參數仍依此順序決定。

這次指定單一網站的值：

```bash
sudo clp php-pm example.com -max-children=80 -max-requests=500
```

這次全部網站都使用指定的值：

```bash
sudo clp php-pm -all -max-children=50 -idle-timeout=60s
```

存成預設值（之後 `clp php-pm`、新建網站、還原等自動調校都會使用）：

```bash
sudo clp config -set php-max-children=50
```

```bash
sudo clp config -set php-idle-timeout=60s
```

```bash
sudo clp config -set php-max-requests=500
```

> [!NOTE]
> 指令參數只套用在這一次執行。之後再執行 `clp php-pm -all`（未帶參數）時，會改回 `clp config` 或預設值；個別網站要固定不同的值，需要每次對該網站帶入參數。

#### 依用量建議數值（`-status`／`-fix`）

`-status` 顯示每個 pool 實際的忙碌程度，並建議 `pm.max_children` 的值；`-fix` 套用建議值。只會修改 `pm = ondemand` 的 pool 的 `pm.max_children`，`pm.process_idle_timeout` 與 `pm.max_requests` 維持不變。

查看全部網站或單一網站的用量與建議值：

```bash
sudo clp php-pm -status
```

```bash
sudo clp php-pm example.com -status
```

單一網站套用建議值（可先用 `-dry-run` 預覽）：

```bash
sudo clp php-pm example.com -fix -dry-run
```

```bash
sudo clp php-pm example.com -fix
```

全部網站（`-exclude=` 排除網站，`-y` 略過確認）：

```bash
sudo clp php-pm -fix -all -dry-run
```

```bash
sudo clp php-pm -fix -all -exclude="test.,dev."
```

數字的來源：

- **peak**：PHP-FPM 啟動以來，同時執行的最多 worker 數（pool status 頁面的 `max active processes`）；**days** 是這段統計的天數。
- **reached**：碰到 `pm.max_children` 上限的次數，來自 status 頁面與近 7 天的 PHP-FPM log。
- **記憶體上限**：總記憶體扣除 MySQL／MariaDB、Varnish（`malloc` 大小）、Redis 與保留的 512MB 後，除以每個 PHP worker 的記憶體（取忙碌中的 worker 實測，樣本太少時以 100MB 計算）。

建議值的算法：

1. peak × 1.5，無條件進位到 5 的倍數，最少 10；曾經滿載時改用目前的值 × 1.5。
2. 記憶體上限會壓低預留的空間，但不會低於實際出現過的 peak；這類網站會標示「（記憶體偏緊）」。
3. 結論：**需要調高**（曾經滿載，或目前的值低於 peak × 1.2）、**可調低**（超過建議值的 2 倍，或超過記憶體上限），其餘為**正常**。
4. PHP-FPM 啟動未滿 3 天時，統計時間太短，會標示出來，`-fix` 也會略過。

> [!NOTE]
> PHP-FPM 重載或重新啟動（包含 `-fix` 本身）會讓 status 頁面的統計重新計算，請至少 3 天後再用 `-status` 檢查。之後若再用固定值執行 `clp php-pm -all`，會覆蓋建議值。

---

### 7. 全域設定管理模組 (`clp config`)

CLP Helper 提供專屬的全域設定管理模組 (`clp config`)，把偏好設定與金鑰儲存在 `/etc/clp/clp.conf`（權限為 600，只有 root 可以讀取）。

#### 支援之設定項目 (Configuration Keys)

| 設定鍵 (Key) | 說明 | 格式與範例 |
| :--- | :--- | :--- |
| `lang` | CLP Helper 預設命令列介面語言 | `en_US`, `zh_TW` |
| `cf-token` | Cloudflare API 權杖 (用於邊緣 WAF 與 SSL DNS-01 自動化) | Token 字串或憑證檔路徑 (如 `/root/.secrets/example.ini`) |
| `php-max-children` | `clp php-pm` 的 `pm.max_children` 預設值 | 1～999999，預設 `35` |
| `php-idle-timeout` | `clp php-pm` 的 `pm.process_idle_timeout` 預設值 | 例如 `30s`、`5m`，預設 `30s` |
| `php-max-requests` | `clp php-pm` 的 `pm.max_requests` 預設值 | 0～999999999，預設 `300` |

#### 指令語法與範例

設定系統全域預設語系為繁體中文：

```bash
sudo clp config -set lang=zh_TW
```

設定系統全域預設語系為英文 (WordPress 標準)：

```bash
sudo clp config -set lang=en_US
```

設定全域 Cloudflare API Token (支援直接輸入 Token 字串)：

```bash
sudo clp config -set cf-token="your_cloudflare_api_token"
```

設定全域 Cloudflare API Token (支援直接傳入憑證檔路徑，自動提取 Token)：

```bash
sudo clp config -set cf-token="/root/.secrets/example.ini"
```

查詢已設定之參數 (機敏 Token 自動遮蔽顯示: 1234****cdef，並標註來源)：

```bash
sudo clp config -get lang
```

```bash
sudo clp config -get cf-token
```

取得原始未遮蔽 Token：

```bash
sudo clp config -get cf-token --raw
```

列出所有目前已生效之全域設定：

```bash
sudo clp config -list
```

清除指定設定鍵（恢復為系統預設值）：

```bash
sudo clp config -unset lang
```

```bash
sudo clp config -unset cf-token
```

---

## 七、常用維運排程建議做法 (Crontab Best Practices)

透過 `sudo crontab -e` 加入定期自動排程，讓維運工作自動執行（注意：CLI 執行訊息與日誌均輸出至 `stderr`，排程指令請使用 `>> file 2>&1` 重導向日誌）：

```cron
# ==============================================================================
# CLP Helper 自動化備份與維護排程
# ==============================================================================

# 1. 每日凌晨 03:00 執行全網站資料庫備份至 Google Drive (保留 7 天，排除測試站)
0 3 * * * /usr/local/bin/clp backup all -type=db -to=google -expire=7d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-db.log 2>&1

# 2. 每日凌晨 03:30 執行精簡網站檔案備份至 Google Drive (排除歷史年度圖片，保留 7 天)
30 3 * * * /usr/local/bin/clp backup all -type=compact -to=google -expire=7d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-compact.log 2>&1

# 3. 每月 1 號凌晨 04:00 執行歷年 uploads 封存備份至 Google Drive (保留最近 2 份；與 1、2 合起來即為完整網站)
0 4 1 * * /usr/local/bin/clp backup all -type=archive -to=google -expire=35d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-archive.log 2>&1

# 4. (可選) 每月 2 號凌晨 04:00 執行全站完整備份至 Google Drive (同一時間點的完整網站，保留最近 2 份)
0 4 2 * * /usr/local/bin/clp backup all -type=full -to=google -expire=35d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-full.log 2>&1

# 5. 每週日凌晨 05:00 執行伺服器空間清理瘦身 (日誌與暫存清理)
0 5 * * 0 /usr/local/bin/clp server -clean >> /var/log/clp/cron-clean.log 2>&1
```

> [!NOTE]
> 舊備份只會在新備份上傳成功後才清除。每月備份（3、4）的保留天數設為 35 天，可以確保每次執行後都保留「本月＋上月」兩份。Google Drive 刪除的檔案預設會先移到垃圾桶，空間要等垃圾桶清空後才會釋放；若空間有限，可在 rclone 的 Google Drive 遠端設定中加入 `use_trash = false`。

---

## 八、架構與安全性防護設計 (Security Architecture)

1. **嚴格的 SSH 防反鎖檢測 (Anti-Lockout Guarantee)**：
   在停用密碼認證前，強制驗證 `/root/.ssh/authorized_keys` 與 `SUDO_USER` 公鑰有效性；針對雲端供應商之 `50-cloud-init.conf` 衝突，會自動建立優先順序更高的設定來覆蓋，最後再用 `sshd -T` 確認實際生效的值。
2. **來源主機唯讀搬遷 (Zero Remote Write)**：
   搬移時只讀取來源主機，資料一律從來源主機傳到本機，遠端主機無須安裝任何代理程式或額外腳本，絕不觸碰或變更來源站任何檔案。
3. **路徑消毒與 WAF 防崩潰 (Path Sanitization)**：
   網站複製與搬遷時自動解析各外掛（如 Wordfence WAF、WP Rocket）殘留之伺服器絕對路徑，防止因檔案缺漏引發 PHP Fatal Error。
4. **多站 Redis 快取隔離 (Cache Key Salt)**：
   同一台主機上多個網站共用 Redis 時，自動在 `wp-config.php` 加入專屬的隨機 Salt，避免網站之間的快取互相干擾。

---

## 九、專案結構 (Directory Structure)

```text
clp-helper/
├── clp.sh                   # 指令分派入口 (CLI Entrypoint)
├── get.sh                   # 一行安裝用的引導腳本（從 GitHub 下載後執行 install.sh）
├── install.sh               # 一鍵全域安裝與解除安裝程式
├── LICENSE                  # MIT 開源授權條款
├── README.md                # 專案說明與操作手冊 (English)
├── README.zh-TW.md          # 專案說明與操作手冊 (繁體中文)
├── lib/                     # 核心模組函式庫
│   ├── backup.sh            # 備份與還原模組 (整合 rclone 多雲端與過期清除)
│   ├── cloudflare.sh        # Cloudflare 整合模組 (DNS-01 憑證與邊緣 WAF 規則部署)
│   ├── clp_fileops.py       # 安全檔案操作輔助模組 (fd 與 O_NOFOLLOW 防止符號連結攻擊)
│   ├── config.sh            # 全域設定管理模組 (偏好設定與金鑰持久化)
│   ├── core.sh              # 核心共用庫 (日誌、權限檢查、網域拼字建議、DB 存取)
│   ├── httpauth.sh          # HTTP Basic 認證防護與 IP 白名單
│   ├── httpauth_vhost.py    # Nginx vhost HTTP 認證設定注入與還原輔助模組
│   ├── i18n.sh              # 國際化多語系 (i18n) 執行引擎
│   ├── php_fpm.sh           # PHP-FPM 行程池動態偵測與調校
│   ├── server.sh            # 伺服器維運、安全加固與 17 模組安裝器
│   └── site.sh              # 網站管理模組 (建立、停啟用、複製、搬移、刪除)
├── locales/                 # i18n 語系定義檔目錄 (WordPress 標準代碼)
│   ├── en_US.sh             # 英文語系字典 (基準 / 預設 en_US)
│   ├── en.sh                # 相容性重導向 shim 至 en_US.sh
│   └── zh_TW.sh             # 台灣繁體中文語系字典 (zh_TW)
└── templates/               # 設定檔範本庫
    ├── cf-rules.conf        # Cloudflare 自訂 WAF 規則範本
    └── nginx-httpauth.conf  # HTTP 認證與 IP 白名單整合範本
```

---

## 十、授權條款 (License)

本專案採用 [MIT License](LICENSE) 開源授權。
您可以自由修改、散布與商業使用。

CLP Helper 為獨立開發專案，與 CloudPanel 或 MGT Commerce GmbH 無任何關聯。CloudPanel 與 WordPress 為其各自所有者之商標。
