# Codex app-server entegrasyonu

> **Durum: opt-in.** Codex oturumları varsayılan olarak Codex CLI'sini bir PTY'de
> çalıştırır — Claude oturumlarının kendi CLI'sini çalıştırdığı gibi. App-server
> yolu JSON konuşur, yani prompt'u, geçmişi ve satır düzenlemeyi CLI'nin kendi
> TUI'si yerine Uncoil'in sağlaması gerekir; bunlar olmadan oturum boş bir
> imleçle açılıyordu. Protokol istemcisi silinmedi: yapılandırılmış onaylar ve
> turn durumu bunun üzerine kurulu ve testleri duruyor. Açmak için
> `-codex-app-server` argümanı (`LaunchConfig.codexAppServerEnabled`).

Uncoil'in `codex app-server` protokol entegrasyonu bu argümanla devreye girer. İnteraktif Codex PTY yolu varsayılandır; app-server açıkken de uyumluluk ve çalışma zamanı fallback'i olarak korunur.

## Protokol eşlemesi

- Doğrulanan Codex CLI: `codex-cli 0.145.0`
- Resmi JSON schema üretimi: `codex app-server generate-json-schema`
- Uncoil schema eşlemesi: `CodexAppServerCompatibility.schemaVersion`
- Desteklenen aralık: `0.145.x`
- Transport: session başına kullanıcıya özel Unix socket üzerinde WebSocket
- Mesaj biçimi: WebSocket text frame başına bir JSON-RPC-benzeri mesaj; `jsonrpc` alanı kullanılmaz
- Handshake: `initialize` isteği, ardından `initialized` bildirimi

Desteklenmeyen sürüm, başarısız handshake, process başlangıç hatası veya bozuk socket açık bir uyumluluk mesajı üretir ve aynı session mevcut PTY yoluna geçirilir. Provider veya preset için structured protokole çevrilemeyen ek CLI argümanları varsa session doğrudan PTY ile başlatılır.

## Yaşam döngüsü

Her Codex session şu dizini kullanır:

```text
<Uncoil data>/cas/<session-prefix>/
├── s.sock
├── server.pid
└── server.log
```

App-server `0600` socket’in bulunduğu `0700` dizinde çalışır. Uncoil WebSocket bağlantısını kapatsa bile “Keep sessions running” tercihinde server yaşamaya devam eder. Uygulama yeniden açıldığında aynı socket’e bağlanır ve kalıcı thread kimliğiyle `thread/resume` çağırır. Session açıkça kapatılırsa veya “Terminate all agents on quit” seçiliyse PID doğrulanarak server sonlandırılır.

Stale socket bağlantısı bir kez temiz başlangıçla onarılır. İkinci hata fallback’i tetikler; sonsuz restart döngüsü oluşturulmaz.

## Thread ve turn akışı

Yeni session:

1. `account/read`
2. `thread/start`
3. Dönen `thread.id` değerini `SessionRecord.providerSessionID` alanına atomik olarak kaydet
4. Kullanıcı girdisinde `turn/start`

Devam eden session:

1. `account/read`
2. `thread/resume`
3. `initialTurnsPage` ile son 50 turn’ü tam item görünümünde al
4. Structured history’yi terminal yüzeyine render et

Ctrl-C, aktif turn kimliği varsa `turn/interrupt` çağırır.

## Domain event eşlemesi

| App-server olayı | Uncoil davranışı |
|---|---|
| `thread/status/changed` | Session durumunu running, idle veya error’a eşler |
| `turn/started` | `thinking` |
| `turn/completed` | `completed`; başarısız turn için hata detayı |
| `item/agentMessage/delta` | Agent metnini streaming render eder |
| `item/commandExecution/outputDelta` | Komut çıktısını streaming render eder |
| `item/started` | Reasoning, command, file change, MCP ve tool state’ini structured olarak gösterir |
| `item/completed` | Son item sonucunu tamamlar; streaming metni yinelenmez |
| `account/updated` | Authentication metadata’sını yeniler |

Terminal metni status veya tool türü çıkarmak için parse edilmez. Terminal yalnız structured event’lerin görünür çıktısı ve kullanıcı girişi için kullanılır.

## Onaylar

Desteklenen server request’leri:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`

Session ekranı isteğin başlığını, nedenini ve sunucunun bildirdiği kararları gösterir. Komut ve dosya kararları `accept`, `acceptForSession` veya `decline` olarak yanıtlanır. Permissions isteğinde yalnız istenen permission profili geri gönderilir; reddetme boş permission profili kullanır. Onay beklerken session `waitingForPermission` durumundadır.

## Authentication

Uncoil `account/read` çağrısında token yenilemesi istemez ve yalnız hesap metadata’sını tutar. Raw token uygulama modeline veya loglara girmez.

- Hesap varsa `authenticated`
- `requiresOpenaiAuth` true ve hesap yoksa `required`
- Protokol hatasında `error`

Giriş gereksinimi session ekranında görünür. Login işlemi Codex’in resmi login akışında yapılır.

## Fallback sınırı

PTY fallback şu durumlarda kullanılır:

- Codex binary bulunamaz
- Codex sürümü kaydedilmiş schema aralığıyla uyumsuzdur
- Unix socket veya WebSocket handshake başarısızdır
- Initialize/thread start/resume başarısızdır
- Session preset’i veya provider ayarı çevrilemeyen ek CLI argümanı içerir
- UI test açıkça app-server fixture’ına opt-in etmez

Fallback, mevcut runtime daemon ve in-process terminal yollarını değiştirmez.

## Doğrulama

Deterministik test kapsamı:

- Response, notification ve server request envelope decode
- JSON request/response framing
- Codex sürüm/schema uyumluluğu
- Structured history ve resume page render
- Command ve MCP tool render
- Ardışık, parçalı ve extended-length WebSocket frame decode
- UI approval panelinin üç karar yolu
- PTY fallback

Manuel kabul:

```text
-ui-testing -reset-state -fixture demo -route project
-window-width 1100 -window-height 720 -disable-animations
-runtime -codex-app-server
```

Computer Use ile AX ağacı her state değişiminden sonra yeniden okunur. SwiftTerm içeriği AX sunmadığı için terminalin görsel çıktısı window screenshot ile, session state’i `session.container` üzerinden doğrulanır.
