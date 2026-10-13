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
- 📦 **靈活備份與雲端同步**：三種備份型態（`db` 資料庫、`compact` 精簡打包、`full` 完整封裝），直接整合 `rclone` 支援 Google Drive、Backblaze B2、Cloudflare R2 與 AWS S3，可以依備份類型自動刪除過期的備份 (`-expire`)。
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

```bash
# 檢視版本資訊 (顯示版本號碼與建置時間戳記)
clp -v
# 輸出範例: CLP Helper v1.0.0 (建置時間 2026-10-13 23:11:41)

# 查看全域功能說明選單
clp --help
```

### 3. 解除安裝

若日後需要從主機完整移除 CLP Helper (`clp`)：

```bash
sudo bash /usr/local/lib/clp-helper/install.sh --uninstall
```

---

## 四、指令總覽與架構 (Command Architecture)

CLP Helper 的指令架構設計遵循統一、直覺的語法規範：

```bash
sudo clp <module> [target_domain] [options...]
```

### 核心模組速覽

| 模組 | 主要功能 | 常用操作指令 |
| :--- | :--- | :--- |
| **`site`** | WordPress 網站管理 | `-new`, `-list`, `-on`, `-off`, `-ssl`, `-cf-waf`, `-clone-from`, `-migrate`, `delete` |
| **`server`** | 主機維運與安全加固 | `(無參數狀態檢查)`, `install`, `-harden`, `-ufw`, `-ssh`, `-fail2ban`, `-clean` |
| **`backup`** | 網站與資料庫備份 | `-type={db\|full\|compact}`, `-to={local\|<remote>}`, `-expire=<Nd>` |
| **`restore`** | 備份還原作業 | `[-file=<name>]`, `-type={db\|full\|compact}`, `-to={local\|<remote>}` |
| **`httpauth`** | HTTP 認證與存取防護 | `-add`, `-delete`, `-list`, `-wp-admin`, `-path`, `-whitelist` |
| **`php-pm`** | PHP-FPM 行程池調校 | `<domain>`, `all` |
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

```bash
# 以繁體中文顯示說明選單
sudo clp --lang=zh_TW --help

# 以英文顯示說明選單
sudo clp --lang=en_US --help

# 以繁體中文檢視版本資訊
clp --lang=zh_TW -v

# 以英文檢視版本資訊
clp --lang=en_US -v

# 搭配各模組指令使用
sudo clp --lang=zh_TW site -list
sudo clp --lang=en_US site example.com -new
sudo clp --lang=zh_TW server
```

#### 2. 環境變數設定 (Persistent Override)
在終端機中匯出 `CLP_LANG`，或加入 `~/.bashrc` / `/etc/environment`：

```bash
# 將目前工作階段切換為繁體中文
export CLP_LANG="zh_TW"
clp -v
sudo clp --help

# 將目前工作階段切換為英文
export CLP_LANG="en_US"
clp -v
sudo clp --help
```

#### 3. 透過 `clp config` 永久設定預設語系 (Persistent Configuration)
可以用 `clp config` 設定預設語系，之後就不必每次登入都設定環境變數：

```bash
# 將系統全域預設語系永久設定為繁體中文
sudo clp config -set lang=zh_TW

# 將系統全域預設語系永久設定為英文 (WordPress 標準)
sudo clp config -set lang=en_US

# 查詢目前已設定之預設語系
clp config -get lang

# 清除語系設定（恢復為依系統環境自動判斷）
sudo clp config -unset lang
```

#### 4. 安裝程式語系指定 (`install.sh`)
安裝程式也支援切換語系，並會自動偵測系統語系：

```bash
# 以繁體中文執行安裝程式
sudo bash install.sh --lang=zh_TW

# 以英文執行安裝程式 (國際化伺服器環境預設)
sudo bash install.sh --lang=en_US

# 檢視安裝程式說明選單
bash install.sh --help
bash install.sh --lang=zh_TW --help

# 以指定語系執行解除安裝
sudo bash /usr/local/lib/clp-helper/install.sh --uninstall --lang=zh_TW
```

---

## 六、各模組詳細手冊 (Modules Reference)

### 1. 網站管理模組 (`clp site`)

#### ① 網站清單檢視 (`clp site -list`)

```bash
# 表格模式：列出所有網站
sudo clp site -list

# 依狀態或 SSL 憑證篩選
sudo clp site -list=enabled     # 僅列出已啟用網站
sudo clp site -list=disabled    # 僅列出暫停中網站
sudo clp site -list=ssl         # 僅列出具備 SSL 憑證網站

# 腳本專用純文字模式 (-raw)：每行輸出一個網域名稱，利於迴圈自動化
sudo clp site -list=enabled -raw
```

#### ② 建立全新 WordPress 網站 (`clp site <domain> -new`)

```bash
# 互動式建立 (依序提示 Site User、PHP 版本、SSL 模式與管理員帳密)
sudo clp site example.com -new

# 一鍵指定參數建立 (採用 CloudPanel 原生 HTTP-01 驗證)
sudo clp site example.com -new -http -php=8.4 -user=myuser

# 一鍵指定參數建立 (採用 Cloudflare DNS-01 API 驗證)
sudo clp site example.com -new -dns -php=8.4

# 略過 SSL 申請建立
sudo clp site example.com -new -ssl=off

# 覆寫已存在的同名網站
sudo clp site example.com -new -force-replace
```

> [!TIP]
> 執行 `-new` 建立網站時，詢問 WordPress 管理員帳號密碼若直接按 `Enter` 留空，系統將自動套用預設值（帳號預設 `wpadmin`，密碼自動產生高強度隨機密碼並存至 `/root/.clp/<網域>-wp-admin.txt`，Email 預設 `wpadmin@wp.com`）。

#### ③ SSL 憑證管理 (`clp site <domain> -ssl`)

```bash
# 透過 Cloudflare DNS-01 申請 SSL（自動完成驗證並設定續約排程）
sudo clp site example.com -ssl=on -dns
sudo clp site example.com -dns

# 指定特定 Cloudflare API 金鑰設定檔
sudo clp site example.com -ssl=on -dns -api=my-cloudflare.ini

# 申請 CloudPanel 原生 HTTP-01 SSL (網域已指向本機 IP)
sudo clp site example.com -ssl=on -http

# 關閉並移除 SSL 憑證
sudo clp site example.com -ssl=off
```

#### ④ 同機網站複製 (`clp site -clone-from`)

```bash
# 基本複製 (目標站不存在將全自動建立)
sudo clp site -clone-from=example.com new-example.com

# 覆寫已存在的目標站
sudo clp site -clone-from=example.com new-example.com -force-replace

# 自訂目標站使用者或 PHP 版本
sudo clp site -clone-from=example.com new-example.com -user=newuser -php=8.4
```

- **自動處理項目**：
  - 複製時優先申請 SSL，驗證失敗就提早停止 (Fail-Fast)，避免白白傳輸資料。
  - 自動偵測 Wordfence WAF 路徑並替換，若檔案遺失會自動處理，避免網站出現 500 錯誤。
  - 自動為 Redis 注入全站隨機 Salt（`WP_CACHE_KEY_SALT`），避免網站之間的快取互相干擾。
  - WP-CLI 深度置換網址，並自動校正 `robots.txt` 內之 Sitemap 網址。

#### ⑤ 跨主機網站安全搬移 (`clp site -migrate`)

```bash
# 同網域跨主機搬遷 (網域保持不變，略過 search-replace)
sudo clp site -migrate=remote-vps -from=example.com

# 不同網域跨主機搬遷 (自動執行資料庫網址置換)
sudo clp site -migrate=remote-vps -from=example.com new-site.com

# 批次搬移遠端主機所有網站至本地 (網域不變)
sudo clp site -migrate=remote-vps -all

# 批次搬移並排除特定測試子網域
sudo clp site -migrate=remote-vps -all -exclude="test.,dev.,staging." -force-replace
```

- **搬移防護**：
  - **遠端唯讀存取**：資料庫以壓縮的 SSH 連線傳到本機，確認完整後再匯入；來源主機不會寫入任何檔案。
  - **心跳鎖定預警**：自動檢查來源網站在 10 分鐘內是否有人正在編輯文章（`_edit_lock`），避免蓋掉正在撰寫的文章。
  - **SSH 金鑰解鎖整合**：金鑰有設定密碼時，會自動載入 `ssh-agent`，只需要輸入一次。

#### ⑥ 啟用、停用與刪除網站

```bash
# 暫停網站服務 (檔案與資料庫完整保留)
sudo clp site example.com -off

# 重新啟動網站
sudo clp site example.com -on

# 互動確認刪除網站與對應資料庫
sudo clp site delete example.com

# 強制刪除網站 (略過確認提示)
sudo clp site delete example.com --force
```

#### ⑦ Cloudflare 邊緣 WAF 防護與安全最佳化 (`clp site <domain> -cf-waf`)

> ⚠️ **作用範圍為整個 zone：** [CLP] WAF 規則與 SSL／HTTPS／TLS 設定會套用到整個 Cloudflare zone（其中所有主機名稱）。對任一網域執行 `-cf-waf`（或 `-cf-waf=off`）都會取代整個 zone 的 [CLP] 規則，您自建的非 [CLP] 規則會保留。若已設定 `clp config -set cf-default-mode / cf-always-https / cf-min-tls`，zone 設定會依設定值套用。

一鍵為網域設定 Cloudflare 的 Full (Strict) SSL、Always Use HTTPS、最低 TLS 1.2，並部署 4 條 WAF 規則（保護 WP 後台登入、阻斷 XML-RPC、封鎖敏感原始檔/備份檔、攔截惡意掃描器與空 UA）：

```bash
# 一鍵為指定網域設定邊緣安全性並部署 WAF 規則
sudo clp site example.com -cf-waf

# 模擬執行 (驗證 Token、解析 Zone ID 並輸出即將套用之規則 JSON，不實際變更)
sudo clp site example.com -cf-waf --dry-run

# 指定後台登入放行白名單 IP
sudo clp site example.com -cf-waf --whitelist="1.2.3.4,5.6.7.8"

# 查詢網域目前邊緣安全防禦與 WAF 規則狀態
sudo clp site example.com -cf-waf=status

# 安全清理與停用 (僅刪除 [CLP] 規則，完整保留使用者自訂規則)
sudo clp site example.com -cf-waf=off
```

- **安全設計**：
  - **Token 四級解析**：自動支援 CLI `--token`、既有 Certbot `/root/.secrets/*.ini` 憑證檔、全域 `/etc/clp/clp.conf` 或環境變數。
  - **自訂規則隔離保護**：僅變更標註 `[CLP]` 前綴之規則，使用者原有業務規則絕不覆蓋。
  - **配額上限檢查**：部署前依 zone 方案檢查自訂規則數量上限（Free 5／Pro 20／Business 100／Enterprise 1000），超過時停止並列出現有規則，避免 API 400 錯誤。

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

```bash
# 互動式引導安裝 (自選資料庫引擎與 17 個核心模組)
sudo clp server install

# 一鍵快速安裝建議設定 (預設 MySQL 8.4 LTS)
sudo clp server install -y

# 指定 MariaDB 11.4 LTS 安裝
sudo clp server install -y --db=MARIADB_11.4

# 模擬測試模式 (不對系統做任何異動)
sudo clp server install --dry-run
```

**17 個核心部署模組一覽**：
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
17. `wordfence`：透過 pipx 部署 Wordfence CLI 惡意程式碼掃描器

#### ③ 互動式資安加固流程 (`sudo clp server -harden`)

針對已經在使用中的 CloudPanel 主機，逐項強化安全設定：

```bash
# 逐項互動確認加固
sudo clp server -harden

# 一鍵套用加固
sudo clp server -harden -y
```

#### ④ 輔助工具隨選安裝 (`sudo clp server -install=...`)

```bash
sudo clp server -install=netdata    # 安裝 Netdata 效能監控
sudo clp server -install=rclone     # 安裝 Rclone 雲端備份工具
sudo clp server -install=certbot    # 安裝 Certbot 與 Cloudflare DNS 外掛
sudo clp server -install=wordfence  # 安裝 Wordfence CLI 掃描器
sudo clp server -install=smtp       # 安裝 Postfix Relay 郵件服務
sudo clp server -install=all -y     # 一鍵全數安裝
```

#### ⑤ 獨立日常維運指令

```bash
# 防火牆維運
sudo clp server -ufw               # 檢視防火牆規則清單
sudo clp server -ufw -allow=8080   # 放行特定連接埠
sudo clp server -ufw -icmp=drop    # 阻擋外網 Ping

# SSH 維運與緊急復原
sudo clp server -ssh               # 查看 SSH 設定與金鑰數量
sudo clp server -ssh -harden       # 停用密碼登入
sudo clp server -ssh -unharden     # 【緊急復原】：臨時恢復密碼登入

# Fail2ban 入侵防護
sudo clp server -fail2ban          # 查看被封鎖的 IP 清單
sudo clp server -fail2ban -unban=203.0.113.10  # 解鎖指定 IP
sudo clp server -fail2ban -unban=all           # 一鍵解鎖所有 IP
sudo clp server -fail2ban -whitelist=1.2.3.4  # 新增白名單

# 系統 DNS 與時區同步
sudo clp server -dns=auto          # 自動設定 Google/Cloudflare DNS
sudo clp server -timezone=Asia/Taipei # 一鍵同步系統與全機所有 PHP 版本時區

# 郵件測試與磁碟空間瘦身
sudo clp server -smtp -test=admin@example.com  # 發送測試信驗證 SMTP
sudo clp server -clean             # 清理日誌、APT 暫存套件與暫存檔，並顯示釋放了多少空間
```

---

### 3. 網站與資料庫備份模組 (`clp backup`)

#### ① 參數規格

```bash
sudo clp backup <domain|all> [options...]
```

| 參數 | 預設值 | 說明 |
| :--- | :--- | :--- |
| `-type={db\|full\|compact}` | `full` | • `db`: 僅備份資料庫 (`.sql.gz`)<br>• `compact`: 精簡備份（不含 DB，uploads 僅保留當年度，排除快取）<br>• `full`: 完整打包資料庫與全站所有實體檔案 (`.tar.gz`) |
| `-to={local\|<remote>}` | `local` | • `local`: 儲存於本機伺服器 (`/root/clpBackup`)<br>• `<remote>`: 指定 rclone 設定檔中之雲端名稱 (如 `google`, `b2`, `r2`) |
| `-path=<path>` | 依目的地 | 自訂本機目錄或雲端資料夾路徑 |
| `-expire=<Nd>` | 無 | 自動清除過期備份（如 `-expire=7d` 或 `-expire=30d`），精準僅清除同類型備份，絕不誤刪 |
| `-exclude=<pattern>` | 無 | 排除特定網站（適用於 `backup all`，支援逗號分隔） |

#### ② 實用操作範例

```bash
# 備份指定網站資料庫至本機
sudo clp backup example.com -type=db

# 每日備份資料庫並保留 7 天
sudo clp backup example.com -type=db -expire=7d

# 完整備份網站至本地，自動清除 30 天前備份
sudo clp backup example.com -type=full -expire=30d

# 精簡備份至 Google Drive (透過 rclone)
sudo clp backup example.com -type=compact -to=google

# 全伺服器網站批次備份至雲端，排除測試網站並保留 14 天
sudo clp backup all -type=full -to=b2 -expire=14d -exclude="test.,dev.,staging."
```

---

### 4. 網站與資料庫還原模組 (`clp restore`)

#### ① 互動式選單還原 (省略 `-file` 參數)

```bash
# 從本機備份清單中選取還原
sudo clp restore example.com

# 從 Google Drive 雲端備份清單中選取還原
sudo clp restore example.com -to=google
```

執行後系統會自動列出歷史備份清單，輸入號碼並輸入 `yes` 確認即可自動執行資料庫匯入、檔案還原、重新載入 PHP-FPM 與清除 WordPress 快取。

#### ② 精確命令列還原

```bash
# 指定本機特定備份檔案還原
sudo clp restore example.com -file=example.com-db-20261005_120000.sql.gz

# 指定遠端備份檔案且免確認強制還原
sudo clp restore example.com -file=example.com-full-20261005_153000.tar.gz -to=b2 --force
```

---

### 5. HTTP Basic 認證防護模組 (`clp httpauth`)

針對網站提供密碼防護與存取控制，密碼檔放在網站使用者的家目錄（`/home/<user>/.htpasswd`），不在網站根目錄中：

#### ① 帳號管理

```bash
# 互動式新增使用者 (密碼輸入時遮蔽)
sudo clp httpauth example.com -add

# 指令指定帳號與密碼新增（注意：密碼會留在 shell 歷史紀錄中，建議使用互動模式）
sudo clp httpauth example.com -add=[admin,StrongPassword123!]

# 刪除指定使用者
sudo clp httpauth example.com -delete=admin

# 列出目前所有認證使用者
sudo clp httpauth example.com -list
```

#### ② WordPress 後台保護 (`-wp-admin`)

針對 `/wp-admin/` 與 `wp-login.php` 加上 HTTP 認證，阻擋暴力破解的機器人：

```bash
# 開啟後台防護
sudo clp httpauth example.com -wp-admin

# 關閉後台防護
sudo clp httpauth example.com -wp-admin -off
```

#### ③ 全站或自訂路徑保護 (`-path`)

```bash
# 全站密碼保護 (適合 Staging 預備環境)
sudo clp httpauth example.com -path=/

# 移除全站保護
sudo clp httpauth example.com -path=/ -off

# 保護特定子目錄
sudo clp httpauth example.com -path=/staging
```

#### ④ IP / 網段免密碼白名單 (`-whitelist`)

設定固定 IP 或公司網段免密碼直接通行（Nginx `satisfy any` 機制）：

```bash
# 追加 IP 至白名單 (支援 CIDR)
sudo clp httpauth example.com -whitelist=203.0.113.50,192.168.1.0/24

# 移除特定 IP
sudo clp httpauth example.com -whitelist=203.0.113.50 -delete

# 清除全部白名單 (所有人皆須密碼)
sudo clp httpauth example.com -whitelist=clear

# 檢視綜合防護狀態看板
sudo clp httpauth example.com -list=protected
```

---

### 6. PHP-FPM 行程池調校模組 (`clp php-pm`)

針對高負載環境調校 PHP-FPM 行程池參數（`pm.max_children = 35`, `pm.process_idle_timeout = 30s`, `pm.max_requests = 300`）：

```bash
# 調校單一網站 (自動對應網站實際使用的 PHP 版本)
sudo clp php-pm example.com

# 批次調校全機所有網站
sudo clp php-pm all
```

- 調校前自動在 `/root/php/` 留下帶有時間戳記之設定檔備份。
- 調校後自動以 `php-fpm<version> -t` 檢查語法，檢查失敗時立即還原。

---

### 7. 全域設定管理模組 (`clp config`)

CLP Helper 提供專屬的全域設定管理模組 (`clp config`)，把偏好設定與金鑰儲存在 `/etc/clp/clp.conf`（權限為 600，只有 root 可以讀取）。

#### 支援之設定項目 (Configuration Keys)

| 設定鍵 (Key) | 說明 | 格式與範例 |
| :--- | :--- | :--- |
| `lang` | CLP Helper 預設命令列介面語言 | `en_US`, `zh_TW` |
| `cf-token` | Cloudflare API 權杖 (用於邊緣 WAF 與 SSL DNS-01 自動化) | Token 字串或憑證檔路徑 (如 `/root/.secrets/example.ini`) |

#### 指令語法與範例

```bash
# 設定系統全域預設語系為繁體中文
sudo clp config -set lang=zh_TW

# 設定系統全域預設語系為英文 (WordPress 標準)
sudo clp config -set lang=en_US

# 設定全域 Cloudflare API Token (支援直接輸入 Token 字串)
sudo clp config -set cf-token="your_cloudflare_api_token"

# 設定全域 Cloudflare API Token (支援直接傳入憑證檔路徑，自動提取 Token)
sudo clp config -set cf-token="/root/.secrets/example.ini"

# 查詢已設定之參數 (機敏 Token 自動遮蔽顯示: 1234****cdef，並標註來源)
sudo clp config -get lang
sudo clp config -get cf-token
sudo clp config -get cf-token --raw    # 取得原始未遮蔽 Token

# 列出所有目前已生效之全域設定
sudo clp config -list

# 清除指定設定鍵（恢復為系統預設值）
sudo clp config -unset lang
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

# 3. 每月 1 號凌晨 04:00 執行一次全站完整封裝備份至 Backblaze B2 (保留 30 天)
0 4 1 * * /usr/local/bin/clp backup all -type=full -to=b2 -expire=30d -exclude="test.,dev.,staging." >> /var/log/clp/cron-backup-full.log 2>&1

# 4. 每週日凌晨 05:00 執行伺服器空間清理瘦身 (日誌與暫存清理)
0 5 * * 0 /usr/local/bin/clp server -clean >> /var/log/clp/cron-clean.log 2>&1
```

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
