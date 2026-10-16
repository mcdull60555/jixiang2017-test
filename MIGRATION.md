> ## 目前進度（2026-10-15 補記）
>
> 以下原始清單保持原樣。實際做法與原計畫有幾處不同：
>
> - 決策 #1：4 位數密碼採「前綴 jx」；真正的 PIN 存在 `private.login_pins`，由 Edge Function `login` 驗證。
> - 決策 #2：已取消顯示學生明文密碼，只保留重設為 0000。
> - 決策 #6：Auth 內建速率限制不夠，改為自建登入閘門，輸錯 3 次鎖 1 分鐘並顯示剩餘次數。
> - 保留天數已改為 7 天（歸檔項目、聯絡簿、送審紀錄），由 pg_cron 每日清理。
> - 已完成階段 1～8，另外新增：多老師／多班級、管理者後台、年級限制。
> - 階段 9 壓力測試已完成（2026-10-16）：100 位學生＋8 位老師同時使用無失敗；老師審核改為只補抓變動項目後，流量約為舊做法 1/10，兩天全部壓測共用 0.303 GB（免費 5 GB/月）。
> - 防休眠已安裝：GitHub Actions `.github/workflows/keepalive.yml` 每 2 天台灣時間 8:30 讀一次年級清單。
> - 備份按鈕已完成（`sql/phase_i_backup.sql`）：管理者下載全校備份、老師下載本班備份，JSON 檔，不含密碼。
> - 待做：階段 10 切換計畫、還原功能（目前只有下載備份）。
> - 注意：流量與老師端一次載入資料量，詳見對話中的估算；必要時老師端只抓最近 7 天。

---

# 基翔小學通：GAS → Supabase 遷移清單

> 依據：Code.gs（BACKEND_VERSION 2026-10-13-v12-startdate）與 index.html。
> 這份只是規劃，**尚未修改任何檔案**。Supabase 功能細節請以官方文件為準（supabase.com/docs）。

## 0. 原則

- 正式版（jixiang2026-system、GAS、試算表）完全不動。
- 只在獨立測試資料夾與獨立的 Supabase 測試專案中作業，只用假資料。
- 保留使用者看到的畫面與操作：學生/家長「下拉選學生＋輸入密碼」登入、老師端各頁籤。
- service_role key 絕不寫進任何檔案或前端。前端只放 Project URL 與 publishable（anon）key。
- 每個階段完成後先說明改了什麼，再進入下一階段。

## 1. 動手前必須先決定的事項

| # | 問題 | 背景 | 選項 |
|---|------|------|------|
| 1 | 4 位數密碼 | Supabase Auth 密碼最短 6 碼 | A. 前端把 4 位數補固定前綴（例如 `jx` + 4 碼）再送出，使用者仍只輸入 4 碼，但安全性仍等同 4 位數；B. 自建驗證（Edge Function 驗證後簽 JWT），可保留純 4 位數；C. 改成 6 位數。 |
| 2 | 老師端顯示學生明文密碼 | Auth 無法還原密碼；目前靠 pwdView 加密還原 | A.（建議）取消顯示，只保留「重設為 0000」；B. 另存加密欄位（需 Edge Function 與金鑰管理）。 |
| 3 | 家長與學生共用帳號 | 現況是共用一組 | 維持：每位學生一個 Auth 帳號。 |
| 4 | 學生 Auth 帳號的 Email 格式 | 登入畫面是選姓名，不輸入 Email | 用內部代號組成假 Email，並關閉 Email 驗證；先在測試專案驗證該網域可用。 |
| 5 | 登入前的學生名單是否外露 | 下拉選單必須在登入前顯示姓名、學校、年級 | 建公開 view，只含 id、姓名、學校、年級、班級；其餘一律要登入。 |
| 6 | 登入失敗鎖定（5 次、1 分鐘） | GAS 自己實作 | 先用 Auth 內建速率限制，再評估是否需要額外機制。 |

## 2. 資料表設計（初稿）

欄位名稱以 snake_case 為例，實際以建表時為準。

- `profiles`：id（對應 auth.users）、role（`teacher` / `student`）、student_id
- `students`：id、name、school、grade、class_name、avatar、auth_user_id
- `grades`：name、avatar、sort_order（取代 gradeAvatars 與年級順序）
- `subjects`：name、sort_order
- `tasks`：id、student_id（on delete cascade）、type（作業/考卷）、subject、title、date、student_checked、pending_review、teacher_status、submitted_at、done_at、reviewed_at
  - 唯一限制：student_id + type + subject + title + date（對應現有「四項相同視為同一項目」的規則）
- `contact_book`：id、date、weekday、content、items（jsonb，含 text 與 targets: [{grade, schools[]}]）
- `submit_log`：id、at、action（submit / withdraw / review）、task_id、student_id、student_name、type、subject、title、date、status

## 3. Code.gs 功能對照

### 登入與權限
| 現況（GAS） | Supabase 做法 |
|---|---|
| `login`（老師/學生）、加鹽 SHA-256 | Supabase Auth `signInWithPassword` |
| token 存 CacheService，6 小時 | Auth JWT 與 refresh；前端的 60 分鐘閒置登出保留 |
| 輸錯 5 次鎖 1 分鐘 | Auth 內建速率限制（驗證效果） |
| `get` 公開名單 | 公開 view（anon 可讀） |
| `data` 依身分裁切 | RLS：學生只能讀自己的 students / tasks；老師可讀全部 |
| 學生只看到「發布日當天起」的項目 | RLS 或 view 以台灣日期過濾 tasks.date |
| `changePwd`（學生改自己的密碼） | `auth.updateUser({ password })`（只能改自己） |
| 老師改密碼、預設 1234 提醒 | `auth.updateUser`；預設密碼提醒改為首次登入檢查 |

### 資料讀寫
| 現況 | Supabase 做法 |
|---|---|
| `save` 整份儲存（主要的慢與衝突來源） | 取消，改成逐筆 insert / update / delete |
| `mergeIncoming_`：進度欄位以資料庫為準 | 老師只能改 type/subject/title/date；進度欄位只能透過 RPC 修改（trigger 或 RPC 限制） |
| `studentSubmit` / `studentWithdraw` | RPC `student_submit(ids)`、`student_withdraw(ids)`：檢查項目屬於自己且老師尚未審核為已完成；寫入 submitted_at 與 submit_log |
| `teacherReview` | RPC `teacher_review(ids, status)`：更新狀態、reviewed_at、done_at、清除/設定 student_checked，並寫入 submit_log |
| `cbSet` / `cbDelete` | 直接對 contact_book 做 upsert / delete（僅老師） |
| 聯絡簿 targets（年級＋學校）過濾 | security definer 函式 `get_contact_book()`，依登入學生的年級與學校過濾 items |
| 輪詢 `since` 版本標記（15～60 秒） | Realtime 訂閱 tasks 與 contact_book；或先保留輪詢作為退路 |
| 學生建立、批次建立（預設 0000）、刪除 | Edge Function（用 service_role 建立/刪除 Auth 帳號，並先驗證呼叫者是老師） |
| 批次「預設密碼 0000」 | Edge Function `reset_password` |

### 自動化與計算
| 現況 | Supabase 做法 |
|---|---|
| 跑馬燈 champions（上週週一～週日、台灣時間、全部已完成、依最後審核時間排序） | SQL 函式 `get_champions()`；前端維持「週二～週日才顯示」的判斷 |
| 聯絡簿超過 10 天自動刪除 | pg_cron 每日刪除，顯示端同時過濾 |
| 送審紀錄保留 15 天、最多 1000 筆 | pg_cron 每日清理 |
| 歸檔項目（整組 100% 完成）超過 15 天清空（目前由老師端前端執行） | 改為 pg_cron，邏輯需與前端的分組規則（類型_科目_標題_日期）一致 |
| 舊紀錄搬移、importFromOldDeployment、migratePasswords | 不需要；改寫一次性的資料匯入腳本（只匯測試用假資料） |

## 4. index.html 需要修改的函式

**通訊與同步層（建議抽成一個資料存取層，畫面程式盡量不動）**
- `gasPost_`、`loadDataFromSheets`、`fetchLatestAppData`、`saveData`、`_postOnce`、`_saveWithRetry`、`_drainSaveQueue`
- `pollTeacherRealtimeData`、`pollStudentRealtimeData`、`scheduleTeacherPoll_`、`startStudentRealtimeSync`

**登入與身分**
- `verifyTeacherLogin`、`verifyStudentLogin`、`clearAuthAndLogout`、`logout`、`logoutStudent`、`saveAuthState`、`openStudentLoginModal`（名單來源改為公開 view）

**學生端**
- `applyStudentChanges`、`submitStudentDrafts`、`withdrawStudentSubmission`、`saveStudentSelfPwd`

**老師端：審核與派發**
- `teacherReviewPatch_`、`batchUpdateTaskStatus`、`updateTaskStatus`
- `saveAssignedTask`、`saveSingleDispatchEdit`、`confirmBatchEditDispatches`、`deleteDispatchGroup`、`batchDeleteDispatches`、`checkAndCleanLifeCycleTasks`

**老師端：學生、年級、科目、聯絡簿**
- `saveStudent`、`saveBatchStudents`、`resetSelectedStudentPwdsToDefault`、`deleteStudent`、`batchDeleteStudents`、`confirmBatchChangeGrade`、`unifyGradeAvatars`、`setGradeAvatar_`
- `saveNewGrade`、`removeGrade`、`saveNewSubject`、`removeSubject`
- `contactBookPatch_`、`saveContactBookEntry`、`deleteContactBookEntry`
- `saveTeacherPwd`、`renderStudentsCards`（移除顯示明文密碼的部分，視決策 #2）

**資料策略**
- 25 人規模可維持：老師端載入全部資料、學生端只載入自己的資料，維持現有 `window.appData` 結構，先求畫面行為不變。
- 大量派發改成批次 insert。

## 5. 分階段計畫與驗收

1. **準備**：建立資料夾、`git init`、CLAUDE.md、測試用 Supabase 專案；確認檔案中沒有正式網址或真實資料。
2. **資料表與 RLS**：建表、開啟 RLS、公開 view、假資料（測試生 01～05）。
3. **登入**：老師與學生登入、公開名單、登出、閒置登出。
4. **讀取**：老師端與學生端畫面能顯示資料。
5. **學生送審與撤回**（RPC）。
6. **老師審核**（RPC、submit_log）。
7. **派發管理與學生管理**（含 Edge Function）。
8. **聯絡簿、紀錄、跑馬燈、pg_cron**。
9. **測試**：模擬約 25 人同時送出、與目前速度比較；RLS 驗證（用學生身分嘗試讀取他人資料與老師功能，必須失敗）。
10. **備份與切換計畫**：每週匯出；挑寒暑假或段考後切換；切換後保留 GAS 與試算表 1～2 個月作為退路；告知家長「系統升級，密碼不變」。

## 6. 資安檢查清單

- [ ] 所有資料表都已開啟 RLS
- [ ] anon 角色只能讀公開名單 view
- [ ] 前端沒有 service_role key
- [ ] Edge Function 都先驗證呼叫者為老師
- [ ] 用學生身分測試：看不到他人資料、不能呼叫老師審核
- [ ] 測試專案只含假資料
- [x] 免費方案無自動備份：已有備份下載按鈕（仍需每週手動下載）
- [x] 免費專案 7 天無活動會暫停：已用 GitHub Actions 每 2 天保活

## 7. 待使用者回答

1. 決策 #1（4 位數密碼）與 #2（是否取消顯示明文密碼）要選哪個？
2. 目前實際遇到的問題是慢、同時送出失敗，還是同步失敗？（決定遷移的優先順序與要不要先調整輪詢間隔）
3. DEFAULT_DATA 內的三位範例學生（王小明、林小花、張阿豪）是否確定為假資料？

## 8. 給 Claude Code 的第一個提示詞

> 請讀 index.html、Code.gs 與本清單，確認每個後端功能與 Supabase 的對應是否完整，補上遺漏之處，並產出第一版建表與 RLS 的 SQL 草稿。這一步不要修改任何檔案，也不要連線任何 Supabase 專案。
