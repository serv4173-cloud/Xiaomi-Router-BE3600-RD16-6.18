# OpenWrt for Xiaomi BE3600 RD16 (Linux 6.18, AArch64)

**СТАТУС: ЭКСПЕРИМЕНТАЛЬНЫЙ. НЕ ПРОВЕРЕНО НА УСТРОЙСТВЕ.**

Портирование OpenWrt на Xiaomi BE3600 RD16 с ядром Linux 6.18.39 и архитектурой AArch64.

---

## Целевое устройство

- **Модель:** Xiaomi BE3600 RD16
- **SoC:** Qualcomm IPQ5332 (4× ARM Cortex-A53)
- **RAM:** предположительно 256 MiB (не подтверждено)
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
| FIT (2 конфигурации) | Не проверено | Макрос Build/fit-dual добавлен, но образ не собирался (CI делает только make target/linux/prepare). Какую конфигурацию запросит U-Boot, неизвестно |
| Сборка | ✅ `make target/linux/prepare` | Полная сборка образа не запускалась |
| Установка | 🚫 Заблокирована | Требует UART на 1,8 В |

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
- Сток RD16 содержит только `config@1` (ARM32).
- RD15 запрашивает `config@mi04.1-c2`.
- Образ собирается с обеими, но какую выберет U-Boot, неизвестно.

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

Подробная инструкция по сборке и установке пока не написана.

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

**Только с UART на 1,8 В!** Подробная инструкция пока не написана.

Метод 1 (рекомендуется): RAM boot через TFTP + UART, затем установка в mtd20 через `install-slot1.sh`.

Метод 2 (рискованно): запись в mtd20 из стока через `ubiformat`, откат на `flag_try_sys2_failed`. Не доказано.

---

## Известные ограничения

- Аппаратное ускорение (NSS/ECM): недоступно (QSDK 5.4). PPE работает как MAC/DMA, аппаратного NAT нет.
- SQM/CAKE: на CPU, производительность не измерена.
- Порядок портов: не проверен кабелями.
- RAM: объём не подтверждён.

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
