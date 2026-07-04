# 🎙️ Whisper Local

**Transcripción de voz 100% local para iPhone — optimizada para Neural Engine (A17 Pro)**

---

## ✨ Qué hace

- Transcribe audio a texto usando modelos Whisper directamente en tu iPhone
- Descarga nuevos modelos desde HuggingFace sin salir de la app
- Procesa archivos de **varias horas** sin problema (chunking automático)
- Exporta transcripciones en **6 formatos**: TXT, SRT, VTT, JSON, CSV, Markdown
- Todo se procesa localmente — **nada sale de tu iPhone**

## 🏗️ Arquitectura

```
WhisperLocal/
├── WhisperLocal.xcodeproj/          # Proyecto Xcode
├── Package.swift                    # SPM: WhisperKit dependency
├── WhisperLocal/
│   ├── WhisperLocalApp.swift        # App entry + AppState
│   ├── Models/
│   │   ├── Transcription.swift      # SwiftData model con segments embebidos
│   │   ├── DownloadedModel.swift    # Modelo descargado (persistencia)
│   │   └── HFModel.swift           # API response models de HuggingFace
│   ├── Services/
│   │   ├── HuggingFaceService.swift # Search, list files, download con streaming
│   │   ├── AudioProcessor.swift     # Conversión 16kHz PCM, chunking, duración
│   │   ├── TranscriptionEngine.swift # Orquestador: modelo + audio → resultado
│   │   ├── WhisperProcessor.swift   # Core ML inference: mel → encoder → decoder
│   │   ├── ModelManager.swift       # Gestión de modelos locales
│   │   └── ExportService.swift      # Exportación a 6 formatos
│   ├── Views/
│   │   ├── RootTabView.swift        # Tab bar
│   │   ├── TranscribeView.swift     # Vista principal de transcripción
│   │   ├── ModelsView.swift         # Buscar/descargar/gestionar modelos
│   │   ├── HistoryView.swift        # Historial + detalle con timestamps
│   │   ├── ExportSheet.swift        # Sheet de exportación
│   │   └── SettingsView.swift       # Ajustes + About
│   ├── Assets.xcassets/
│   └── Info.plist
└── README.md
```

## 🧠 Optimizaciones para Neural Engine (A17 Pro)

| Componente | Optimización |
|-----------|-------------|
| **Core ML** | `computeUnits = .cpuAndNeuralEngine` en todos los modelos |
| **Audio** | Conversión directa a 16kHz mono Float32 (formato nativo Whisper) |
| **FFT** | Accelerate framework (vDSP) para mel spectrogram |
| **Chunking** | Ventanas de 30s con 2s de overlap para no cortar palabras |
| **Largo alcance** | Archivos de horas se dividen automáticamente, timestamps globales correctos |
| **SwiftData** | Persistencia con segments serializados en Data (evita N+1 queries) |
| **AsyncStream** | Descargas con progreso en tiempo real via `AsyncThrowingStream` |

## 📱 Requisitos

- iOS 17.0+
- iPhone 12 o superior (recomendado: **iPhone 15 Pro** para Neural Engine dedicado)
- ~200MB de almacenamiento para el app + espacio para modelos

## 📦 Dependencias

- [WhisperKit](https://github.com/Argonormal/WhisperKit) (MIT) — Core ML Whisper para Apple Silicon

---

## 🔧 Instalación en iPhone SIN Mac

### Opción A: Sideloadly (Windows/Mac) — ⭐ Más fácil

1. **Descarga Sideloadly**: https://sideloadly.io
2. **Necesitas un .ipa** — ver sección "Compilar" abajo
3. Conecta iPhone por USB → abre Sideloadly
4. Arrastra el .ipa → introduce tu Apple ID → "Start"
5. En iPhone: **Ajustes → General → VPN y gestión de dispositivos → Confía**

### Opción B: AltStore

1. **Descarga AltServer**: https://altstore.io
2. Instala AltStore en tu iPhone (necesitas USB + Apple ID una vez)
3. Envía el .ipa a tu iPhone (email, AirDrop, Files...)
4. En AltStore → "My Apps" → "+" → selecciona el .ipa

### Opción C: TrollStore (solo iOS ≤17.0)

1. Instala TrollStore: https://github.com/opa334/TrollStore
2. Abre el .ipa con TrollStore → instalación sin firma

> ⚠️ **Importante**: TrollStore solo funciona en iOS 14.0–17.0. En iOS 17.0.1+ Apple parcheó el exploit. No intentes instalarlo en versiones superiores.

### ⚠️ Notas sobre sideloading

- Con **Apple ID gratuito**: la app caduca cada 7 días (reinstalar)
- Con **Apple Developer** ($99/año): dura 1 año
- AltStore renueva automáticamente si tu iPhone y PC están en la misma WiFi

---

## 🏭 Compilar el proyecto

### Si tienes acceso a un Mac (aunque sea prestado 10 min):

```bash
# 1. Abre en Xcode
open WhisperLocal.xcodeproj

# 2. En Xcode:
#    - Selecciona tu iPhone como destino
#    - Product → Archive
#    - Distribute App → Development
#    - Exporta el .ipa
```

### Sin Mac — GitHub Actions (gratis, 3000 min/mes):

1. Sube este proyecto a GitHub
2. Crea `.github/workflows/build.yml`:

```yaml
name: Build IPA
on: workflow_dispatch

jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      
      - name: Resolve packages
        run: xcodebuild -resolvePackageDependencies -project WhisperLocal.xcodeproj -scheme WhisperLocal
      
      - name: Build for iOS
        run: |
          xcodebuild -project WhisperLocal.xcodeproj \
            -scheme WhisperLocal \
            -sdk iphoneos \
            -configuration Release \
            -derivedDataPath build \
            -allowProvisioningUpdates \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO
      
      - name: Create IPA
        run: |
          mkdir -p Payload
          cp -r build/Build/Products/Release-iphoneos/WhisperLocal.app Payload/
          zip -r WhisperLocal.ipa Payload
      
      - name: Upload
        uses: actions/upload-artifact@v4
        with:
          name: WhisperLocal-IPA
          path: WhisperLocal.ipa
```

3. Ve a **Actions** → "Build IPA" → **Run workflow**
4. Descarga el `.ipa` del artifact
5. Sideloadea con Sideloadly o AltStore

### Sin Mac — Servicios cloud:

- **Codemagic.io** — 500 min/mes gratis, compila iOS sin Mac
- **MacInCloud** — Alquiler de Mac por horas desde $1/h

---

## 🎯 Uso

### 1. Descargar un modelo

Ve a la pestaña **Models** → toca el botón de descarga en cualquier modelo.

**Recomendados:**
| Modelo | Tamaño | Velocidad | Calidad |
|--------|--------|-----------|---------|
| whisper-tiny | ~75MB | ⚡⚡⚡ | ⭐⭐ |
| whisper-base | ~150MB | ⚡⚡ | ⭐⭐⭐ |
| **whisper-small** | ~500MB | ⚡ | ⭐⭐⭐⭐ |
| whisper-medium | ~1.5GB | 🐢 | ⭐⭐⭐⭐⭐ |
| whisper-large-v3 | ~3GB | 🐌 | ⭐⭐⭐⭐⭐ |

**Empieza con `whisper-small`** — buen balance entre calidad y velocidad.

### 2. Transcribir

1. Pestaña **Transcribe** → "Select Audio File"
2. Elige idioma (o "Auto-detect")
3. Selecciona "Transcribe" o "Translate" (a inglés)
4. "Start Transcription"
5. Espera — verás progreso en tiempo real

### 3. Exportar

1. En el resultado → "Export"
2. Elige formato (SRT para subtítulos, TXT para texto plano, JSON para datos...)
3. Comparte via AirDrop, email, Messages, Files...

---

## 📄 Formatos de exportación

| Formato | Extensión | Uso ideal |
|---------|-----------|-----------|
| Plain Text | .txt | Lectura rápida, copiar/pegar |
| SRT | .srt | Subtítulos para video (VLC, Premiere, YouTube) |
| WebVTT | .vtt | Subtítulos web (HTML5 video) |
| JSON | .json | Integración con otros apps/scripts |
| CSV | .csv | Análisis en Excel/Numbers |
| Markdown | .md | Documentación, blogs, Obsidian |

---

## 🔒 Privacidad

- **Cero llamadas de red** para transcripción
- Los modelos se descargan una vez desde HuggingFace y se almacenan localmente
- Audio y texto nunca salen del dispositivo
- Sin analytics, sin tracking, sin telemetría
- El app ni siquiera tiene permisos de red para la transcripción

---

## 📝 Licencia

MIT

---

## 🙏 Créditos

- [WhisperKit](https://github.com/Argonormal/WhisperKit) — Core ML Whisper
- [HuggingFace](https://huggingface.co) — Modelos y API
- [OpenAI Whisper](https://github.com/openai/whisper) — Modelo de transcripción
