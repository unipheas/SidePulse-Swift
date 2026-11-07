#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Classifier"
xcodebuild -scheme SidePulseClassifier -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../.build/classifier -enableCodeCoverage YES \
  CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
  'OTHER_CPLUSPLUSFLAGS=$(inherited) -include exception -include algorithm' test
