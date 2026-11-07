#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
configuration="${CLASSIFIER_CONFIGURATION:-Release}"
coverage=(-enableCodeCoverage "${CLASSIFIER_COVERAGE:-NO}")
if [[ "${CLASSIFIER_COVERAGE:-NO}" == YES ]]; then
  coverage+=('OTHER_SWIFT_FLAGS=$(inherited) -profile-generate -profile-coverage-mapping'
    'OTHER_LDFLAGS=$(inherited) -profile-generate')
fi
cd Classifier
# Explicit standard-library includes accommodate newer Apple libc++ releases.
xcodebuild -scheme SidePulseClassifier -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
  -configuration "$configuration" -derivedDataPath "$root/.build/classifier" \
  'OTHER_CPLUSPLUSFLAGS=$(inherited) -include exception -include algorithm' \
  "${coverage[@]}" build
