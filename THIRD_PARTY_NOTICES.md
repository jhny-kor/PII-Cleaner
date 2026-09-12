# 제3자 구성요소 고지

- 설치파일은 저장소에 포함된 라이선스 보유 `schift-ko-pii-v7` 모델 스냅샷을 포함합니다. 원본 가중치는 Git 호스팅 파일 크기 제한에 맞춰 분할되며, 빌드 시 SHA-256 검증 후 복원됩니다. 모델의 `LICENSE*` 파일은 필수이며 설치된 모델 폴더에도 함께 복사됩니다.
- PySide6, PyInstaller, PyTorch, Transformers, Safetensors, Hugging Face Hub, `schift-ko-pii`와 그 의존성인 `ko-pii`는 각 구성요소의 라이선스에 따라 설치됩니다. 배포 전 해당 라이선스와 모델 배포 조건을 검토해야 합니다.

## 폐쇄망 문서 엔진

### Kordoc 4.13.1

`.hwp` HWP 5.x 파싱·패치에 [Kordoc 4.13.1](https://github.com/chrisryugj/kordoc)을 사용합니다. Kordoc 자체 코드는 [MIT License](https://github.com/chrisryugj/kordoc/blob/main/LICENSE)이며, 배포 tarball의 `LICENSE`, `NOTICE`, `THIRD_PARTY/`를 변경하지 않고 설치파일의 `engines\kordoc\node_modules\kordoc\`에 포함합니다.

빌드 입력은 `npm ci --omit=optional --ignore-scripts`로 만든 lockfile 고정 production tree입니다. 이번 앱은 Kordoc CLI의 HWP 파싱과 `patch`만 사용하고, PDF·이미지·OCR 선택 의존성(`@huggingface/transformers`, `@hyzyla/pdfium`, `onnxruntime-node`, `pdfjs-dist`, `sharp`)은 설치하지 않으며 `--ocr`·`--formula-ocr`도 호출하지 않습니다. `tools/verify-kordoc-runtime.mjs`가 Kordoc 버전, lockfile, 설치된 전체 production 의존성의 SPDX 표현식, 선택 의존성 미설치, 외부 symlink를 빌드 전에 검사합니다. JSZip의 이중 라이선스는 MIT 조건을 선택합니다.

Kordoc upstream `NOTICE`에는 Pix2Text 수식 OCR 구현과 그 기반인 Ultralytics YOLOv8의 AGPL-3.0 관련 검토 고지가 있습니다. 따라서 이 프로젝트는 해당 OCR 경로를 비활성화하지만, 표준 Kordoc 배포물의 고지만으로 상용·비공개 배포에 대한 법적 면제를 주장하지 않습니다. 배포 전 Kordoc `NOTICE`와 실제 포함 파일을 법무/오픈소스 담당자가 확인해야 하며, 수식 OCR 또는 이미지 OCR을 추가하면 별도 라이선스 승인이 필요합니다.

### Node.js

Kordoc을 실행하는 Node.js는 [공식 Node.js 배포물](https://github.com/nodejs/node/blob/main/LICENSE)의 MIT 조건과 배포물에 포함된 bundled component 고지를 따릅니다. 공식 Windows x64 런타임 디렉터리 전체를 `engines\node\`에 복사하고, 그 안의 `LICENSE`와 `README.md`를 삭제·변경하지 않습니다. 버전과 SHA-256은 폐쇄망 반입 기록에 고정합니다.

### LibreOffice

`.doc` → `.docx`, `.xls` → `.xlsx` 변환에는 [LibreOffice 공식 stable Windows x64 배포물](https://www.libreoffice.org/licenses/)을 사용합니다. LibreOffice는 [MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/)을 중심으로 여러 bundled component 라이선스가 함께 적용되므로 “MPL 하나”로 단순화하지 않습니다. 공식 설치 디렉터리 전체를 `engines\libreoffice\`에 포함하고, 원본 `LICENSE*`, `NOTICE*`, `readlicense*` 및 기타 고지를 보존합니다. 동일 버전의 소스 제공/고지 의무는 [LibreOffice 라이선스 안내](https://www.libreoffice.org/licenses/)와 실제 배포물의 라이선스 파일을 기준으로 릴리스마다 확인합니다.

이 세 런타임은 실행 중 npm 레지스트리, Hugging Face, webhook에 접근하지 않습니다. 앱은 Kordoc subprocess에 `KORDOC_OFFLINE=1`과 모델 오프라인 변수를 전달하며, 엔진 누락·변환 실패·HWP 재파싱 검증 실패 시 원본을 덮어쓰지 않습니다.

## schift-ko-pii-v7 모델

`schift-io/schift-ko-pii-v7` 모델 가중치와 모델 파일은 [Schift License v2.0](https://huggingface.co/schift-io/schift-ko-pii-v7/blob/main/LICENSE)의 적용을 받습니다. Copyright (c) 2026 Schift, Inc. (Room821 Co., Ltd.). 이 라이선스는 Apache License 2.0 기반이지만, 최근 완료 회계연도 기준 연 매출이 미화 1,000만 달러를 초과하는 법인의 상업적 사용에는 별도 상용 라이선스를 요구하는 추가 조건이 있습니다. 연구·교육·평가·개인 프로젝트·비영리 단체 사용은 매출과 무관하게 허용된다고 원문에 명시되어 있습니다.

이 프로젝트의 `Apache-2.0` 라이선스는 PII Cleaner의 자체 작성 코드·문서에만 적용되며, 모델에는 적용되지 않습니다. 모델을 포함하는 설치파일은 빌드에 사용한 스냅샷의 원본 `LICENSE*` 파일을 그대로 함께 배포해야 합니다. 모델 원본: <https://huggingface.co/schift-io/schift-ko-pii-v7>

## Flaticon 아이콘 저작자 표시

`Folder`, `File`, `Scanner`, `Shield`, `Power`, `Delete`, `Vision` 아이콘은 [AB Design](https://www.flaticon.com/authors/ab-design)이 Flaticon에 제공했습니다. Flaticon 무료 라이선스(저작자 표시 필요)에 따라 설치 프로그램의 이 고지에 출처를 포함합니다.

- [Folder](https://www.flaticon.com/free-icon/folder_13840477)
- [File](https://www.flaticon.com/free-icon/file_13840036)
- [Scanner](https://www.flaticon.com/free-icon/scanner_13839746)
- [Shield](https://www.flaticon.com/free-icon/shield_13840089)
- [Power](https://www.flaticon.com/free-icon/power_13840095)
- [Delete](https://www.flaticon.com/free-icon/delete_13840077)
- [Vision](https://www.flaticon.com/free-icon/vision_13839952)

## 제공 브랜딩 자산

`resources/icons/branding/`의 앱 아이콘과 워드마크는 프로젝트 사용자가 제공한 이미지에서 생성했습니다. 이 자산의 배포 권한은 제공자에게 확인해야 합니다.
