# Insectopedia App

Flutter mobile app for on-device agricultural pest identification. Runs a full three-stage inference pipeline (YOLO26 + RepViT-SAM + ResNet-18) entirely on-device with no network dependency.

The training pipeline and annotated dataset are maintained in separate repositories.

---

## Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Models](#models)
- [Dependencies](#dependencies)
- [Getting Started](#getting-started)
- [Related Components](#related-components)

---

## Overview

The app allows farmers and agronomists to photograph a pest and receive a species-level identification in seconds. The pipeline runs fully on-device using ONNX Runtime, preserving privacy and enabling offline use in field conditions.

Key features:

- Camera capture and image picker input
- Three-stage on-device inference: detection, segmentation, classification
- Human-in-the-loop (HITL) confirmation UI with retry loop
- SQLite inference logging for session history
- Light and dark theme toggle
- Localization support

---

## Requirements

- Flutter 3.13.0 or higher
- Dart SDK 3.0.0 or higher
- Android device or emulator (Android 10+ recommended)
- Tested on Xiaomi M2012K11AG (Android 15)

---

## Models

All models are bundled as ONNX assets and run via `onnxruntime`.

| Asset | Description |
|---|---|
| `yolo26.onnx` | Coarse bucket detector (9 classes) |
| `repvit_sam_encoder.onnx` | RepViT-SAM image encoder |
| `repvit_sam_decoder.onnx` | RepViT-SAM mask decoder |
| `rn18_tiny_pests.onnx` | Classifier: aphids, thrips, spider_mite |
| `rn18_flea_beetle.onnx` | Classifier: flea_beetle, grape_flea_beetle, striped_flea_beetle |
| `rn18_caterpillars.onnx` | Classifier: army_worm, black_cutworm, corn_borer |
| `rn18_plant_bugs.onnx` | Classifier: miridae, tarnished_plant_bug, four_lined_plant_bug |
| `rn18_soil_larvae.onnx` | Classifier: grub, wireworm |
| `rn18_weevils.onnx` | Classifier: alfalfa_weevil, strawberry_root_weevil |
| `rn18_stink_bugs.onnx` | Classifier: green_stink_bug, brown_marmorated_stink_bug |
| `rn18_blister_beetle.onnx` | Classifier: blister_beetle, black_blister_beetle, striped_blister_beetle |

Models are not included in this repository due to file size. Place ONNX files in `assets/models/` before building.

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `onnxruntime` | ^1.16.0 | On-device ONNX inference |
| `camera` | ^0.10.5+9 | Camera capture |
| `image_picker` | ^1.0.7 | Gallery image input |
| `image` | ^4.1.7 | Image preprocessing |
| `flutter_riverpod` | ^2.4.9 | State management |
| `google_fonts` | ^6.1.0 | Typography |
| `fl_chart` | ^0.66.2 | Result visualization |
| `lottie` | ^3.0.0 | Animations |
| `share_plus` | ^7.2.1 | Result sharing |
| `path_provider` | ^2.1.2 | File system access |
| `path` | ^1.9.0 | Path utilities |

---

## Getting Started

1. Clone the repository:
```bash
git clone https://github.com/Shafiul1711/Insectopedia-App.git
cd Insectopedia-App
```

2. Install dependencies:
```bash
flutter pub get
```

3. Place ONNX model files in `assets/models/`.

4. Connect an Android device or start an emulator, then run:
```bash
flutter run
```

---

## Related Components

| Component | Description |
|---|---|
| **Insectopedia Dataset** | Annotated image dataset for training and evaluation |
| **Insectopedia Pipeline** | Training scripts, inference tools, and model weights |
| **Insectopedia App** (this repo) | Flutter mobile app with on-device inference and HITL correction workflow |

---

Developed as part of a computer vision capstone project at the University of Windsor in collaboration with Local Greenhouse (2026).
