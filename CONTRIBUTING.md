# Contributing to Bremorph · المساهمة في Bremorph

**English** · [العربية](#العربية)

Thanks for helping make Bremorph better.

## Getting started

1. Install Apple's Command Line Tools: `xcode-select --install`.
2. Clone the repo and run `./build.command`. It builds, installs to `~/Applications` and opens the app.
3. Optional helpers (ffmpeg, LibreOffice, webp) unlock more formats: `./install-tools.command`.

## Before you open a pull request

- Build with `./build.command` and make sure it ends with `BUILD_OK`.
- If you touched a converter, run `./test.command` (it needs a `CLI Tests/` folder with sample files).
- Keep everything on-device. Bremorph has no network code, and pull requests that upload files won't be merged.
- Any new interface text must be translatable:
  - SwiftUI literals such as `Text("Done")` are picked up automatically.
  - Any other text goes through `L("…")`, or `LF("… %@ …", value)` when it has values in it.
  - Then run `python3 l10n/extract.py` and add the Arabic in `l10n/ar.json`. If you can't translate it, say so in the pull request and someone else will.
- Check the layout in Arabic (Settings → General → Language → العربية) so nothing breaks right-to-left.

## Adding a language

1. Copy `l10n/ar.json` to `l10n/<code>.json` (for example `fr.json`) and translate the values.
2. Write the `"plurals"` forms for your language's plural rules (`one`, `few`, `many`, `other`…).
3. Add the code to `CFBundleLocalizations` in `Info.plist` and to `AppLanguage` in `Sources/Localization.swift`.
4. Run `python3 l10n/extract.py --build`, then `./build.command`.

## Reporting bugs

Open an issue with your macOS version, the file type, what you did, and what happened. Please don't attach private files. A small sample that shows the problem is perfect.

---

<div dir="rtl">

## العربية

شكرًا لمساعدتك في تحسين Bremorph.

### البداية

1. ثبّت أدوات سطر الأوامر من Apple: `xcode-select --install`.
2. انسخ المستودع وشغّل `./build.command`، فيُبنى التطبيق ويُثبَّت في `~/Applications` ثم يُفتح.
3. الأدوات المساعدة الاختيارية (ffmpeg وLibreOffice وwebp) تضيف صيغًا أخرى: `./install-tools.command`.

### قبل فتح طلب دمج

- ابنِ التطبيق بـ `./build.command` وتأكد أنه ينتهي بـ `BUILD_OK`.
- إذا عدّلت أحد المحوّلات، شغّل `./test.command` (يحتاج مجلد `CLI Tests/` فيه ملفات عينة).
- أبقِ كل شيء على الجهاز. لا يحتوي Bremorph على أي شيفرة اتصال بالشبكة، ولن تُقبل طلبات الدمج التي ترفع الملفات.
- يجب أن يكون أي نص جديد في الواجهة قابلًا للترجمة:
  - نصوص SwiftUI مثل `Text("Done")` تُلتقط تلقائيًا.
  - أي نص آخر يمر عبر `L("…")`، أو عبر `LF("… %@ …", value)` إذا كان يحتوي على قيم.
  - بعدها شغّل `python3 l10n/extract.py` وأضف الترجمة العربية في `l10n/ar.json`. إذا لم تستطع الترجمة فاذكر ذلك في طلب الدمج وسيترجمها أحد غيرك.
- افحص الواجهة بالعربية (الإعدادات ← عام ← اللغة ← العربية) حتى لا يختل شيء في الاتجاه من اليمين إلى اليسار.

### إضافة لغة جديدة

1. انسخ `l10n/ar.json` إلى `l10n/<الرمز>.json` (مثل `fr.json`) وترجم القيم.
2. اكتب صيغ `"plurals"` وفق قواعد الجمع في لغتك (`one` و`few` و`many` و`other`…).
3. أضف رمز اللغة إلى `CFBundleLocalizations` في `Info.plist` وإلى `AppLanguage` في `Sources/Localization.swift`.
4. شغّل `python3 l10n/extract.py --build` ثم `./build.command`.

### الإبلاغ عن مشكلة

افتح بلاغًا يتضمن إصدار macOS ونوع الملف وما فعلته وما حدث. من فضلك لا ترفق ملفات خاصة. تكفي عينة صغيرة تُظهر المشكلة.

</div>
