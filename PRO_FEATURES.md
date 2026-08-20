# Cloudreve Pro Edition — Complete Feature Inventory & Replication Notes

> Reference compiled 2026-08-19 from official sources:
> [cloudreve.org/pricing](https://cloudreve.org/pricing) · [docs.cloudreve.org](https://docs.cloudreve.org) (OIDC, Load Balance, Payment, Custom Frontend, Pro License, Desktop Client, Upgrade to Pro, Concepts)
>
> Purpose: internal checklist for re-implementing Pro features on our Community Edition fork (`cloudreve-extend`). Community Edition is GPLv3; Pro is proprietary. Do not redistribute Pro assets; this doc only describes publicly documented behavior.

---

## 0. Licensing model (how Pro is sold & enforced)

| Item | Detail |
|---|---|
| Price | $89.90 / root domain; Pro D5 = $299.90 / 5 root domains |
| License unit | One root domain + authorized subdomains (wildcards NOT supported) |
| Activation | `--license-key` flag or `CR_LICENSE_KEY` env; redeems an **Offline License Key** at first online startup |
| Offline license | Shorter validity; contains authorized domains, subdomains, iOS VOL licenses. Server requires a valid (may be expired) offline license to start |
| Expired behavior | Site becomes **read-only** — major modifications (file changes) blocked |
| Refresh | Admin dashboard "Refresh Offline License" button; manual entry fallback |
| Offline deployment | `CR_LICENSE_KEY` + `CR_OFFLINE_LICENSE` envs; manual refresh before expiry |
| Domain change | $25 fee, one change per license |
| LAN deployment | License a root domain, resolve it internally to the private IP (don't license a changing LAN IP) |
| Upgrade path | Replace binary → `./cloudreve proupgrade` (SQLite: user-group storage-policy settings lost, reconfigure) |

### Code hooks in community repo (`cloudreve-extend`)

- `application/constants/constants.go` — `IsPro = "false"` (ldflags `-X ...constants.IsPro=true` at build time)
- `application/statics/statics.go` — `NewServerStaticFS(l, statics, isPro)`; serves embedded `cloudreve-frontend` vs `cloudreve-frontend-pro`
- `pkg/serializer/error.go` — `CodeDomainNotLicensed = 40087` ("domain not licensed")
- `pkg/setting/provider.go` — `License(ctx)` reads setting key `"license"`
- `inventory/setting.go` — default `"license": ""`
- `cmd/*` — `licenseKey` flag plumbed through `dependency.WithProFlag`

Pro enforcement/feature logic itself is in the proprietary Pro binary/frontend — NOT in this repo.

---

## 1. Advanced sharing & collaboration (Pro)

Share links become collaboration portals, not just download links.

### 1.1 Share-link actions
- Recipients can **upload** files through a share link
- Recipients can **modify** (edit/overwrite) files
- Recipients can **delete** files
- All configurable per share link

### 1.2 Granular permission model
- Permissions can be assigned to:
  - Individual **users**
  - **User groups**
  - **Anonymous visitors**
- Per-file and per-directory permissions
- Permission lookup walks up parent directories to the shared root
- Share-link settings **override** the shared root directory's own permissions; subdirectory permissions remain effective
- Single-file shares: share-link permission settings are used, file's own settings ignored
- Admin group always has all permissions (unchanged)

### 1.3 Anonymous collaboration
- Anonymous upload, modification, and deletion via share links (opt-in)

### 1.4 Default shares (pinned)
- Admin pins selected shares; **new users see them automatically after registration**

### 1.5 Paid share links
- Require payment before visitors can access shared content (ties into §3 payments)

---

## 2. Storage policy management (Pro)

### 2.1 Multiple storage policies per user group
- Community: one storage policy per user group
- Pro: a group is assigned **multiple** policies; **users choose** which policy to use when uploading
- Files/folders carry a "preferred policy"; folders propagate policy to children; fallback = first available policy for user

### 2.2 Load-balance storage policy
- Special policy type combining multiple sub-policies
- New uploads distributed by **configurable weights**:
  - weight 0 → never selected
  - weight N → N× probability vs weight 1
- Once a file is stored, its policy never auto-switches
- **Implementation is frontend-controlled** — users can still bypass via API and pick a sub-policy directly (i.e. backend must validate policy selection server-side for real enforcement)

---

## 3. Payments & monetization (Pro)

### 3.1 Currency settings (Settings → VAS → Payment settings)
- ISO 4217 currency code (e.g. `CNY`, `USD`)
- Display symbol (e.g. `¥`, `$`)
- **Currency unit** — smallest units per integer unit: USD=100, JPY=1
- Alipay/WeChat Pay MUST use CNY; Stripe allows configurable currency

### 3.2 Native payment providers
- **Alipay** (CNY)
- **WeChat Pay** (CNY)
- **Stripe** (any currency)

### 3.3 Custom payment provider (HTTP interface, v4)
You implement an independent HTTP service with 3 endpoints:

**Create order** — `POST <endpoint>`
- Headers: `Authorization: Bearer Cr <sig>:<expiry_ts>`, `X-Cr-Version`, `X-Cr-Site-Id`, `X-Cr-Site-Url`
- Body: `{ name, order_no, notify_url, amount (smallest unit), currency }`
- Response 200: `{ "code": 0, "data": "<checkout URL>" }` (data shown as QR / openable)

**Query order** — `GET <endpoint>?order_no=...`
- Headers same; signature in `sign` URL param instead of Authorization
- Response: `{ "code": 0, "data": "PAID" }` or non-PAID value

**Callback** — after payment, `GET <notify_url>` from provider side
- Retry with exponential backoff unless response body returns explicit error code
- Success response: `{ "code": 0 }`

**Signature algorithm (HMAC-SHA256):**
1. Extract `signature:timestamp`; reject if `timestamp < now`
2. Create order: collect all `X-Cr-*` headers → `key=value`, sort, join with `&` → `signedHeaderStr`; sign content = JSON `{"Path": url.Path, "Header": signedHeaderStr, "Body": body}` (Path `/` if empty)
3. Query order: sign content = `url.Path` only (query excluded)
4. `signContentFinal = signContent + ":" + timestamp`
5. `signActual = base64url( HMAC-SHA256(communicationKey, signContentFinal) )`
6. Compare with presented signature

> v3 custom payment API is incompatible with v4 — only implement v4 spec.

### 3.4 Monetization targets
- Paid share links (access to shared content)
- Paid storage plans / virtual goods (store)

---

## 4. OIDC / SSO authentication (Pro)

Admin panel: Settings → User Session → Third-party sign-in.

### 4.1 Native providers
- **Logto** — configure directly
- **Tencent QQ** (QQ Connect) — configure directly
- **Microsoft Entra ID (Azure AD)** — app registration, client secret, client ID, import OIDC metadata URL (`.../v2.0/.well-known/openid-configuration`)
- **Google** — OAuth client (Web app), client ID/secret, well-known config `https://accounts.google.com/.well-known/openid-configuration`

### 4.2 Provider requirements (OIDC compliance)
- `client_secret_post` token exchange
- `response_type=code`
- scopes `openid email profile`
- `userinfo_endpoint`
- `state` parameter support
- Recommended: email + avatar in userinfo, `end_session_endpoint` for logout

### 4.3 Userinfo field mapping
- Default mapping: `sub` → ID, `name` → display name, `email` → email, `picture` → avatar
- Non-standard responses mappable via **GJSON path syntax** (e.g. `attributes.uid`, `attributes.securityEmail`, `attributes.cn`)

---

## 5. Desktop sync client (Pro server required)

Official Windows app (Microsoft Store: `9p3gh5rnnzfd`; source: github.com/cloudreve/desktop).

### 5.1 Features
- Real-time **bidirectional sync** (SSE push notifications — `api/events`)
- **On-demand files** (Windows Cloud Files placeholders; no local disk usage until opened)
- Windows Explorer integration: context menus, thumbnails, status icons
- Works with all storage policies configured on the server

### 5.2 Placeholder states
- Online-only (cloud icon) — metadata local, content server-side
- Locally available (green check) — content downloaded; system may evict when low on space
- Always available (green circle+check) — pinned, never evicted
- Right-click: Free up space / Always keep on this device

### 5.3 Sync mechanics
- Real-time via SSE; requires proxy with SSE buffering disabled + long timeouts
- Force sync: right-click → Cloudreve → Sync now
- Conflict resolution: notification dialog; right-click → Resolve conflict
- Uploads go **directly to storage provider** (not relayed through server)
- Chunked parallel uploads

### 5.4 vs WebDAV
| | Desktop client | WebDAV |
|---|---|---|
| On-demand files | Yes | No |
| Real-time sync | Yes (SSE) | No |
| Upload | Direct to storage | Relayed via server |
| Offline | Pinned files | Cached only |
| Requirements | Win10 1903+, Pro server | Any OS/WebDAV client |

---

## 6. Custom frontend source (Pro)

- Pro purchasers get the **frontend source code** from the license-management dashboard
- License allows modification for own use; **redistribution prohibited**
- Community workaround (already available): build the public `cloudreve/frontend` repo → rename `build` → `statics` → drop into `data/` dir next to the binary → server serves it ("Folder with xxx already exists..." log line)
- Or `./cloudreve eject` extracts embedded static resources to `data/statics`
- i18n: `statics/public/locales/<lang>/*.json`, format `file:section.key`; register new languages in `src/i18n.ts`; rebuild required
- ServiceWorker caches statics; update prompt on version change; hard clear: DevTools → Application → Storage → Clear site data

---

## 7. Pro UI surface in the community frontend (ground truth for replication)

Audited `cloudreve-extend-FE` (commit `0834841`, pinned by backend tag `4.18.0`). **The community FE already ships nearly the entire Pro UI** — it is gated client-side (`pro` flag → `ProChip` + `ProDialog` popup) and the community backend has no endpoints behind it. Replication is mostly backend work + removing gates.

### 7.1 Gating mechanism
- `src/component/Pages/Setting/SettingForm.tsx` — `pro` prop → ProChip + ProDialog, blocks children interaction
- `src/component/Admin/Common/ProDialog.tsx` — the canonical Pro feature list: `shareLinkCollabration`, `filePermission`, `multipleStoragePolicy`, `auditAndActivity`, `vasService`, `sso`, `more`
- `src/component/Frame/NavBar/PageNavigation.tsx` — nav items carry `pro: true`
- Home page shows Pro chip when `summary.version.pro`; `src/api/request.ts` maps `DomainNotLicensed: 40087`, `AnonymouseAccessDenied: 40088`

### 7.2 Pro admin nav items (PageNavigation.tsx)
| Route | Label key | Meaning |
|---|---|---|
| `/admin/payment` | `dashboard:vas.orders` | VAS / payment orders |
| `/admin/event` | `dashboard:nav.events` | Audit & activity log |
| `/admin/abuse` | `dashboard:nav.abuseReport` | Abuse reports |

### 7.3 Settings → VAS tab (`src/component/Admin/Settings/VAS/`)
- `VAS.tsx` — credit system switch, currency (code/symbol/unit), payment config JSON `values.payment`, storage products `values.storage_products`, group sell data `values.group_sell_data`
- `PaymentProviders.tsx` — "Add payment provider" (Stripe/Alipay/WeChat/custom)
- `StorageProducts.tsx` — paid storage plans (SKU + storage_size)
- `GroupProducts.tsx` — paid group upgrades
- `GiftCodes.tsx` — gift/redeem codes

### 7.4 Settings → Events tab (`src/component/Admin/Settings/Event/Events.tsx`)
Full audit-log browser. Event taxonomy in `src/api/explorer.ts` (`AuditLogType`, 62 codes) — includes payment lifecycle: `payment_created`(34), `points_change`(35), `payment_paid`(36), `payment_fulfilled`(37), `payment_fulfill_failed`(38), `storage_added`(39), `group_changed`(40), `user_exceed_quota_notified`(41), `report_abuse`(58), `oauth_grant_create/token_exchange/revoke`(59–61).
- `src/api/dashboard.ts` — `AuditLog` type: `correlation_id`, `ip`, `content: LogEntry` (fields: `payment_id`, `points_change`, `sku`, `storage_size`, `expire`, `group_id`, `openid_provider`, `sub`, `passkey_id`, `direct_link_id`, …), edges → user/file/entity/share

### 7.5 Settings → UserSession → SSO (`SSOSettings.tsx`)
QQ Connect, Logto, OIDC accordions — all Pro-gated, empty bodies in community. Matches docs §4. `src/api/user.ts`: `sso_enabled`, `qq_enabled`, `direct_sso` on login-config.

### 7.6 Pro-gated admin form sections (all in `src/component/Admin/`)
| File | Section | Feature |
|---|---|---|
| `File/FileDialog/FileForm.tsx` | primaryStoragePolicy | per-file preferred storage policy (multi-policy) |
| `Group/EditGroup/DefaultPinnedSection.tsx` | default pinned shares | per-group default shares |
| `Group/EditGroup/FileManagementSection.tsx` | allowedNodes | restrict nodes per group |
| `Group/EditGroup/UploadDownloadSection.tsx` | (switches) | upload/download limits |
| `User/UserDialog/UserForm.tsx` | points / originUserGroup / groupExpired | VAS points, group change + expiry |
| `Settings/SiteInformation/SiteInformation.tsx` | announcement / appFeedback / appForum | announcement block, VAS app feedback+forum links |
| `Settings/UserSession/UserSession.tsx` | defaultSymbolics / filterEmailProvider / switch | default share symbols, email-provider allow/deny |
| `Settings/Email/EmailTemplates.tsx` | `mail_receipt_template`, `mail_exceed_quota_template` | receipt + quota-exceeded email templates |
| `FileSystem/CustomProps/CustomPropsSetting.tsx` | custom field types flagged `pro` | Pro metadata field types |

### 7.7 Storage policy providers (`StoragePolicySetting.tsx` `PolicyPropsMap`)
Only **`load_balance`** policy type is marked Pro; all storage backends (local, remote, S3, OneDrive, OSS, COS, OBS, KS3, Upyun, Qiniu) are community.

### 7.8 License UI
`src/api/dashboard.ts` — `ManualRefreshLicenseService { license }` (refresh offline license from admin dashboard; matches docs §0).

---

## 8. Replication plan (our fork)

Key advantage: **frontend UI already exists for everything below** (see §7) — work is backend endpoints + removing `pro` gates + flipping `IsPro`.

Order of effort (cheapest → hardest):

1. **Multi-policy per group** — backend: group→policies relation (ent schema), policy picker in upload UI; frontend mostly done (§7.6 FileForm/primaryStoragePolicy)
2. **Share-link collaboration** — extend share permission model (user/group/anonymous × upload/modify/delete); backend share visit endpoints + DB perms; frontend share dialog
3. **Load balance policy** — policy type field + weighted random pick at upload; validate selection server-side (FE provider card exists, §7.7)
4. **Default shares** — DB flag on share; inject into new-user home (FE: DefaultPinnedSection, §7.6)
5. **Audit log (Events)** — backend audit table + event emission (community FE taxonomy exists, §7.4; `pkg/filemanager/eventhub` for SSE); wire `/admin/event`
6. **Abuse reports** — report endpoint + admin list UI (`/admin/abuse`, §7.2)
7. **OIDC** — Go `coreos/go-oidc`; JWT/session bridge; QQ/Logto/Entra/Google discovery (FE accordions exist, §7.5)
8. **Custom payment** — HMAC-signed HTTP client + callback handler + orders UI (`/admin/payment`, VAS tab, §7.3; spec §3.3)
9. **Desktop client parity** — requires SSE events API (exists: `pkg/filemanager/eventhub`), direct-to-storage uploads, cloud-files integration; biggest effort; skip unless needed
10. **License enforcement** — skip (we don't sell); keep `IsPro=false`

### Suggested doc references (read before implementing)
- [OIDC](https://docs.cloudreve.org/en/usage/oidc)
- [Load Balance](https://docs.cloudreve.org/en/usage/storage/load-balance)
- [Official payments](https://docs.cloudreve.org/en/payment/official)
- [Custom payment](https://docs.cloudreve.org/en/payment/custom)
- [Concepts (permissions/policies)](https://docs.cloudreve.org/en/usage/concept)
- [Desktop client](https://docs.cloudreve.org/en/usage/desktop-client)
- [Pro license](https://docs.cloudreve.org/en/maintain/pro-license)
- [Upgrade to Pro](https://docs.cloudreve.org/en/maintain/upgrade-to-pro)
