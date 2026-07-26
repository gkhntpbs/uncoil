# Uncoil — Durum ve Yol Haritası

> Son güncelleme: 2026-07-25 · Testler: 198/198 unit+entegrasyon + 8/8 UI + Computer Use kabul akışı
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
- IPC: `App Support/Uncoil/runtime.sock` (0600) üzerinde satır-JSON protokol (`Shared/RuntimeProtocol.swift`, major/minor negotiation); her peer LOCAL_PEERCRED euid kontrolünden geçer. Uyumsuz major sürüm açık kullanıcı hatası üretir
- Daemon: tek-instance dosya kilidi, openpty + posix_spawn (SETSID + CLOEXEC_DEFAULT; slave'i fd0 açarak controlling tty), oturum başına 512 KB / toplam 16 MB disk-sınırlı replay, 1 MB × 3 dönen log, child reaping/idle detection, NOFILE/core limitleri ve graceful upgrade drain
- App: `RuntimeClient` heartbeat, sınırlı exponential crash restart ve sleep/wake reconnect uygular; `TerminalRegistry` daemon destekli `TerminalView` kullanır. Daemon ulaşılamazsa eski in-process PTY'ye düşer. UI testlerinde determinizm için kapalı (`-runtime` arg'ı ile açılır)
- Doğrulama: gerçek uygulamada terminal persistence/replay akışı; gerçek `uncoil-runtimed` binary’siyle handshake, heartbeat, version mismatch, graceful upgrade, tek-instance, crash restart, child reaping, replay disk limiti, log rotation ve sleep/wake reconnect entegrasyon testleri; runtime mismatch uyarısı Computer Use kabul testi

### Uygulama lifecycle
- **Çıkış politikası** — Ayarlar → Agent Ayarları altında kalıcı “Keep sessions running” ve “Terminate all agents on quit” seçenekleri; varsayılan güvenli davranış oturumları daemon içinde yaşatır
- App termination kararı runtime kuyruğuna senkron iletilir; terminate seçimi daemon’ı ve tüm process gruplarını kapatır, keep seçimi yalnız app bağlantısını bırakır
- Runtime daemon socket başına `flock` ile tek instance kalır; ikinci daemon canlı soketi değiştiremez
- Ana pencere kapalıyken Dock/ikinci açılış olayı SwiftUI `WindowGroup` sahnesini yeniden üretir; ⌘N aynı güvenilir yolu kullanır
- Ana pencere konumu/boyutu AppKit frame autosave ile, son proje/grup/oturum seçimi geçerli kayıt kontrolüyle restore edilir; UI fixture’ları gerçek kullanıcı restorasyon durumunu değiştirmez
- Doğrulama: gerçek daemon ile iki quit-policy testi, daemon single-instance testi, 6/6 XCUITest ve Computer Use ile kapatılan `main-AppWindow-1` penceresinin `main-AppWindow-2` olarak yeniden oluşturulması

### Session sistemi
- Kapanan oturumlar exit metadata’sıyla ayrı geçmiş panelinde tutulur; yeniden açıldığında aktif listeye döner ve restart sayacı güncellenir
- Session kayıtları sürümlü `SessionDocument` içinde saklanır; eski düz dizi formatı güvenli biçimde migrate edilir, gelecekteki bilinmeyen sürümler downgrade edilmez
- Claude hook session kimliğiyle `--resume`, Codex rollout `session_meta` kimliğiyle `codex resume` kullanır; Codex eşleştirmesi hesap kökü ve tam çalışma diziniyle sınırlıdır
- Agent Ayarları altında provider, CLI argümanları, başlangıç promptu, permission modu ve capability sınırlarını düzenleyen kalıcı session preset editörü bulunur
- Terminal transcript saklama varsayılan olarak kapalıdır; 7 gün, 30 gün veya süresiz retention seçilebilir. Dosyalar 0600 izinle, ana UI thread’i dışında yazılır; hassas transcriptlerin tamamı onaylı tek işlemle silinebilir
- Doğrulama: migration, future-schema, history/restart, resume komutları, Codex metadata eşleştirmesi, preset persistence, transcript retention/prune/clear testleri; 8/8 XCUITest ve Computer Use ile history → Codex resume, dolu preset editörü ve transcript temizleme onayı

### MCP kontrol düzlemi (plan §16–17 — ajan işbirliği)
- **Altı MCP aracı** ajanlara sınırlı bir yüzey açar: `uncoil_projects / uncoil_sessions / uncoil_artifacts / uncoil_system / uncoil_browser / uncoil_computer`. Her oturuma pakete gömülü `uncoil-mcp` stdio sunucusu kaydedilir; app içi kontrol düzlemine `control.sock` (0600 + euid kontrolü) üzerinden satır-JSON ile ulaşır. Tel biçimleri tek yerde (`Shared/ControlProtocol.swift`), hem app hem `uncoil-mcp` derler
- **Katmanlar:** `ControlPlaneServer` → `CapabilityRouter` → saf `PolicyEngine` (izin/ilişki kararları) + `PermissionService` (yönlü kullanıcı izinleri) + handler'lar; her istek denetim günlüğüne (`audit/*.jsonl`, yalnız arg anahtarları) yazılır
- **Orkestrasyon (M5):** `create_child` ham shell KABUL ETMEZ — yalnız adlandırılmış `SessionPreset`'ler (yerleşik `claude-worker` / `codex-reviewer`); yetenekler kesişimle daraltılır (preset ∩ çağıran, asla yükseltmez), idempotency_key ile tekrar-üretim engellenir. Çocuk oturum kenar çubuğunda normal oturum gibi görünür. Çocuk koordinasyonu: `inspect_child`, `wait_for_children` (settled durum bekleme + TIMEOUT), `summarize_children` (durum + çıktı kuyruğu + artefakt sayısı), tek yönlü `report_to_parent` / `read_reports` (parent inbox.jsonl; `pending_reports` inspect'te)
- **İzin akışı:** kardeş/ilgisiz kontrol → `PERMISSION_REQUIRED`; ajan `uncoil_system request_permission` çağırır, kullanıcı **Ayarlar → İzinler**'de onaylar/reddeder/iptal eder. İzinler yönlü (A→B, C→B'yi kapsamaz), iptal edilebilir, her çağrıda yeniden kontrol edilir (önbelleksiz), bekleyenler 10 dk sonra düşer. `permissions.json` atomik yazılır
- **Sağlamlaştırma (M6):** wait'ler sokete engel olmaz (her istek ayrı `Task { @MainActor }`, `Task.sleep` aktörü serbest bırakır); `permissions.json` / `artifacts.json` write-temp-rename (`AtomicFile`)
- **Belgeler:** `docs/current/mcp/` (ARCHITECTURE / CAPABILITIES / PERMISSIONS / ARTIFACTS / SECURITY / TROUBLESHOOTING). `UncoilTests` paketinde 198/198 test geçti; altı MCP aracı gerçek kontrol soketi üzerinden kabul testinden geçti

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

### Ayarlar (native macOS, kategorili + aramalı)
- macOS'un kendi ayar dili: kaynak listesi + `Form(.grouped)` sayfaları, sistem fontu ve kontrolleri, yeniden boyutlanabilir pencere, dar genişlikte kontrolü etiketin altına alan satırlar. Arama sayfa başlıklarını değil **sayfa içindeki ayarları** eşler; eski derin bağlantılar (`defaults`, `transcripts`…) çözülmeye devam eder
- **Genel** (varsayılan agent, editör, çıkış davranışı, komut paleti kısayolu) · **Agentlar** (Hesaplar / CLI Araçları / Parametreler / Mod ve Klavye / Session Presetleri) · **Bildirimler** (Genel / Olaylar / Hatırlatmalar / Sessiz Saatler / Proje Bazında) · **Menü Çubuğu** · **Görünüm** · **Gizlilik ve İzinler** (İzinler / Veri ve Transcript / Durum Takibi) · **Entegrasyonlar** (GitHub / Sürücüler) · **Hakkında**
- **Bildirimler olay bazlı** — izin, girdi, tur tamamlandı, hata, görev tamamlandı, merge hazır, giriş gerekiyor: her biri kendi aç-kapa, öncelik ve sesini taşır (olay → proje → genel sırasıyla çözülür). Teslimat filtreleri: yalnız arka plandayken bildir, ekranda açık oturum için bildirme, projeye göre grupla
- **Hatırlatmalar** — kullanıcı işlem yapana kadar süren durumlar (girdi/izin bekleme, düşen giriş, merge hazır) ayarlanabilir aralık ve sayıda tekrar bildirilir; her tekrardan önce oturumun güncel durumu yeniden okunur, çözülmüş bir durum hatırlatılmaz
- **Sessiz saatler** — gece yarısını aşan aralıklar dahil; istenirse yüksek öncelikli olaylar bu aralıkta da geçer
- **Menü çubuğu ayarları** — simge biçimi (Uncoil işareti / SF Symbol / yalnız sayaç), tek renk, hangi sayaçların görüneceği (çalışan, bekleyen, sorun, görev), boştayken gizle, menüdeki bölümler; canlı önizlemeli
- GitHub token'ı ile özel repo PR'ları; arka plan Keychain okumaları etkileşimsizdir ve parola penceresi açmaz
- **İzinler** — sık kullanılan izinleri anlaşılır dört grupta gösterir; proje/oturum/browser otomasyonu varsayılan açık, yalnız Computer Use zorunlu olarak kapalı ve onay gerektirir
- **Agent Browser seçimi** — yalnız makinede kurulu Chromium tabanlı tarayıcılar listelenir; Uncoil Chromium, Chrome, Arc, Edge, Brave, Vivaldi ve Chromium desteklenir
- **Provider çalışma modları** — Claude ve Codex için yeni oturumlarda kullanılacak çalışma modu Agent Ayarları'ndan seçilir; Claude Manual/Accept Edits/Plan/Auto/Dangerously Skip Permissions, Codex Ask for Approval/Approve for Me/Full Access seçeneklerini destekler

### Terminal uyumluluğu
- Runtime resize artık PTY foreground process grubuna `SIGWINCH` gönderir; Claude Code pencere boyutu değişikliklerine Codex gibi anında uyum sağlar

### Geliştirme altyapısı
- XcodeBuildMCP (build/test/launch) + Computer Use (görsel kabul ve kullanıcı akışları)
- Deterministik başlatma: `-ui-testing -reset-state -fixture demo -route -window-width/height -disable-animations` (durum `$TMPDIR/UncoilUITest`)
- Hiyerarşik accessibility kimlikleri; `UncoilUI` şemasında 8 UI testi
- Komut paletinden tek tıkla oluşturulan geçici kabul workspace'i; Swift ve JavaScript örnekleri, başarılı/başarısız/uzun/büyük çıktı/crash process fixture'ları ve izin sınıflandırmalı sahte MCP araçları
- Computer Use ile tamamlanan guided acceptance akışı; Claude/Codex session, grup ve toplu işlemler, ayrı pencere, yeniden başlatma/reconnect/replay, worktree, MCP, Browser, Computer Use izin reddi/onayı, harici process sonlandırma/recovery ve session artifact sonucu
- Codex oturumları bundled `uncoil-mcp` komutu ve oturuma özel kontrol-plane environment override'larıyla başlatılıyor; global Codex config değiştirilmiyor
- Komut paletinden Debug Bundle export; scoped app/runtime logları, agent sürümleri, yapısal olarak sanitize edilmiş config’ler, MCP/permission/crash/acceptance/system bilgileri ve ZIP manifesti
- Debug Bundle güvenliği; terminal replay ve prompt içeriği dışlanır, JSON prompt/history/message alanları yapısal silinir, token/secret/CLI secret argümanları ile home/temp/project/dış disk yolları maskelenir
- Kritik ders: AppKit pencere restorasyonu ikinci örnek varken sıfır pencereyle açtırıyordu → native state restoration kapalı; ana scene, frame ve seçim restorasyonu uygulama tarafından deterministik yönetiliyor

## Kalanlar

Güncel ve öncelikli iş listesi kök dizindeki `TODO.md` belgesinde tutulur.

## Bilinen kısıtlar

- Persistent runtime v1: daemon'a ulaşılamazsa in-process PTY'ye düşülür (o durumda terminaller app ile ölür); oturumlar reboot'ta her hâlükârda ölür (kayıtlar kalır, Claude/Codex resume ile döner)
- Xcode'dan çalıştırırken DerivedData dahili diskte (Xcode ayarından `.build-cache`'e yönlendirilebilir); launch args yalnız taze süreçte etkili
