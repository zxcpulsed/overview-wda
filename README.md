# OverView WDA

WebDriverAgent (appium) с дополнительными командами для OverView Uploader:
сохранение креативов в альбом «OverView» и очистка этого альбома через PhotoKit.

- `POST /overview/auth` — запросить доступ к фото
- `POST /overview/import {"name": "file.mp4"}` — импорт файла из `Documents` контейнера WDA в альбом
- `POST /overview/clean` — удалить содержимое альбома из медиатеки (с системным подтверждением)
- `GET /overview/status` — состояние и итог последней операции

## Сборка
Actions → **Build** → **Run workflow**. Через 10–15 минут в разделе Artifacts появится `OverView-WDA.ipa`.
Ставится через Sideloadly вместо обычного WDA.
