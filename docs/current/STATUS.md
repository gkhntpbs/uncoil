# Uncoil — Durum ve Yol Haritası

> Son güncelleme: 2026-07-25 · Testler: 171/171 birim + 4/4 UI + Computer Use kabul akışı
> `docs/roadmap/FOUNDATION_PLAN.md` belgesinin güncel gerçeklik karşılığı budur.
> Yeni oturumlar önce bu dosyayı, ardından ilgili ajan yönergesini okumalı.

## Plandan sapmalar (bilinçli kararlar)

| Plan ne diyordu | Ne yapıldı | Neden |
|---|---|---|
| fork of an existing project'u üzerine inşa et (§4–5) | **Sıfırdan kendi kod tabanı.** Tarihsel temiz-oda incelemesi `docs/history/` altında tutuluyor; GPL kodu asla kopyalanmaz | Kullanıcı kararı (2026-07-23): "hazır projenin üzerine geliştirme istemiyorum". Lisans tamamen bize kaldı |
| Ghostty terminal motoru | **SwiftTerm (MIT, SPM)** | zig 0.15.2 macOS 26.5 SDK ile linklenemiyor; SwiftTerm yeterli ve sorunsuz |
| GPL-3.0 dağıtım zorunluluğu | Geçerli değil — tek bağımlılık MIT | Fork terk edildi |
| Xcode projesi elle | **XcodeGen** (`project.yml` → generate) | Üretilebilirlik; `Uncoil.xcodeproj` gitignore'da |
| Milestone sıralaması (§27) | Ürün geri bildirimiyle esnek sıra izlendi | Kullanıcı canlı test edip yön verdi |
| Persistent runtime = LaunchAgent (§12) | **On-demand daemon** (`uncoil-runtimed`, pakete gömülü; app soketi bulamayınca spawn eder, setsid ile app'ten bağımsız yaşar) | LaunchAgent kaydı (SMAppService + Login Items onayı) v1 için gereksiz sürtünme; daemon çökerse PTY'ler zaten ölür, launchd restart değer katmıyor. SMAppService sonradan eklenebilir |

## Yapıldı ✅

### Çekirdek
- **Proje/oturum modeli + kalıcılık** — `projects.json` / `sessions.json` (App Support/Uncoil), atomik yazma
- **Terminal altyapısı** — oturum başına PTY (SwiftTerm), agent `exec` ile doğrudan başlar (komut görünmez), PTY ortamına HOME/PATH düzeltmesi, ölen oturum seçilince otomatik yeniden başlar (Claude `--resume` ile geçmişiyle)
- **CLI çözümleme** — bilinen kurulum dizinleri + interaktif login shell; kaybolmuş yol otomatik yeniden çözülür
- **Claude hook köprüsü** — `uncoil-hook` helper (pakete gömülü) → Unix soket (0600) → durum indirgeyici; `~/.claude/settings.json`'a yedekli/atomik/geri-alınabilir kurulum (Ayarlar → Hooks)
- **Dürüst durum makinesi** — Hazır / Düşünüyor / Çalışıyor(araç) / İzin bekliyor / Yanıt bekliyor / Kapandı; başlıklar ilk prompt'tan otomatik

### Persistent runtime ("terminals that never die", plan §12 — v1)
- **`uncoil-runtimed`**: PTY'lerin sahibi ayrı daemon (`RuntimeHelper/`, tool target, Resources'a gömülü). App kapansa/çökse de agent süreçleri yaşar
- IPC: `App Support/Uncoil/runtime.sock` (0600) üzerinde satır-JSON protokol (`Shared/RuntimeProtocol.swift`, versiyonlu hello); her peer LOCAL_PEERCRED euid kontrolünden geçer
- Daemon: openpty + posix_spawn (SETSID + CLOEXEC_DEFAULT; slave'i fd0 açarak controlling tty), oturum başına 512 KB sınırlı replay buffer, resize/kill/attach/list/shutdown komutları
- App: `RuntimeClient` (bağlan-yoksa-spawn, bekleyen open kuyruğu) + `TerminalRegistry` daemon destekli `TerminalView`; daemon ulaşılamazsa eski in-process PTY'ye düşer. UI testlerinde determinizm için kapalı (`-runtime` arg'ı ile açılır)
- Doğrulama (2026-07-23, ekran görüntülü): gerçek uygulamada terminal oturumu başlat → komut çalıştır → uygulamadan çık (daemon + shell yaşıyor) → yeniden aç → oturuma tıkla → önceki içerik replay + aynı shell'de yeni komut çalışıyor. Daemon protokolü ayrıca soket düzeyinde uçtan uca test edildi

### MCP kontrol düzlemi (plan §16–17 — ajan işbirliği)
- **Altı MCP aracı** ajanlara sınırlı bir yüzey açar: `uncoil_projects / uncoil_sessions / uncoil_artifacts / uncoil_system / uncoil_browser / uncoil_computer`. Her oturuma pakete gömülü `uncoil-mcp` stdio sunucusu kaydedilir; app içi kontrol düzlemine `control.sock` (0600 + euid kontrolü) üzerinden satır-JSON ile ulaşır. Tel biçimleri tek yerde (`Shared/ControlProtocol.swift`), hem app hem `uncoil-mcp` derler
- **Katmanlar:** `ControlPlaneServer` → `CapabilityRouter` → saf `PolicyEngine` (izin/ilişki kararları) + `PermissionService` (yönlü kullanıcı izinleri) + handler'lar; her istek denetim günlüğüne (`audit/*.jsonl`, yalnız arg anahtarları) yazılır
- **Orkestrasyon (M5):** `create_child` ham shell KABUL ETMEZ — yalnız adlandırılmış `SessionPreset`'ler (yerleşik `claude-worker` / `codex-reviewer`); yetenekler kesişimle daraltılır (preset ∩ çağıran, asla yükseltmez), idempotency_key ile tekrar-üretim engellenir. Çocuk oturum kenar çubuğunda normal oturum gibi görünür. Çocuk koordinasyonu: `inspect_child`, `wait_for_children` (settled durum bekleme + TIMEOUT), `summarize_children` (durum + çıktı kuyruğu + artefakt sayısı), tek yönlü `report_to_parent` / `read_reports` (parent inbox.jsonl; `pending_reports` inspect'te)
- **İzin akışı:** kardeş/ilgisiz kontrol → `PERMISSION_REQUIRED`; ajan `uncoil_system request_permission` çağırır, kullanıcı **Ayarlar → İzinler**'de onaylar/reddeder/iptal eder. İzinler yönlü (A→B, C→B'yi kapsamaz), iptal edilebilir, her çağrıda yeniden kontrol edilir (önbelleksiz), bekleyenler 10 dk sonra düşer. `permissions.json` atomik yazılır
- **Sağlamlaştırma (M6):** wait'ler sokete engel olmaz (her istek ayrı `Task { @MainActor }`, `Task.sleep` aktörü serbest bırakır); `permissions.json` / `artifacts.json` write-temp-rename (`AtomicFile`)
- **Belgeler:** `docs/current/mcp/` (ARCHITECTURE / CAPABILITIES / PERMISSIONS / ARTIFACTS / SECURITY / TROUBLESHOOTING). Test: socket'siz birim paketi (`UncoilTests`), toplam 169 test yeşil; altı MCP aracı gerçek kontrol soketi üzerinden kabul testinden geçti

### Çoklu hesap
- Profil başına izole config kökü: `CLAUDE_CONFIG_DIR` / `CODEX_HOME` (profiles/<provider>/<ad>)
- **Tarayıcıdan giriş**: profilde "Giriş Yap" → gömülü terminalde `claude /login` / `codex login`; kimlik asla Uncoil'e girmez
- Giriş tespiti: Claude `.claude.json` oauthAccount; Codex `auth.json` (JWT e-posta)

### UI (Unpeel-esinli özgün dil)
- Başlıksız pencere, tek koyu yüzey, mono tipografi, Tabler Icons webfont (5016 ikon)
- Sidebar: proje satırları (özelleştirilebilir ikon+renk+isim), hover'da agent başlatma şeridi, oturum alt satırları (AI logoları: Claude ✳ / OpenAI), pin, sürükle-sırala, proje başına ve toplu gizle/göster, ⌘B + kenar sürükleyerek boyutlandır/gizle
- **Proje panosu**: oturumlar, worktree listesi+oluşturma (`.uncoil-worktrees/<slug>`, worktree içinde agent başlatma), git durumu+commit'ler, PR paneli (GitHub), dosya ağacı
- **Oturum görünümü**: kontrol kümesi — editör (gerçek app ikonu + kurulu editör menüsü), restart, sağdan Değişiklikler paneli (dosyaya tıkla→editörde aç)
- Oturumu **ayrı pencerede** aç (paylaşılan PTY) ve **sürükle-bırak split** (yan yana iki oturum)
- **Oturum grupları** — proje altında kalıcı gruplar, gruba özel yönetim görünümü, çoklu seçim, toplu prompt/kes/restart/sil, çoklu sürükle-bırak ve toplu silme
- **Otomatik düzenleme** — proje panosundaki kısayol Claude oturumu başlatır; ajan Uncoil MCP grup araçlarıyla oturumları amaçlarına göre düzenler
- Durum orb animasyonları, özel scroll barlar, özel klasör seçici, silme onayı

### Ayarlar (kenar çubuklu + aramalı)
- Hesaplar / Varsayılanlar (editör seçimi dahil) / **CLI Araçları** (sürüm + kaynak rozeti; otomatik güncelleme kontrolü, sadece gerektiğinde Güncelle) / Parametreler (provider başına ek arg) / **Bildirimler** (durum başına tek bildirim, olay bazlı aç-kapa, öncelik, sistem sesleri, **proje bazlı override**) / **Tema** (koyu-açık preset + tüm renkler özelleştirilebilir, terminal renkleri dahil) / GitHub (**device-flow tarayıcı girişi**, token yalnız Keychain) / Hooks
- GitHub token'ı ile özel repo PR'ları
- **İzinler** — sık kullanılan izinleri anlaşılır dört grupta gösterir; proje/oturum/browser otomasyonu varsayılan açık, yalnız Computer Use zorunlu olarak kapalı ve onay gerektirir
- **Agent Browser seçimi** — yalnız makinede kurulu Chromium tabanlı tarayıcılar listelenir; Uncoil Chromium, Chrome, Arc, Edge, Brave, Vivaldi ve Chromium desteklenir
- **Provider çalışma modları** — Claude ve Codex için yeni oturumlarda kullanılacak çalışma modu Agent Ayarları'ndan seçilir; Claude Manual/Accept Edits/Plan/Auto/Dangerously Skip Permissions, Codex Ask for Approval/Approve for Me/Full Access seçeneklerini destekler

### Terminal uyumluluğu
- Runtime resize artık PTY foreground process grubuna `SIGWINCH` gönderir; Claude Code pencere boyutu değişikliklerine Codex gibi anında uyum sağlar

### Geliştirme altyapısı
- XcodeBuildMCP (build/test/launch) + Computer Use (görsel kabul ve kullanıcı akışları)
- Deterministik başlatma: `-ui-testing -reset-state -fixture demo -route -window-width/height -disable-animations` (durum `$TMPDIR/UncoilUITest`)
- Hiyerarşik accessibility kimlikleri; `UncoilUI` şemasında 4 UI testi
- Komut paletinden tek tıkla oluşturulan geçici kabul workspace'i; Swift ve JavaScript örnekleri, başarılı/başarısız/uzun/büyük çıktı/crash process fixture'ları ve izin sınıflandırmalı sahte MCP araçları
- Computer Use ile tamamlanan guided acceptance akışı; Claude/Codex session, grup ve toplu işlemler, ayrı pencere, yeniden başlatma/reconnect/replay, worktree, MCP, Browser, Computer Use izin reddi/onayı, harici process sonlandırma/recovery ve session artifact sonucu
- Codex oturumları bundled `uncoil-mcp` komutu ve oturuma özel kontrol-plane environment override'larıyla başlatılıyor; global Codex config değiştirilmiyor
- Kritik ders: AppKit pencere restorasyonu ikinci örnek varken sıfır pencereyle açtırıyordu → `ApplePersistenceIgnoreState` ile tamamen kapalı

## Kalanlar

Güncel ve öncelikli iş listesi kök dizindeki `TODO.md` belgesinde tutulur.

## Bilinen kısıtlar

- Persistent runtime v1: daemon'a ulaşılamazsa in-process PTY'ye düşülür (o durumda terminaller app ile ölür); oturumlar reboot'ta her hâlükârda ölür (kayıtlar kalır, Claude resume ile döner)
- Uygulamadan çıkmak agent'ları artık KAPATMAZ (daemon sahipleniyor) — "çıkarken kapat" tercihi henüz yok
- `UncoilUI` koşucusu fixture penceresindeki AX kimliklerini bulamıyor; aynı akış Computer Use ile doğrulanıyor ve takip işi `TODO.md` içinde
- Xcode'dan çalıştırırken DerivedData dahili diskte (Xcode ayarından `.build-cache`'e yönlendirilebilir); launch args yalnız taze süreçte etkili
