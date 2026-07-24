# Uncoil MCP Kabul Testi

Bu akış, Uncoil içinden başlatılan bir Claude oturumunun altı MCP aracını gerçek kontrol düzlemi üzerinden sınamasını sağlar. Test, mevcut proje verilerini silmez, yeni worktree oluşturmaz, mesaj göndermez ve kalıcı tarayıcı profili kullanmaz.

## Son doğrulama

24 Temmuz 2026 tarihinde Debug uygulaması `-ui-testing -control-plane -reset-state -fixture demo` argümanlarıyla çalıştırıldı. Uygulamayla paketlenen `uncoil-mcp`, demo Claude oturumunun kimliği ve izole `control.sock` üzerinden doğrudan sınandı. Claude süreci başlatılmadı.

| Alan | Sonuç | Kanıt |
|---|---|---|
| MCP protokolü | PASS | `initialize` protokol `2025-06-18`, `tools/list` altı aracı döndürdü. |
| `uncoil_system` | PASS | `help`, `status`, `version`, `capabilities`, `doctor`, `dependencies` başarılı. Kontrol ve hook soketleri hazır; kullanılmayan runtime daemon kapalı. |
| `uncoil_projects` | PASS | Demo proje, boş worktree listesi ve `claude-worker` preset’i okundu. |
| `uncoil_sessions` | PASS | Mevcut demo oturumu, oturum listesi, çocuk listesi ve boş rapor kutusu okundu. |
| `uncoil_artifacts` | PASS | Boş liste döndü; bulunmayan artifact `INVALID_PATH` ile güvenli biçimde reddedildi. |
| `uncoil_browser` | PASS | Ephemeral oturumda `example.com` açıldı; snapshot, başlık, screenshot ve sekme listesi doğrulanıp oturum kapatıldı. |
| `uncoil_computer` | PASS | Oturuma özel Computer Use izni sonrası izinler, uygulamalar, Uncoil penceresi, AX snapshot ve pencere screenshot’ı doğrulandı. |

Toplam 40 araç eylemi PASS verdi. İlk Computer Use denemesinde beklenen `CAPABILITY_DISABLED` görüldü; izin yalnızca demo Claude oturumuna verildikten sonra aynı salt-okunur akış geçti. Yeni worktree veya çocuk oturum oluşturulmadı, mesaj gönderilmedi, kalıcı tarayıcı profili kullanılmadı ve sürücü kurulumu yapılmadı.

## Ön koşullar

- Uncoil güncel Debug derlemesiyle çalışıyor.
- Aynı bundle kimliğine sahip ikinci bir Uncoil süreci çalışmıyor.
- Test oturumu Sonnet 5 kullanıyor.
- Oturumda gerekli olduğunda şu yetkiler veriliyor:
  - `projects.read`
  - `worktrees.read`
  - `sessions.read`
  - `sessions.create_children`
  - `sessions.control_children`
  - `artifacts.read`
  - `artifacts.write`
  - `browser.use`
  - `computer.inspect`
- Cua Driver kurulu ve macOS Accessibility ile Screen Recording izinleri açık.
- `agent-browser` veya kullandığı Playwright tarayıcı binary’si kurulu değilse tarayıcı testi `BROWSER_UNAVAILABLE` sonucunu beklenen durum olarak kaydeder; otomatik kurulum yapılmaz.

## Çalıştırma hazırlığı

1. XcodeBuildMCP oturum varsayılanlarında proje, `Uncoil` scheme’i, Debug, arm64 ve `.build-cache/DerivedData` yolunu doğrula.
2. Çalışan tüm eski Uncoil örneklerini XcodeBuildMCP ile durdur.
3. Test edilmiş uygulamayı XcodeBuildMCP ile şu tam yoldan başlat:
   `.build-cache/DerivedData/Build/Products/Debug/Uncoil.app`
4. Computer Use çağrılarında uygulama adı yerine aynı tam uygulama yolunu hedefle. Böylece macOS iç diskteki eski DerivedData kopyasını açamaz.
5. Uncoil içinde yeni Claude oturumu aç ve Sonnet 5 seçimini doğrula.
6. Gerekli oturum yetkilerini Ayarlar → İzinler’den bu yeni oturuma ver.
7. Aşağıdaki Claude istemini terminal alanına girip fiziksel Return ile gönder.

## Aşamalar

1. `uncoil_system`
   - `help`, `status`, `version`, `capabilities`, `doctor`, `dependencies`
   - Kontrol soketi, runtime daemon, git, veri dizini ve bağımlılık sonuçlarını kaydet.
2. `uncoil_projects`
   - `help`, `current`, `list`, `inspect`, `list_worktrees`, `list_presets`
   - İlk preset için `inspect_preset`.
   - `create_worktree` çağırma.
3. `uncoil_sessions`
   - `help`, `current`, `list`, `inspect`, `list_children`, `read_reports`
   - Yetki varsa `claude-worker` preset’iyle tek çocuk oluştur.
   - Çocuğa yalnızca `uncoil_system status` çağırıp `report_to_parent` ile sonucu bildirmesini söyle.
   - `inspect_child`, `wait_for_children`, `summarize_children`, `read_reports` çağrılarını doğrula.
   - Çocuk hâlâ çalışıyorsa `stop` ile kapat.
4. `uncoil_artifacts`
   - `help`, `list`
   - Listede bir dosya varsa `inspect`, `resolve_path` ve metinse `read_text`.
   - Var olmayan bir adla `inspect` çağırıp güvenli hata sözleşmesini doğrula.
5. `uncoil_browser`
   - `help`, `status`
   - Motor kuruluysa yalnızca ephemeral oturum başlat; `https://example.com` aç, `snapshot`, `get title`, `screenshot`, `list_tabs`, ardından `stop`.
   - CLI veya Playwright tarayıcı binary’si kurulu değilse `BROWSER_UNAVAILABLE` durumunu beklenen sonuç olarak kaydet ve kurulum yapma.
6. `uncoil_computer`
   - Daha önce doğrulanmış kontrol eylemlerini tekrarlamadan `help`, `status`, `permissions`, `list_apps`.
   - Uncoil penceresini `inspect_window` ile bağla, `snapshot` ve `screenshot` al.
   - Bu kabul testinde tıklama, yazma ve `bring_to_front` çağırma.

## Sonuç formatı

Claude tek bir tablo üretir:

| Araç | Eylem | Sonuç | Kanıt |
|---|---|---|---|
| `uncoil_system` | `status` | PASS/FAIL/BLOCKED | Dönen temel alanlar veya hata kodu |

Sonunda toplam PASS, FAIL, BLOCKED sayılarını; beklenen bağımlılık eksiklerini; verilen izinleri; oluşturulan çocuk oturum kimliğini ve üretilen artifact yollarını listeler. Hata alan bir aşama diğer aşamaları durdurmaz.

## Claude istemi

```text
Uncoil MCP kabul testini çalıştır. Yalnızca Uncoil tarafından sağlanan uncoil_system, uncoil_projects, uncoil_sessions, uncoil_artifacts, uncoil_browser ve uncoil_computer araçlarını kullan. Her araçta önce help çağır ve dönen güncel sözleşmeye uy.

Sırasıyla:
1) uncoil_system: status, version, capabilities, doctor, dependencies.
2) uncoil_projects: current, list, inspect, list_worktrees, list_presets ve ilk preset için inspect_preset. create_worktree çağırma.
3) uncoil_sessions: current, list, inspect, list_children, read_reports. sessions.create_children ve sessions.control_children yetkileri varsa claude-worker ile yalnızca uncoil_system status çağırıp report_to_parent yapan tek çocuk oluştur; inspect_child, wait_for_children, summarize_children ve read_reports ile doğrula; çocuk çalışıyorsa stop ile kapat.
4) uncoil_artifacts: list; dosya varsa inspect, resolve_path ve metinse read_text; ayrıca var olmayan bir adı inspect ederek güvenli hata kodunu doğrula.
5) uncoil_browser: status. CLI ve Playwright tarayıcı binary’si hazırsa ephemeral_session başlat, yalnızca https://example.com aç, snapshot, get title, screenshot, list_tabs ve stop çağır. Bunlardan biri kurulu değilse BROWSER_UNAVAILABLE sonucunu beklenen BLOCKED olarak kaydet; kurulum yapma.
6) uncoil_computer: status, permissions, list_apps; com.gkhntpbs.uncoil penceresini inspect_window ile bağla, snapshot ve screenshot al. Tıklama, yazma veya bring_to_front çağırma.

İzin eksikse hangi grant_key gerektiğini açıkça yaz ve bekle. İzin verildiğinde kaldığın aşamadan devam et. Bir hata diğer aşamaları durdurmasın. Yeni worktree oluşturma, mevcut dosyaları değiştirme veya silme, mesaj gönderme, kalıcı tarayıcı profili kullanma, uzaktan kurulum çalıştırma.

Sonuçta Araç | Eylem | Sonuç | Kanıt sütunlarıyla tek tablo ve PASS/FAIL/BLOCKED toplamlarını ver. Hata kodlarını aynen koru; çocuk oturum kimliğini ve artifact yollarını listele.
```
