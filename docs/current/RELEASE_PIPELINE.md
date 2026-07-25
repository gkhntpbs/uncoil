# Uncoil release pipeline

`scripts/release.sh` runs the build, signing, packaging and — with credentials —
notarization and stapling. This document is the gate around it: what must be
true before it runs, and the distribution decisions behind it.

## Build inputs

- Generated project source: `project.yml`
- Scheme: `Uncoil`
- Configuration: `Release`
- Destination: `platform=macOS,arch=arm64`
- DerivedData: `.build-cache/DerivedData`
- Development team: `K3TKWWVEB9`
- Bundle identifier: `com.gkhntpbs.uncoil`

## Validation

1. Confirm the working tree is clean and the release commit is tagged.
2. Regenerate `Uncoil.xcodeproj` from `project.yml`.
3. Run the full `Uncoil` unit suite.
4. Run the `UncoilUI` smoke suite.
5. Run the MCP acceptance flow in `docs/current/mcp/ACCEPTANCE_TEST_FLOW.md`.
6. Launch the Release app and verify its main project, session, settings, light icon, and dark icon states with Computer Use.
7. Confirm `uncoil-runtimed`, `uncoil-hook`, and `uncoil-mcp` exist under `Uncoil.app/Contents/Resources`.
8. Verify the final signature and bundle identifier.

## Release build

```bash
"xcodegen" generate
xcodebuild -project Uncoil.xcodeproj -scheme Uncoil -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build-cache/DerivedData build
```

## Distribution status

Notarization, Developer ID signing, DMG packaging, update feeds, GitHub Releases, and CI workflows are not implemented. Do not publish a build until those steps have explicit credentials, automation, rollback instructions, and a successful clean-machine installation test.

The files under `docs/history/` describe a historical third-party release system. They are not commands or configuration for Uncoil.

---

Bu belge Uncoil'in dağıtım kararlarını ve nedenlerini kaydeder. Kararların
gerekçesi burada duruyor ki altı ay sonra "neden böyle?" sorusu cevapsız kalmasın.

## Pipeline

`scripts/release.sh`:

1. `xcodegen generate` — proje dosyası üretilir.
2. Debug testleri — yeşil olmadan devam etmez.
3. `MARKETING_VERSION` okunur ve `CHANGELOG.md` içinde o sürüm için bir bölüm
   aranır. Release notes olmadan release yapılmaz.
4. Release archive (hardened runtime **açık**; Debug'da kapalı, çünkü yerel
   derlemede debugger ve yardımcı süreçler entitlement turu istemesin).
5. Developer ID export, ardından imza doğrulaması. İmzada `runtime` flag'i
   yoksa script durur: notarization o build'i reddeder.
6. Yardımcı binary'ler (`uncoil-mcp`, `uncoil-hook`, `uncoil-extension`,
   `uncoil-runtimed`) tek tek doğrulanır.
7. `ditto` ile zip + SHA-256.
8. `--notarize` verildiğinde `notarytool submit --wait` ve `stapler staple`.

Notarization kimlik bilgisi gerektirir (`xcrun notarytool store-credentials`,
sonra `NOTARY_PROFILE`). Script kimlik bilgisi yoksa tahmin etmez, durur.

Signing team: `K3TKWWVEB9` (Apple Development: Alparslan Topbas), bundle id
`com.gkhntpbs.uncoil`.

## Güncelleme mekanizması kararı

**Karar: Sparkle yok; GitHub Releases + elle indirme.**

Neden:

- Uncoil'in bağımlılık politikası "sıfır yeni bağımlılık" (`CLAUDE.md`).
  Sparkle MIT olsa da imzalı appcast, EdDSA anahtar yönetimi ve kendi
  güncelleyici sürecini beraberinde getirir.
- Uncoil zaten agent CLI'larını ve extension'ları güncelliyor. Uygulamanın
  kendisini de sessizce güncelleyen bir mekanizma, "hiçbir şey benim
  onayım olmadan olmaz" kuralıyla çelişir.
- Sürüm kontrolü ucuz: `uncoil_system` zaten sürüm bildiriyor; yeni sürüm
  duyurusu GitHub Releases üzerinden okunabilir ve indirme kullanıcının
  tıklamasıyla olur.

Bu karar bir kapı kapatmıyor: ihtiyaç netleşirse imzalı appcast eklenebilir.

## App update rollback politikası

Uncoil kendini downgrade etmez. Politika:

- Her release zip'i ve SHA-256'sı GitHub Releases'te durur; geri dönüş
  "önceki zip'i indir ve `/Applications` içindekiyle değiştir" adımıdır.
- Uygulama verisi şema sürümlüdür (`UncoilSchema`). Yeni sürüm okuyabildiği
  eski şemayı ileriye taşır; **eski sürüm yeni şemayı reddeder**, yarım
  okumaz. Bu yüzden downgrade sonrası veri kaybı değil, açık bir
  "bu dosya bu sürümden yeni" mesajı görülür.
- Downgrade planlıyorsan önce `BackupService` ile yedek al: geri yükleme
  şemayı doğrular ve hangi extension'ın hangi commit'ten yeniden
  kurulabileceğini söyler.

## Runtime daemon güncellemesi

`uncoil-runtimed` uygulama paketinin içinde gelir, ayrı kurulmaz.

- Protokol sürümü uygulama ile daemon arasında el sıkışmada karşılaştırılır
  (`RuntimeProtocol.version` / `minor`). Uyumsuzsa uygulama oturumları kendi
  içindeki PTY ile sürdürür ve Attention Center'da uyumsuzluğu bildirir.
- Uygulama güncellendiğinde eski daemon çalışmaya devam edebilir: yeni
  uygulama uyumsuzluğu görür, kullanıcıya daemon'ı yeniden başlatmasını
  söyler. Daemon çalışan agent'ları taşıdığı için **kendiliğinden
  öldürülmez**; bu kullanıcının kararı.
- Daemon tek örnek `flock` ile garanti edilir; iki sürümün aynı socket'i
  paylaşması mümkün değil.

## SMAppService kararı

**Karar: gerekmiyor.**

- Daemon uygulama tarafından ihtiyaç anında başlatılır ve uygulama kapandıktan
  sonra da yaşar; agent'ların uygulama kapalıyken çalışması bunu gerektiriyor.
- `SMAppService` (login item) daemon'ı kullanıcı oturum açtığında başlatırdı.
  Uncoil'in ihtiyacı bu değil: agent yoksa çalışan bir daemon da gereksizdir.
- Login item eklemek ayrıca kullanıcıdan ayrı bir onay ve bir sistem ayarı
  penceresi ister — çalıştırılacak bir iş yokken bunu istemek yanlış olur.

Bu karar da geri alınabilir: zamanlanmış Bumblebee taramaları uygulama kapalıyken
çalışacaksa `SMAppService` yeniden değerlendirilir.

## Kaldırma (uninstall)

`UninstallService` ne silineceğini önce **listeler**. Kural: Uncoil'in
oluşturduğu silinir, kullanıcının kendi dosyası kalır.

Silinenler:

- `~/Library/Application Support/Uncoil` içindeki Uncoil verisi
  (projeler, oturumlar, ayarlar, preset'ler, permission kararları, audit log,
  transcript'ler, TODO yedekleri).
- Extension store'un mirror, revision, lock ve scan dizinleri.
- Agent skill dizinlerinde **Uncoil'in kurduğu** symlink'ler.
- `~/.agents/.skill-lock.json` (Uncoil'in ürettiği dosya).

Silinmeyenler:

- Kullanıcının elle yazdığı skill klasörleri ve başkasının symlink'leri.
- Agent config dosyaları (`~/.claude.json`, `~/.codex/config.toml`,
  `~/.gemini/settings.json`, `~/.cursor/mcp.json`,
  `~/.config/amp/settings.json`). Uncoil'in eklediği MCP kayıtları
  kaldırılmak isteniyorsa Extensions ekranından, plan gösterilerek yapılır.
- Keychain'deki secret'lar: kullanıcının kendi verisi.

## Gizlilik ve telemetri

**Uncoil hiçbir telemetri veya çökme raporunu ağ üzerinden göndermez.**

- Analitik, kullanım sayacı, "crash ping" yok.
- Ağa çıkan tek şeyler kullanıcının kendi istediği işlerdir: agent CLI'larının
  kendi bağlantıları, `git fetch`, ve kullanıcının eklediği remote MCP
  sunucularına yapılan sağlık kontrolü.
- Çökme raporlama (`CrashReportingPolicy`) **varsayılan kapalı** ve açıldığında
  bile yalnızca yereldeki çökme günlüklerini Uncoil'in debug paketine
  toplar. Paketi paylaşmak kullanıcının kararı.
- Secret değerleri config, diff, log, export ve yedeklerde görünmez; yalnızca
  anahtar **adları** taşınır (`ExtensionsAcceptanceTests` bunu doğruluyor).
