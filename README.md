# OpenWrt for Xiaomi BE3600 RD16 (Linux 6.18, AArch64)

**СТАТУС: ЭКСПЕРИМЕНТАЛЬНЫЙ. НЕ ПРОВЕРЕНО НА УСТРОЙСТВЕ.**

Портирование OpenWrt на Xiaomi BE3600 RD16 с ядром Linux 6.18.39 и архитектурой AArch64.

---

## Целевое устройство

- **Модель:** Xiaomi BE3600 RD16
- **SoC:** Qualcomm IPQ5332 (4× ARM Cortex-A53)
- **RAM:** 256 MiB (вывод по MemTotal около 180 MB и reserved-memory, напрямую не измерено)
- **NAND:** Winbond W25N01KWZEIG, 128 MiB, SPI-NAND через QPIC
- **Ethernet:** YT9215S 4-портовый коммутатор + DSA, 2500base-x к SoC через PPE/PCS
- **Wi-Fi 2,4 ГГц:** встроенное радио IPQ5332, ath12k AHB
- **Wi-Fi 5 ГГц:** QCN6432 через Q6 remoteproc (userPD2, hybrid bus)
- **Плата:** IPQ5332/AP-MI04.1-C2

---

## Базовая платформа

1. [fivefold3/openwrt-gl-be3600](https://github.com/fivefold3/openwrt-gl-be3600) (`e46ea77`): GL-BE3600, ядро 6.18.39, QPIC NAND, Q6, PPE/EDMA, ath12k + QCN6432.
2. [victorpivotto-cloud/openwrt-xiaomi-be3600-rd15](https://github.com/victorpivotto-cloud/openwrt-xiaomi-be3600-rd15) (`d9c8a55`): RD15, YT921x DSA, профиль Xiaomi, скрипты слотов.
3. **Слой RD16** (этот репозиторий): DTS, профиль, калибровка, конфигурация.

---

## Статус компонентов

| Компонент | Статус | Примечания |
|---|---|---|
| DTS | ✅ Компилируется `dtc` | Предупреждения косметические |
| NAND | ⚠️ Не проверено | Winbond W25N01KW. ECC 4/512 на стоке, возможно 8/512 на 6.18. Проверка только через RAM boot |
| Ethernet | ⚠️ Не проверено | PPE/EDMA/PCS из PR #23161. DSA YT9215S из RD15. Линки на стоке работают |
| Wi-Fi 2,4/5 ГГц | ⚠️ Не проверено | ath12k AHB + QCN6432 (Q6 userPD2). Firmware из стока 1.0.31 |
| Q6 remoteproc | ⚠️ Не проверено | `qcom,ipq5332-wcss-sec-pil`, reserved-memory совпадает с RD15 |
| FIT (2 конфигурации) | ⚠️ Собирается, на железе не проверен | `config@1` и `config@mi04.1-c2` ссылаются на `kernel-1` и `fdt-1`, по умолчанию `config@mi04.1-c2`. В стоковом FIT есть только `config@1`, в APPSBL есть обе строки. Какую запросит U-Boot, неизвестно |
| Сборка | ✅ Полная сборка в CI | Артефакты: initramfs `.itb`, `factory.ubi`, `sysupgrade.bin` (прогон 43891170660, около 47 минут) |
| Sysupgrade | 🚫 Отключён | `RD16_UPGRADE_ENABLED=0`, `platform.sh` отказывает с сообщением. Раскладка томов 40/133/143 LEB выбрана нами и не проверена |
| Установка | 🚫 Заблокирована | Требует UART на 1,8 В (контактная гребёнка найдена на плате, адаптер заказан) |

---

## ⚠️ Критичные предупреждения (P0)

### Без UART на 1,8 В установка опасна
- U-Boot RD16 паникует при ручном `bootm` (опыт RD15).
- RAM boot через UART — единственный безопасный способ первой проверки.
- **Адаптер на 3,3 В может повредить SoC** (уровни логики 1,8 В).
- Автооткат U-Boot не доказан.
- Зависание ядра без UART не лечится.

### ECC NAND не подтверждён на 6.18
- Сток использует ECC 4/512. RD15 на 6.18 требует 8/512.
- Ошибка ECC **необратимо портит данные**.
- Запись в NAND запрещена до первой успешной загрузки из RAM.

### Потеря калибровки и ART
- В `0:ART` лежат MAC и калибровки Wi-Fi.
- **Обязателен полный бэкап с SHA256** всех разделов до любых действий.
- Бэкап должен храниться на внешнем носителе.

### Неизвестная конфигурация FIT
- Сток RD16 содержит только `config@1`.
- RD15 запрашивает `config@mi04.1-c2`.
- В APPSBL RD16 есть строки обоих имён.
- Образ собирается с обеими, но какую выберет U-Boot, неизвестно. Покажет лог U-Boot по UART.

---

## Структура репозитория

```
.github/workflows/rd16-patch-check.yml  # CI: dtc, make target/linux/prepare
configs/xiaomi_rd16.diffconfig           # Конфигурация
scripts/
  prepare-tree-rd16.sh                   # Применение слоя RD16
  stage-vendor-firmware-rd16.sh          # Извлечение Wi-Fi blob
  rd16-fit-alt-config.sh                 # FIT с двумя конфигурациями
target/linux/qualcommbe/
  dts/ipq5332-xiaomi-rd16.dts            # Device Tree
  image/xiaomi_rd16.mk.part              # Профиль (фрагмент)
  ipq53xx/base-files/                    # Сетевая раскладка, калибровка, скрипты слотов
```

`.part` — фрагменты, вставляемые `prepare-tree-rd16.sh` в дерево OpenWrt.

---

## Быстрый старт

Сборка выполняется в CI (workflow `rd16-patch-check`). Порядок установки и условия остановки описаны в [docs/INSTALL.md](docs/INSTALL.md). Команды ниже показывают ручную сборку и не проверялись вне CI.

```sh
# Клонирование базы и патчей
git clone https://github.com/fivefold3/openwrt-gl-be3600.git openwrt
cd openwrt && git checkout e46ea77ba4f4

git clone https://github.com/victorpivotto-cloud/openwrt-xiaomi-be3600-rd15.git ../rd15
git clone https://github.com/serv4173-cloud/Xiaomi-Router-BE3600-RD16-6.18.git ../rd16

# Применение патчей
for p in ../rd15/patches/*.patch; do git apply "$p"; done
cp -r ../rd15/openwrt-tree/* .
../rd16/scripts/prepare-tree-rd16.sh .

# Конфигурация и сборка
cp ../rd16/configs/xiaomi_rd16.diffconfig .config
make defconfig
make -j$(nproc)
```

Образы: `bin/targets/qualcommbe/ipq53xx/xiaomi_rd16-uImage.itb` (RAM boot) и `*-sysupgrade.bin`.

---

## Установка

**Только с UART на 1,8 В!** Подробности в [docs/INSTALL.md](docs/INSTALL.md).

Схема слотов: сток остаётся в mtd19 (`rootfs`, `flag_boot_rootfs=0`), OpenWrt ставится в mtd20 (`rootfs_1`, `flag_boot_rootfs=1`). U-Boot и его переменные без явной необходимости не менять.

Метод 1 (рекомендуется): RAM boot через TFTP + UART (образ initramfs `.itb`), затем установка в mtd20 через `install-slot1.sh` (черновик).

Метод 2 (рискованно, не проверен): запись образа `factory.ubi` в mtd20 через `ubiformat` из стока. `sysupgrade.bin` для этого не подходит. Без UART зависание ядра не лечится.

---

## Известные ограничения

- Аппаратное ускорение (NSS/ECM): недоступно (QSDK 5.4). PPE работает как MAC/DMA, аппаратного NAT нет.
- SQM/CAKE: на CPU, производительность не измерена.
- Порядок портов проверен кабелем на стоке: 4 гнезда, все на YT9215S. Гнездо 1 (крайнее слева) = `wan`, гнёзда 2-4 = `lan1`-`lan3`.
- RAM 256 MiB выведена косвенно (MemTotal, reserved-memory), напрямую не измерена.
- Sysupgrade отключён до проверки на железе.

---

## Ссылки

- [fivefold3/openwrt-gl-be3600](https://github.com/fivefold3/openwrt-gl-be3600)
- [victorpivotto-cloud/openwrt-xiaomi-be3600-rd15](https://github.com/victorpivotto-cloud/openwrt-xiaomi-be3600-rd15)
- [OpenWrt PR #23161 (qualcommbe ipq53xx)](https://github.com/openwrt/openwrt/pull/23161)
- [RomikB/openwrt (5.4, справочник)](https://github.com/RomikB/openwrt/tree/openwrt-25-be3600)

---

## Лицензия

GPL-2.0. Wi-Fi firmware из стока Xiaomi — проприетарные.

**Отказ от ответственности:** проект экспериментальный. Автор не несёт ответственности за потерю устройства. Используйте на свой риск.
