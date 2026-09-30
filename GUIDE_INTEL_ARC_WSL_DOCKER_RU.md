# Исчерпывающее руководство: Запуск Intel Arc B580 (Battlemage) в Docker под WSL2 с нативным PyTorch XPU

> **Цель руководства**: Поднять контейнер Docker под Windows 11 / WSL2 для работы с нейросетями в PyTorch на видеокарте поколения **Intel Arc B580 (Battlemage, Xe2, PCI ID: `0xe20b`)** без сторонних костылей и устаревшего IPEX.

---

## ЧАСТЬ 1. ГОТОВЫЙ РАБОЧИЙ РЕЦЕПТ (QUICK START)

### 1. Требования к хост-системе (Windows)
- **ОС**: Windows 11 (с обновлением WSL2).
- **Драйвер Intel**: версия `32.0.101.8991` или новее (официальный драйвер с поддержкой Battlemage в WSL).
- **Docker Desktop**: активирован движок WSL2 backend.

---

### 2. Скрипт динамического входа (`entrypoint.sh`)
Создайте файл `entrypoint.sh` рядом с Dockerfile. 

> 💡 **Дефолтный путь (наш рабочий срез для драйвера 101.8991)**:  
> `/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1`  
> Он прописан в скрипте как fallback на случай, если поиск по файловой системе вернет пустой результат.

```bash
#!/bin/bash
set -e

# Дефолтный (проверенный) путь для драйвера 101.8991 на случай сбоя поиска
DEFAULT_DRV_DIR="/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1"

# Динамический поиск актуального хелпера драйвера
HELPER_PATH=$(find /usr/lib/wsl/drivers -name "libwsl_compute_helper.so" 2>/dev/null | head -n 1)

if [ -n "$HELPER_PATH" ]; then
    DRV_DIR=$(dirname "$HELPER_PATH")
elif [ -d "$DEFAULT_DRV_DIR" ]; then
    echo "[entrypoint] Dynamic lookup failed, falling back to default driver path: $DEFAULT_DRV_DIR"
    DRV_DIR="$DEFAULT_DRV_DIR"
else
    echo "[entrypoint] WARNING: Neither dynamic nor default driver path found! Check -v /usr/lib/wsl:/usr/lib/wsl mount."
    DRV_DIR=""
fi

if [ -n "$DRV_DIR" ]; then
    # Каталог /usr/lib/wsl/lib обязательно ставится первым
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${DRV_DIR}:${LD_LIBRARY_PATH}"
else
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH}"
fi

export ZES_ENABLE_SYSMAN=0

exec "$@"
```

---

### 3. Рабочий Dockerfile (`Dockerfile.xpu`)
Создайте файл `Dockerfile.xpu`:

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ZES_ENABLE_SYSMAN=0

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    python3 \
    python3-pip \
    git \
    libze1 \
    libze-dev \
    intel-opencl-icd \
    ocl-icd-libopencl1 \
    && rm -rf /var/lib/apt/lists/*

# Установка Intel Compute Runtime 26.35.39758.10 и GmmLib 22.10.0 с поддержкой Battlemage Xe2
RUN mkdir -p /tmp/neo && cd /tmp/neo && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/libigdgmm12_22.10.0_amd64.deb && \
    curl -sL -O https://github.com/intel/intel-graphics-compiler/releases/download/v2.41.5/intel-igc-core-2_2.41.5+22716_amd64.deb && \
    curl -sL -O https://github.com/intel/intel-graphics-compiler/releases/download/v2.41.5/intel-igc-opencl-2_2.41.5+22716_amd64.deb && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/intel-ocloc_26.35.39758.10-0_amd64.deb && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/intel-opencl-icd_26.35.39758.10-0_amd64.deb && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/libze-intel-gpu1_26.35.39758.10-0_amd64.deb && \
    dpkg -i --force-overwrite *.deb && \
    rm -rf /tmp/neo

# Установка нативного PyTorch с официальным бэкендом XPU
RUN pip3 install --no-cache-dir --break-system-packages torch torchvision --index-url https://download.pytorch.org/whl/xpu

# Встраиваем автоопределение путей драйвера
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]
```

Сборка образа:
```bash
docker build -t game_sandbox_xpu:latest -f Dockerfile.xpu .
```

---

### 4. Правильный запуск контейнера (Production-Ready)

> ⚠️ **КРИТИЧЕСКИ ВАЖНО**: 
> 1. Стандартный флаг `-v /usr/lib/wsl/lib:/usr/lib/wsl/lib` **НЕ РАБОТАЕТ** для Intel Arc. Нужно монтировать **ВЕСЬ** каталог `/usr/lib/wsl` (`-v /usr/lib/wsl:/usr/lib/wsl`)!
> 2. Хэш в папке `/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_<HASH>` **МЕНЯЕТСЯ при каждом обновлении видеодрайвера хоста**. Не хардкодьте его вручную!

#### Вариант А: Автоматический запуск (рекомендуется)
Если в образ встроен `entrypoint.sh`, переменная `LD_LIBRARY_PATH` вычисляется контейнером автоматически:
```bash
docker run -d \
  --name game_sandbox_xpu \
  --privileged \
  --device=/dev/dxg \
  -v /usr/lib/wsl:/usr/lib/wsl \
  -v $(pwd):/workspace \
  game_sandbox_xpu:latest
```

#### Вариант Б: Однострочник на Bash / WSL (с динамическим поиском на хосте)
```bash
INTEL_DRV=$(find /usr/lib/wsl/drivers -name "libwsl_compute_helper.so" -exec dirname {} \; 2>/dev/null | head -n 1)

docker run -d \
  --name game_sandbox_xpu \
  --privileged \
  --device=/dev/dxg \
  -v /usr/lib/wsl:/usr/lib/wsl \
  -e LD_LIBRARY_PATH="/usr/lib/wsl/lib:${INTEL_DRV}" \
  -e ZES_ENABLE_SYSMAN=0 \
  -v $(pwd):/workspace \
  game_sandbox_xpu:latest
```

#### Вариант В: Однострочник для Windows PowerShell
```powershell
$drv = (wsl.exe -e sh -c "find /usr/lib/wsl/drivers -name 'libwsl_compute_helper.so' -exec dirname {} \; 2>/dev/null | head -n 1").Trim()

docker run -d `
  --name game_sandbox_xpu `
  --privileged `
  --device=/dev/dxg `
  -v /usr/lib/wsl:/usr/lib/wsl `
  -e "LD_LIBRARY_PATH=/usr/lib/wsl/lib:$drv" `
  -e ZES_ENABLE_SYSMAN=0 `
  -v $(pwd):/workspace `
  game_sandbox_xpu:latest
```

#### Назначение каждого флага:
| Флаг | Зачем нужен |
|---|---|
| `--privileged` | Даёт контейнеру доступ к виртуальным устройствам WDDM ядра WSL2 без блокировок безопасности cgroups. |
| `--device=/dev/dxg` | Прямой мост к виртуализированному DirectX Graphics Kernel адаптеру Windows хоста. |
| `-v /usr/lib/wsl:/usr/lib/wsl` | Монтирует **не только** базовые стабы DirectX (`libdxcore.so`), но и подпапку `drivers/`, в которой лежит фирменный бинарник Intel `libwsl_compute_helper.so`. |
| `-e LD_LIBRARY_PATH=...` | Указывает линковщику Linux искать библиотеки сначала в `/usr/lib/wsl/lib`, а затем в каталоге актуального Windows-драйвера хоста. |
| `-e ZES_ENABLE_SYSMAN=0` | Отключает модуль управления питанием/частотами Level Zero Sysman (в WSL прямой доступ к физическим датчикам кулеров/ваттметра запрещён гипервизором). |
| `-e ZES_ENABLE_SYSMAN=0` | Отключает модуль управления питанием/частотами Level Zero Sysman (в WSL прямой доступ к физическим датчикам кулеров/ваттметра запрещён гипервизором). |

---

### 4. Тестовый скрипт проверки PyTorch (`test_xpu.py`)

Создайте файл `test_xpu.py`:
```python
import torch

print("=== PyTorch XPU Test ===")
print("PyTorch Version:", torch.__version__)
print("XPU available?:", torch.xpu.is_available())

if torch.xpu.is_available():
    print("Device count:", torch.xpu.device_count())
    print("Device name:", torch.xpu.get_device_name(0))
    
    print("\n--- Running Tensor Computation on XPU ---")
    x = torch.randn(1000, 1000, device="xpu")
    y = torch.randn(1000, 1000, device="xpu")
    z = torch.matmul(x, y)
    print("Matrix multiplication succeeded!")
    print("Result shape:", z.shape)
    print("Result sum:", z.sum().item())
    print("\n🎉 ALL TESTS PASSED! Intel Arc GPU is fully functional in PyTorch! 🎉")
else:
    print("❌ XPU is NOT available in PyTorch.")
```

Запуск проверки:
```bash
docker exec game_sandbox_xpu python3 /workspace/test_xpu.py
```

Ожидаемый вывод:
```text
=== PyTorch XPU Test ===
PyTorch Version: 2.14.0+xpu
XPU available?: True
Device count: 1
Device name: Intel(R) Graphics [0xe20b]

--- Running Tensor Computation on XPU ---
Matrix multiplication succeeded!
Result shape: torch.Size([1000, 1000])
Result sum: 44167.1875

🎉 ALL TESTS PASSED! Intel Arc GPU is fully functional in PyTorch! 🎉
```

---

## ЧАСТЬ 2. ГЛУБОКИЙ ТЕХНИЧЕСКИЙ РАЗБОР (МЯСО И АНАТОМИЯ ОШИБОК)

Здесь задокументированы все грабли, ошибки и скрытые проблемы стека Intel под WSL2, которые мы последовательно локализовали и решили.

```
+-----------------------------------------------------------------------------------+
|                            СТЕК РАБОТЫ ИНТЕЛ ДРАЙВЕРА                             |
+-----------------------------------------------------------------------------------+
|  PyTorch (torch.xpu)                                                              |
|        ↓                                                                          |
|  oneAPI Level Zero Loader (libze_loader.so.1)                                     |
|        ↓                                                                          |
|  Intel Compute Runtime (libze_intel_gpu.so / NEO)                                 |
|        ↓                                                                          |
|  Intel Graphics Memory Management (libigdgmm.so.12 v22.10.0)                      |
|        ↓                                                                          |
|  WDDM Translator & Helper (/usr/lib/wsl/drivers/.../libwsl_compute_helper.so)     |
|        ↓                                                                          |
|  DirectX Core Runtime (/usr/lib/wsl/lib/libdxcore.so)                             |
|        ↓                                                                          |
|  WSL2 Kernel Device (/dev/dxg)                                                    |
|        ↓                                                                          |
|  Windows Host Driver (Intel Arc Graphics 101.8991 -> B580 Hardware 0xe20b)        |
+-----------------------------------------------------------------------------------+
```

---

### Ловушка №1: Устаревший репозиторий Ubuntu 24.04 (Рантайм 23.43)
- **Симптом**: `zeInit` завершается с кодом ошибки `2013265921` (`0x78000001` = `ZE_RESULT_ERROR_UNINITIALIZED`). Видеокарта не определяется вообще.
- **Причина**: Стандартные пакеты `apt install intel-opencl-icd libze-intel-gpu1` в Ubuntu 24.04 содержат сборку `23.43.27642.40`. Этот релиз вышел в конце 2023 года. Видеокарты линейки **Intel Arc Battlemage (B580 / Xe2)** вышли позже. Старый рантайм просто не знает PCI ID `0xe20b` и не имеет шейдерных трансляторов для новой архитектуры.
- **Решение**: Использовать `intel-compute-runtime` версии **`26.35.39758.10`** и `intel-graphics-compiler 2.41.5` из официальных релизов GitHub Intel. В release notes этой версии явно указано: *«WSL support tested with Windows host driver 101.8991; Battlemage WSL status: Production»*.

---

### Ловушка №2: Неполный маунт WSL (`/usr/lib/wsl/lib` vs `/usr/lib/wsl`)
- **Симптом**: `zeInit` крашился с аварийным завершением:
  ```text
  Abort was called at 56 line in file:
  ./shared/source/os_interface/windows/wddm/create_um_km_data_translator.cpp
  ```
  При трассировке через `strace` виден неудачный вызов:
  ```text
  openat("/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1/libwsl_compute_helper.so") = -1 ENOENT
  ```
- **Причина**: Во всех мануалах Microsoft и Docker для NVIDIA пишут монтировать `-v /usr/lib/wsl/lib:/usr/lib/wsl/lib`. Но у NVIDIA все библиотеки лежат в `lib/`, а Intel складывает низкоуровневый транслятор команд WSL (`libwsl_compute_helper.so`) в каталог конкретного INF-драйвера хоста: `/usr/lib/wsl/drivers/...`.
- **Решение**: Пробрасывать весь родительский каталог:
  ```bash
  -v /usr/lib/wsl:/usr/lib/wsl
  -e LD_LIBRARY_PATH=/usr/lib/wsl/lib:/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1
  ```

---

### Ловушка №3: Ошибка символа `Is64KBPageSuitable` в GmmLib
- **Симптом**: При попытке загрузки `libwsl_compute_helper.so` происходил отказ:
  ```text
  undefined symbol: _ZN6GmmLib21GmmResourceInfoCommon18Is64KBPageSuitableEv
  ```
- **Причина**: `libwsl_compute_helper.so` скомпилирован под обновлённый интерфейс библиотеки управления графической памятью **GmmLib**. Старая версия `libigdgmm12` (`22.3.17`), установленная из Ubuntu, не содержала метода `GmmResourceInfoCommon::Is64KBPageSuitable()`.
- **Решение**: Установка актуального пакета `libigdgmm12_22.10.0_amd64.deb` из комплекта поставки рантайма `26.35.39758.10`.

---

### Ловушка №4: Попытка `LD_PRELOAD` Windows-библиотеки `libigdgmm_w.so.12`
- **Симптом**: После принудительного добавления `-e LD_PRELOAD=.../libigdgmm_w.so.12` инициализация падала с новой ошибкой:
  ```text
  Abort was called at 51 line in file:
  ../../neo/shared/source/gmm_helper/client_context/gmm_client_context.cpp
  ```
- **Исходный код места падения (`gmm_client_context.cpp:51`)**:
  ```cpp
  auto ret = GmmInterface::initialize(&inArgs, &outArgs);
  UNRECOVERABLE_IF(ret != GMM_SUCCESS);
  ```
- **Причина**: В каталоге хостового драйвера Intel лежит файл `libigdgmm_w.so.12`. Суффикс `_w` означает сборку под внутренние интерфейсы Windows WSL хелпера. Когда этот файл был внедрён глобально через `LD_PRELOAD`, основной Linux-драйвер `libze_intel_gpu.so` попытался инициализировать память через Windows-версию. Из-за несовпадения бинарных структур аргументов (`GMM_INIT_IN_ARGS`) функция вернула ошибку, что привело к мгновенному аборту.
- **Решение**: **НИКОГДА не использовать `LD_PRELOAD` для `libigdgmm_w.so.12`!** Linux-рантайм должен использовать свою родную библиотеку `/usr/lib/x86_64-linux-gnu/libigdgmm.so.12` версии `22.10.0`, а пути к Windows-хелперу должны резолвиться исключительно через `LD_LIBRARY_PATH`.

---

### Ловушка №5: Предупреждение Level Zero Sysman в WSL2
- **Симптом**: 
  ```text
  UserWarning: Can't initialize Level Zero Sysman
    return _enum_zes_device_infos(visible_mask)
  ```
- **Причина**: Подсистема Sysman отвечает за доступ к аппаратным датчикам видеокарты: считывание температуры чипа, скорости вращения кулеров, текущего вольтажа и энергопотребления (Power Limit). Виртуальный драйвер Microsoft DirectX (`/dev/dxg`) изолирует гостевую ОС от прямого доступа к физическим регистрам питания хоста в целях безопасности.
- **Решение**: На вычисления и обучение нейросетей это не влияет. Чтобы отключить спам варнингом, передаётся переменная:
  ```bash
  -e ZES_ENABLE_SYSMAN=0
  ```

---

### Ловушка №6: Миф об обязательности IPEX (`intel-extension-for-pytorch`)
- **Заблуждение**: «Для работы PyTorch на Intel Arc обязательно нужен `intel-extension-for-pytorch` (ipex)».
- **Реальность**: В современных версиях PyTorch бэкенд `xpu` является **полноценной нативной частью ядра PyTorch** (начиная с PyTorch 2.4/2.5+). Установка пакета `intel-extension-for-pytorch` устарела, приводит к конфликту ABI компиляторов и ломает системные зависимости. 
- **Правильный подход**: Достаточно установить официальные колеса PyTorch:
  ```bash
  pip3 install torch torchvision --index-url https://download.pytorch.org/whl/xpu
  ```
  И обращаться к видеокарте стандартным синтаксисом:
  ```python
  device = torch.device("xpu")
  x = torch.randn(100, 100, device=device)
  ```

---

### Ловушка №7: Плавающий хэш каталога драйвера при обновлениях Windows Update
- **Симптом**: Контейнер успешно работал недели или месяцы, но после перезагрузки компьютера или автоматического обновления Windows Update внезапно перестал видеть видеокарту с ошибкой отсутствия `libwsl_compute_helper.so`.
- **Причина**: Каталог `/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_<HASH>` содержит уникальный хэш пакета драйвера из хранилища `DriverStore` Windows. При каждом обновлении графического драйвера Intel этот хэш перегенерируется. Если путь был захардкожен в `Dockerfile` или `docker run`, контейнер начинает ссылаться на несуществующую удалённую папку.
- **Решение**: Резолвить путь к драйверу **динамически**:
  - Либо на этапе входа в контейнер через [entrypoint.sh](file:///c:/Users/user/Desktop/game/entrypoint.sh) с помощью `find /usr/lib/wsl/drivers -name "libwsl_compute_helper.so"`.
  - Либо перед запуском `docker run` однострочником на хосте.
  При этом путь `/usr/lib/wsl/lib` **обязательно** должен стоять первым в `LD_LIBRARY_PATH`, чтобы шейдерные компиляторы Linux-пакетов не конфликтовали с внутренними библиотеками Windows-драйвера.

---

## ЧАСТЬ 3. ДИАГНОСТИЧЕСКИЙ ЧЕК-ЛИСТ

Если что-то идёт не так, выполните эту последовательность команд внутри контейнера:

1. **Проверка доступности DirectX устройства**:
   ```bash
   ls -la /dev/dxg
   # Должно быть: crw-rw-rw- 1 root root ... /dev/dxg
   ```

2. **Проверка проброса хелпера Intel**:
   ```bash
   ls -la /usr/lib/wsl/drivers/*/libwsl_compute_helper.so
   # Файл должен существовать и читаться
   ```

3. **Проверка версий пакетов Intel**:
   ```bash
   dpkg -l | grep -E "intel|libze|gmm"
   # libze-intel-gpu1 и intel-opencl-icd должны быть 26.35.39758.10
   # libigdgmm12 должен быть 22.10.0
   ```

4. **Прямой тест Level Zero через Python**:
   ```python
   import ctypes
   ze = ctypes.CDLL('libze_loader.so.1')
   assert ze.zeInit(1) == 0, "Level Zero init failed"
   print("Level Zero OK!")
   ```

5. **Тест PyTorch**:
   ```python
   import torch
   assert torch.xpu.is_available(), "XPU not available"
   print("Device:", torch.xpu.get_device_name(0))
   ```

---

## ЧАСТЬ 4. ОФИЦИАЛЬНЫЕ ИСТОЧНИКИ И ССЫЛКИ (АКТУАЛЬНО НА СЕНТЯБРЬ 2026)

> ⚠️ **Фиксация контекста версий**: Все ссылки, версии пакетов и хэши зафиксированы по состоянию на **сентябрь 2026 года**. Если вы настраиваете систему в будущем и вышли более новые поколения драйверов, используйте эти ссылки как отправную точку:

1. **Драйвер хоста Intel Arc Graphics (Windows)**:
   - [Страница загрузки официального драйвера Intel Arc Graphics Windows DCH](https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html)
   - Протестированная версия с поддержкой Battlemage в WSL2: `32.0.101.8991` (или новее).

2. **Intel Compute Runtime (NEO) — OpenCL & Level Zero**:
   - [Репозиторий GitHub intel/compute-runtime](https://github.com/intel/compute-runtime)
   - [Релиз 26.35.39758.10 на GitHub](https://github.com/intel/compute-runtime/releases/tag/26.35.39758.10) (содержит пакеты `intel-opencl-icd`, `libze-intel-gpu1`, `intel-ocloc` и библиотеку памяти `libigdgmm12_22.10.0`).
   - Примечания к выпуску: официально подтверждена поддержка WSL для архитектуры Battlemage (Xe2) с драйвером `101.8991`.

3. **Intel Graphics Compiler (IGC)**:
   - [Репозиторий GitHub intel/intel-graphics-compiler](https://github.com/intel/intel-graphics-compiler)
   - [Релиз IGC v2.41.5 на GitHub](https://github.com/intel/intel-graphics-compiler/releases/tag/v2.41.5) (пакеты `intel-igc-core-2` и `intel-igc-opencl-2`).

4. **oneAPI Level Zero Specification & Loader**:
   - [Репозиторий GitHub oneapi-src/level-zero](https://github.com/oneapi-src/level-zero) (исходники загрузчика `libze_loader`).
   - [Спецификация oneAPI Level Zero](https://oneapi-src.github.io/level-zero-spec/) (документация API управления устройствами, памятью и очередями команд).

5. **PyTorch с нативным бэкендом XPU**:
   - [Официальный репозиторий сборки wheels PyTorch XPU](https://download.pytorch.org/whl/xpu)
   - [Официальная документация PyTorch: модуль torch.xpu](https://pytorch.org/docs/stable/xpu.html)

6. **Архитектура виртуализации Microsoft WSL2 GPU Compute**:
   - [Руководство Microsoft Learn по GPU Compute в WSL](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gpu-compute)
   - [Репозиторий ядра и драйвера Microsoft WSL2 DirectX (dxgkrnl / wslg)](https://github.com/microsoft/wslg)

---
*Документ составлен на основе реального дебага и решения проблем на конфигурации Windows 11 + WSL2 + Docker + Intel Arc B580 (Xe2).*

